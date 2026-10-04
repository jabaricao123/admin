-- pgTAP：report 批次 1 安全与正确性修复
-- 覆盖：
--   1. register_allowed_view：普通视图/matview/表登记被拒；列不存在/类型不匹配/null 类型被拒；
--      security_invoker 视图可登记且 upsert 幂等；存量 seed（departments_v/audit_operations_v）复验通过。
--   2. run_report：in 按列声明类型比较（timestamptz ISO 串命中、数值列字符串/数字元素均命中）；
--      注入字符串仍只当值（文本列 0 行、数值列报类型转换错误，均不执行 SQL）。
--   3. app.csv_field：= + - @ Tab CR 公式前缀中和；正常文本与 RFC 4180 转义不回归。
--   4. delete_report_definition：有订阅（含逻辑删）拒绝并报数；无订阅正常删除。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(43);

create temporary table fix_ids (label text primary key, id uuid);
grant select on fix_ids to authenticated;

-- 修复项 1 夹具：普通视图（无 security_invoker）/ 物化视图 / security_invoker 视图 / 表
create view public.rpt_plain_v as select 1::integer as num;
create materialized view public.rpt_mat_v as select 1::integer as num;
create view public.rpt_invoker_v
with (security_invoker = true)
as select 1::integer as num, 'a'::text as name;
create table public.rpt_tbl (num integer);

-- ===========================================================================
-- 1. register_allowed_view：security_invoker 守卫 + 列存在/类型/null 校验（11）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$ select public.register_allowed_view('rpt_plain_v', '{"num":"integer"}'::jsonb) $$,
  '42501',
  '仅允许 security_invoker 视图，防止 RLS 绕过：public.rpt_plain_v 未设置 security_invoker=true',
  '普通视图（无 security_invoker）登记被拒'
);
select throws_ok(
  $$ select public.register_allowed_view('rpt_mat_v', '{"num":"integer"}'::jsonb) $$,
  '42501',
  '仅允许 security_invoker 视图，防止 RLS 绕过：public.rpt_mat_v 是物化视图',
  '物化视图登记被拒（不继承底层 RLS）'
);
select throws_ok(
  $$ select public.register_allowed_view('rpt_tbl', '{"num":"integer"}'::jsonb) $$,
  'P0002',
  'public.rpt_tbl 不存在或不是视图',
  '非视图对象（表）登记被拒'
);
select throws_ok(
  $$ select public.register_allowed_view('rpt_invoker_v', '{"nope":"integer"}'::jsonb) $$,
  '22023',
  '列不存在：public.rpt_invoker_v.nope',
  'allowed_columns 中不存在的列被拒'
);
select throws_ok(
  $$ select public.register_allowed_view('rpt_invoker_v', '{"num":"text"}'::jsonb) $$,
  '22023',
  '列类型不匹配：public.rpt_invoker_v.num（视图实际 integer，登记 text）',
  '列声明类型与视图实际类型不一致被拒'
);
select throws_ok(
  $$ select public.register_allowed_view('rpt_invoker_v', '{"name":null}'::jsonb) $$,
  '22023',
  '不支持的列类型：NULL',
  'null 类型值被拒（C-3：原判断 NULL 放行）'
);
select lives_ok(
  $$ select public.register_allowed_view('rpt_invoker_v', '{"num":"integer","name":"text"}'::jsonb) $$,
  'security_invoker 视图且列类型一致，登记成功'
);
select is(
  (select allowed_columns from public.report_allowed_views where view_name = 'rpt_invoker_v'),
  '{"num":"integer","name":"text"}'::jsonb,
  '登记后 allowed_columns 落表正确'
);
select lives_ok(
  $$ select public.register_allowed_view('rpt_invoker_v', '{"num":"integer","name":"text"}'::jsonb) $$,
  '重复登记走 upsert（幂等）成功'
);
select lives_ok(
  $$ select public.register_allowed_view('departments_v',
       '{"name":"text","path":"text","depth":"integer","status":"text","sort_order":"integer","leader_id":"uuid","created_at":"timestamptz"}'::jsonb) $$,
  '存量 seed departments_v 复验通过（security_invoker + 列类型一致）'
);
select lives_ok(
  $$ select public.register_allowed_view('audit_operations_v',
       '{"module":"text","action":"text","actor_name":"text","object_type":"text","object_id":"text","created_at":"timestamptz"}'::jsonb) $$,
  '存量 seed audit_operations_v 复验通过（security_invoker + 列类型一致）'
);
reset role;

