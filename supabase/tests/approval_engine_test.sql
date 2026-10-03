-- pgTAP：approval/001+002+003 — 引擎核心表 + submit_instance/act_task/withdraw_instance/my_todos + RLS
-- 运行：supabase test db（建议先 supabase db reset，seed 004 提供 demo 数据）
-- 覆盖：表/列/约束（含两唯一约束+部分唯一索引）、函数存在与安全属性、表级权限与 RLS、
--       审批人解析（role/dept_leader/user）、渲染注册、submit 校验与端到端、
--       act 状态机（单节点/多节点/驳回/并发二次 act/越权）、withdraw 边界、
--       任务唯一约束、published 冻结、审计与通知落库、无关用户不可见。

begin;
select plan(145);

-- ---------------------------------------------------------------------------
-- 夹具（as postgres；auth.users 触发器自动建 profiles）
--   c...001 工程师（发起人） / c...002 管理员（审批人） / c...003 质检（第二节点）
--   c...004 计划员（无关用户，RLS 不可见验证）
-- created_at 固定为 2026-01-01：resolve_approver 按「建档最早」取 admin 时确定性优先于 seed 账号
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
  ('00000000-0000-4000-c000-000000000001', 'appr-eng@example.com',
   '{"provider":"email","providers":["email"],"role":"engineer"}', '{"full_name":"审批工程师"}'),
  ('00000000-0000-4000-c000-000000000002', 'appr-admin@example.com',
   '{"provider":"email","providers":["email"],"role":"admin"}', '{"full_name":"审批管理员"}'),
  ('00000000-0000-4000-c000-000000000003', 'appr-quality@example.com',
   '{"provider":"email","providers":["email"],"role":"quality"}', '{"full_name":"审批质检"}'),
  ('00000000-0000-4000-c000-000000000004', 'appr-planner@example.com',
   '{"provider":"email","providers":["email"],"role":"planner"}', '{"full_name":"审批计划"}');

update public.profiles
   set created_at = '2026-01-01T00:00:00Z'
 where id in (
   '00000000-0000-4000-c000-000000000001',
   '00000000-0000-4000-c000-000000000002',
   '00000000-0000-4000-c000-000000000003',
   '00000000-0000-4000-c000-000000000004'
 );

-- 部门负责人（dept_leader 解析；工程师挂到该部门，负责人=审批管理员）
insert into public.departments (id, name, leader_id, sort_order, status)
values (
  '55555555-5555-4555-8555-555555555501', '审批测试部',
  '00000000-0000-4000-c000-000000000002', 1, 'active'
);

update public.profiles
   set department_id = '55555555-5555-4555-8555-555555555501'
 where id = '00000000-0000-4000-c000-000000000001';

-- 测试模板 + 流程（published；模板 module='demo'）
insert into public.approval_form_templates (id, name, code, module, version, schema, status) values
  ('66666666-6666-4666-8666-666666666601', '单节点请假测试', 'test.leave', 'demo', 1,
   '{"fields":[
      {"key":"title","label":"标题","type":"text","required":true},
      {"key":"days","label":"天数","type":"number","required":true},
      {"key":"reason","label":"事由","type":"text"}
    ]}'::jsonb, 'published'),
  ('66666666-6666-4666-8666-666666666602', '双节点出差测试', 'test.trip', 'demo', 1,
   '{"fields":[
      {"key":"title","label":"标题","type":"text","required":true},
      {"key":"city","label":"城市","type":"text","required":true}
    ]}'::jsonb, 'published');

insert into public.approval_flows (id, name, template_id, version, nodes, status) values
  ('77777777-7777-4777-8777-777777777701', '请假单节点', '66666666-6666-4666-8666-666666666601', 1,
   '[{"seq":1,"approver_rule":{"type":"role","value":"admin"},"timeout_hours":24}]'::jsonb, 'published'),
  ('77777777-7777-4777-8777-777777777702', '出差双节点', '66666666-6666-4666-8666-666666666602', 1,
   '[{"seq":1,"approver_rule":{"type":"role","value":"admin"}},
     {"seq":2,"approver_rule":{"type":"user","value":"00000000-0000-4000-c000-000000000003"}}]'::jsonb, 'published');

-- ---------------------------------------------------------------------------
-- A. 结构：表 / 列 / 约束 / 索引
-- ---------------------------------------------------------------------------
select has_table('public', 'approval_form_templates', 'approval_form_templates 表存在');
select has_table('public', 'approval_flows', 'approval_flows 表存在');
select has_table('public', 'approval_instances', 'approval_instances 表存在');
select has_table('public', 'approval_tasks', 'approval_tasks 表存在');
select has_table('public', 'approval_ccs', 'approval_ccs 表存在');
select has_table('public', 'form_renderers', 'form_renderers 表存在');

