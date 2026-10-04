-- pgTAP：report/004 补齐 —— unpublish_report_definition（admin 取消发布公共报表）
-- 运行：supabase db reset && supabase test db
-- 覆盖：函数存在性 / security definer + search_path / 授权面；admin 取消发布（幂等、审计、
--       updated_by 回写）；非 admin 被拒；取消发布后 RLS 收窄（非 owner 不可见，owner 仍可见可执行）。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(22);

-- 测试账号（seeds）：admin=1111...1111 / engineer=...0001 / planner=...0002
create temporary table fixture_ids (label text primary key, id uuid);
grant select on fixture_ids to authenticated;

-- ===========================================================================
-- 1. 函数存在性 / security / 授权面（8）
-- ===========================================================================
select has_function('app', 'unpublish_report_definition', array['uuid'],
  'app.unpublish_report_definition(uuid) 存在');
select has_function('public', 'unpublish_report_definition', array['uuid'],
  'public.unpublish_report_definition(uuid) 存在');

select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'unpublish_report_definition'),
  'app 实现为 SECURITY DEFINER + search_path 固定为空'
);
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'unpublish_report_definition'),
  'public 包装为 SECURITY DEFINER + search_path 固定为空'
);
select ok(
  has_function_privilege('authenticated', 'public.unpublish_report_definition(uuid)', 'EXECUTE'),
  'authenticated 可执行 public 包装'
);
select ok(
  not has_function_privilege('authenticated', 'app.unpublish_report_definition(uuid)', 'EXECUTE'),
  'app 实现不直接对 authenticated 开放（INDEX 规则 10）'
);
select ok(
  not has_function_privilege('anon', 'public.unpublish_report_definition(uuid)', 'EXECUTE'),
  'anon 无执行权'
);
select ok(
  not has_function_privilege('service_role', 'public.unpublish_report_definition(uuid)', 'EXECUTE'),
  'service_role 无执行权（全局禁令）'
);

-- ===========================================================================
-- 2. 夹具：engineer 建定义 → admin 发布（2）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select public.save_report_definition(null, '取消发布测试', 'departments_v',
  '{"dimensions":["name"],"metrics":[],"filters":[],"chart":"table"}'::jsonb);
reset role;
insert into fixture_ids (label, id)
select 'unpub_def', id from public.report_definitions where name = '取消发布测试';

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.publish_report_definition((select id from fixture_ids where label = 'unpub_def')) $$,
  '夹具：admin 发布该定义为公共报表'
);
reset role;
select ok(
  (select visibility = 'public' from public.report_definitions
    where id = (select id from fixture_ids where label = 'unpub_def')),
  '夹具确认：visibility=public'
);

-- ===========================================================================
-- 3. 非 admin 被拒（2）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select count(*) from public.report_definitions
    where id = (select id from fixture_ids where label = 'unpub_def')),
  1::bigint,
  '发布后非 owner 可见（public 策略）'
);
select throws_ok(
  $$ select public.unpublish_report_definition((select id from fixture_ids where label = 'unpub_def')) $$,
  '42501', '仅管理员可取消发布公共报表',
  '非 admin 取消发布被拒'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220002","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.unpublish_report_definition((select id from fixture_ids where label = 'unpub_def')) $$,
  '42501', '仅管理员可取消发布公共报表',
  '另一非 admin（planner）取消发布也被拒'
);
reset role;

-- ===========================================================================
-- 4. admin 取消发布：幂等 / 审计 / RLS 收窄（8）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.unpublish_report_definition((select id from fixture_ids where label = 'unpub_def')) $$,
  'admin 取消发布成功'
);
reset role;
select ok(
  (select visibility = 'private' and updated_by = '11111111-1111-1111-1111-111111111111'
     from public.report_definitions
    where id = (select id from fixture_ids where label = 'unpub_def')),
  '取消发布后 visibility=private 且 updated_by 回写 admin'
);
select ok(
  (select count(*) > 0 from public.audit_operations
    where module = 'report' and action = 'unpublish'
      and object_type = 'report_definition'
      and object_id = (select id from fixture_ids where label = 'unpub_def')::text),
  '取消发布写审计摘要（action=unpublish）'
);

-- 取消发布后：非 owner 不可见（RLS 收窄），owner 仍可见可执行
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220002","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select count(*) from public.report_definitions
    where id = (select id from fixture_ids where label = 'unpub_def')),
  0::bigint,
  '取消发布后非 owner 不可见（RLS 收窄）'
);
select throws_ok(
  $$ select public.run_report((select id from fixture_ids where label = 'unpub_def')) $$,
  'P0002', null,
  '取消发布后非 owner 执行被拒（定义不可见）'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select count(*) from public.report_definitions
    where id = (select id from fixture_ids where label = 'unpub_def')),
  1::bigint,
  '取消发布后 owner 仍可见自己的私有报表'
);
select lives_ok(
  $$ select public.run_report((select id from fixture_ids where label = 'unpub_def')) $$,
  'owner 仍可执行已取消发布的报表'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.unpublish_report_definition((select id from fixture_ids where label = 'unpub_def')) $$,
  '重复取消发布幂等（不报错）'
);
select throws_ok(
  $$ select public.unpublish_report_definition('00000000-0000-0000-0000-0000000000ee') $$,
  'P0002', '报表定义不存在',
  '不存在的定义报 P0002'
);
reset role;

select * from finish();
rollback;
