-- pgTAP：approval 页面辅助 RPC（工单 005+006+007）— urge_instance / my_instances / my_ccs / mark_cc_read / instance_detail
-- 运行：supabase test db（建议先 supabase db reset，seed 004 提供 demo 模板）
-- 覆盖：last_urged_at 列；函数存在/安全属性/GRANT；催办属主+状态+2h 节流+通知落库；
--       my_instances 只见本人+当前处理人+limit 夹取；my_ccs 未读过滤+join 字段；
--       mark_cc_read 属主校验+幂等；instance_detail 参与方可见+非参与方 42501+schema/轨迹；
--       anon 与无身份调用被拒。夹具事务内生效，finish 后 rollback。

begin;

select plan(57);

-- ---------------------------------------------------------------------------
-- 夹具（as postgres；auth.users 触发器自动建 profiles）
--   d...001 工程师（发起人） / d...002 管理员（审批人） / d...003 质检（抄送人） / d...004 计划员（无关人）
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
  ('00000000-0000-4000-d000-000000000001', 'appr-pages-u1@example.com',
   '{"provider":"email","providers":["email"],"role":"engineer"}', '{"full_name":"页面发起人"}'),
  ('00000000-0000-4000-d000-000000000002', 'appr-pages-u2@example.com',
   '{"provider":"email","providers":["email"],"role":"admin"}', '{"full_name":"页面审批人"}'),
  ('00000000-0000-4000-d000-000000000003', 'appr-pages-u3@example.com',
   '{"provider":"email","providers":["email"],"role":"quality"}', '{"full_name":"页面抄送人"}'),
  ('00000000-0000-4000-d000-000000000004', 'appr-pages-u4@example.com',
   '{"provider":"email","providers":["email"],"role":"planner"}', '{"full_name":"页面无关人"}');

update public.profiles
   set created_at = '2026-01-01T00:00:00Z'
 where id in (
   '00000000-0000-4000-d000-000000000001',
   '00000000-0000-4000-d000-000000000002',
   '00000000-0000-4000-d000-000000000003',
   '00000000-0000-4000-d000-000000000004'
 );

insert into public.approval_form_templates (id, name, code, module, version, schema, status) values
  ('88888888-8888-4888-8888-888888888801', '页面RPC测试模板', 'test.pages', 'demo', 1,
   '{"fields":[
      {"key":"title","label":"标题","type":"text","required":true},
      {"key":"days","label":"天数","type":"number","required":true},
      {"key":"reason","label":"事由","type":"text","required":true}
    ]}'::jsonb, 'published');

insert into public.approval_flows (id, name, template_id, version, nodes, status) values
  ('88888888-8888-4888-8888-888888888802', '页面RPC单节点', '88888888-8888-4888-8888-888888888801', 1,
   '[{"seq":1,"approver_rule":{"type":"user","value":"00000000-0000-4000-d000-000000000002"},"timeout_hours":24}]'::jsonb,
   'published');

-- ---------------------------------------------------------------------------
-- A. 结构 / 函数 / 安全属性 / 执行权限（20）
-- ---------------------------------------------------------------------------
select has_column('public', 'approval_instances', 'last_urged_at', 'instances.last_urged_at 列存在');

select has_function('app', 'urge_instance', array['uuid'], 'app.urge_instance 存在');
select has_function('public', 'urge_instance', array['uuid'], 'public.urge_instance 包装存在');
select has_function('app', 'my_instances', array['integer'], 'app.my_instances 存在');
select has_function('public', 'my_instances', array['integer'], 'public.my_instances 包装存在');
select has_function('app', 'my_ccs', array['boolean'], 'app.my_ccs 存在');
select has_function('public', 'my_ccs', array['boolean'], 'public.my_ccs 包装存在');
select has_function('app', 'mark_cc_read', array['uuid'], 'app.mark_cc_read 存在');
select has_function('public', 'mark_cc_read', array['uuid'], 'public.mark_cc_read 包装存在');
select has_function('app', 'instance_detail', array['uuid'], 'app.instance_detail 存在');
select has_function('public', 'instance_detail', array['uuid'], 'public.instance_detail 包装存在');

