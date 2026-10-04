-- pgTAP：org/014 — org.user_changed 发射点（admin_update_profile / assign_role）
-- 运行：supabase db reset && supabase test db
-- 覆盖：admin_update_profile 成功写后入队 org.user_changed（payload user_id/action=
--       profile_updated）；assign_role 成功写后入队（action=role_assigned）；
--       兼容路径 admin_update_profile(p_role) 两条都发；失败路径（非 admin / 目标不存在）
--       不产生事件；payload 为 jsonb 对象。
-- 说明：事件查询以 postgres 身份直查 integration_events（测试事务内 rollback）；
--       emit_event 为 integration/004 软依赖，本测试运行时已合入。

begin;

select plan(19);

-- ===========================================================================
-- 1. 夹具（u1 / u2，engineer 建档）与基线
-- ===========================================================================
insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
  ('ae000000-0000-4000-8000-000000000001', 'org-event-u1@example.com',
   '{}'::jsonb, '{"full_name":"事件用户一"}'),
  ('ae000000-0000-4000-8000-000000000002', 'org-event-u2@example.com',
   '{}'::jsonb, '{"full_name":"事件用户二"}');

select is(
  (select count(*) from public.integration_events
    where event = 'org.user_changed'
      and payload ->> 'user_id' = 'ae000000-0000-4000-8000-000000000001'),
  0::bigint,
  '基线：u1 无 org.user_changed 事件'
);

-- ===========================================================================
-- 2. admin_update_profile：成功写后发射 profile_updated（6）
-- ===========================================================================
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select is(
  (public.admin_update_profile(
     'ae000000-0000-4000-8000-000000000001', '事件改名', null, null, null, null, null
   )).full_name,
  '事件改名',
  'admin_update_profile 成功更新姓名'
);

reset role;

select is(
  (select count(*) from public.integration_events
    where event = 'org.user_changed'
      and payload ->> 'user_id' = 'ae000000-0000-4000-8000-000000000001'
      and payload ->> 'action' = 'profile_updated'),
  1::bigint,
  '更新档案后入队 1 条 org.user_changed(profile_updated)'
);
select is(
  (select payload ->> 'user_id' from public.integration_events
    where event = 'org.user_changed'
      and payload ->> 'user_id' = 'ae000000-0000-4000-8000-000000000001'
      and payload ->> 'action' = 'profile_updated'),
  'ae000000-0000-4000-8000-000000000001',
  'payload.user_id 指向被更新用户'
);
select is(
  (select payload ->> 'status' from public.integration_events
    where event = 'org.user_changed'
      and payload ->> 'user_id' = 'ae000000-0000-4000-8000-000000000001'
      and payload ->> 'action' = 'profile_updated'),
  'active',
  'payload 携带写入后的 status'
);
select ok(
  (select jsonb_typeof(payload) = 'object' from public.integration_events
    where event = 'org.user_changed'
      and payload ->> 'user_id' = 'ae000000-0000-4000-8000-000000000001'
      and payload ->> 'action' = 'profile_updated'),
  'payload 为 jsonb 对象'
);
select is(
  (select status from public.integration_events
    where event = 'org.user_changed'
      and payload ->> 'user_id' = 'ae000000-0000-4000-8000-000000000001'
      and payload ->> 'action' = 'profile_updated'),
  'pending',
  '事件以 pending 入队（等待投递器消费）'
);

-- ===========================================================================
-- 3. assign_role：成功写后发射 role_assigned（3）
-- ===========================================================================
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select is(
  (public.assign_role(
     'ae000000-0000-4000-8000-000000000001', 'buyer'
   )).role,
  'buyer'::public.user_role,
  'assign_role 成功切换角色'
);

reset role;

select is(
  (select payload ->> 'role' from public.integration_events
    where event = 'org.user_changed'
      and payload ->> 'user_id' = 'ae000000-0000-4000-8000-000000000001'
      and payload ->> 'action' = 'role_assigned'),
  'buyer',
  '角色分配后入队 org.user_changed(role_assigned) 且 payload.role 正确'
);
select is(
  (select count(*) from public.integration_events
    where event = 'org.user_changed'
      and payload ->> 'user_id' = 'ae000000-0000-4000-8000-000000000001'),
  2::bigint,
  'u1 累计 2 条事件（profile_updated + role_assigned）'
);

-- ===========================================================================
-- 4. 兼容路径：admin_update_profile(p_role) 两条事件都发（3）
-- ===========================================================================
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select is(
  (public.admin_update_profile(
     'ae000000-0000-4000-8000-000000000002', null, null, 'planner', null, null, null
   )).role,
  'planner'::public.user_role,
  'admin_update_profile 兼容路径转调 assign_role 并返回新角色'
);

reset role;

select is(
  (select count(*) from public.integration_events
    where event = 'org.user_changed'
      and payload ->> 'user_id' = 'ae000000-0000-4000-8000-000000000002'
      and payload ->> 'action' = 'profile_updated'),
  1::bigint,
  '兼容路径发射 profile_updated'
);
select is(
  (select count(*) from public.integration_events
    where event = 'org.user_changed'
      and payload ->> 'user_id' = 'ae000000-0000-4000-8000-000000000002'
      and payload ->> 'action' = 'role_assigned'),
  1::bigint,
  '兼容路径转调 assign_role 发射 role_assigned'
);

-- ===========================================================================
-- 5. 失败路径不产生事件（4）
-- ===========================================================================
-- u2 当前事件数（profile_updated 1 + role_assigned 1 = 2）
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;

select throws_ok(
  $$ select public.admin_update_profile(
       'ae000000-0000-4000-8000-000000000002', '越权改名', null, null, null, null, null) $$,
  '42501', '仅管理员可执行此操作',
  '非 admin 调用 admin_update_profile 被拒'
);
select throws_ok(
  $$ select public.assign_role(
       'ae000000-0000-4000-8000-000000000002', 'buyer') $$,
  '42501', '仅管理员可执行此操作',
  '非 admin 调用 assign_role 被拒'
);

reset role;

select is(
  (select count(*) from public.integration_events
    where event = 'org.user_changed'
      and payload ->> 'user_id' = 'ae000000-0000-4000-8000-000000000002'),
  2::bigint,
  '越权失败后 u2 事件数不变（仍 2 条）'
);
select is(
  (select count(*) from public.integration_events
    where event = 'org.user_changed'
      and payload ->> 'user_id' = 'ae000000-0000-4000-8000-000000000099'),
  0::bigint,
  '目标不存在的失败路径不产生事件'
);

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select throws_ok(
  $$ select public.admin_update_profile(
       'ae000000-0000-4000-8000-000000000099', '幽灵改名', null, null, null, null, null) $$,
  'P0002', null,
  'admin 更新不存在用户被拒（P0002）'
);

reset role;

select is(
  (select count(*) from public.integration_events
    where event = 'org.user_changed'
      and payload ->> 'user_id' = 'ae000000-0000-4000-8000-000000000099'),
  0::bigint,
  '更新不存在用户后仍无该用户事件'
);

select * from finish();
rollback;
