-- pgTAP：dashboard/001+004 — get_dashboard_stats / signup_trend（工作台统计与注册趋势）
-- 运行：supabase db reset && supabase test db
-- 覆盖：函数存在与安全属性（SECURITY DEFINER + search_path 固定）；GRANT 面（authenticated 可执行、
--       anon 拒绝；批 2 起 app 实现层对 authenticated/service_role 收口 EXECUTE）；
--       admin 全量分支（用户总数/本周新增/活跃用户与 profiles 表口径一致）；与 org_stats 的
--       收敛 parity（admin/非 admin 各一条）；本人待办数（不串号、不泄露全局计数、无待办为 0；
--       批 2 起 205 条 pending 验证无 200 封顶）；性能索引存在性；
--       signup_trend 天数边界（默认 30 / 0→1 / 999→365）与逐日计数与 profiles 表一致；非 admin 空集。
-- 说明：待办夹具直插 approval 实例/任务（测试事务内，rollback）；
--       模板/流程复用 seed 004（demo.leave）；夹具只在本事务内生效，finish 后 rollback。

begin;

select plan(42);

-- ---------------------------------------------------------------------------
-- 夹具：3 个账号（admin / engineer / planner）+ 4 个实例与任务（4b 另加批量账号与 205 实例）
--   admin   ：2 条 pending + 1 条已办（不应计入）
--   engineer：1 条 pending
--   planner ：0 条
-- created_at 拉开：admin 今天 / engineer 3 天前 / planner 10 天前
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
  ('dddddddd-dddd-4ddd-8ddd-dddddddddd01', 'dash-admin@example.com',
   '{"provider":"email","providers":["email"]}', '{"full_name":"工作台管理员"}'),
  ('dddddddd-dddd-4ddd-8ddd-dddddddddd02', 'dash-eng@example.com',
   '{"provider":"email","providers":["email"]}', '{"full_name":"工作台工程师"}'),
  ('dddddddd-dddd-4ddd-8ddd-dddddddddd03', 'dash-planner@example.com',
   '{"provider":"email","providers":["email"]}', '{"full_name":"工作台计划员"}');

update public.profiles
   set role = 'admin'::public.user_role
 where id = 'dddddddd-dddd-4ddd-8ddd-dddddddddd01';

update public.profiles
   set created_at = now() - interval '3 days'
 where id = 'dddddddd-dddd-4ddd-8ddd-dddddddddd02';

update public.profiles
   set created_at = now() - interval '10 days'
 where id = 'dddddddd-dddd-4ddd-8ddd-dddddddddd03';

insert into public.approval_instances
  (id, title, module, ref_type, ref_id, template_version_id, flow_version_id, form_data, initiator_id)
values
  ('dddddddd-dddd-4ddd-8ddd-ddddddddd101', '管理员待办 A', 'demo', 'demo_leave', 'dash-a',
   '44444444-4444-4444-4444-444444444401', '44444444-4444-4444-4444-444444444402',
   '{"title":"管理员待办 A","days":1,"reason":"测试"}'::jsonb,
   'dddddddd-dddd-4ddd-8ddd-dddddddddd02'),
  ('dddddddd-dddd-4ddd-8ddd-ddddddddd102', '管理员待办 B', 'demo', 'demo_leave', 'dash-b',
   '44444444-4444-4444-4444-444444444401', '44444444-4444-4444-4444-444444444402',
   '{"title":"管理员待办 B","days":2,"reason":"测试"}'::jsonb,
   'dddddddd-dddd-4ddd-8ddd-dddddddddd02'),
  ('dddddddd-dddd-4ddd-8ddd-ddddddddd103', '管理员已办', 'demo', 'demo_leave', 'dash-c',
   '44444444-4444-4444-4444-444444444401', '44444444-4444-4444-4444-444444444402',
   '{"title":"管理员已办","days":1,"reason":"测试"}'::jsonb,
   'dddddddd-dddd-4ddd-8ddd-dddddddddd02'),
  ('dddddddd-dddd-4ddd-8ddd-ddddddddd104', '工程师待办', 'demo', 'demo_leave', 'dash-d',
   '44444444-4444-4444-4444-444444444401', '44444444-4444-4444-4444-444444444402',
   '{"title":"工程师待办","days":1,"reason":"测试"}'::jsonb,
   'dddddddd-dddd-4ddd-8ddd-dddddddddd01');

insert into public.approval_tasks (id, instance_id, seq, assignee_id, status, acted_at) values
  ('dddddddd-dddd-4ddd-8ddd-ddddddddd201', 'dddddddd-dddd-4ddd-8ddd-ddddddddd101', 1,
   'dddddddd-dddd-4ddd-8ddd-dddddddddd01', 'pending', null),
  ('dddddddd-dddd-4ddd-8ddd-ddddddddd202', 'dddddddd-dddd-4ddd-8ddd-ddddddddd102', 1,
   'dddddddd-dddd-4ddd-8ddd-dddddddddd01', 'pending', null),
  ('dddddddd-dddd-4ddd-8ddd-ddddddddd203', 'dddddddd-dddd-4ddd-8ddd-ddddddddd103', 1,
   'dddddddd-dddd-4ddd-8ddd-dddddddddd01', 'approved', now()),
  ('dddddddd-dddd-4ddd-8ddd-ddddddddd204', 'dddddddd-dddd-4ddd-8ddd-ddddddddd104', 1,
   'dddddddd-dddd-4ddd-8ddd-dddddddddd02', 'pending', null);