select is(
  (select count(*)
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname in ('urge_instance', 'my_instances', 'my_ccs', 'mark_cc_read', 'instance_detail')
      and p.prosecdef
      and p.proconfig = array['search_path=""']),
  5::bigint, 'app 侧 5 个页面函数均 security definer + search_path 固定为空'
);
select is(
  (select count(*)
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('urge_instance', 'my_instances', 'my_ccs', 'mark_cc_read', 'instance_detail')
      and p.prosecdef
      and p.proconfig = array['search_path=""']),
  5::bigint, 'public 包装层均 security definer + search_path 固定为空'
);

select ok(
  has_function_privilege('authenticated', 'public.urge_instance(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.my_instances(integer)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.my_ccs(boolean)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.mark_cc_read(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.instance_detail(uuid)', 'EXECUTE'),
  'authenticated 可执行 5 个 public 包装'
);
select ok(
  not has_function_privilege('anon', 'public.urge_instance(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.my_instances(integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.my_ccs(boolean)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.mark_cc_read(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.instance_detail(uuid)', 'EXECUTE'),
  'anon 无 5 个包装执行权'
);
select ok(
  has_function_privilege('authenticated', 'app.urge_instance(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'app.instance_detail(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'app.my_instances(integer)', 'EXECUTE'),
  'app 侧业务实现与 public 包装同授 authenticated（同 engine 业务 RPC 先例）'
);

-- ---------------------------------------------------------------------------
-- B. u1（发起人）：提交 / my_instances / 催办成功与节流（10）
-- ---------------------------------------------------------------------------
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-d000-000000000001', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select lives_ok(
  $$ select public.submit_instance('demo', 'demo_leave', '', 'test.pages',
       '{"title":"页面RPC测试A","days":2,"reason":"测试A"}'::jsonb) $$,
  'u1 提交实例 A 成功'
);
select lives_ok(
  $$ select public.submit_instance('demo', 'demo_leave', '', 'test.pages',
       '{"title":"页面RPC测试B","days":1,"reason":"测试B"}'::jsonb) $$,
  'u1 提交实例 B 成功'
);
select is(
  (select count(*) from public.my_instances(200)),
  2::bigint, 'my_instances 返回本人 2 条实例'
);
select is(
  (select current_assignee_name from public.my_instances(200) where title = '页面RPC测试A'),
  '页面审批人', 'my_instances 带出当前任务处理人姓名'
);
select is(
  (select instance_status || '/' || current_task_status from public.my_instances(200)
    where title = '页面RPC测试A'),
  'running/pending', 'my_instances 带出实例/任务状态'
);
select is(
  (select form_data ->> 'days' from public.my_instances(200) where title = '页面RPC测试A'),
  '2', 'my_instances 带出 form_data'
);
select is(
  (select count(*) from public.my_instances(0)),
  1::bigint, 'my_instances limit 夹取到 1'
);

select lives_ok(
  $$ select public.urge_instance((select id from public.approval_instances where title = '页面RPC测试A')) $$,
  'u1 首次催办 A 成功'
);
select isnt(
  (select last_urged_at from public.my_instances(200) where title = '页面RPC测试A'),
  null, '催办后 last_urged_at 已写入'
);
select throws_ok(
  $$ select public.urge_instance((select id from public.approval_instances where title = '页面RPC测试A')) $$,
  '22023', '催办过于频繁：同一单据 2 小时内仅可催办一次',
  '2h 内第二次催办被拒'
);