select has_column('public', 'approval_form_templates', 'schema', 'templates.schema 列存在');
select has_column('public', 'approval_flows', 'nodes', 'flows.nodes 列存在');
select has_column('public', 'approval_instances', 'current_seq', 'instances.current_seq 列存在');
select has_column('public', 'approval_tasks', 'acted_at', 'tasks.acted_at 列存在');
select has_column('public', 'approval_ccs', 'read_at', 'ccs.read_at 列存在');

select is(
  (select count(*) from pg_constraint
    where conrelid = 'public.approval_form_templates'::regclass
      and contype = 'u' and conname = 'approval_form_templates_code_version_uq'),
  1::bigint, '模板唯一约束 (code, version) 存在'
);
select is(
  (select count(*) from pg_constraint
    where conrelid = 'public.approval_flows'::regclass
      and contype = 'u' and conname = 'approval_flows_template_version_uq'),
  1::bigint, '流程唯一约束 (template_id, version) 存在'
);
select is(
  (select count(*) from pg_constraint
    where conrelid = 'public.approval_tasks'::regclass
      and contype = 'u' and conname = 'approval_tasks_instance_seq_uq'),
  1::bigint, '任务唯一约束 (instance_id, seq) 存在'
);

select has_index('public', 'approval_tasks', 'approval_tasks_one_pending_uq',
                 '同实例仅一 pending 的部分唯一索引存在');
select has_index('public', 'approval_form_templates', 'approval_form_templates_code_version_uq',
                 '模板 code+version 唯一索引存在');
select has_index('public', 'approval_flows', 'approval_flows_template_version_uq',
                 '流程 template+version 唯一索引存在');
select has_index('public', 'approval_tasks', 'approval_tasks_instance_seq_uq',
                 '任务 instance+seq 唯一索引存在');

