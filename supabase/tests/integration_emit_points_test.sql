-- pgTAP：integration/010 —— 首期发射点验收（approval.submitted / org.user_changed / sync.run_finished）
-- 运行：supabase db reset && supabase test db
-- 覆盖：菜单登记（menu_items 含 /integration/* 4 条路由）；emit_event 存在且未 GRANT API 角色（规则 10）；
--       submit_instance → approval.submitted 事件入队 + payload 校验；
--       execute_sync_task 终态 → sync.run_finished 事件入队 + payload 校验；
--       admin_update_profile → org.user_changed（org/014 并行开发中：检测未合入则 skip，合入后自动启用断言）。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(17);

-- ===========================================================================
-- 0. 夹具：发起人（engineer）；审批人复用 seed 管理员 11111111-...
-- ===========================================================================
insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
  ('00000000-0000-4000-d000-000000000001', 'emit-eng@example.com',
   '{"provider":"email","providers":["email"],"role":"engineer"}', '{"full_name":"发射验收工程师"}');

-- 审批模板 + 流程（published；单节点 user 规则指向 seed 管理员，避免 role 解析歧义）
insert into public.approval_form_templates (id, name, code, module, version, schema, status) values
  ('00000000-0000-4000-d000-000000000101', '发射点验收模板', 'emit.accept', 'demo', 1,
   '{"fields":[{"key":"title","label":"标题","type":"text","required":true}]}'::jsonb, 'published');

insert into public.approval_flows (id, name, template_id, version, nodes, status) values
  ('00000000-0000-4000-d000-000000000102', '发射点验收流程',
   '00000000-0000-4000-d000-000000000101', 1,
   '[{"seq":1,"approver_rule":{"type":"user","value":"11111111-1111-1111-1111-111111111111"}}]'::jsonb,
   'published');

-- ===========================================================================
-- A. 菜单登记：menu_items 含 /integration/* 4 条路由（access/005 底座 seed）
-- ===========================================================================
select is(
  (select count(*) from public.menu_items where route like '/integration/%'),
  4::bigint,
  'menu_items 登记 /integration/* 4 条路由'
);
select is(
  (select array_agg(route order by sort_order) from public.menu_items where route like '/integration/%'),
  array['/integration/api-keys', '/integration/webhooks', '/integration/logs', '/integration/docs']::text[],
  '4 条路由与页面顺序一致'
);
select ok(
  (select bool_and(module = 'integration' and parent_key = '/integration')
     from public.menu_items where route like '/integration/%'),
  '4 条路由 module=integration 且挂在 /integration 下'
);

-- ===========================================================================
-- B. emit_event 可达面（规则 10）：存在；API 角色不可直调
-- ===========================================================================
select has_function('app', 'emit_event', array['text', 'jsonb'], 'app.emit_event 存在');
select ok(
  not has_function_privilege('authenticated', 'app.emit_event(text,jsonb)', 'EXECUTE')
    and not has_function_privilege('anon', 'app.emit_event(text,jsonb)', 'EXECUTE'),
  'emit_event 未 GRANT authenticated/anon（规则 10）'
);

-- ===========================================================================
-- C. approval 链路：submit_instance → approval.submitted 入队
-- ===========================================================================
select coalesce(max(id), 0) as ev_before
  from public.integration_events \gset

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-d000-000000000001', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select public.submit_instance(
  'demo', 'leave', 'EMIT-验收-001', 'emit.accept', '{"title":"发射点验收"}'::jsonb
) as inst \gset
reset role;

select ok(
  exists (
    select 1 from public.integration_events
    where event = 'approval.submitted' and id > :ev_before
  ),
  'submit_instance → approval.submitted 事件入队'
);
select is(
  (select payload ->> 'instance_id' from public.integration_events
    where event = 'approval.submitted' and id > :ev_before),
  :'inst',
  'approval.submitted payload.instance_id 一致'
);
select is(
  (select payload ->> 'module' from public.integration_events
    where event = 'approval.submitted' and id > :ev_before),
  'demo',
  'approval.submitted payload.module 一致'
);
select is(
  (select payload ->> 'template_code' from public.integration_events
    where event = 'approval.submitted' and id > :ev_before),
  'emit.accept',
  'approval.submitted payload.template_code 一致'
);
select is(
  (select payload ->> 'initiator_id' from public.integration_events
    where event = 'approval.submitted' and id > :ev_before),
  '00000000-0000-4000-d000-000000000001',
  'approval.submitted payload.initiator_id 一致'
);

-- ===========================================================================
-- D. org 链路：admin_update_profile → org.user_changed（org/014 并行开发中）
--    未合入时（函数定义无 org.user_changed 且无新事件）skip：
--    验收范围按 integration/AGENT.md 010 降级为 approval+sync 两处。
-- ===========================================================================
select coalesce(max(id), 0) as org_before
  from public.integration_events \gset

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '11111111-1111-1111-1111-111111111111', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select public.admin_update_profile(
  '00000000-0000-4000-d000-000000000001', '发射验收工程师（已改）', null, null, null
) as org_profile \gset
reset role;

select case
  when pg_get_functiondef(
         'public.admin_update_profile(uuid,text,text,public.user_role,public.profile_status,uuid,uuid)'::regprocedure
       ) like '%org.user_changed%'
    or exists (
         select 1 from public.integration_events
         where event = 'org.user_changed' and id > :org_before
       )
  then ok(
         exists (
           select 1 from public.integration_events
           where event = 'org.user_changed' and id > :org_before
         ),
         'admin_update_profile → org.user_changed 事件入队'
       )
  else skip(1, 'org/014 未合入：org.user_changed 用例跳过（验收收窄为 approval+sync）')
end;

-- ===========================================================================
-- E. sync 链路：execute_sync_task 终态 → sync.run_finished 入队
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '11111111-1111-1111-1111-111111111111', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select public.upsert_sync_source(
  null, '发射点验收源', 'api', '{"base_url":"https://emit.example.com"}'::jsonb, 'tok-emit', null
) as em_src \gset
select public.test_sync_source((:'em_src'::jsonb ->> 'id')::uuid) as em_src_v \gset

select public.upsert_sync_task(
  null, '发射点验收任务', (:'em_src'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"dept","target_field":"name"}]'::jsonb, 'skip', null
) as em_task \gset
reset role;

select coalesce(max(id), 0) as sync_before
  from public.integration_events \gset

set local role authenticated;
select public.run_sync_task((:'em_task'::jsonb ->> 'id')::uuid, '[]'::jsonb) as em_run \gset
reset role;

select ok(
  exists (
    select 1 from public.integration_events
    where event = 'sync.run_finished' and id > :sync_before
  ),
  'execute_sync_task 完成 → sync.run_finished 事件入队'
);
select is(
  (select payload ->> 'run_id' from public.integration_events
    where event = 'sync.run_finished' and id > :sync_before),
  :'em_run',
  'sync.run_finished payload.run_id 一致'
);
select is(
  (select payload ->> 'task_id' from public.integration_events
    where event = 'sync.run_finished' and id > :sync_before),
  (:'em_task'::jsonb ->> 'id'),
  'sync.run_finished payload.task_id 一致'
);
select is(
  (select payload ->> 'status' from public.integration_events
    where event = 'sync.run_finished' and id > :sync_before),
  'success',
  'sync.run_finished payload.status=success'
);
select is(
  (select payload ->> 'trigger' from public.integration_events
    where event = 'sync.run_finished' and id > :sync_before),
  'manual',
  'sync.run_finished payload.trigger=manual'
);
select ok(
  (select (payload -> 'stats') ?& array['insert', 'update', 'conflict', 'skip', 'failed']
     from public.integration_events
    where event = 'sync.run_finished' and id > :sync_before),
  'sync.run_finished payload.stats 含五类计数'
);

select * from finish();
rollback;
