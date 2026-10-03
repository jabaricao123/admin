-- pgTAP：report/002+003 —— report_allowed_views / report_definitions / run_report + 管理 RPC
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构/seed；白名单登记（admin/校验）；定义 CRUD 权限（owner/public/admin）；
--       RLS 可见性与无表级写；run_report 白名单外列被拒、值参数化（注入串当值处理）、
--       非 owner 执行 private 被拒、底层 security_invoker 视图 RLS 兜底。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(119);

-- 测试账号（seeds）：admin=1111...1111 / engineer=...0001 / planner=...0002
create temporary table fixture_ids (label text primary key, id uuid);
grant select on fixture_ids to authenticated;

-- ===========================================================================
-- 1. 结构：表 / 列 / PK / FK / check / RLS / 策略 / 授权 / 索引（32）
-- ===========================================================================
select has_table('public', 'report_allowed_views', 'report_allowed_views 表存在');
select has_table('public', 'report_definitions', 'report_definitions 表存在');

select has_column('public', 'report_allowed_views', 'view_name', 'allowed_views.view_name 存在');
select has_column('public', 'report_allowed_views', 'allowed_columns', 'allowed_views.allowed_columns 存在');
select has_column('public', 'report_allowed_views', 'registered_by', 'allowed_views.registered_by 存在');
select has_column('public', 'report_allowed_views', 'created_at', 'allowed_views.created_at 存在');

select has_column('public', 'report_definitions', 'name', 'definitions.name 存在');
select has_column('public', 'report_definitions', 'source_view', 'definitions.source_view 存在');
select has_column('public', 'report_definitions', 'config', 'definitions.config 存在');
select has_column('public', 'report_definitions', 'visibility', 'definitions.visibility 存在');
select has_column('public', 'report_definitions', 'owner_id', 'definitions.owner_id 存在');
select has_column('public', 'report_definitions', 'created_by', 'definitions.created_by 存在');
select has_column('public', 'report_definitions', 'updated_by', 'definitions.updated_by 存在');

select col_is_pk('public', 'report_allowed_views', 'view_name', 'allowed_views.view_name 为主键');
select col_is_pk('public', 'report_definitions', 'id', 'definitions.id 为主键');

select ok(
  exists (
    select 1
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public'
      and t.relname = 'report_definitions'
      and c.contype = 'f'
      and pg_get_constraintdef(c.oid) like '%report_allowed_views(view_name)%'
  ),
  'source_view 外键指向 report_allowed_views'
);
select ok(
  exists (
    select 1
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public'
      and t.relname = 'report_definitions'
      and c.contype = 'f'
      and pg_get_constraintdef(c.oid) like '%profiles(id)%'
  ),
  'owner_id 外键指向 profiles'
);

select throws_ok(
  $$ insert into public.report_definitions (name, source_view, config, visibility, owner_id)
     values ('x', 'departments_v', '{}'::jsonb, 'shared',
             '11111111-1111-1111-1111-111111111111') $$,
  '23514', null, 'visibility 非法取值被 check 拒绝'
);
select throws_ok(
  $$ insert into public.report_definitions (name, source_view, config, owner_id)
     values ('x', 'departments_v', '{"chart":"radar"}'::jsonb,
             '11111111-1111-1111-1111-111111111111') $$,
  '23514', null, 'chart 非法取值被 check 拒绝'
);
select throws_ok(
  $$ insert into public.report_definitions (name, source_view, config, owner_id)
     values ('   ', 'departments_v', '{}'::jsonb,
             '11111111-1111-1111-1111-111111111111') $$,
  '23514', null, '空白名称被 check 拒绝'
);
select throws_ok(
  $$ insert into public.report_definitions (name, source_view, config, owner_id)
     values ('x', 'no_such_view', '{}'::jsonb,
             '11111111-1111-1111-1111-111111111111') $$,
  '23503', null, '白名单外 source_view 被外键拒绝'
);
select throws_ok(
  $$ insert into public.report_allowed_views (view_name, allowed_columns)
     values ('bad name', '{"x":"text"}'::jsonb) $$,
  '23514', null, '白名单视图名不合法被 check 拒绝'
);
select throws_ok(
  $$ insert into public.report_allowed_views (view_name, allowed_columns)
     values ('empty_v', '{}'::jsonb) $$,
  '23514', null, 'allowed_columns 空对象被 check 拒绝'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.report_allowed_views'::regclass)
  and (select relrowsecurity from pg_class where oid = 'public.report_definitions'::regclass),
  '两张表均启用 RLS'
);
select is(
  (select count(*) from pg_policies
    where schemaname = 'public' and tablename = 'report_definitions'),
  3::bigint,
  'definitions 恰 3 条策略（owner/public/admin）'
);
select is(
  (select count(*) from pg_policies
    where schemaname = 'public' and tablename = 'report_allowed_views'),
  1::bigint,
  'allowed_views 恰 1 条策略（登录可读）'
);