-- ---------------------------------------------------------------------------
-- B. RLS 与表级权限（敏感表二分：无任何 API 角色的表级写）
-- ---------------------------------------------------------------------------
select is(
  (select count(*) from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname in ('approval_form_templates', 'approval_flows', 'approval_instances',
                       'approval_tasks', 'approval_ccs', 'form_renderers')
     and c.relrowsecurity),
  6::bigint, '六张新表均启用 RLS'
);
select is(
  (select count(*) from pg_policies
    where schemaname = 'public'
      and tablename in ('approval_form_templates', 'approval_flows', 'approval_instances',
                        'approval_tasks', 'approval_ccs', 'form_renderers')),
  6::bigint, '六张表各 1 条 SELECT 策略'
);
select is(
  (select count(*) from pg_policies
    where schemaname = 'public'
      and tablename in ('approval_form_templates', 'approval_flows', 'approval_instances',
                        'approval_tasks', 'approval_ccs', 'form_renderers')
      and cmd in ('INSERT', 'UPDATE', 'DELETE')),
  0::bigint, '无任何表级写策略'
);
select ok(
  has_table_privilege('authenticated', 'public.approval_form_templates', 'SELECT')
  and has_table_privilege('authenticated', 'public.approval_flows', 'SELECT')
  and has_table_privilege('authenticated', 'public.approval_instances', 'SELECT')
  and has_table_privilege('authenticated', 'public.approval_tasks', 'SELECT')
  and has_table_privilege('authenticated', 'public.approval_ccs', 'SELECT')
  and has_table_privilege('authenticated', 'public.form_renderers', 'SELECT'),
  'authenticated 六张表均有 SELECT'
);
select ok(
  not has_table_privilege('authenticated', 'public.approval_form_templates', 'INSERT')
  and not has_table_privilege('authenticated', 'public.approval_form_templates', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.approval_form_templates', 'DELETE'),
  'templates 无表级写（含 admin）'
);
select ok(
  not has_table_privilege('authenticated', 'public.approval_flows', 'INSERT')
  and not has_table_privilege('authenticated', 'public.approval_flows', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.approval_flows', 'DELETE'),
  'flows 无表级写（含 admin）'
);
select ok(
  not has_table_privilege('authenticated', 'public.approval_instances', 'INSERT')
  and not has_table_privilege('authenticated', 'public.approval_instances', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.approval_instances', 'DELETE'),
  'instances 无表级写（写仅经 RPC）'
);
select ok(
  not has_table_privilege('authenticated', 'public.approval_tasks', 'INSERT')
  and not has_table_privilege('authenticated', 'public.approval_tasks', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.approval_tasks', 'DELETE'),
  'tasks 无表级写（写仅经 RPC）'
);
select ok(
  not has_table_privilege('authenticated', 'public.approval_ccs', 'INSERT')
  and not has_table_privilege('authenticated', 'public.approval_ccs', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.approval_ccs', 'DELETE'),
  'ccs 无表级写（写仅经 RPC）'
);
select ok(
  not has_table_privilege('anon', 'public.approval_instances', 'SELECT')
  and not has_table_privilege('service_role', 'public.approval_instances', 'SELECT'),
  'anon/service_role 均无实例读权限（不授予 API 旁路）'
);

-- ---------------------------------------------------------------------------
-- C. 函数存在性 / 安全属性 / 执行权限
-- ---------------------------------------------------------------------------
select has_function('app', 'resolve_approver', array['jsonb', 'uuid'], 'app.resolve_approver 存在');
select has_function('app', 'register_form_renderer', array['text', 'text', 'text'], 'app.register_form_renderer 存在');
select has_function('app', 'submit_instance', array['text', 'text', 'text', 'text', 'jsonb'], 'app.submit_instance 存在');
select has_function('app', 'act_task', array['uuid', 'text', 'text'], 'app.act_task 存在');
select has_function('app', 'withdraw_instance', array['uuid'], 'app.withdraw_instance 存在');
select has_function('app', 'my_todos', array['boolean', 'integer'], 'app.my_todos 存在');
select has_function('public', 'submit_instance', array['text', 'text', 'text', 'text', 'jsonb'], 'public.submit_instance 存在');
select has_function('public', 'act_task', array['uuid', 'text', 'text'], 'public.act_task 存在');
select has_function('public', 'withdraw_instance', array['uuid'], 'public.withdraw_instance 存在');
select has_function('public', 'my_todos', array['boolean', 'integer'], 'public.my_todos 存在');

select is(
  (select count(*) from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app'
     and p.proname in ('resolve_approver', 'register_form_renderer', 'submit_instance',
                       'act_task', 'withdraw_instance', 'my_todos', 'is_instance_participant')
     and p.prosecdef
     and p.proconfig = array['search_path=""']),
  7::bigint, 'app 侧 7 个业务函数均 security definer + search_path 固定为空'
);
select is(
  (select count(*) from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('submit_instance', 'act_task', 'withdraw_instance', 'my_todos')
     and p.prosecdef
     and p.proconfig = array['search_path=""']),
  4::bigint, 'public 包装层均 security definer + search_path 固定为空'
);
select ok(has_function_privilege('authenticated', 'public.submit_instance(text,text,text,text,jsonb)', 'EXECUTE'),
          'authenticated 可执行 public.submit_instance');
select ok(has_function_privilege('authenticated', 'public.act_task(uuid,text,text)', 'EXECUTE'),
          'authenticated 可执行 public.act_task');
select ok(has_function_privilege('authenticated', 'public.withdraw_instance(uuid)', 'EXECUTE'),
          'authenticated 可执行 public.withdraw_instance');
select ok(has_function_privilege('authenticated', 'public.my_todos(boolean,integer)', 'EXECUTE'),
          'authenticated 可执行 public.my_todos');
select ok(not has_function_privilege('authenticated', 'app.register_form_renderer(text,text,text)', 'EXECUTE'),
          'authenticated 不可执行 register_form_renderer（INDEX 规则 10）');
select ok(not has_function_privilege('authenticated', 'app.resolve_approver(jsonb,uuid)', 'EXECUTE'),
          'authenticated 不可执行 resolve_approver（内部函数）');
select ok(not has_function_privilege('authenticated', 'app.flow_node(jsonb,integer)', 'EXECUTE'),
          'authenticated 不可执行 flow_node（内部函数）');
select ok(not has_function_privilege('anon', 'public.my_todos(boolean,integer)', 'EXECUTE'),
          'anon 不可执行 my_todos');

-- ---------------------------------------------------------------------------
-- D. 审批人解析 resolve_approver（as postgres）
-- ---------------------------------------------------------------------------
select is(
  app.resolve_approver('{"type":"role","value":"admin"}'::jsonb,
                       '00000000-0000-4000-c000-000000000001'),
  '00000000-0000-4000-c000-000000000002'::uuid,
  'role=admin 解析到最早建档的 active 管理员'
);
select throws_ok(
  $$ select app.resolve_approver('{"type":"role","value":"no.such.role"}'::jsonb,
                                 '00000000-0000-4000-c000-000000000001') $$,
  'P0002', null, '不存在的角色解析被拒'
);
select throws_ok(
  $$ select app.resolve_approver('{"type":"role"}'::jsonb, null) $$,
  '22023', null, '角色规则缺少 value 被拒'
);
select is(
  app.resolve_approver('{"type":"user","value":"00000000-0000-4000-c000-000000000003"}'::jsonb,
                       '00000000-0000-4000-c000-000000000001'),
  '00000000-0000-4000-c000-000000000003'::uuid,
  'user 规则直取指定用户'
);
select throws_ok(
  $$ select app.resolve_approver('{"type":"user","value":"not-a-uuid"}'::jsonb,
                                 '00000000-0000-4000-c000-000000000001') $$,
  '22023', null, 'user 规则非法 uuid 被拒'
);
select is(
  app.resolve_approver('{"type":"dept_leader"}'::jsonb,
                       '00000000-0000-4000-c000-000000000001'),
  '00000000-0000-4000-c000-000000000002'::uuid,
  'dept_leader 按 department_id→leader_id 解析'
);
select throws_ok(
  $$ select app.resolve_approver('{"type":"dept_leader"}'::jsonb,
                                 '00000000-0000-4000-c000-000000000003') $$,
  '22023', null, '无部门用户 dept_leader 解析被拒'
);
select throws_ok(
  $$ select app.resolve_approver('{"type":"bogus","value":"x"}'::jsonb,
                                 '00000000-0000-4000-c000-000000000001') $$,
  '22023', null, '未知审批人规则类型被拒'
);

-- ---------------------------------------------------------------------------
-- E. 渲染注册 register_form_renderer（内部入口）
-- ---------------------------------------------------------------------------
select lives_ok(
  $$ select app.register_form_renderer('demo', 'leave', 'leave-form-v1') $$,
  '业务模块注册渲染 key 成功'
);
select is(
  (select renderer_key from public.form_renderers where module = 'demo' and ref_type = 'leave'),
  'leave-form-v1', 'renderer_key 已落库'
);
select lives_ok(
  $$ select app.register_form_renderer('demo', 'leave', 'leave-form-v2') $$,
  '重复注册同 module+ref_type 走 upsert'
);
select is(
  (select renderer_key from public.form_renderers where module = 'demo' and ref_type = 'leave'),
  'leave-form-v2', 'renderer_key 已被 upsert 覆盖'
);

-- ---------------------------------------------------------------------------
-- F. submit_instance：schema 校验 + 端到端首节点（以发起人身份）
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-c000-000000000001', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select throws_ok(
  $$ select public.submit_instance('demo', 'leave', 'LV-ERR-1', 'test.leave', '{"days":1}'::jsonb) $$,
  '22023', null, '缺少 required 字段被拒'
);
select throws_ok(
  $$ select public.submit_instance('demo', 'leave', 'LV-ERR-2', 'test.leave',
      '{"title":"x","days":"两天"}'::jsonb) $$,
  '22023', null, '字段类型粗检失败被拒（number 收到字符串）'
);
select throws_ok(
  $$ select public.submit_instance('demo', 'leave', 'LV-ERR-3', 'test.leave', '[]'::jsonb) $$,
  '22023', null, 'form_data 非对象被拒'
);
select throws_ok(
  $$ select public.submit_instance('demo', 'leave', 'LV-ERR-4', 'no.such.template', '{"title":"x"}'::jsonb) $$,
  'P0002', null, '模板不存在/未发布被拒'
);
select throws_ok(
  $$ select public.submit_instance('org', 'leave', 'LV-ERR-5', 'test.leave',
      '{"title":"x","days":1}'::jsonb) $$,
  '22023', null, '模板 module 与来源模块不一致被拒'
);

select ok(
  (select public.submit_instance('demo', 'leave', 'LV-2026-001', 'test.leave',
      '{"title":"单节点请假","days":2,"reason":"回家探亲"}'::jsonb)) is not null,
  '合法提交返回实例 id'
);

reset role;

select is(
  (select status from public.approval_instances where title = '单节点请假'),
  'running', '实例状态 running'
);
select is(
  (select current_seq from public.approval_instances where title = '单节点请假'),
  1, '实例 current_seq=1'
);
select is(
  (select t.assignee_id from public.approval_tasks t
     join public.approval_instances i on i.id = t.instance_id
    where i.title = '单节点请假' and t.seq = 1),
  '00000000-0000-4000-c000-000000000002'::uuid, '首节点任务指派给 admin（role 解析）'
);
select is(
  (select t.status from public.approval_tasks t
     join public.approval_instances i on i.id = t.instance_id
    where i.title = '单节点请假' and t.seq = 1),
  'pending', '首节点任务为 pending'
);
select is(
  (select tf.code
     from public.approval_instances i
     join public.approval_form_templates tf on tf.id = i.template_version_id
    where i.title = '单节点请假'),
  'test.leave', '实例绑定模板具体版本'
);
select is(
  (select f.id
     from public.approval_instances i
     join public.approval_flows f on f.id = i.flow_version_id
    where i.title = '单节点请假'),
  '77777777-7777-4777-8777-777777777701'::uuid, '实例绑定流程具体版本'
);
select is(
  (select form_data ->> 'days' from public.approval_instances where title = '单节点请假'),
  '2', 'form_data 原样落库'
);
select is(
  (select title from public.approval_instances where title = '单节点请假'),
  '单节点请假', 'title 取 form_data.title'
);
select is(
  (select count(*) from public.audit_operations
    where module = 'approval' and action = 'submit'
      and object_id = (select id::text from public.approval_instances where title = '单节点请假')),
  1::bigint, 'submit 写审计摘要'
);
select is(
  (select count(*) from public.messages
    where recipient_id = '00000000-0000-4000-c000-000000000002'
      and event_key = 'approval.pending'
      and ref_id = (select id::text from public.approval_instances where title = '单节点请假')),
  1::bigint, 'submit 给审批人发 pending 通知'
);
select is(
  (select title from public.messages
    where recipient_id = '00000000-0000-4000-c000-000000000002'
      and event_key = 'approval.pending'
      and ref_id = (select id::text from public.approval_instances where title = '单节点请假')),
  '待审批：单节点请假', 'pending 通知标题含单据标题'
);

-- ---------------------------------------------------------------------------
-- G. my_todos（待办列表 / 已办列表 / limit 夹取）
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-c000-000000000002', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select is(
  (select count(*) from public.my_todos(true) where title = '单节点请假'),
  1::bigint, 'admin 待办可见该实例'
);
select is(
  (select instance_status from public.my_todos(true) where title = '单节点请假'),
  'running', 'my_todos 带出实例状态'
);
select is(
  (select initiator_name from public.my_todos(true) where title = '单节点请假'),
  '审批工程师', 'my_todos 带出发起人姓名'
);
select is(
  (select count(*) from public.my_todos(false) where title = '单节点请假'),
  0::bigint, '未处理任务不出现在已办'
);
select is(
  (select count(*) from public.my_todos(true, -5)),
  1::bigint, 'limit 夹取下限 1'
);

-- 发起人不是 assignee：待办为空
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-c000-000000000001', 'role', 'authenticated')::text,
  true
);
select is(
  (select count(*) from public.my_todos(true)),
  0::bigint, '发起人（非审批人）待办为空'
);

-- ---------------------------------------------------------------------------
-- H. act_task 状态机：越权 / 驳回意见必填 / 单节点通过 / 二次 act
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ select public.act_task(
       (select t.id from public.approval_tasks t
          join public.approval_instances i on i.id = t.instance_id
         where i.title = '单节点请假' and t.seq = 1),
       'approve', null) $$,
  '42501', null, '非 assignee act 被拒'
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-c000-000000000002', 'role', 'authenticated')::text,
  true
);

select throws_ok(
  $$ select public.act_task(
       (select t.id from public.approval_tasks t
          join public.approval_instances i on i.id = t.instance_id
         where i.title = '单节点请假' and t.seq = 1),
       'reject', null) $$,
  '22023', null, '驳回未填意见被拒（服务端强制）'
);
select throws_ok(
  $$ select public.act_task(
       (select t.id from public.approval_tasks t
          join public.approval_instances i on i.id = t.instance_id
         where i.title = '单节点请假' and t.seq = 1),
       'cancel', null) $$,
  '22023', null, '非法 action 被拒'
);
select lives_ok(
  $$ select public.act_task(
       (select t.id from public.approval_tasks t
          join public.approval_instances i on i.id = t.instance_id
         where i.title = '单节点请假' and t.seq = 1),
       'approve', '同意') $$,
  '末节点 approve 成功'
);
select throws_ok(
  $$ select public.act_task(
       (select t.id from public.approval_tasks t
          join public.approval_instances i on i.id = t.instance_id
         where i.title = '单节点请假' and t.seq = 1),
       'approve', '再点一次') $$,
  '22023', null, '同一任务二次 act 被拒（并发双审第二道防线）'
);

reset role;

select is(
  (select status from public.approval_instances where title = '单节点请假'),
  'approved', '末节点通过后实例 approved'
);
select is(
  (select t.status from public.approval_tasks t
     join public.approval_instances i on i.id = t.instance_id
    where i.title = '单节点请假' and t.seq = 1),
  'approved', '任务状态 approved'
);
select ok(
  (select t.acted_at is not null from public.approval_tasks t
     join public.approval_instances i on i.id = t.instance_id
    where i.title = '单节点请假' and t.seq = 1),
  '任务写入 acted_at'
);
select is(
  (select t.comment from public.approval_tasks t
     join public.approval_instances i on i.id = t.instance_id
    where i.title = '单节点请假' and t.seq = 1),
  '同意', '通过意见落库'
);
select is(
  (select count(*) from public.audit_operations
    where module = 'approval' and action = 'approve'
      and object_id = (select id::text from public.approval_instances where title = '单节点请假')),
  1::bigint, 'approve 写审计摘要'
);
select is(
  (select count(*) from public.messages
    where recipient_id = '00000000-0000-4000-c000-000000000001'
      and event_key = 'approval.approved'
      and ref_id = (select id::text from public.approval_instances where title = '单节点请假')),
  1::bigint, '通过后通知发起人（approval.approved）'
);

-- my_todos 已办视角（admin）
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-c000-000000000002', 'role', 'authenticated')::text,
  true
);
set local role authenticated;
select is(
  (select count(*) from public.my_todos(true) where title = '单节点请假'),
  0::bigint, '处理后待办不再出现'
);
select is(
  (select task_status from public.my_todos(false) where title = '单节点请假'),
  'approved', '已办列表带出任务状态'
);
reset role;