-- ===========================================================================
-- 2. run_report：in 按列声明类型比较 + 注入串仍当值（13）
-- ===========================================================================
-- 前置：固定 created_at 的审计行，验证 timestamptz 的 ISO 串比较
insert into public.audit_operations (module, action, object_type, created_at)
values ('rpt_fix2', 'created', 'fixture', '2026-02-03 04:05:06+00');

select ok(
  (select created_at::text <> '2026-02-03T04:05:06Z'
     from public.audit_operations where module = 'rpt_fix2'),
  '夹具前提：created_at 的 ::text 与 ISO 串不同（原文本比较必为 0 行）'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$ select public.save_report_definition(null, '数值in文本元素', 'departments_v',
       '{"dimensions":["name"],"metrics":[],"filters":[{"column":"depth","op":"in","value":["2","3"]}],"chart":"table"}'::jsonb) $$,
  'in 元素为字符串的数值列定义保存成功'
);
select is(
  (select jsonb_array_length(public.run_report(id) -> 'rows')
     from public.report_definitions where name = '数值in文本元素'),
  5,
  '数值列 in 字符串元素按 integer 转换后命中 5 行（depth 2/3）'
);
select lives_ok(
  $$ select public.save_report_definition(null, '数值in数字元素', 'departments_v',
       '{"dimensions":["name"],"metrics":[],"filters":[{"column":"depth","op":"in","value":[1,2]}],"chart":"table"}'::jsonb) $$,
  'in 元素为数字的数值列定义保存成功'
);
select is(
  (select jsonb_array_length(public.run_report(id) -> 'rows')
     from public.report_definitions where name = '数值in数字元素'),
  3,
  '数值列 in 数字元素命中 3 行（depth 1/2，回归）'
);
select lives_ok(
  $$ select public.save_report_definition(null, '文本in注入', 'departments_v',
       '{"dimensions":["name"],"metrics":[],"filters":[{"column":"name","op":"in","value":["x''); drop table public.profiles; --"]}],"chart":"table"}'::jsonb) $$,
  '文本列 in 注入串作为元素保存（仅当值）'
);
select is(
  (select public.run_report(id) -> 'rows'
     from public.report_definitions where name = '文本in注入'),
  '[]'::jsonb,
  '注入串仍只当值：文本列返回 0 行而非全量'
);
select lives_ok(
  $$ select public.save_report_definition(null, '数值in注入', 'departments_v',
       '{"dimensions":["name"],"metrics":[],"filters":[{"column":"depth","op":"in","value":["1; drop table public.profiles"]}],"chart":"table"}'::jsonb) $$,
  '数值列 in 注入串作为元素保存（保存期不校验元素取值）'
);
select throws_ok(
  $$ select public.run_report((select id from public.report_definitions where name = '数值in注入')) $$,
  '22P02', null,
  '数值列注入串报类型转换错误（fail closed，不执行 SQL）'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$ select public.save_report_definition(null, '日期inISO', 'audit_operations_v',
       '{"dimensions":["module"],"metrics":[],"filters":[{"column":"created_at","op":"in","value":["2026-02-03T04:05:06Z"]}],"chart":"table"}'::jsonb) $$,
  'timestamptz 列 in ISO 串定义保存成功'
);
select is(
  (select jsonb_array_length(public.run_report(id) -> 'rows')
     from public.report_definitions where name = '日期inISO'),
  1,
  'timestamptz in 常见 ISO 日期格式命中 1 行（原 ::text 比较为 0 行）'
);
select is(
  (select public.run_report(id) #>> '{rows,0,module}'
     from public.report_definitions where name = '日期inISO'),
  'rpt_fix2',
  '命中行为夹具审计行'
);
reset role;

