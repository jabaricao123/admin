-- pgTAP：approval cc 抄送数据链路（批次 1）— submit cc 数组 / 节点 cc_rule / approval.cc 通知 /
--       变量渲染（initiator/comment 对齐）/ mark_cc_read 与 messages.read_at 同源
-- 运行：supabase test db（建议先 supabase db reset，seed 004 提供 demo 数据）
-- 覆盖：
--   A. 结构：add_instance_ccs 存在、submit_instance 6 参签名与 default、授权面、事件注册与变量清单；
--   B. 提交带 cc 数组：落库 + 去重 + 排除发起人自身/停用用户 + approval.cc 通知与 initiator 渲染；
--   C. my_ccs 不再为空 + mark_cc_read 同步 messages.read_at（既有死代码激活验证）；
--   D. 驳回通知 comment 变量渲染；
--   E. 节点 cc_rule（role=admin）：act 推进下一节点时落 cc + 通知；pending 通知 initiator 渲染；
--   F. submit cc 与节点 cc_rule 同人去重（不重复通知）。

begin;
select plan(50);

\set u1 'eeeeeeee-eeee-4eee-8eee-eeeeeeee0001'
\set u2 'eeeeeeee-eeee-4eee-8eee-eeeeeeee0002'
\set u3 'eeeeeeee-eeee-4eee-8eee-eeeeeeee0003'
\set u4 'eeeeeeee-eeee-4eee-8eee-eeeeeeee0004'
\set u5 'eeeeeeee-eeee-4eee-8eee-eeeeeeee0005'

\set tpl1  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01'
\set flow1 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee02'
\set tpl2  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee03'
\set flow2 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee04'

\set mt_cc       'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee05'
\set mt_pending  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee06'
\set mt_approved 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee07'
\set mt_rejected 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee08'
\set mt_urge     'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee09'

-- ---------------------------------------------------------------------------
-- 夹具（as postgres；auth.users 触发器自动建档）
--   u1 工程师（发起人）/ u2 管理员（审批人 & 节点 cc_rule 目标）/ u3 质检（cc 人 & 节点2 审批人）
--   u4 计划员（先停用，验证排除）/ u5 计划员（第二 cc 人）
-- created_at 固定 2026-01-01：resolve_approver 按「建档最早」取 admin 时确定性优先于 seed 账号
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
  (:'u1', 'cc-chain-eng@example.com',
   '{"provider":"email","providers":["email"],"role":"engineer"}', '{"full_name":"链路发起人"}'),
  (:'u2', 'cc-chain-admin@example.com',
   '{"provider":"email","providers":["email"],"role":"admin"}', '{"full_name":"链路管理员"}'),
  (:'u3', 'cc-chain-quality@example.com',
   '{"provider":"email","providers":["email"],"role":"quality"}', '{"full_name":"链路质检"}'),
  (:'u4', 'cc-chain-inactive@example.com',
   '{"provider":"email","providers":["email"],"role":"planner"}', '{"full_name":"链路停用"}'),
  (:'u5', 'cc-chain-planner@example.com',
   '{"provider":"email","providers":["email"],"role":"planner"}', '{"full_name":"链路计划"}');

update public.profiles
   set created_at = '2026-01-01T00:00:00Z'
 where id in (:'u1', :'u2', :'u3', :'u4', :'u5');

update public.profiles set status = 'inactive' where id = :'u4';

-- 模板 + 流程：flow1 单节点无 cc_rule；flow2 节点2 带 cc_rule role=admin
insert into public.approval_form_templates (id, name, code, module, version, schema, status) values
  (:'tpl1', 'cc 单节点测试', 'cc.chain', 'demo', 1,
   '{"fields":[{"key":"title","label":"标题","type":"text","required":true}]}'::jsonb, 'published'),
  (:'tpl2', 'cc 双节点测试', 'cc.two', 'demo', 1,
   '{"fields":[{"key":"title","label":"标题","type":"text","required":true}]}'::jsonb, 'published');