select ok(
  not has_table_privilege('authenticated', 'public.report_definitions', 'insert')
  and not has_table_privilege('authenticated', 'public.report_definitions', 'update')
  and not has_table_privilege('authenticated', 'public.report_definitions', 'delete')
  and not has_table_privilege('authenticated', 'public.report_allowed_views', 'insert')
  and not has_table_privilege('authenticated', 'public.report_allowed_views', 'update')
  and not has_table_privilege('authenticated', 'public.report_allowed_views', 'delete'),
  '两表无 API 写权限（写全经 SECURITY DEFINER RPC）'
);
select ok(
  has_table_privilege('authenticated', 'public.report_definitions', 'select')
  and has_table_privilege('authenticated', 'public.report_allowed_views', 'select'),
  'authenticated 对两表仅有 SELECT'
);
select ok(
  not has_table_privilege('anon', 'public.report_definitions', 'select')
  and not has_table_privilege('anon', 'public.report_allowed_views', 'select'),
  'anon 无两表读权限'
);
select ok(
  not has_table_privilege('service_role', 'public.report_definitions', 'select')
  and not has_table_privilege('service_role', 'public.report_allowed_views', 'select'),
  'service_role 无两表读权限（全局禁 service_role）'
);

select has_index('public', 'report_definitions', 'report_definitions_owner_idx', '属主索引存在');
select has_index('public', 'report_definitions', 'report_definitions_public_idx', 'public 部分索引存在');

-- ===========================================================================
-- 2. seed 白名单（6）
-- ===========================================================================
select is(
  (select count(*) from public.report_allowed_views),
  2::bigint,
  'seed 恰 2 个白名单视图'
);
select is(
  (select count(*) from public.report_allowed_views where registered_by is null),
  2::bigint,
  'seed 行 registered_by 为 NULL（系统预置）'
);
select is(
  (select allowed_columns ->> 'name' from public.report_allowed_views where view_name = 'departments_v'),
  'text',
  'departments_v.name 类型登记为 text'
);
select is(
  (select allowed_columns ->> 'depth' from public.report_allowed_views where view_name = 'departments_v'),
  'integer',
  'departments_v.depth 类型登记为 integer'
);
select ok(
  (select allowed_columns ? 'path' and allowed_columns ? 'leader_id'
     from public.report_allowed_views where view_name = 'departments_v'),
  'departments_v 含 path / leader_id 列'
);
select is(
  (select string_agg(key, ',' order by key)
     from public.report_allowed_views, jsonb_each_text(allowed_columns)
    where view_name = 'audit_operations_v'),
  'action,actor_name,created_at,module,object_id,object_type',
  'audit_operations_v 列清单与规格一致（6 列）'
);