-- ---------------------------------------------------------------------------
-- H2. 多节点推进：node1 approve → current_seq+1 + 生成 node2 任务
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-c000-000000000001', 'role', 'authenticated')::text,
  true
);
set local role authenticated;
select ok(
  (select public.submit_instance('demo', 'trip', 'TRIP-2026-001', 'test.trip',
      '{"title":"多节点出差","city":"上海"}'::jsonb)) is not null,
  '多节点流程提交成功'
);
reset role;
select is(
  (select t.assignee_id from public.approval_tasks t
     join public.approval_instances i on i.id = t.instance_id
    where i.title = '多节点出差' and t.seq = 1),
  '00000000-0000-4000-c000-000000000002'::uuid, '多节点 node1 指派给 admin'
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-c000-000000000002', 'role', 'authenticated')::text,
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.act_task(
       (select t.id from public.approval_tasks t
          join public.approval_instances i on i.id = t.instance_id
         where i.title = '多节点出差' and t.seq = 1),
       'approve', null) $$,
  '非末节点 approve 成功'
);
reset role;

select is(
  (select current_seq from public.approval_instances where title = '多节点出差'),
  2, 'approve 后 current_seq 推进到 2'
);
select is(
  (select status from public.approval_instances where title = '多节点出差'),
  'running', '非末节点通过后实例仍 running'
);
select is(
  (select t.assignee_id from public.approval_tasks t
     join public.approval_instances i on i.id = t.instance_id
    where i.title = '多节点出差' and t.seq = 2),
  '00000000-0000-4000-c000-000000000003'::uuid, 'node2 任务指派给指定用户（user 规则）'
);
select is(
  (select t.status from public.approval_tasks t
     join public.approval_instances i on i.id = t.instance_id
    where i.title = '多节点出差' and t.seq = 2),
  'pending', 'node2 任务为 pending'
);
select is(
  (select count(*) from public.approval_tasks t
     join public.approval_instances i on i.id = t.instance_id
    where i.title = '多节点出差'),
  2::bigint, '实例共生成 2 条任务'
);
select is(
  (select count(*) from public.messages
    where recipient_id = '00000000-0000-4000-c000-000000000003'
      and event_key = 'approval.pending'
      and ref_id = (select id::text from public.approval_instances where title = '多节点出差')),
  1::bigint, 'node2 生成时通知新审批人'
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-c000-000000000003', 'role', 'authenticated')::text,
  true
);
set local role authenticated;
select is(
  (select count(*) from public.my_todos(true) where title = '多节点出差'),
  1::bigint, 'quality 待办出现 node2 任务'
);
select lives_ok(
  $$ select public.act_task(
       (select t.id from public.approval_tasks t
          join public.approval_instances i on i.id = t.instance_id
         where i.title = '多节点出差' and t.seq = 2),
       'approve', '同意出差') $$,
  '末节点 approve 成功（node2）'
);
reset role;