insert into public.approval_flows (id, name, template_id, version, nodes, status) values
  (:'flow1', 'cc 单节点流程', :'tpl1', 1,
   jsonb_build_array(
     jsonb_build_object('seq', 1,
       'approver_rule', jsonb_build_object('type', 'user', 'value', :'u2'))
   ), 'published'),
  (:'flow2', 'cc 双节点流程', :'tpl2', 1,
   jsonb_build_array(
     jsonb_build_object('seq', 1,
       'approver_rule', jsonb_build_object('type', 'user', 'value', :'u2')),
     jsonb_build_object('seq', 2,
       'approver_rule', jsonb_build_object('type', 'user', 'value', :'u3'),
       'cc_rule', jsonb_build_object('type', 'role', 'value', 'admin'))
   ), 'published');

-- 已发布站内信模板：验证 vars 真实渲染（渲染优先级：模板 > fallback vars 直传）
insert into public.message_templates
  (id, event_key, channel, subject_tpl, body_tpl, version, status) values
  (:'mt_cc',       'approval.cc',       'inbox', '{{title}}', '{{initiator}} 提交的申请已抄送给你', 1, 'published'),
  (:'mt_pending',  'approval.pending',  'inbox', '{{title}}', '{{initiator}} 的申请待你处理',       1, 'published'),
  (:'mt_approved', 'approval.approved', 'inbox', '{{title}}', '审批意见：{{comment}}',             1, 'published'),
  (:'mt_rejected', 'approval.rejected', 'inbox', '{{title}}', '驳回意见：{{comment}}',             1, 'published'),
  (:'mt_urge',     'approval.urge',     'inbox', '{{title}}', '{{initiator}} 催促你尽快处理该审批申请', 1, 'published');

insert into public.message_template_current (event_key, channel, template_id) values
  ('approval.cc',       'inbox', :'mt_cc'),
  ('approval.pending',  'inbox', :'mt_pending'),
  ('approval.approved', 'inbox', :'mt_approved'),
  ('approval.rejected', 'inbox', :'mt_rejected'),
  ('approval.urge',     'inbox', :'mt_urge');

-- ---------------------------------------------------------------------------
-- A. 结构 / 签名 / 授权 / 事件注册（12）
-- ---------------------------------------------------------------------------
select has_function('app', 'add_instance_ccs', array['uuid', 'uuid[]'],
                    'A1 app.add_instance_ccs 存在');
select has_function('app', 'submit_instance', array['text', 'text', 'text', 'text', 'jsonb', 'uuid[]'],
                    'A2 app.submit_instance 6 参签名存在');
select has_function('public', 'submit_instance', array['text', 'text', 'text', 'text', 'jsonb', 'uuid[]'],
                    'A3 public.submit_instance 6 参签名存在');
select ok(
  (select pg_get_function_arguments(p.oid) like '%p_cc_user_ids uuid[] DEFAULT NULL%'
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'submit_instance'),
  'A4 p_cc_user_ids 默认 null（旧 5 参调用兼容）'
);
select ok(
  has_function_privilege('authenticated', 'public.submit_instance(text,text,text,text,jsonb,uuid[])', 'EXECUTE'),
  'A5 authenticated 可执行 public.submit_instance（新签名）'
);
select ok(
  not has_function_privilege('anon', 'public.submit_instance(text,text,text,text,jsonb,uuid[])', 'EXECUTE'),
  'A6 anon 不可执行 public.submit_instance'
);
select ok(
  not has_function_privilege('authenticated', 'app.add_instance_ccs(uuid,uuid[])', 'EXECUTE'),
  'A7 authenticated 不可执行 add_instance_ccs（内部 RPC）'
);
select is(
  (select available_vars from public.message_event_registry where event_key = 'approval.cc'),
  '["initiator","title"]'::jsonb, 'A8 approval.cc 已注册且变量 = initiator,title'
);
select is(
  (select available_vars from public.message_event_registry where event_key = 'approval.pending'),
  '["initiator","title"]'::jsonb, 'A9 approval.pending 注册变量与实际发送一致'
);
select is(
  (select available_vars from public.message_event_registry where event_key = 'approval.approved'),
  '["title","comment"]'::jsonb, 'A10 approval.approved 注册变量与实际发送一致'
);
select is(
  (select available_vars from public.message_event_registry where event_key = 'approval.rejected'),
  '["title","comment"]'::jsonb, 'A11 approval.rejected 注册变量与实际发送一致'
);
select is(
  (select available_vars from public.message_event_registry where event_key = 'approval.urge'),
  '["initiator","title"]'::jsonb, 'A12 approval.urge 注册变量与实际发送一致'
);

