-- pgTAP：org/013 — org_stats() / signup_trend() / department_headcount() 公开 RPC
-- 运行：supabase db reset && supabase test db
-- 覆盖：三函数存在性与安全属性（SECURITY DEFINER + search_path 空）、GRANT 面
--       （authenticated 可执行、anon 拒绝）；org_stats admin/own 两支（不泄露全量计数）；
--       signup_trend 天数边界与逐日计数、非 admin 空集；department_headcount 含子部门
--       聚合正确（父子部门 + 成员：id 路径 / 文本兜底 / inactive / disabled 部门与岗位 /
--       deleted 部门隐藏）、登录可读。
-- 说明：待办夹具直插 approval 实例/任务（测试事务内 rollback）；模板/流程复用 seed 004
--       （demo.leave）。department_headcount 断言按夹具 id 前缀过滤，避免受 seed 部门影响。

begin;

select plan(46);

-- ===========================================================================
-- 1. 结构与安全属性（10）
-- ===========================================================================
select has_function('app', 'org_stats', 'app.org_stats 存在');
select has_function('public', 'org_stats', 'public.org_stats 薄包装存在');
select has_function('app', 'signup_trend', array['integer'], 'app.signup_trend 存在');
select has_function('public', 'signup_trend', array['integer'], 'public.signup_trend 薄包装存在');
select has_function('app', 'department_headcount', 'app.department_headcount 存在');
select has_function('public', 'department_headcount', 'public.department_headcount 薄包装存在');