select is(
  (select status from public.approval_instances where title = '多节点出差'),
  'approved', '两节点全部通过后实例 approved'
);
select is(
  (select count(*) from public.messages
    where recipient_id = '00000000-0000-4000-c000-000000000001'
      and event_key = 'approval.approved'
      and ref_id = (select id::text from public.approval_instances where title = '多节点出差')),
  1::bigint, '末节点通过只通知发起人一次'
);

-- ---------------------------------------------------------------------------
-- H3. 驳回链路
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-c000-000000000001', 'role', 'authenticated')::text,
  true
);
set local role authenticated;
select ok(
  (select public.submit_instance('demo', 'leave', 'LV-2026-002', 'test.leave',
      '{"title":"驳回测试","days":3}'::jsonb)) is not null,
  '驳回用例提交成功'
);
reset role;

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-c000-000000000002', 'role', 'authenticated')::text,
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.act_task(
       (select t.id from public.approval_tasks t
          join public.approval_instances i on i.id = t.instance_id
         where i.title = '驳回测试' and t.seq = 1),
       'reject', '资料不全') $$,
  'reject（带意见）成功'
);
reset role;

select is(
  (select status from public.approval_instances where title = '驳回测试'),
  'rejected', '驳回后实例 rejected'
);
select is(
  (select t.comment from public.approval_tasks t
     join public.approval_instances i on i.id = t.instance_id
    where i.title = '驳回测试' and t.seq = 1),
  '资料不全', '驳回意见落库'
);
select is(
  (select count(*) from public.approval_tasks t
     join public.approval_instances i on i.id = t.instance_id
    where i.title = '驳回测试' and t.status = 'pending'),
  0::bigint, '驳回后该实例无 pending 任务'
);
select is(
  (select count(*) from public.messages
    where recipient_id = '00000000-0000-4000-c000-000000000001'
      and event_key = 'approval.rejected'
      and ref_id = (select id::text from public.approval_instances where title = '驳回测试')),
  1::bigint, '驳回后通知发起人（approval.rejected）'
);
select ok(
  (select body like '%资料不全%' from public.messages
    where recipient_id = '00000000-0000-4000-c000-000000000001'
      and event_key = 'approval.rejected'
      and ref_id = (select id::text from public.approval_instances where title = '驳回测试')),
  '驳回通知正文包含意见'
);
select is(
  (select count(*) from public.audit_operations
    where module = 'approval' and action = 'reject'
      and object_id = (select id::text from public.approval_instances where title = '驳回测试')),
  1::bigint, 'reject 写审计摘要'
);