-- ===========================================================================
-- 3. 函数存在性 / security / 授权面（8）
-- ===========================================================================
select ok(
  (select count(*) = 11
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
      ('app', 'run_report'), ('public', 'run_report'),
      ('app', 'save_report_definition'), ('public', 'save_report_definition'),
      ('app', 'delete_report_definition'), ('public', 'delete_report_definition'),
      ('app', 'publish_report_definition'), ('public', 'publish_report_definition'),
      ('app', 'register_allowed_view'), ('public', 'register_allowed_view')
    )
      or (n.nspname = 'app' and p.proname = 'validate_report_config')),
  'run_report / save / delete / publish / register_allowed_view / validate 共 11 个函数齐备'
);
select ok(
  (select count(*) = 2
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where p.proname = 'run_report'
      and n.nspname in ('app', 'public')
      and not p.prosecdef
      and p.proconfig @> array['search_path=""']),
  'run_report（app + public）均为 SECURITY INVOKER + search_path 固定为空'
);
select ok(
  (select count(*) = 5
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname in (
        'save_report_definition', 'delete_report_definition',
        'publish_report_definition', 'register_allowed_view', 'validate_report_config')
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '管理 RPC 为 SECURITY DEFINER + search_path 固定为空'
);
select ok(
  has_function_privilege('authenticated', 'public.run_report(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.save_report_definition(uuid,text,text,jsonb)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.delete_report_definition(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.publish_report_definition(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.register_allowed_view(text,jsonb)', 'EXECUTE'),
  'authenticated 可执行 5 个 public 用户 RPC'
);
select ok(
  not has_function_privilege('authenticated', 'app.save_report_definition(uuid,text,text,jsonb)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.delete_report_definition(uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.publish_report_definition(uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.register_allowed_view(text,jsonb)', 'EXECUTE'),
  '管理实现不直接对 authenticated 开放（INDEX 规则 10）'
);
select ok(
  has_function_privilege('authenticated', 'app.run_report(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'app.validate_report_config(text,jsonb)', 'EXECUTE'),
  'invoker 链路例外：app.run_report / validate 对 authenticated 开放（否则 RLS 链断裂）'
);
select ok(
  not has_function_privilege('anon', 'public.run_report(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.save_report_definition(uuid,text,text,jsonb)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.register_allowed_view(text,jsonb)', 'EXECUTE'),
  'anon 无用户 RPC 执行权'
);
select ok(
  not has_function_privilege('service_role', 'public.run_report(uuid)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.save_report_definition(uuid,text,text,jsonb)', 'EXECUTE'),
  'service_role 无用户 RPC 执行权（全局禁令）'
);

-- ===========================================================================
-- 4. register_allowed_view：admin 校验 / upsert / 审计（10）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.register_allowed_view('audit_denied_v', '{"module":"text"}'::jsonb) $$,
  '42501', '仅管理员可登记白名单视图', '非 admin 登记白名单被拒'
);
reset role;

select set_config('request.jwt.claims', '{}', true);
set local role authenticated;
select throws_ok(
  $$ select public.register_allowed_view('audit_denied_v', '{"module":"text"}'::jsonb) $$,
  '42501', null, '未登录登记白名单被拒'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.register_allowed_view('no_such_view', '{"module":"text"}'::jsonb) $$,
  'P0002', null, '不存在的视图被拒'
);
select throws_ok(
  $$ select public.register_allowed_view('departments_v', '{"BadCol":"text"}'::jsonb) $$,
  '22023', null, '列名不合法被拒'
);
select throws_ok(
  $$ select public.register_allowed_view('departments_v', '{"name":"json"}'::jsonb) $$,
  '22023', null, '列类型不在枚举内被拒'
);
select lives_ok(
  $$ select public.register_allowed_view('audit_denied_v',
       '{"user_name":"text","module":"text","route":"text","reason":"text","time":"timestamptz"}'::jsonb) $$,
  'admin 登记新视图成功'
);
select is(
  (select registered_by from public.report_allowed_views where view_name = 'audit_denied_v'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  '登记人记录为 admin'
);
select lives_ok(
  $$ select public.register_allowed_view('audit_denied_v', '{"module":"text"}'::jsonb) $$,
  '重复登记走 upsert 更新列清单'
);
reset role;
select is(
  (select string_agg(key, ',' order by key)
     from jsonb_each_text((select allowed_columns from public.report_allowed_views where view_name = 'audit_denied_v'))),
  'module',
  'upsert 后 allowed_columns 已更新'
);
select ok(
  (select count(*) > 0 from public.audit_operations
    where module = 'report' and action = 'register' and object_type = 'report_allowed_view'),
  '登记白名单写审计摘要'
);

-- ===========================================================================
-- 5. save_report_definition：owner 校验 / config 白名单（16）
--    夹具：engineer 建 d_eng_priv；admin 建 d_admin_priv
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.save_report_definition(null, '工程私有', 'departments_v',
       '{"dimensions":["name"],"metrics":[{"column":"depth","agg":"sum"}],"filters":[],"chart":"bar"}'::jsonb) $$,
  'engineer 新建报表定义成功'
);
select is(
  (select visibility || '/' || (owner_id = '22222222-2222-2222-2222-222222220001'::uuid)::text
     from public.report_definitions where name = '工程私有'),
  'private/true',
  '新建定义 visibility=private 且 owner=调用者'
);
select throws_ok(
  $$ select public.save_report_definition(null, '  ', 'departments_v',
       '{"dimensions":["name"],"metrics":[],"filters":[],"chart":"table"}'::jsonb) $$,
  '22023', '报表名称不能为空', '空白名称被拒'
);
select throws_ok(
  $$ select public.save_report_definition(null, 'x', 'no_such_view',
       '{"dimensions":["name"],"metrics":[],"filters":[],"chart":"table"}'::jsonb) $$,
  '42501', null, '白名单外数据源被拒'
);
select throws_ok(
  $$ select public.save_report_definition(null, 'x', 'departments_v',
       '{"dimensions":["name; drop table public.profiles"],"metrics":[],"filters":[],"chart":"table"}'::jsonb) $$,
  '42501', null, '白名单外维度（注入串）被拒'
);
select throws_ok(
  $$ select public.save_report_definition(null, 'x', 'departments_v',
       '{"dimensions":["name"],"metrics":[{"column":"depth","agg":"median"}],"filters":[],"chart":"table"}'::jsonb) $$,
  '22023', null, '不支持的聚合被拒'
);
select throws_ok(
  $$ select public.save_report_definition(null, 'x', 'departments_v',
       '{"dimensions":["name"],"metrics":[{"column":"name","agg":"sum"}],"filters":[],"chart":"table"}'::jsonb) $$,
  '22023', null, 'sum 作用于非数值列被拒'
);
select throws_ok(
  $$ select public.save_report_definition(null, 'x', 'departments_v',
       '{"dimensions":["name"],"metrics":[],"filters":[],"chart":"radar"}'::jsonb) $$,
  '22023', null, '非法 chart 被拒'
);
select throws_ok(
  $$ select public.save_report_definition(null, 'x', 'departments_v',
       '{"dimensions":["name"],"metrics":[],"filters":[{"column":"status","op":"regexp","value":"a"}],"chart":"table"}'::jsonb) $$,
  '22023', null, '不支持的筛选操作符被拒'
);
select throws_ok(
  $$ select public.save_report_definition(null, 'x', 'departments_v',
       '{"dimensions":["name"],"metrics":[],"filters":[{"column":"id","op":"=","value":"1"}],"chart":"table"}'::jsonb) $$,
  '42501', null, '白名单外筛选列被拒'
);
select lives_ok(
  $$ select public.save_report_definition(
       (select id from public.report_definitions where name = '工程私有'),
       '工程私有', 'departments_v',
       '{"dimensions":["name"],"metrics":[],"filters":[],"chart":"line","extra":"drop"}'::jsonb) $$,
  'owner 更新定义成功（白名单内）'
);
select is(
  (select config ? 'extra' or visibility <> 'private'
     from public.report_definitions where name = '工程私有'),
  false,
  'config 仅保留契约键且 visibility 不被 save 改动'
);
reset role;

insert into fixture_ids (label, id)
select 'eng_priv', id from public.report_definitions where name = '工程私有';
insert into fixture_ids (label, id)
select 'sum_def', id from public.report_definitions where name = '工程私有';

-- 非 owner 更新被拒
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220002","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.save_report_definition(
       (select id from fixture_ids where label = 'eng_priv'),
       '被改名', 'departments_v',
       '{"dimensions":["name"],"metrics":[],"filters":[],"chart":"table"}'::jsonb) $$,
  '42501', null, '非 owner 更新被拒'
);
select throws_ok(
  $$ select public.delete_report_definition((select id from fixture_ids where label = 'eng_priv')) $$,
  '42501', null, '非 owner 删除被拒'
);
reset role;