select has_table('public', 'profiles', '注入尝试未执行 SQL：profiles 表仍在');

-- ===========================================================================
-- 3. app.csv_field：CSV 公式注入中和 + 转义不回归（14）
-- ===========================================================================
select is(
  app.csv_field('=HYPERLINK("http://evil","x")'),
  '"''' || '=HYPERLINK(""http://evil"",""x"")' || '"',
  '= 开头公式被前缀单引号中和（引号/逗号转义仍生效）'
);
select is(app.csv_field('=1+1'), '''=1+1', '= 开头字段加单引号前缀');
select is(app.csv_field('+1'), '''+1', '+ 开头字段加单引号前缀');
select is(app.csv_field('-1'), '''-1', '- 开头字段加单引号前缀');
select is(app.csv_field('@SUM(A1)'), '''@SUM(A1)', '@ 开头字段加单引号前缀');
select is(
  app.csv_field(chr(9) || 'x'),
  '''' || chr(9) || 'x',
  'Tab 开头字段加单引号前缀'
);
select is(
  app.csv_field(chr(13) || 'x'),
  '"''' || chr(13) || 'x"',
  'CR 开头字段加单引号前缀（含 CR 仍按 RFC 4180 加引号）'
);
select is(app.csv_field(null), '', 'NULL 仍输出空字段');
select is(app.csv_field('normal text'), 'normal text', '正常文本不受影响');
select is(app.csv_field('a,b'), '"a,b"', '含逗号字段仍加双引号（回归）');
select is(app.csv_field('say "hi"'), '"say ""hi"""', '引号翻倍规则不回归');
select is(
  app.csv_field('l1' || chr(10) || 'l2'),
  '"l1' || chr(10) || 'l2"',
  '含换行字段仍加双引号（回归）'
);
select is(app.csv_line(array['=1', 'a,b']), '''=1,"a,b"', 'csv_line 组合：中和 + 转义');
select is(
  app.csv_encode(array['col'], array[array['=x', 'b']]),
  'col' || chr(10) || '''=x,b',
  'csv_encode 全链路：表头 + 数据行公式中和'
);

-- ===========================================================================
-- 4. delete_report_definition：订阅引用预检（5）
-- ===========================================================================
insert into public.report_definitions (name, source_view, config, visibility, owner_id)
values ('订阅删除守卫', 'departments_v',
        '{"dimensions":["name"],"metrics":[],"filters":[],"chart":"table"}'::jsonb,
        'private', '22222222-2222-2222-2222-222222220001');
insert into fix_ids (label, id)
select 'sub_guard', id from public.report_definitions where name = '订阅删除守卫';
insert into public.report_subscriptions
  (report_def_id, cron_expr, created_by, is_deleted, status)
values
  ((select id from fix_ids where label = 'sub_guard'), '0 * * * *',
   '22222222-2222-2222-2222-222222220001', false, 'active'),
  ((select id from fix_ids where label = 'sub_guard'), '0 9 * * 1',
   '22222222-2222-2222-2222-222222220001', true, 'disabled');

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.delete_report_definition((select id from fix_ids where label = 'sub_guard')) $$,
  'P0001',
  '该报表仍有 2 条订阅记录（含已删除订阅），无法删除',
  'owner 删除有订阅（含逻辑删）的报表被拒且报数'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.delete_report_definition((select id from fix_ids where label = 'sub_guard')) $$,
  'P0001',
  '该报表仍有 2 条订阅记录（含已删除订阅），无法删除',
  'admin 删除有订阅的报表同样被拒'
);
reset role;

select ok(
  exists (select 1 from public.report_definitions
           where id = (select id from fix_ids where label = 'sub_guard')),
  '删除被拒后定义仍在'
);

delete from public.report_subscriptions
 where report_def_id = (select id from fix_ids where label = 'sub_guard');
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.delete_report_definition((select id from fix_ids where label = 'sub_guard')) $$,
  '无订阅后正常删除成功'
);
reset role;

select ok(
  not exists (select 1 from public.report_definitions
               where id = (select id from fix_ids where label = 'sub_guard')),
  '无订阅删除后定义不存在'
);

select * from finish();
rollback;