-- ---------------------------------------------------------------------------
-- I. withdraw_instance 边界
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-c000-000000000001', 'role', 'authenticated')::text,
  true
);
set local role authenticated;
select ok(
  (select public.submit_instance('demo', 'leave', 'LV-2026-003', 'test.leave',
      '{"title":"撤回测试A","days":1}'::jsonb)) is not null,
  '撤回用例 A 提交成功'
);
reset role;

-- 非发起人撤回被拒（admin 可见实例但非发起人，权限校验先于状态）
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-c000-000000000002', 'role', 'authenticated')::text,
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.withdraw_instance(
       (select id from public.approval_instances where title = '撤回测试A')) $$,
  '42501', null, '非发起人撤回被拒（含 admin）'
);
reset role;

-- 发起人撤回成功
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-c000-000000000001', 'role', 'authenticated')::text,
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.withdraw_instance(
       (select id from public.approval_instances where title = '撤回测试A')) $$,
  '首节点未处理时可撤回'
);
select throws_ok(
  $$ select public.withdraw_instance(
       (select id from public.approval_instances where title = '撤回测试A')) $$,
  '22023', null, '已撤回实例不可再次撤回'
);
reset role;

select is(
  (select status from public.approval_instances where title = '撤回测试A'),
  'withdrawn', '撤回后实例 withdrawn'
);
select is(
  (select t.status from public.approval_tasks t
     join public.approval_instances i on i.id = t.instance_id
    where i.title = '撤回测试A' and t.seq = 1),
  'skipped', '撤回后 pending 任务置 skipped'
);
select is(
  (select count(*) from public.audit_operations
    where module = 'approval' and action = 'withdraw'
      and object_id = (select id::text from public.approval_instances where title = '撤回测试A')),
  1::bigint, 'withdraw 写审计摘要'
);