-- ===========================================================================
-- 1. 结构与安全属性（14）
-- ===========================================================================
select has_function('app', 'get_dashboard_stats', 'app.get_dashboard_stats 存在');
select has_function('public', 'get_dashboard_stats', 'public.get_dashboard_stats 薄包装存在');
select has_function('app', 'signup_trend', array['integer'], 'app.signup_trend 存在');
select has_function('public', 'signup_trend', array['integer'], 'public.signup_trend 薄包装存在');

select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = 'get_dashboard_stats'
      and p.prosecdef
      and p.proconfig @> array['search_path=""']
  ),
  'app.get_dashboard_stats 为 SECURITY DEFINER 且 search_path 固定为空'
);
select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = 'signup_trend'
      and p.prosecdef
      and p.proconfig @> array['search_path=""']
  ),
  'app.signup_trend 为 SECURITY DEFINER 且 search_path 固定为空'
);
select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('get_dashboard_stats', 'signup_trend')
      and p.prosecdef
      and p.proconfig @> array['search_path=""']
    having count(*) = 2
  ),
  'public 薄包装均为 SECURITY DEFINER 且 search_path 固定为空'
);
select ok(
  has_function_privilege('authenticated', 'public.get_dashboard_stats()', 'EXECUTE'),
  'authenticated 可执行 public.get_dashboard_stats'
);
select ok(
  has_function_privilege('authenticated', 'public.signup_trend(integer)', 'EXECUTE'),
  'authenticated 可执行 public.signup_trend'
);
select ok(
  not has_function_privilege('anon', 'public.get_dashboard_stats()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.signup_trend(integer)', 'EXECUTE'),
  'anon 不可执行两个公开 RPC'
);
select ok(
  not has_function_privilege('authenticated', 'app.get_dashboard_stats()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.signup_trend(integer)', 'EXECUTE')
  and not has_function_privilege('service_role', 'app.get_dashboard_stats()', 'EXECUTE')
  and not has_function_privilege('service_role', 'app.signup_trend(integer)', 'EXECUTE'),
  'app 实现层对 authenticated/service_role 已收口 EXECUTE（只经 public 薄包装）'
);

select has_index('public', 'profiles', 'profiles_created_at_idx',
  'profiles(created_at) 索引存在');
select has_index('public', 'profiles', 'profiles_status_idx',
  'profiles(status) 索引存在');
select has_index('public', 'audit_row_versions', 'audit_row_versions_changed_at_idx',
  'audit_row_versions(changed_at desc, id desc) 索引存在');

-- ===========================================================================
-- 2. admin 分支：全量计数与表口径一致 + 本人待办（6）
-- ===========================================================================
set local request.jwt.claims = '{"sub":"dddddddd-dddd-4ddd-8ddd-dddddddddd01","role":"authenticated"}';
set local role authenticated;

select is(
  (public.get_dashboard_stats() ->> 'is_admin')::boolean,
  true,
  'admin 调用 is_admin=true'
);
select is(
  (public.get_dashboard_stats() ->> 'total_users')::bigint,
  (select count(*) from public.profiles),
  '用户总数与 profiles 全量计数一致'
);
select is(
  (public.get_dashboard_stats() ->> 'new_this_week')::bigint,
  (select count(*) from public.profiles p where p.created_at >= date_trunc('week', now())),
  '本周新增与 profiles 口径一致（ISO 周起点）'
);
select is(
  (public.get_dashboard_stats() ->> 'active_users')::bigint,
  (select count(*) from public.profiles p where p.status = 'active'),
  '活跃用户与 profiles 口径一致'
);
select is(
  (public.get_dashboard_stats() ->> 'pending_todos')::bigint,
  2::bigint,
  'admin 待办数=本人 2 条（已办与他人任务不计入）'
);
select is(
  public.get_dashboard_stats(),
  public.org_stats(),
  'admin：get_dashboard_stats 委托 org_stats 返回一致（收敛）'
);

-- ===========================================================================
-- 3. 非 admin 分支（engineer）：只见本人统计、不泄露全量计数（8）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"dddddddd-dddd-4ddd-8ddd-dddddddddd02","role":"authenticated"}';
set local role authenticated;

select is(
  (public.get_dashboard_stats() ->> 'is_admin')::boolean,
  false,
  '非 admin 调用 is_admin=false'
);
select ok(
  not (public.get_dashboard_stats() ? 'total_users'),
  '非 admin 返回不含 total_users'
);
select ok(
  not (public.get_dashboard_stats() ? 'new_this_week'),
  '非 admin 返回不含 new_this_week'
);
select ok(
  not (public.get_dashboard_stats() ? 'active_users'),
  '非 admin 返回不含 active_users'
);
select is(
  (select count(*) from jsonb_object_keys(public.get_dashboard_stats() -> 'own')),
  1::bigint,
  '非 admin own 仅 1 个键'
);
select ok(
  public.get_dashboard_stats() -> 'own' ? 'pending_todos',
  '非 admin own.pending_todos 存在'
);
select is(
  (public.get_dashboard_stats() -> 'own' ->> 'pending_todos')::bigint,
  1::bigint,
  '非 admin 待办数=本人 1 条（不串 admin 的 2 条）'
);
select is(
  public.get_dashboard_stats(),
  public.org_stats(),
  '非 admin：get_dashboard_stats 委托 org_stats 返回一致（收敛）'
);