-- ---------------------------------------------------------------------------
-- B. 提交带 cc 数组：落库 / 去重 / 排除 + approval.cc 通知与变量渲染（13）
-- ---------------------------------------------------------------------------
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', :'u1', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select public.submit_instance(
  'demo', 'cc_chain', 'CC-A', 'cc.chain',
  '{"title":"链路A"}'::jsonb,
  array[:'u3'::uuid, :'u5'::uuid, :'u3'::uuid, :'u1'::uuid, :'u4'::uuid]
) as inst_a \gset

reset role;

select is(
  (select count(*) from public.approval_ccs where instance_id = :'inst_a'::uuid),
  2::bigint, 'B1 去重后落 2 行 cc'
);
select is(
  (select count(*) from public.approval_ccs
    where instance_id = :'inst_a'::uuid and cc_user_id = :'u3'::uuid),
  1::bigint, 'B2 质检 u3 已 cc'
);
select is(
  (select count(*) from public.approval_ccs
    where instance_id = :'inst_a'::uuid and cc_user_id = :'u5'::uuid),
  1::bigint, 'B3 计划 u5 已 cc'
);
select is(
  (select count(*) from public.approval_ccs
    where instance_id = :'inst_a'::uuid and cc_user_id = :'u1'::uuid),
  0::bigint, 'B4 发起人自身被排除'
);
select is(
  (select count(*) from public.approval_ccs
    where instance_id = :'inst_a'::uuid and cc_user_id = :'u4'::uuid),
  0::bigint, 'B5 已停用用户被排除'
);
select is(
  (select count(*) from public.messages
    where event_key = 'approval.cc' and recipient_id = :'u3'::uuid and ref_id = :'inst_a'),
  1::bigint, 'B6 数组内重复 cc 不重复通知'
);
select is(
  (select count(*) from public.messages
    where event_key = 'approval.cc' and recipient_id = :'u5'::uuid and ref_id = :'inst_a'),
  1::bigint, 'B7 u5 收到 1 条 approval.cc'
);
select is(
  (select count(*) from public.messages where event_key = 'approval.cc' and ref_id = :'inst_a'),
  2::bigint, 'B8 本实例共 2 条 approval.cc 通知'
);
select is(
  (select title from public.messages
    where event_key = 'approval.cc' and recipient_id = :'u3'::uuid and ref_id = :'inst_a'),
  '抄送：链路A', 'B9 approval.cc 标题变量渲染'
);
select is(
  (select body from public.messages
    where event_key = 'approval.cc' and recipient_id = :'u3'::uuid and ref_id = :'inst_a'),
  '链路发起人 提交的申请已抄送给你', 'B10 approval.cc 含 initiator 变量渲染'
);
select is(
  (select ref_type || ':' || ref_id from public.messages
    where event_key = 'approval.cc' and recipient_id = :'u3'::uuid),
  'approval_instance:' || :'inst_a', 'B11 通知 ref 指向实例（mark_cc_read 同源依据）'
);
select is(
  (select body from public.messages
    where event_key = 'approval.pending' and recipient_id = :'u2'::uuid and ref_id = :'inst_a'),
  '链路发起人 的申请待你处理', 'B12 submit pending 通知含 initiator 变量'
);
select is(
  (select title from public.messages
    where event_key = 'approval.pending' and recipient_id = :'u2'::uuid and ref_id = :'inst_a'),
  '待审批：链路A', 'B13 submit pending 标题渲染'
);