-- 已审批结束的实例不可撤回
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-c000-000000000001', 'role', 'authenticated')::text,
  true
);
set local role authenticated;
select ok(
  (select public.submit_instance('demo', 'leave', 'LV-2026-004', 'test.leave',
      '{"title":"撤回测试B","days":1}'::jsonb)) is not null,
  '撤回用例 B 提交成功'
);
reset role;

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-c000-000000000002', 'role', 'authenticated')::text,
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.act_task(
       (select t.id from public.approval_tasks t
          join public.approval_instances i on i.id = t.instance_id
         where i.title = '撤回测试B' and t.seq = 1),
       'approve', null) $$,
  '撤回用例 B 先通过'
);
reset role;

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-c000-000000000001', 'role', 'authenticated')::text,
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.withdraw_instance(
       (select id from public.approval_instances where title = '撤回测试B')) $$,
  '22023', null, '已通过实例不可撤回'
);
reset role;

-- ---------------------------------------------------------------------------
-- J. 任务唯一约束（并发双审第一道防线）
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ insert into public.approval_tasks (instance_id, seq, assignee_id)
     select i.id, 1, '00000000-0000-4000-c000-000000000002'
       from public.approval_instances i where i.title = '单节点请假' $$,
  '23505', null, '重复 (instance_id, seq) 直插被唯一约束拒绝'
);