-- ---------------------------------------------------------------------------
-- C. u2（审批人）：只见本人 / 非发起人不可催办 / 处理后再催办被拒（8）
-- ---------------------------------------------------------------------------
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-d000-000000000002', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select is(
  (select count(*) from public.my_instances(200)),
  0::bigint, 'my_instances 只见本人（审批人看不到他人发起）'
);
select throws_ok(
  $$ select public.urge_instance((select id from public.approval_instances where title = '页面RPC测试A')) $$,
  '42501', '仅发起人可催办', '审批人（非发起人）催办被拒'
);
select lives_ok(
  $$ select public.act_task(
       (select id from public.approval_tasks
         where instance_id = (select id from public.approval_instances where title = '页面RPC测试A')
           and status = 'pending'),
       'approve', '') $$,
  'u2 通过实例 A'
);
select lives_ok(
  $$ select public.act_task(
       (select id from public.approval_tasks
         where instance_id = (select id from public.approval_instances where title = '页面RPC测试B')
           and status = 'pending'),
       'reject', '不同意') $$,
  'u2 驳回实例 B'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-d000-000000000001', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select throws_ok(
  $$ select public.urge_instance((select id from public.approval_instances where title = '页面RPC测试A')) $$,
  '22023', '审批实例已结束，不可催办', '已通过实例催办被拒（状态校验先于节流）'
);
select throws_ok(
  $$ select public.urge_instance((select id from public.approval_instances where title = '页面RPC测试B')) $$,
  '22023', '审批实例已结束，不可催办', '已驳回实例催办被拒'
);

reset role;
select is(
  (select count(*) from public.messages
    where recipient_id = '00000000-0000-4000-d000-000000000002'
      and event_key = 'approval.urge'),
  1::bigint, '仅 1 次成功催办产生 1 条 approval.urge 通知（失败调用不落通知）'
);
select is(
  (select status from public.approval_instances where title = '页面RPC测试A'),
  'approved', '实例 A 状态已推进为 approved'
);

-- ---------------------------------------------------------------------------
-- D. u3（抄送人）：my_ccs 过滤 / mark_cc_read 属主与幂等（10）
-- ---------------------------------------------------------------------------
insert into public.approval_ccs (instance_id, cc_user_id, read_at, created_at) values
  ((select id from public.approval_instances where title = '页面RPC测试A'),
   '00000000-0000-4000-d000-000000000003', null, '2026-02-01T10:00:00Z'),
  ((select id from public.approval_instances where title = '页面RPC测试B'),
   '00000000-0000-4000-d000-000000000003', '2026-02-01T09:00:00Z', '2026-02-02T10:00:00Z');

-- 抄送通知消息（验证 mark_cc_read 与 message 未读同源；u4 为他人消息哨兵）
insert into public.messages
  (recipient_id, event_key, title, body, source_module, ref_type, ref_id, read_at, created_at) values
  ('00000000-0000-4000-d000-000000000003', 'approval.cc', '抄送：页面RPC测试A', '正文',
   'approval', 'approval_instance',
   (select id::text from public.approval_instances where title = '页面RPC测试A'), null, '2026-02-01T10:00:00Z'),
  ('00000000-0000-4000-d000-000000000004', 'approval.cc', '抄送：页面RPC测试A（他人）', '正文',
   'approval', 'approval_instance',
   (select id::text from public.approval_instances where title = '页面RPC测试A'), null, '2026-02-01T10:00:00Z');

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-d000-000000000003', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select is(
  (select count(*) from public.my_ccs(false)),
  2::bigint, 'my_ccs(false) 返回全部抄送 2 条'
);
select is(
  (select count(*) from public.my_ccs(true)),
  1::bigint, 'my_ccs(true) 仅未读 1 条'
);
select is(
  (select initiator_name || '/' || current_assignee_name from public.my_ccs(false)
    where title = '页面RPC测试A'),
  '页面发起人/页面审批人', 'my_ccs 带出发起人与当前处理人姓名'
);
select isnt(
  (select public.mark_cc_read((select id from public.approval_instances where title = '页面RPC测试A'))),
  null, 'cc 属主标记已读返回 read_at'
);
select is(
  (select count(*) from public.my_ccs(true)),
  0::bigint, '标记后未读抄送为 0'
);
select is(
  (select public.mark_cc_read((select id from public.approval_instances where title = '页面RPC测试A'))),
  (select read_at from public.approval_ccs
    where instance_id = (select id from public.approval_instances where title = '页面RPC测试A')
      and cc_user_id = '00000000-0000-4000-d000-000000000003'),
  '重复标记幂等（read_at 不变）'
);
select isnt(
  (select read_at from public.messages
    where recipient_id = '00000000-0000-4000-d000-000000000003'
      and event_key = 'approval.cc'),
  null, 'mark_cc_read 同步标记本人通知消息（与消息未读同源）'
);
select throws_ok(
  $$ select public.mark_cc_read('99999999-9999-4999-8999-999999999999') $$,
  '42501', '审批抄送不存在或无权操作', '不存在的抄送标记被拒'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-d000-000000000001', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select throws_ok(
  $$ select public.mark_cc_read((select id from public.approval_instances where title = '页面RPC测试A')) $$,
  '42501', '审批抄送不存在或无权操作', '发起人（非 cc 属主）标记被拒'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-d000-000000000004', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select is(
  (select count(*) from public.my_ccs(false)),
  0::bigint, '未抄送用户 my_ccs 为空'
);