-- admin 更新他人定义
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.save_report_definition(
       (select id from fixture_ids where label = 'eng_priv'),
       '工程私有(管理员改名)', 'departments_v',
       '{"dimensions":["name"],"metrics":[],"filters":[],"chart":"table"}'::jsonb) $$,
  'admin 可更新他人定义'
);
reset role;
select ok(
  (select count(*) > 0 from public.audit_operations
    where module = 'report' and action = 'save' and object_type = 'report_definition'),
  '保存定义写审计摘要'
);

-- ===========================================================================
-- 6. RLS：可见性与无表级写（11）
--     夹具：engineer 建 d_pub 并由 admin 发布；admin 建 d_admin_priv
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.save_report_definition(null, '公开报表', 'departments_v',
       '{"dimensions":["status"],"metrics":[{"column":"name","agg":"count"}],"filters":[],"chart":"pie"}'::jsonb) $$,
  '夹具：engineer 新建待发布定义'
);
reset role;
insert into fixture_ids (label, id)
select 'pub_def', id from public.report_definitions where name = '公开报表';

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.save_report_definition(null, '管理员私有', 'audit_operations_v',
       '{"dimensions":["module"],"metrics":[{"column":"action","agg":"count"}],"filters":[],"chart":"bar"}'::jsonb) $$,
  '夹具：admin 新建私有定义'
);
select lives_ok(
  $$ select public.publish_report_definition((select id from fixture_ids where label = 'pub_def')) $$,
  'admin 发布 public 报表'
);
reset role;
insert into fixture_ids (label, id)
select 'admin_priv', id from public.report_definitions where name = '管理员私有';