-- 部分唯一索引：同实例已有 pending 时第二个 pending 被拒（先造 running 实例夹具，测完清场）
insert into public.approval_instances
  (title, module, template_version_id, flow_version_id, form_data, status, current_seq, initiator_id)
values (
  '约束测试实例', 'demo',
  '66666666-6666-4666-8666-666666666601', '77777777-7777-4777-8777-777777777701',
  '{}'::jsonb, 'running', 1, '00000000-0000-4000-c000-000000000004'
);
insert into public.approval_tasks (instance_id, seq, assignee_id)
select i.id, 1, '00000000-0000-4000-c000-000000000002'
  from public.approval_instances i where i.title = '约束测试实例';

select throws_ok(
  $$ insert into public.approval_tasks (instance_id, seq, assignee_id)
     select i.id, 2, '00000000-0000-4000-c000-000000000002'
       from public.approval_instances i where i.title = '约束测试实例' $$,
  '23505', null, '同实例第二个 pending 被部分唯一索引拒绝'
);

delete from public.approval_instances where title = '约束测试实例';

-- ---------------------------------------------------------------------------
-- K. published 冻结（仅 draft 可编辑；published 仅可流转 disabled）
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ update public.approval_form_templates
        set schema = '{"fields":[]}'::jsonb
      where code = 'test.leave' $$,
  '22023', null, '已发布模板 schema 不可修改'
);
select throws_ok(
  $$ update public.approval_form_templates
        set name = '改名尝试'
      where code = 'test.leave' $$,
  '22023', null, '已发布模板 name 不可修改'
);
select throws_ok(
  $$ update public.approval_flows
        set nodes = '[{"seq":1,"approver_rule":{"type":"role","value":"engineer"}}]'::jsonb
      where id = '77777777-7777-4777-8777-777777777701' $$,
  '22023', null, '已发布流程 nodes 不可修改'
);
select lives_ok(
  $$ update public.approval_form_templates
        set status = 'disabled'
      where code = 'test.leave' $$,
  '已发布模板可流转为 disabled'
);
select is(
  (select status from public.approval_form_templates where code = 'test.leave'),
  'disabled', '模板状态已停用'
);

-- ---------------------------------------------------------------------------
-- L. RLS：无关用户不可见 / 参与方可见 / 直写拒绝
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-c000-000000000004', 'role', 'authenticated')::text,
  true
);
set local role authenticated;
select is((select count(*) from public.approval_instances), 0::bigint, '无关用户不可见任何实例');
select is((select count(*) from public.approval_tasks), 0::bigint, '无关用户不可见任何任务');
reset role;

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-c000-000000000001', 'role', 'authenticated')::text,
  true
);
set local role authenticated;
select is((select count(*) from public.approval_instances), 5::bigint, '发起人可见自己全部 5 个实例');
select is((select count(*) from public.approval_tasks), 6::bigint, '发起人可见所属实例的全部 6 条任务行（initiator 参与方）');
reset role;

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-c000-000000000002', 'role', 'authenticated')::text,
  true
);
set local role authenticated;
select is((select count(*) from public.approval_instances), 5::bigint, 'admin 可见全部实例');
select is((select count(*) from public.form_renderers where module = 'demo' and ref_type = 'leave'),
          1::bigint, 'form_renderers 登录用户可读');
select throws_ok(
  $$ insert into public.approval_instances
       (title, module, ref_type, ref_id, template_version_id, flow_version_id, form_data, initiator_id)
     values ('hack', 'demo', null, null,
             '66666666-6666-4666-8666-666666666601',
             '77777777-7777-4777-8777-777777777701',
             '{}'::jsonb, '00000000-0000-4000-c000-000000000002') $$,
  '42501', null, 'authenticated 直插实例被拒'
);
select throws_ok(
  $$ update public.approval_instances set title = 'hack' $$,
  '42501', null, 'authenticated 直改实例被拒'
);
select throws_ok(
  $$ delete from public.approval_tasks $$,
  '42501', null, 'authenticated 直删任务被拒'
);
reset role;

-- ---------------------------------------------------------------------------
-- M. seed 004：demo 模板 + 单节点流程
-- ---------------------------------------------------------------------------
select is(
  (select count(*) from public.approval_form_templates
    where code = 'demo.leave' and status = 'published'),
  1::bigint, 'seed demo.leave 模板已发布'
);
select is(
  (select count(*) from public.approval_flows f
     join public.approval_form_templates t on t.id = f.template_id
    where t.code = 'demo.leave'
      and f.status = 'published'
      and f.nodes @> '[{"approver_rule":{"type":"role","value":"admin"}}]'::jsonb),
  1::bigint, 'seed demo.leave 流程绑定 role=admin'
);

select * from finish();
rollback;