-- ---------------------------------------------------------------------------
-- E. instance_detail：参与方可见 / 非参与方 42501 / schema 与轨迹（10）
-- ---------------------------------------------------------------------------
reset role;
select is(
  (select read_at from public.messages
    where recipient_id = '00000000-0000-4000-d000-000000000004'
      and event_key = 'approval.cc'),
  null, '他人通知消息未被 mark_cc_read 波及'
);
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-d000-000000000001', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select is(
  (select count(*) from public.instance_detail((select instance_id from public.my_instances(200) where title = '页面RPC测试A'))),
  1::bigint, '发起人可读实例详情'
);
select is(
  (select schema -> 'fields' -> 0 ->> 'key'
     from public.instance_detail((select instance_id from public.my_instances(200) where title = '页面RPC测试A'))),
  'title', '详情带出模板 schema fields'
);
select is(
  (select jsonb_array_length(tasks)
     from public.instance_detail((select instance_id from public.my_instances(200) where title = '页面RPC测试A'))),
  1, '详情轨迹含 1 个节点'
);
select is(
  (select tasks -> 0 ->> 'assignee_name'
     from public.instance_detail((select instance_id from public.my_instances(200) where title = '页面RPC测试A'))),
  '页面审批人', '轨迹带出处理人姓名'
);
select is(
  (select instance_status || '/' || (tasks -> 0 ->> 'status')
     from public.instance_detail((select instance_id from public.my_instances(200) where title = '页面RPC测试A'))),
  'approved/approved', '轨迹与实例状态一致'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-d000-000000000002', 'role', 'authenticated')::text,
  true
);
set local role authenticated;
select is(
  (select count(*) from public.instance_detail(
     (select id from public.approval_instances where title = '页面RPC测试A'))),
  1::bigint, '任务处理人可读实例详情'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-d000-000000000003', 'role', 'authenticated')::text,
  true
);
set local role authenticated;
select is(
  (select count(*) from public.instance_detail(
     (select id from public.approval_instances where title = '页面RPC测试A'))),
  1::bigint, '抄送人可读实例详情'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-d000-000000000004', 'role', 'authenticated')::text,
  true
);
set local role authenticated;
select throws_ok(
  $$ select * from public.instance_detail(
       (select id from public.approval_instances where title = '页面RPC测试A')) $$,
  '42501', '审批实例不存在或无权查看', '非参与方读详情被拒'
);
select throws_ok(
  $$ select * from public.instance_detail('99999999-9999-4999-8999-999999999999') $$,
  '42501', '审批实例不存在或无权查看', '不存在实例读详情被拒（防探测）'
);

-- ---------------------------------------------------------------------------
-- F. anon 与无身份调用被拒（3）
-- ---------------------------------------------------------------------------
reset role;
set local role anon;
select throws_ok(
  'select public.my_instances(20)',
  '42501', null, 'anon 调用 my_instances 被拒（无执行权限）'
);

reset role;
set local request.jwt.claims = '{"role":"authenticated"}';
set local role authenticated;
select is(
  (select count(*) from public.my_instances(20)),
  0::bigint, '无 sub 身份 my_instances 返回空'
);
select throws_ok(
  $$ select public.urge_instance(
       (select id from public.approval_instances where title = '页面RPC测试A')) $$,
  '42501', '未登录，无法催办审批', '无 sub 身份催办被拒'
);

select * from finish();
rollback;