select ok(
  (select count(*) = 3
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname in ('org_stats', 'signup_trend', 'department_headcount')
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '三个 app 实现均为 SECURITY DEFINER 且 search_path 固定为空'
);
select ok(
  (select count(*) = 3
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('org_stats', 'signup_trend', 'department_headcount')
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '三个 public 薄包装均为 SECURITY DEFINER 且 search_path 固定为空'
);
select ok(
  has_function_privilege('authenticated', 'public.org_stats()', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.signup_trend(integer)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.department_headcount()', 'EXECUTE'),
  'authenticated 可执行三个公开 RPC'
);
select ok(
  not has_function_privilege('anon', 'public.org_stats()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.signup_trend(integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.department_headcount()', 'EXECUTE'),
  'anon 不可执行三个公开 RPC'
);

-- ===========================================================================
-- 2. 夹具（as postgres 写入）
--    部门树：总部 → 研发 → {前端, 外包(disabled)}；行政(根)；已删(根, deleted)
--    用户：u1 研发 active / u2 前端 active / u3 文本兜底(外包 disabled，id=NULL)
--          / u4 行政 inactive / u5 无部门 / u6 总部直属 / u7 已删部门
--    岗位：研发岗3 / 前端岗2 / 行政岗1 / 停用岗5(研发, disabled)
--    待办：admin 1 条 pending、u1 1 条 pending
-- ===========================================================================
insert into public.departments (id, name, parent_id, sort_order, status, created_by)
values
  ('aa000000-0000-4000-8000-000000000001', '测试-总部', null, 1, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('aa000000-0000-4000-8000-000000000002', '测试-研发',
   'aa000000-0000-4000-8000-000000000001', 1, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('aa000000-0000-4000-8000-000000000003', '测试-前端',
   'aa000000-0000-4000-8000-000000000002', 1, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('aa000000-0000-4000-8000-000000000004', '测试-行政', null, 2, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('aa000000-0000-4000-8000-000000000005', '测试-外包',
   'aa000000-0000-4000-8000-000000000002', 3, 'disabled',
   '11111111-1111-1111-1111-111111111111'),
  ('aa000000-0000-4000-8000-000000000006', '测试-已删', null, 4, 'deleted',
   '11111111-1111-1111-1111-111111111111');

insert into public.positions
  (id, name, code, department_id, headcount, status, created_by, updated_by)
values
  ('ab000000-0000-4000-8000-000000000001', '测试-研发岗', 'TEST-ORG-STATS-1',
   'aa000000-0000-4000-8000-000000000002', 3, 'active',
   '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111'),
  ('ab000000-0000-4000-8000-000000000002', '测试-前端岗', 'TEST-ORG-STATS-2',
   'aa000000-0000-4000-8000-000000000003', 2, 'active',
   '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111'),
  ('ab000000-0000-4000-8000-000000000003', '测试-行政岗', 'TEST-ORG-STATS-3',
   'aa000000-0000-4000-8000-000000000004', 1, 'active',
   '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111'),
  ('ab000000-0000-4000-8000-000000000004', '测试-停用岗', 'TEST-ORG-STATS-4',
   'aa000000-0000-4000-8000-000000000002', 5, 'disabled',
   '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111');

insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
  ('ac000000-0000-4000-8000-000000000001', 'org-stats-u1@example.com',
   '{}'::jsonb, '{"full_name":"统计用户一"}'),
  ('ac000000-0000-4000-8000-000000000002', 'org-stats-u2@example.com',
   '{}'::jsonb, '{"full_name":"统计用户二"}'),
  ('ac000000-0000-4000-8000-000000000003', 'org-stats-u3@example.com',
   '{}'::jsonb, '{"full_name":"统计用户三"}'),
  ('ac000000-0000-4000-8000-000000000004', 'org-stats-u4@example.com',
   '{}'::jsonb, '{"full_name":"统计用户四"}'),
  ('ac000000-0000-4000-8000-000000000005', 'org-stats-u5@example.com',
   '{}'::jsonb, '{"full_name":"统计用户五"}'),
  ('ac000000-0000-4000-8000-000000000006', 'org-stats-u6@example.com',
   '{}'::jsonb, '{"full_name":"统计用户六"}'),
  ('ac000000-0000-4000-8000-000000000007', 'org-stats-u7@example.com',
   '{}'::jsonb, '{"full_name":"统计用户七"}');

-- 部门归属（触发器回写文本；u3 文本=disabled 部门名，解析不到 active → id 保持 NULL，
-- 用于覆盖 department_headcount 的文本兜底口径）
update public.profiles set department_id = 'aa000000-0000-4000-8000-000000000002'
 where id = 'ac000000-0000-4000-8000-000000000001';
update public.profiles set department_id = 'aa000000-0000-4000-8000-000000000003'
 where id = 'ac000000-0000-4000-8000-000000000002';
update public.profiles set department = '测试-外包'
 where id = 'ac000000-0000-4000-8000-000000000003';
update public.profiles set department_id = 'aa000000-0000-4000-8000-000000000004',
                          status = 'inactive'
 where id = 'ac000000-0000-4000-8000-000000000004';
update public.profiles set department_id = 'aa000000-0000-4000-8000-000000000001'
 where id = 'ac000000-0000-4000-8000-000000000006';
update public.profiles set department_id = 'aa000000-0000-4000-8000-000000000006'
 where id = 'ac000000-0000-4000-8000-000000000007';

insert into public.approval_instances
  (id, title, module, ref_type, ref_id, template_version_id, flow_version_id, form_data, initiator_id)
values
  ('ad000000-0000-4000-8000-000000000101', '统计待办-管理员', 'demo', 'demo_leave', 'org-stats-a',
   '44444444-4444-4444-4444-444444444401', '44444444-4444-4444-4444-444444444402',
   '{"title":"统计待办-管理员","days":1,"reason":"测试"}'::jsonb,
   '11111111-1111-1111-1111-111111111111'),
  ('ad000000-0000-4000-8000-000000000102', '统计待办-用户一', 'demo', 'demo_leave', 'org-stats-b',
   '44444444-4444-4444-4444-444444444401', '44444444-4444-4444-4444-444444444402',
   '{"title":"统计待办-用户一","days":1,"reason":"测试"}'::jsonb,
   '11111111-1111-1111-1111-111111111111');

insert into public.approval_tasks (id, instance_id, seq, assignee_id, status, acted_at) values
  ('ad000000-0000-4000-8000-000000000201', 'ad000000-0000-4000-8000-000000000101', 1,
   '11111111-1111-1111-1111-111111111111', 'pending', null),
  ('ad000000-0000-4000-8000-000000000202', 'ad000000-0000-4000-8000-000000000102', 1,
   'ac000000-0000-4000-8000-000000000001', 'pending', null);

-- ===========================================================================
-- 3. org_stats：admin 分支（8）
-- ===========================================================================
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select is(
  (public.org_stats() ->> 'is_admin')::boolean,
  true,
  'admin 调用 is_admin=true'
);
select is(
  (public.org_stats() ->> 'total_users')::bigint,
  (select count(*) from public.profiles),
  'total_users 与 profiles 全量计数一致'
);
select is(
  (public.org_stats() ->> 'new_this_week')::bigint,
  (select count(*) from public.profiles p where p.created_at >= date_trunc('week', now())),
  'new_this_week 与 profiles 口径一致（ISO 周起点）'
);
select is(
  (public.org_stats() ->> 'active_users')::bigint,
  (select count(*) from public.profiles p where p.status = 'active'),
  'active_users 与 profiles 口径一致'
);
select is(
  (public.org_stats() ->> 'total_departments')::bigint,
  (select count(*) from public.departments d where d.status <> 'deleted'),
  'total_departments 与 departments 口径一致（不含 deleted）'
);
select is(
  (public.org_stats() ->> 'total_positions')::bigint,
  (select count(*) from public.positions),
  'total_positions 与 positions 全量计数一致'
);
select is(
  (public.org_stats() ->> 'pending_todos')::bigint,
  1::bigint,
  'admin 待办数=本人 1 条（u1 的待办不串号）'
);
select is(
  public.org_stats(),
  app.org_stats(),
  'public 包装与 app 实现返回一致'
);

-- ===========================================================================
-- 4. org_stats：非 admin 分支（u1 / u2，6）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"ac000000-0000-4000-8000-000000000001","role":"authenticated"}';
set local role authenticated;

select is(
  (public.org_stats() ->> 'is_admin')::boolean,
  false,
  '非 admin 调用 is_admin=false'
);
select ok(
  not (public.org_stats() ? 'total_users'),
  '非 admin 返回不含 total_users'
);
select ok(
  not (public.org_stats() ? 'active_users')
  and not (public.org_stats() ? 'total_departments')
  and not (public.org_stats() ? 'total_positions'),
  '非 admin 返回不含组织全量计数'
);
select is(
  (select count(*) from jsonb_object_keys(public.org_stats() -> 'own')),
  1::bigint,
  '非 admin own 仅 1 个键'
);
select is(
  (public.org_stats() -> 'own' ->> 'pending_todos')::bigint,
  1::bigint,
  '非 admin 待办数=本人 1 条（不串 admin）'
);

reset role;
set local request.jwt.claims = '{"sub":"ac000000-0000-4000-8000-000000000002","role":"authenticated"}';
set local role authenticated;

select is(
  (public.org_stats() -> 'own' ->> 'pending_todos')::bigint,
  0::bigint,
  '无待办用户 own.pending_todos=0'
);

-- ===========================================================================
-- 5. signup_trend：admin 天数边界与逐日计数（5）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*) from public.signup_trend()),
  30::bigint,
  'p_days 默认 30 行'
);
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
  'p_days=0 夹取为 1 行（今天）'
);

-- ===========================================================================
-- 6. signup_trend：非 admin 返回空集（1）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"ac000000-0000-4000-8000-000000000001","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*) from public.signup_trend(30)),
  0::bigint,
  '非 admin 注册趋势返回空集（不泄露全量计数）'
);

-- ===========================================================================
-- 7. department_headcount：含子部门聚合（admin，13）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*) from public.department_headcount()
    where department_id::text like 'aa000000-%'),
  5::bigint,
  '夹具部门返回 5 行（4 active + 1 disabled；deleted 隐藏）'
);
select is(
  (select count(*) from public.department_headcount()
    where department_id = 'aa000000-0000-4000-8000-000000000006'),
  0::bigint,
  '已删除部门不在结果中'
);
select is(
  (select headcount from public.department_headcount()
    where department_id = 'aa000000-0000-4000-8000-000000000001'),
  4::bigint,
  '总部在岗 4（研发 u1 + 前端 u2 + 文本兜底 u3 + 直属 u6，含子部门）'
);
select is(
  (select headcount from public.department_headcount()
    where department_id = 'aa000000-0000-4000-8000-000000000002'),
  3::bigint,
  '研发在岗 3（u1 + 子部门前端 u2 + 文本兜底 u3，含子部门聚合）'
);
select is(
  (select headcount from public.department_headcount()
    where department_id = 'aa000000-0000-4000-8000-000000000003'),
  1::bigint,
  '前端在岗 1（u2）'
);
select is(
  (select headcount from public.department_headcount()
    where department_id = 'aa000000-0000-4000-8000-000000000004'),
  0::bigint,
  '行政在岗 0（inactive 不计）'
);
select is(
  (select headcount from public.department_headcount()
    where department_id = 'aa000000-0000-4000-8000-000000000005'),
  1::bigint,
  'disabled 部门外包在岗 1（u3 文本兜底命中）'
);
select is(
  (select position_headcount from public.department_headcount()
    where department_id = 'aa000000-0000-4000-8000-000000000001'),
  5::bigint,
  '总部编制 5（研发岗 3 + 前端岗 2，含子部门）'
);
select is(
  (select position_headcount from public.department_headcount()
    where department_id = 'aa000000-0000-4000-8000-000000000002'),
  5::bigint,
  '研发编制 5（研发岗 3 + 子部门前端岗 2；disabled 停用岗 5 不计）'
);
select is(
  (select position_headcount from public.department_headcount()
    where department_id = 'aa000000-0000-4000-8000-000000000004'),
  1::bigint,
  '行政编制 1'
);
select is(
  (select path from public.department_headcount()
    where department_id = 'aa000000-0000-4000-8000-000000000002'),
  '测试-总部/测试-研发',
  '研发 path 与 departments_v 递归口径一致'
);

reset role;
set local request.jwt.claims = '{"sub":"ac000000-0000-4000-8000-000000000001","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*) from public.department_headcount()
    where department_id::text like 'aa000000-%'),
  5::bigint,
  '非 admin 登录可读（行数同 admin）'
);
select is(
  (select headcount from public.department_headcount()
    where department_id = 'aa000000-0000-4000-8000-000000000001'),
  4::bigint,
  '非 admin 聚合结果同 admin（总部 4）'
);

-- ===========================================================================
-- 8. anon 无执行权限（3）
-- ===========================================================================
reset role;
set local role anon;

select throws_ok(
  $$ select public.org_stats() $$,
  '42501', null,
  'anon 无 org_stats 执行权限'
);
select throws_ok(
  $$ select * from public.signup_trend(7) $$,
  '42501', null,
  'anon 无 signup_trend 执行权限'
);
select throws_ok(
  $$ select * from public.department_headcount() $$,
  '42501', null,
  'anon 无 department_headcount 执行权限'
);

reset role;

select * from finish();
rollback;