-- owner 可见自己的 private
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select ok(
  exists (select 1 from public.report_definitions
           where id = (select id from fixture_ids where label = 'eng_priv')),
  'RLS：owner 可见自己的 private 定义'
);
select ok(
  not exists (select 1 from public.report_definitions
               where id = (select id from fixture_ids where label = 'admin_priv')),
  'RLS：engineer 不可见 admin 的 private 定义'
);
select ok(
  exists (select 1 from public.report_definitions
           where id = (select id from fixture_ids where label = 'pub_def')),
  'RLS：public 定义全员可见'
);
select throws_ok(
  $$ insert into public.report_definitions (name, source_view, config, owner_id)
     values ('直插', 'departments_v', '{}'::jsonb,
             '22222222-2222-2222-2222-222222220001') $$,
  '42501', null, '表级无写授权（owner 直插被拒）'
);
select throws_ok(
  $$ insert into public.report_allowed_views (view_name, allowed_columns)
     values ('hack_v', '{"x":"text"}'::jsonb) $$,
  '42501', null, '白名单表级无写授权（直插被拒）'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220002","role":"authenticated"}',
  true
);
set local role authenticated;
select ok(
  not exists (select 1 from public.report_definitions
               where id = (select id from fixture_ids where label = 'eng_priv')),
  'RLS：planner 不可见他人 private 定义'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select ok(
  exists (select 1 from public.report_definitions
           where id = (select id from fixture_ids where label = 'admin_priv'))
  and exists (select 1 from public.report_definitions
               where id = (select id from fixture_ids where label = 'eng_priv')),
  'RLS：admin 全量可见'
);
reset role;

select set_config('request.jwt.claims', '{}', true);
set local role anon;
select throws_ok(
  $$ select count(*) from public.report_definitions $$,
  '42501', null, 'anon 直读定义表被拒'
);
reset role;

-- ===========================================================================
-- 7. run_report：执行权限 / 白名单 / 值参数化 / RLS 兜底（27）
-- ===========================================================================
-- 夹具：audit 公开定义（admin 建后发布）+ 注入值定义 + 篡改定义
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.save_report_definition(null, '操作活跃度', 'audit_operations_v',
       '{"dimensions":["module"],"metrics":[{"column":"action","agg":"count"}],"filters":[],"chart":"bar"}'::jsonb) $$,
  '夹具：audit 报表定义'
);
reset role;
insert into fixture_ids (label, id)
select 'audit_def', id from public.report_definitions where name = '操作活跃度';
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.publish_report_definition((select id from fixture_ids where label = 'audit_def')) $$,
  '夹具：发布 audit 报表'
);
reset role;

-- owner 执行自己的 private：结构与数值
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.run_report((select id from fixture_ids where label = 'eng_priv')) $$,
  'owner 执行自己的 private 定义成功'
);
select is(
  (public.run_report((select id from fixture_ids where label = 'eng_priv')) -> 'chart'),
  '"table"'::jsonb,
  'run_report 返回 chart（更新后的 table）'
);
select results_eq(
  $$ select jsonb_array_length(public.run_report((select id from fixture_ids where label = 'eng_priv')) -> 'rows') $$,
  $$ values (6) $$,
  'departments_v 维度 name 聚合出 6 行'
);
reset role;