-- ---------------------------------------------------------------------------
-- C. my_ccs 不再为空 + mark_cc_read 同步 messages.read_at（8）
-- ---------------------------------------------------------------------------
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', :'u3', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select is(
  (select count(*) from public.my_ccs(false)),
  1::bigint, 'C1 u3 的「抄送我的」列表不再为空'
);
select is(
  (select count(*) from public.my_ccs(true)),
  1::bigint, 'C2 未读抄送 1 条'
);
select isnt(
  (select public.mark_cc_read(:'inst_a'::uuid)),
  null, 'C3 进详情标记已读返回 read_at'
);
select is(
  (select count(*) from public.my_ccs(true)),
  0::bigint, 'C4 标记后未读抄送为 0'
);

reset role;

select isnt(
  (select read_at from public.approval_ccs
    where instance_id = :'inst_a'::uuid and cc_user_id = :'u3'::uuid),
  null, 'C5 approval_ccs.read_at 已写（业务标记）'
);
select isnt(
  (select read_at from public.messages
    where event_key = 'approval.cc' and recipient_id = :'u3'::uuid and ref_id = :'inst_a'),
  null, 'C6 messages.read_at 同步（未读唯一事实源）'
);
select ok(
  (select read_at from public.messages
    where event_key = 'approval.cc' and recipient_id = :'u5'::uuid and ref_id = :'inst_a') is null,
  'C7 标记仅作用于本人消息（u5 仍未读）'
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', :'u3', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select is(
  (select public.mark_cc_read(:'inst_a'::uuid)),
  (select read_at from public.approval_ccs
    where instance_id = :'inst_a'::uuid and cc_user_id = :'u3'::uuid),
  'C8 重复标记幂等（read_at 不变）'
);

-- ---------------------------------------------------------------------------
-- D. 驳回：通知 comment 变量渲染（3）
-- ---------------------------------------------------------------------------
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', :'u2', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select public.act_task(
  (select id from public.approval_tasks
    where instance_id = :'inst_a'::uuid and seq = 1),
  'reject', '材料不全');

reset role;

select is(
  (select status from public.approval_instances where id = :'inst_a'::uuid),
  'rejected', 'D1 驳回后实例状态 rejected'
);
select is(
  (select body from public.messages
    where event_key = 'approval.rejected' and recipient_id = :'u1'::uuid and ref_id = :'inst_a'),
  '驳回意见：材料不全', 'D2 驳回通知含 comment 变量渲染'
);
select is(
  (select title from public.messages
    where event_key = 'approval.rejected' and recipient_id = :'u1'::uuid and ref_id = :'inst_a'),
  '审批已驳回：链路A', 'D3 驳回通知标题渲染'
);

-- ---------------------------------------------------------------------------
-- E. 节点 cc_rule：act 推进下一节点时落 cc + 通知（9）
-- ---------------------------------------------------------------------------
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', :'u1', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

-- 旧 5 参调用（不传 p_cc_user_ids）：兼容性验证
select public.submit_instance(
  'demo', 'cc_chain', 'CC-B', 'cc.two',
  '{"title":"链路B"}'::jsonb
) as inst_b \gset

reset role;

select is(
  (select count(*) from public.approval_ccs where instance_id = :'inst_b'::uuid),
  0::bigint, 'E1 未传 cc 且首节点无 cc_rule → cc 为空'
);
select is(
  (select count(*) from public.messages where event_key = 'approval.cc' and ref_id = :'inst_b'),
  0::bigint, 'E2 未传 cc 不发 approval.cc 通知'
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', :'u2', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select public.act_task(
  (select id from public.approval_tasks
    where instance_id = :'inst_b'::uuid and seq = 1),
  'approve', '同意');