-- ===========================================================================
-- 4. 非 admin 分支（planner）：无待办为 0（1）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"dddddddd-dddd-4ddd-8ddd-dddddddddd03","role":"authenticated"}';
set local role authenticated;

select is(
  (public.get_dashboard_stats() -> 'own' ->> 'pending_todos')::bigint,
  0::bigint,
  '无待办用户 own.pending_todos=0'
);

-- ===========================================================================
-- 4b. 待办数无封顶：205 条 pending（旧实现 my_todos limit 200 会封顶）（2）
-- ===========================================================================
reset role;

insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
  ('dddddddd-dddd-4ddd-8ddd-dddddddddd04', 'dash-bulk@example.com',
   '{"provider":"email","providers":["email"]}', '{"full_name":"批量待办用户"}');

insert into public.approval_instances
  (id, title, module, ref_type, ref_id, template_version_id, flow_version_id,
   form_data, initiator_id)
select
  gen_random_uuid(),
  '批量待办 ' || g,
  'demo', 'demo_leave', 'dash-bulk-' || g,
  '44444444-4444-4444-4444-444444444401',
  '44444444-4444-4444-4444-444444444402',
  jsonb_build_object('title', '批量待办 ' || g, 'days', 1, 'reason', '测试'),
  '11111111-1111-1111-1111-111111111111'
from generate_series(1, 205) as g;

insert into public.approval_tasks (instance_id, seq, assignee_id, status, acted_at)
select i.id, 1, 'dddddddd-dddd-4ddd-8ddd-dddddddddd04', 'pending', null
from public.approval_instances i
where i.ref_id like 'dash-bulk-%';

set local request.jwt.claims = '{"sub":"dddddddd-dddd-4ddd-8ddd-dddddddddd04","role":"authenticated"}';
set local role authenticated;

select is(
  (public.org_stats() -> 'own' ->> 'pending_todos')::bigint,
  205::bigint,
  'org_stats 待办数=205（无 200 封顶）'
);
select is(
  (public.get_dashboard_stats() -> 'own' ->> 'pending_todos')::bigint,
  205::bigint,
  'get_dashboard_stats 待办数=205（无 200 封顶）'
);

-- ===========================================================================
-- 5. signup_trend：admin 天数边界与逐日计数（8）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"dddddddd-dddd-4ddd-8ddd-dddddddddd01","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*) from public.signup_trend(7)),
  7::bigint,
  'p_days=7 返回 7 行（零值补齐）'
);
select is(
  (select min(day) from public.signup_trend(7)),
  ((now() at time zone 'UTC')::date - 6),
  'p_days=7 起始日为今天-6'
);
select is(
  (select max(day) from public.signup_trend(7)),
  ((now() at time zone 'UTC')::date),
  'p_days=7 结束日为今天'
);
select results_eq(
  $$ select day, count from public.signup_trend(7) order by day $$,
  $$ select g.d::date as day,
            (select count(*) from public.profiles p
              where (p.created_at at time zone 'UTC')::date = g.d::date) as count
       from generate_series(
              (now() at time zone 'UTC')::date - 6,
              (now() at time zone 'UTC')::date,
              interval '1 day'
            ) as g(d)
      order by g.d::date $$,
  '近 7 天逐日计数与 profiles 表口径一致'
);
select is(
  (select count(*) from public.signup_trend(0)),
  1::bigint,
  'p_days=0 夹取为 1 行'
);
select is(
  (select day from public.signup_trend(0)),
  (now() at time zone 'UTC')::date,
  'p_days=0 返回今天一行'
);
select is(
  (select count(*) from public.signup_trend(999)),
  365::bigint,
  'p_days=999 夹取为 365 行'
);
select is(
  (select count(*) from public.signup_trend()),
  30::bigint,
  'p_days 默认 30 行'
);

-- ===========================================================================
-- 6. signup_trend：非 admin 返回空集（1）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"dddddddd-dddd-4ddd-8ddd-dddddddddd02","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*) from public.signup_trend(30)),
  0::bigint,
  '非 admin 注册趋势返回空集（不泄露全量计数）'
);

-- ===========================================================================
-- 7. anon 无执行权限（2）
-- ===========================================================================
reset role;
set local role anon;

select throws_ok(
  $$ select public.get_dashboard_stats() $$,
  '42501', null,
  'anon 无 get_dashboard_stats 执行权限'
);
select throws_ok(
  $$ select * from public.signup_trend(7) $$,
  '42501', null,
  'anon 无 signup_trend 执行权限'
);

reset role;

select * from finish();
rollback;