-- sum 度量数值正确（seed 部门 depth 合计 = 14）
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
-- 恢复一个 sum 定义（此前更新把度量去掉了）
select lives_ok(
  $$ select public.save_report_definition(
       (select id from fixture_ids where label = 'sum_def'),
       '工程合计', 'departments_v',
       '{"dimensions":[],"metrics":[{"column":"depth","agg":"sum"}],"filters":[],"chart":"table"}'::jsonb) $$,
  'metric-only（无维度）配置保存成功'
);
select is(
  (public.run_report((select id from fixture_ids where label = 'sum_def'))
     #> '{rows,0,sum_depth}'),
  '14'::jsonb,
  'sum(depth) 聚合值正确（14）'
);
select is(
  (public.run_report((select id from fixture_ids where label = 'sum_def')) -> 'columns'),
  '["sum_depth"]'::jsonb,
  'metric-only 的 columns 仅含度量别名'
);
reset role;

-- 筛选：= / in / between / like
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.save_report_definition(null, '筛选等于', 'departments_v',
       '{"dimensions":[],"metrics":[{"column":"name","agg":"count"}],
         "filters":[{"column":"status","op":"=","value":"active"}],"chart":"table"}'::jsonb) $$,
  '= 筛选定义保存成功'
);
select is(
  (public.run_report((select id from public.report_definitions where name = '筛选等于'))
     #>> '{rows,0,count_name}'),
  '6',
  '= 筛选按值过滤（active 部门 6 个）'
);
select lives_ok(
  $$ select public.save_report_definition(null, '筛选in', 'departments_v',
       '{"dimensions":["name"],"metrics":[],
         "filters":[{"column":"depth","op":"in","value":[2,3]}],"chart":"table"}'::jsonb) $$,
  'in 筛选定义保存成功'
);
select is(
  (select jsonb_array_length(public.run_report(id) -> 'rows')
     from public.report_definitions where name = '筛选in'),
  5,
  'in 筛选命中 5 行（depth 2/3）'
);
select lives_ok(
  $$ select public.save_report_definition(null, '筛选between', 'departments_v',
       '{"dimensions":["name"],"metrics":[],
         "filters":[{"column":"depth","op":"between","value":[1,2]}],"chart":"table"}'::jsonb) $$,
  'between 筛选定义保存成功'
);
select is(
  (select jsonb_array_length(public.run_report(id) -> 'rows')
     from public.report_definitions where name = '筛选between'),
  3,
  'between 筛选命中 3 行（depth 1/2）'
);
select lives_ok(
  $$ select public.save_report_definition(null, '筛选like', 'departments_v',
       '{"dimensions":["name"],"metrics":[],
         "filters":[{"column":"path","op":"like","value":"总部/%"}],"chart":"table"}'::jsonb) $$,
  'like 筛选定义保存成功'
);
select is(
  (select jsonb_array_length(public.run_report(id) -> 'rows')
     from public.report_definitions where name = '筛选like'),
  5,
  'like 筛选命中 5 行（path 前缀）'
);

-- 注入尝试：值只当数据
select lives_ok(
  $$ select public.save_report_definition(null, '注入值', 'departments_v',
       '{"dimensions":["name"],"metrics":[],
         "filters":[{"column":"name","op":"=","value":"x'' OR ''1''=''1"}],"chart":"table"}'::jsonb) $$,
  '注入尝试字符串作为筛选值保存（当值处理）'
);
select is(
  (select public.run_report(id) -> 'rows' from public.report_definitions where name = '注入值'),
  '[]'::jsonb,
  '注入串不被当作 SQL：返回 0 行而非全量'
);
select lives_ok(
  $$ select public.save_report_definition(null, '注入值2', 'departments_v',
       '{"dimensions":["name"],"metrics":[],
         "filters":[{"column":"name","op":"=","value":"''); drop table public.profiles; --"}],"chart":"table"}'::jsonb) $$,
  '第二条注入串作为筛选值保存'
);
select is(
  (select public.run_report(id) -> 'rows' from public.report_definitions where name = '注入值2'),
  '[]'::jsonb,
  '注入串仍只当值：返回 0 行且无错误'
);

-- 非 owner 执行 private：authenticated 视角被 RLS 隐藏（P0002）
reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220002","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.run_report((select id from fixture_ids where label = 'eng_priv')) $$,
  'P0002', null, '非 owner 执行 private 被拒（定义不可见）'
);
reset role;