reset role;

select is(
  (select count(*) from public.approval_ccs where instance_id = :'inst_b'::uuid),
  1::bigint, 'E3 节点2 cc_rule 落 1 行 cc'
);
select is(
  (select cc_user_id from public.approval_ccs where instance_id = :'inst_b'::uuid),
  :'u2'::uuid, 'E4 cc_rule role=admin 解析到最早建档管理员'
);
select is(
  (select count(*) from public.messages
    where event_key = 'approval.cc' and recipient_id = :'u2'::uuid and ref_id = :'inst_b'),
  1::bigint, 'E5 节点 cc 发 1 条 approval.cc 通知'
);
select is(
  (select body from public.messages
    where event_key = 'approval.pending' and recipient_id = :'u3'::uuid and ref_id = :'inst_b'),
  '链路发起人 的申请待你处理', 'E6 act 推进的 pending 通知含 initiator 变量'
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', :'u3', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select public.act_task(
  (select id from public.approval_tasks
    where instance_id = :'inst_b'::uuid and seq = 2),
  'approve', '看起来不错');

reset role;

select is(
  (select status from public.approval_instances where id = :'inst_b'::uuid),
  'approved', 'E7 节点2 通过后实例 approved'
);
select is(
  (select body from public.messages
    where event_key = 'approval.approved' and recipient_id = :'u1'::uuid and ref_id = :'inst_b'),
  '审批意见：看起来不错', 'E8 通过通知含 comment 变量渲染'
);
select is(
  (select count(*) from public.messages
    where event_key = 'approval.cc' and recipient_id = :'u2'::uuid and ref_id = :'inst_b'),
  1::bigint, 'E9 末节点通过不重复 cc 通知'
);

-- ---------------------------------------------------------------------------
-- F. submit cc 与节点 cc_rule 同人去重（5）
-- ---------------------------------------------------------------------------
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', :'u1', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select public.submit_instance(
  'demo', 'cc_chain', 'CC-C', 'cc.two',
  '{"title":"链路C"}'::jsonb,
  array[:'u2'::uuid]
) as inst_c \gset

reset role;

select is(
  (select count(*) from public.approval_ccs where instance_id = :'inst_c'::uuid),
  1::bigint, 'F1 submit cc 落 1 行'
);
select is(
  (select count(*) from public.messages
    where event_key = 'approval.cc' and recipient_id = :'u2'::uuid and ref_id = :'inst_c'),
  1::bigint, 'F2 submit cc 发 1 条通知'
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', :'u2', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select public.act_task(
  (select id from public.approval_tasks
    where instance_id = :'inst_c'::uuid and seq = 1),
  'approve', '');

reset role;

select is(
  (select count(*) from public.approval_ccs where instance_id = :'inst_c'::uuid),
  1::bigint, 'F3 节点 cc_rule 对已 cc 用户去重（不新增行）'
);
select is(
  (select count(*) from public.messages
    where event_key = 'approval.cc' and recipient_id = :'u2'::uuid and ref_id = :'inst_c'),
  1::bigint, 'F4 节点 cc_rule 对已 cc 用户不重复通知'
);

-- ---------------------------------------------------------------------------
-- G. 催办：通知 initiator 变量对齐（1）
-- ---------------------------------------------------------------------------
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', :'u1', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select public.urge_instance(:'inst_c'::uuid);

reset role;

select is(
  (select body from public.messages
    where event_key = 'approval.urge' and recipient_id = :'u3'::uuid and ref_id = :'inst_c'),
  '链路发起人 催促你尽快处理该审批申请', 'G1 urge 通知含 initiator 变量渲染'
);

select * from finish();
rollback;