-- 显式复检：postgres（RLS 绕过）直接执行 private 也拒
select throws_ok(
  $$ select app.run_report((select id from fixture_ids where label = 'eng_priv')) $$,
  '42501', '无权执行该报表定义',
  '显式 owner/public/admin 复检兜底（definer 视角也被拒）'
);

-- 未知 / 空 ID
select throws_ok(
  $$ select public.run_report('00000000-0000-0000-0000-0000000000ee') $$,
  'P0002', null, '不存在的定义报 P0002'
);
select throws_ok(
  $$ select public.run_report(null) $$,
  '22023', '报表 ID 不能为空', '空 ID 报 22023'
);

-- 执行时复检：直改库塞入白名单外列 → 执行被拒
insert into public.report_definitions (name, source_view, config, visibility, owner_id)
values ('篡改定义', 'departments_v',
        '{"dimensions":["name","evil; drop table public.profiles"],"metrics":[],"filters":[],"chart":"table"}'::jsonb,
        'private', '22222222-2222-2222-2222-222222220001');
insert into fixture_ids (label, id)
select 'tampered', id from public.report_definitions where name = '篡改定义';
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.run_report((select id from fixture_ids where label = 'tampered')) $$,
  '42501', null, '直改库绕过保存校验的定义，执行时仍被白名单拒绝'
);
reset role;

-- RLS 兜底：同一 public 定义，admin 有数、engineer 无（audit_operations_v 仅 admin）
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select ok(
  (select jsonb_array_length(public.run_report(id) -> 'rows') > 0
     from public.report_definitions where name = '操作活跃度'),
  'admin 执行 audit 报表：底层 RLS 放行（有数据）'
);
reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select public.run_report(id) -> 'rows'
     from public.report_definitions where name = '操作活跃度'),
  '[]'::jsonb,
  'engineer 执行同一 public 报表：RLS 兜底过滤为空'
);
reset role;

-- ===========================================================================
-- 8. delete / publish（9）
-- ===========================================================================
-- 非 admin 发布被拒
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.publish_report_definition((select id from fixture_ids where label = 'eng_priv')) $$,
  '42501', '仅管理员可发布公共报表', '非 admin 发布被拒'
);
reset role;

-- owner 删除自己的定义
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.delete_report_definition((select id from fixture_ids where label = 'sum_def')) $$,
  'owner 删除自己的定义成功'
);
reset role;
select ok(
  not exists (select 1 from public.report_definitions
               where id = (select id from fixture_ids where label = 'sum_def')),
  '删除后定义不存在'
);

-- admin 删除他人定义（另建一条，避免与 owner 删除用例同 id）
insert into public.report_definitions (name, source_view, config, visibility, owner_id)
values ('待管理员删除', 'departments_v',
        '{"dimensions":["name"],"metrics":[],"filters":[],"chart":"table"}'::jsonb,
        'private', '22222222-2222-2222-2222-222222220001');
insert into fixture_ids (label, id)
select 'eng_del', id from public.report_definitions where name = '待管理员删除';

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.delete_report_definition((select id from fixture_ids where label = 'eng_del')) $$,
  'admin 可删除他人定义'
);
reset role;
select ok(
  not exists (select 1 from public.report_definitions
               where id = (select id from fixture_ids where label = 'eng_del')),
  'admin 删除后定义不存在'
);
select ok(
  (select count(*) > 0 from public.audit_operations
    where module = 'report' and action = 'delete' and object_type = 'report_definition'),
  '删除定义写审计摘要'
);
select ok(
  (select visibility = 'public' from public.report_definitions
    where id = (select id from fixture_ids where label = 'pub_def')),
  'publish 后 visibility=public'
);

-- 发布后的定义：非 owner 可执行
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220002","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.run_report((select id from fixture_ids where label = 'pub_def')) $$,
  '发布后非 owner 可执行 public 定义'
);
reset role;
select ok(
  (select count(*) > 0 from public.audit_operations
    where module = 'report' and action = 'publish' and object_type = 'report_definition'),
  '发布写审计摘要'
);

select * from finish();
rollback;
