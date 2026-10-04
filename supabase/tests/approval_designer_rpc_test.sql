-- pgTAP：approval/008+009+010+011+012 — 模板设计器/流程配置管理 RPC + simulate 一致性 + emit_event 验收
-- 运行：supabase test db（建议先 supabase db reset，seed 004 提供 demo 数据）
-- 覆盖：函数存在与授权（admin 校验/anon 与越权拒绝）、模板 upsert/publish/disable/new_version、
--       schema 校验（非法字段名/选项/重复 key）、published 冻结（触发器 + 入口双层）、
--       流程 nodes 校验（seq 连续/审批人三型）、停用守卫（running 实例引用数）、
--       版本化端到端（发布新版旧实例仍绑旧 schema）、simulate 与真实 submit 同一 resolve_approver
--       （designer 夹具 + demo seed 双对照）、usage counts、submit→approval.submitted /
--       act→approval.approved 事件落库（integration/004 软依赖已生效）。

begin;
select plan(91);

-- ---------------------------------------------------------------------------
-- 夹具（as postgres；auth.users 触发器自动建档）
--   d...001 设计器管理员 / d...002 发起工程师 / d...003 指定审批人（quality）
-- created_at 固定 2026-01-01：resolve_approver 按建档最早取 admin 时优先于 seed 账号
-- ---------------------------------------------------------------------------
insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
  ('99999999-9999-4999-8999-999999999001', 'designer-admin@example.com',
   '{"provider":"email","providers":["email"],"role":"admin"}', '{"full_name":"设计器管理员"}'),
  ('99999999-9999-4999-8999-999999999002', 'designer-eng@example.com',
   '{"provider":"email","providers":["email"],"role":"engineer"}', '{"full_name":"设计器工程师"}'),
  ('99999999-9999-4999-8999-999999999003', 'designer-quality@example.com',
   '{"provider":"email","providers":["email"],"role":"quality"}', '{"full_name":"设计器质检"}');

update public.profiles
   set created_at = '2026-01-01T00:00:00Z'
 where id in (
   '99999999-9999-4999-8999-999999999001',
   '99999999-9999-4999-8999-999999999002',
   '99999999-9999-4999-8999-999999999003'
 );

insert into public.departments (id, name, leader_id, sort_order, status)
values ('99999999-9999-4999-8999-999999999101', '设计器测试部',
        '99999999-9999-4999-8999-999999999001', 1, 'active');

update public.profiles
   set department_id = '99999999-9999-4999-8999-999999999101'
 where id = '99999999-9999-4999-8999-999999999002';

-- ===========================================================================
-- A. 结构 / 权限 / 软依赖（9）
-- ===========================================================================
select ok(
  to_regprocedure('app.upsert_form_template(text,text,text,jsonb,uuid)') is not null
  and to_regprocedure('app.publish_form_template(uuid)') is not null
  and to_regprocedure('app.disable_form_template(uuid)') is not null
  and to_regprocedure('app.new_form_template_version(uuid)') is not null,
  'A1 模板管理 RPC（app 侧）4 个函数存在'
);
select ok(
  to_regprocedure('app.upsert_flow(text,uuid,jsonb,uuid)') is not null
  and to_regprocedure('app.publish_flow(uuid)') is not null
  and to_regprocedure('app.disable_flow(uuid)') is not null
  and to_regprocedure('app.new_flow_version(uuid)') is not null,
  'A2 流程管理 RPC（app 侧）4 个函数存在'
);
select ok(
  to_regprocedure('app.simulate_flow(uuid,jsonb,uuid)') is not null
  and to_regprocedure('app.approval_usage_counts()') is not null,
  'A3 simulate_flow / approval_usage_counts（app 侧）存在'
);
select ok(
  to_regprocedure('public.upsert_form_template(text,text,text,jsonb,uuid)') is not null
  and to_regprocedure('public.publish_form_template(uuid)') is not null
  and to_regprocedure('public.disable_form_template(uuid)') is not null
  and to_regprocedure('public.new_form_template_version(uuid)') is not null
  and to_regprocedure('public.upsert_flow(text,uuid,jsonb,uuid)') is not null
  and to_regprocedure('public.publish_flow(uuid)') is not null
  and to_regprocedure('public.disable_flow(uuid)') is not null
  and to_regprocedure('public.new_flow_version(uuid)') is not null
  and to_regprocedure('public.simulate_flow(uuid,jsonb,uuid)') is not null
  and to_regprocedure('public.approval_usage_counts()') is not null,
  'A4 public 薄包装 10 个函数存在'
);
select ok((
  select count(*) = 10
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app'
    and p.proname in ('upsert_form_template', 'publish_form_template', 'disable_form_template',
                      'new_form_template_version', 'upsert_flow', 'publish_flow', 'disable_flow',
                      'new_flow_version', 'simulate_flow', 'approval_usage_counts')
    and p.prosecdef
    and p.proconfig = array['search_path=""']
), 'A5 app 侧 10 个管理 RPC 均 security definer + search_path 固定为空'
);
select ok((
  select count(*) = 10
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('upsert_form_template', 'publish_form_template', 'disable_form_template',
                      'new_form_template_version', 'upsert_flow', 'publish_flow', 'disable_flow',
                      'new_flow_version', 'simulate_flow', 'approval_usage_counts')
    and p.prosecdef
    and p.proconfig = array['search_path=""']
), 'A6 public 侧 10 个薄包装均 security definer + search_path 固定为空'
);
select ok(
  has_function_privilege('authenticated', 'app.upsert_form_template(text,text,text,jsonb,uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'app.simulate_flow(uuid,jsonb,uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.upsert_flow(text,uuid,jsonb,uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.approval_usage_counts()', 'EXECUTE'),
  'A7 authenticated 可执行管理 RPC（admin 校验在实现内）'
);
select ok(
  not has_function_privilege('anon', 'public.upsert_form_template(text,text,text,jsonb,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.simulate_flow(uuid,jsonb,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.approval_usage_counts()', 'EXECUTE'),
  'A8 anon 无管理 RPC 执行权'
);
select ok(
  not has_function_privilege('authenticated', 'app.validate_template_schema(jsonb)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.validate_flow_nodes(jsonb)', 'EXECUTE'),
  'A9 校验 helper 不授 API 角色（INDEX 规则 10）'
);

-- ===========================================================================
-- B. 模板：草稿编辑 / schema 校验 / 发布 / 冻结（14）
-- ===========================================================================
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '99999999-9999-4999-8999-999999999001', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select lives_ok(
  $$ select public.upsert_form_template(
       '设计器主模板', 'designer.main', 'demo',
       '{"fields":[
          {"key":"title","label":"申请标题","type":"text","required":true},
          {"key":"days","label":"请假天数","type":"number","required":true},
          {"key":"note","label":"备注","type":"text"}
        ]}'::jsonb) $$,
  'B1 admin 新建模板 v1 draft 成功'
);
select is(
  (select version::text || '/' || status from public.approval_form_templates where code = 'designer.main'),
  '1/draft', 'B2 新建模板为 version=1 + draft'
);
select throws_ok(
  $$ select public.upsert_form_template(
       '重复', 'designer.main', 'demo',
       '{"fields":[{"key":"a","label":"a","type":"text"}]}'::jsonb) $$,
  '22023', null, 'B3 p_id=null 且 code 已存在被拒（提示使用「新版本」）'
);
select throws_ok(
  $$ select public.upsert_form_template('坏 schema', 'designer.bad1', 'demo', '{}'::jsonb) $$,
  '22023', null, 'B4 schema 缺 fields 数组被拒'
);
select throws_ok(
  $$ select public.upsert_form_template('坏字段名', 'designer.bad2', 'demo',
       '{"fields":[{"key":"1bad","label":"坏","type":"text"}]}'::jsonb) $$,
  '22023', null, 'B5 非法字段名（数字开头）被拒'
);
select throws_ok(
  $$ select public.upsert_form_template('重复字段', 'designer.bad3', 'demo',
       '{"fields":[{"key":"title","label":"A","type":"text"},{"key":"title","label":"B","type":"text"}]}'::jsonb) $$,
  '22023', null, 'B6 重复字段名被拒'
);
select throws_ok(
  $$ select public.upsert_form_template('缺选项', 'designer.bad4', 'demo',
       '{"fields":[{"key":"kind","label":"类型","type":"select"}]}'::jsonb) $$,
  '22023', null, 'B7 select 缺少选项被拒'
);
select lives_ok(
  $$ select public.upsert_form_template(
       '设计器主模板（改）', 'designer.main', 'demo',
       '{"fields":[
          {"key":"title","label":"申请标题（改）","type":"text","required":true},
          {"key":"days","label":"请假天数","type":"number","required":true},
          {"key":"note","label":"备注","type":"text"}
        ]}'::jsonb,
       (select id from public.approval_form_templates where code = 'designer.main')) $$,
  'B8 p_id 提供：draft 行全字段可改'
);
select is(
  (select schema -> 'fields' -> 0 ->> 'label'
     from public.approval_form_templates where code = 'designer.main' and version = 1),
  '申请标题（改）', 'B9 draft 修改已落库'
);

-- 夹具：直接入库一条非法 schema 草稿（模拟历史脏数据），验证 publish 会复校
reset role;
insert into public.approval_form_templates (name, code, module, version, schema, status)
values ('非法 schema 草稿', 'designer.invalid', 'demo', 1,
        '{"fields":[{"key":"bad key","label":"x","type":"text"}]}'::jsonb, 'draft');
set local role authenticated;

select throws_ok(
  $$ select public.publish_form_template(
       (select id from public.approval_form_templates where code = 'designer.invalid')) $$,
  '22023', null, 'B10 发布前 schema 复校：非法字段名草稿拒绝发布'
);
select lives_ok(
  $$ select public.publish_form_template(
       (select id from public.approval_form_templates where code = 'designer.main' and version = 1)) $$,
  'B11 admin 发布 v1 成功'
);
select is(
  (select status from public.approval_form_templates where code = 'designer.main' and version = 1),
  'published', 'B12 发布后状态为 published'
);
select throws_ok(
  $$ select public.upsert_form_template(
       '改已发布', 'designer.main', 'demo',
       '{"fields":[{"key":"title","label":"t","type":"text"}]}'::jsonb,
       (select id from public.approval_form_templates where code = 'designer.main' and version = 1)) $$,
  '22023', null, 'B13 入口层：published 行禁改（提示「新版本」）'
);

reset role;
select throws_ok(
  $$ update public.approval_form_templates set schema = '{"fields":[]}'::jsonb
      where code = 'designer.main' and version = 1 $$,
  '22023', null, 'B14 触发器层：published 行内容直改被拒（001 冻结触发器）'
);

-- ===========================================================================
-- C. 流程：nodes 校验 / 发布 / 提交绑定 v1（13）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '99999999-9999-4999-8999-999999999001', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select lives_ok(
  $$ select public.upsert_flow(
       '设计器主流程',
       (select id from public.approval_form_templates where code = 'designer.main' and version = 1),
       '[{"seq":1,"approver_rule":{"type":"role","value":"admin"},"timeout_hours":24}]'::jsonb) $$,
  'C1 admin 新建流程 v1 draft 成功'
);
select is(
  (select version::text || '/' || status from public.approval_flows
    where name = '设计器主流程'), '1/draft', 'C2 流程为 version=1 + draft'
);
select throws_ok(
  $$ select public.upsert_flow('绑定不存在模板', '00000000-0000-4000-a000-00000000dead',
       '[{"seq":1,"approver_rule":{"type":"role","value":"admin"}}]'::jsonb) $$,
  'P0002', null, 'C3 绑定不存在的模板被拒'
);
select throws_ok(
  $$ select public.upsert_flow('seq 不连续',
       (select id from public.approval_form_templates where code = 'designer.main' and version = 1),
       '[{"seq":1,"approver_rule":{"type":"role","value":"admin"}},
         {"seq":3,"approver_rule":{"type":"role","value":"admin"}}]'::jsonb) $$,
  '22023', null, 'C4 seq 不连续（跳号）被拒'
);
select throws_ok(
  $$ select public.upsert_flow('非法规则类型',
       (select id from public.approval_form_templates where code = 'designer.main' and version = 1),
       '[{"seq":1,"approver_rule":{"type":"boss","value":"admin"}}]'::jsonb) $$,
  '22023', null, 'C5 approver_rule.type 非法被拒'
);
select throws_ok(
  $$ select public.upsert_flow('角色不存在',
       (select id from public.approval_form_templates where code = 'designer.main' and version = 1),
       '[{"seq":1,"approver_rule":{"type":"role","value":"not_a_role"}}]'::jsonb) $$,
  'P0002', null, 'C6 role 值不存在被拒'
);
select throws_ok(
  $$ select public.upsert_flow('用户非法',
       (select id from public.approval_form_templates where code = 'designer.main' and version = 1),
       '[{"seq":1,"approver_rule":{"type":"user","value":"not-a-uuid"}}]'::jsonb) $$,
  '22023', null, 'C7 user 规则 value 非 uuid 被拒'
);
select throws_ok(
  $$ select public.upsert_flow('负超时',
       (select id from public.approval_form_templates where code = 'designer.main' and version = 1),
       '[{"seq":1,"approver_rule":{"type":"role","value":"admin"},"timeout_hours":-1}]'::jsonb) $$,
  '22023', null, 'C8 超时时长负数被拒'
);
select lives_ok(
  $$ select public.publish_flow(
       (select id from public.approval_flows where name = '设计器主流程' and version = 1)) $$,
  'C9 admin 发布流程 v1 成功'
);
select is(
  (select status from public.approval_flows where name = '设计器主流程' and version = 1),
  'published', 'C10 发布后流程状态为 published'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '99999999-9999-4999-8999-999999999002', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select lives_ok(
  $$ select public.submit_instance('demo', 'demo_leave', '', 'designer.main',
       '{"title":"设计器实例一","days":2,"note":"v1 数据"}'::jsonb) $$,
  'C11 工程师按 v1 模板提交实例成功（真实 submit 路径）'
);

-- 模板/流程表 RLS 仅 admin 可读：切回 admin 断言绑定版本
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '99999999-9999-4999-8999-999999999001', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select is(
  (select t.version::text || '/' || f.version
     from public.approval_instances i
     join public.approval_form_templates t on t.id = i.template_version_id
     join public.approval_flows f on f.id = i.flow_version_id
    where i.title = '设计器实例一'),
  '1/1', 'C12 实例绑定模板 v1 + 流程 v1'
);
select is(
  (select tk.assignee_id::text
     from public.approval_tasks tk
     join public.approval_instances i on i.id = tk.instance_id
    where i.title = '设计器实例一' and tk.seq = 1),
  '99999999-9999-4999-8999-999999999001',
  'C13 首节点审批人经 resolve_approver 解析为最早 admin'
);

-- ===========================================================================
-- D. 版本化端到端：新版发布不影响旧实例（14）
-- ===========================================================================
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '99999999-9999-4999-8999-999999999001', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select lives_ok(
  $$ select public.new_form_template_version(
       (select id from public.approval_form_templates where code = 'designer.main' and version = 1)) $$,
  'D1 「新版本」基于 v1 复制出 v2 draft'
);
select is(
  (select version::text || '/' || status from public.approval_form_templates
    where code = 'designer.main' and version = 2),
  '2/draft', 'D2 新版本为 v2 draft'
);
select lives_ok(
  $$ select public.new_flow_version(
       (select id from public.approval_flows where name = '设计器主流程' and version = 1)) $$,
  'D3 「新版本」基于流程 v1 复制出 v2 draft'
);
select is(
  (select version::text || '/' || status from public.approval_flows
    where name = '设计器主流程' and version = 2),
  '2/draft', 'D4 流程新版本为 v2 draft'
);
select lives_ok(
  $$ select public.upsert_form_template(
       '设计器主模板', 'designer.main', 'demo',
       '{"fields":[
          {"key":"title","label":"申请标题","type":"text","required":true},
          {"key":"hours","label":"请假小时数","type":"number","required":true}
        ]}'::jsonb,
       (select id from public.approval_form_templates where code = 'designer.main' and version = 2)) $$,
  'D5 v2 draft 可继续编辑（schema 变更 days→hours）'
);
select lives_ok(
  $$ select public.publish_form_template(
       (select id from public.approval_form_templates where code = 'designer.main' and version = 2)) $$,
  'D6 v2 发布成功（同 code 多 published 允许）'
);
select is(
  (select count(*) from public.approval_form_templates
    where code = 'designer.main' and status = 'published'),
  2::bigint, 'D7 同 code 同时存在 v1/v2 两个 published'
);
select lives_ok(
  $$ select public.upsert_flow(
       '设计器主流程',
       (select id from public.approval_form_templates where code = 'designer.main' and version = 2),
       (select nodes from public.approval_flows where name = '设计器主流程' and version = 2),
       (select id from public.approval_flows where name = '设计器主流程' and version = 2)) $$,
  'D8 流程 v2 draft 重绑到模板 v2（flow 绑定具体模板版本）'
);
select lives_ok(
  $$ select public.publish_flow(
       (select id from public.approval_flows where name = '设计器主流程' and version = 2)) $$,
  'D9 流程 v2 发布成功'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '99999999-9999-4999-8999-999999999002', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select lives_ok(
  $$ select public.submit_instance('demo', 'demo_leave', '', 'designer.main',
       '{"title":"设计器实例二","hours":8}'::jsonb) $$,
  'D10 工程师再次提交自动取最新 published（v2）'
);

-- 模板/流程表 RLS 仅 admin 可读：切回 admin 断言绑定版本
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '99999999-9999-4999-8999-999999999001', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select is(
  (select t.version::text || '/' || f.version
     from public.approval_instances i
     join public.approval_form_templates t on t.id = i.template_version_id
     join public.approval_flows f on f.id = i.flow_version_id
    where i.title = '设计器实例二'),
  '2/2', 'D11 新实例绑定模板 v2 + 流程 v2'
);
select is(
  (select t.version::text
     from public.approval_instances i
     join public.approval_form_templates t on t.id = i.template_version_id
    where i.title = '设计器实例一'),
  '1', 'D12 进行中旧实例仍绑 v1（发新版不受影响）'
);
select ok(
  exists (
    select 1 from public.instance_detail(
      (select id from public.approval_instances where title = '设计器实例一')) d
    where d.schema -> 'fields' @> '[{"key":"days"}]'::jsonb
  ),
  'D13 旧实例详情仍按 v1 schema（含 days 字段）展示'
);
select ok(
  exists (
    select 1 from public.instance_detail(
      (select id from public.approval_instances where title = '设计器实例二')) d
    where d.schema -> 'fields' @> '[{"key":"hours"}]'::jsonb
  ),
  'D14 新实例详情按 v2 schema（含 hours 字段）展示'
);

-- ===========================================================================
-- E. 停用守卫：running 实例引用拒绝 + 幂等（9）
-- ===========================================================================
select throws_ok(
  $$ select public.disable_form_template(
       (select id from public.approval_form_templates where code = 'designer.main' and version = 1)) $$,
  '22023', '模板 designer.main 仍有 1 个进行中实例引用，不可停用',
  'E1 模板 v1 有 running 实例引用，停用被拒并报实例数'
);
select throws_ok(
  $$ select public.disable_flow(
       (select id from public.approval_flows where name = '设计器主流程' and version = 1)) $$,
  '22023', '流程 设计器主流程 v1 仍有 1 个进行中实例引用，不可停用',
  'E2 流程 v1 有 running 实例引用，停用被拒并报实例数'
);
select lives_ok(
  $$ select public.act_task(
       (select tk.id from public.approval_tasks tk
         join public.approval_instances i on i.id = tk.instance_id
        where i.title = '设计器实例一' and tk.status = 'pending'),
       'approve', '') $$,
  'E3 管理员通过实例一（解除 running 引用）'
);
select lives_ok(
  $$ select public.disable_form_template(
       (select id from public.approval_form_templates where code = 'designer.main' and version = 1)) $$,
  'E4 实例结束后模板 v1 可停用'
);
select is(
  (select status from public.approval_form_templates where code = 'designer.main' and version = 1),
  'disabled', 'E5 模板 v1 停用生效'
);
select lives_ok(
  $$ select public.disable_form_template(
       (select id from public.approval_form_templates where code = 'designer.main' and version = 1)) $$,
  'E6 重复停用幂等成功'
);
select lives_ok(
  $$ select public.disable_flow(
       (select id from public.approval_flows where name = '设计器主流程' and version = 1)) $$,
  'E7 实例结束后流程 v1 可停用'
);
select is(
  (select status from public.approval_flows where name = '设计器主流程' and version = 1),
  'disabled', 'E8 流程 v1 停用生效'
);
select throws_ok(
  $$ select public.upsert_flow('绑定已停用模板',
       (select id from public.approval_form_templates where code = 'designer.main' and version = 1),
       '[{"seq":1,"approver_rule":{"type":"role","value":"admin"}}]'::jsonb) $$,
  '22023', null, 'E9 不可再向已停用模板绑定新流程'
);

-- ===========================================================================
-- F. simulate_flow：三型规则 + demo 数据对照（14）
-- ===========================================================================
select lives_ok(
  $$ select public.upsert_form_template(
       '模拟辅助模板', 'designer.aux', 'demo',
       '{"fields":[{"key":"title","label":"标题","type":"text","required":true}]}'::jsonb) $$,
  'F1 创建模拟辅助模板'
);
select lives_ok(
  $$ select public.upsert_flow(
       '模拟辅助流程',
       (select id from public.approval_form_templates where code = 'designer.aux'),
       '[{"seq":1,"approver_rule":{"type":"dept_leader"}},
         {"seq":2,"approver_rule":{"type":"user","value":"99999999-9999-4999-8999-999999999003"}},
         {"seq":3,"approver_rule":{"type":"role","value":"supplier"}}]'::jsonb) $$,
  'F2 创建三型规则流程（dept_leader / user / role）'
);
select lives_ok(
  $$ select public.publish_form_template(
       (select id from public.approval_form_templates where code = 'designer.aux')) $$,
  'F3 发布模拟辅助模板'
);
select lives_ok(
  $$ select public.publish_flow(
       (select id from public.approval_flows where name = '模拟辅助流程')) $$,
  'F4 发布模拟辅助流程'
);
select is(
  jsonb_array_length(public.simulate_flow(
    (select id from public.approval_flows where name = '模拟辅助流程'),
    '{"title":"模拟"}'::jsonb,
    '99999999-9999-4999-8999-999999999002')),
  3, 'F5 模拟返回 3 个节点'
);
select is(
  public.simulate_flow(
    (select id from public.approval_flows where name = '模拟辅助流程'),
    '{"title":"模拟"}'::jsonb,
    '99999999-9999-4999-8999-999999999002') -> 0 ->> 'approver_id',
  '99999999-9999-4999-8999-999999999001',
  'F6 dept_leader 节点解析为发起人部门负责人'
);
select is(
  public.simulate_flow(
    (select id from public.approval_flows where name = '模拟辅助流程'),
    '{"title":"模拟"}'::jsonb,
    '99999999-9999-4999-8999-999999999002') -> 1 ->> 'approver_id',
  '99999999-9999-4999-8999-999999999003',
  'F7 user 节点解析为指定用户'
);
select ok(
  public.simulate_flow(
    (select id from public.approval_flows where name = '模拟辅助流程'),
    '{"title":"模拟"}'::jsonb,
    '99999999-9999-4999-8999-999999999002') -> 2 ->> 'error' is not null
  and public.simulate_flow(
    (select id from public.approval_flows where name = '模拟辅助流程'),
    '{"title":"模拟"}'::jsonb,
    '99999999-9999-4999-8999-999999999002') -> 2 ->> 'approver_id' is null,
  'F8 角色下无可用用户时该节点标注 error 且 approver_id 为空'
);
select throws_ok(
  $$ select public.simulate_flow('00000000-0000-4000-a000-00000000dead', '{}'::jsonb,
       '99999999-9999-4999-8999-999999999002') $$,
  'P0002', null, 'F9 模拟不存在的流程被拒'
);
select throws_ok(
  $$ select public.simulate_flow(
       (select id from public.approval_flows where name = '模拟辅助流程'),
       '[]'::jsonb, '99999999-9999-4999-8999-999999999002') $$,
  '22023', null, 'F10 form_data 非对象被拒'
);
select throws_ok(
  $$ select public.simulate_flow(
       (select id from public.approval_flows where name = '模拟辅助流程'),
       '{}'::jsonb, '00000000-0000-4000-a000-00000000dead') $$,
  '22023', null, 'F11 模拟发起人不存在被拒'
);

-- 一致性对照：demo seed 流程 —— 真实 submit 的首节点任务 == simulate 结果
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '99999999-9999-4999-8999-999999999002', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select lives_ok(
  $$ select public.submit_instance('demo', 'demo_leave', '', 'demo.leave',
       '{"title":"模拟对照 demo","days":1,"reason":"对照"}'::jsonb) $$,
  'F12 demo 模板真实提交成功（seed 004）'
);
select is(
  (select tk.assignee_id::text
     from public.approval_tasks tk
     join public.approval_instances i on i.id = tk.instance_id
    where i.title = '模拟对照 demo' and tk.seq = 1),
  '99999999-9999-4999-8999-999999999001',
  'F13 demo 首节点审批人为最早 admin（真实路径）'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '99999999-9999-4999-8999-999999999001', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select is(
  public.simulate_flow(
    '44444444-4444-4444-4444-444444444402',
    '{"title":"对照","days":1,"reason":"x"}'::jsonb,
    '99999999-9999-4999-8999-999999999002') -> 0 ->> 'approver_id',
  (select tk.assignee_id::text
     from public.approval_tasks tk
     join public.approval_instances i on i.id = tk.instance_id
    where i.title = '模拟对照 demo' and tk.seq = 1),
  'F14 simulate demo 流程结果与真实 submit 首节点审批人完全一致'
);

-- ===========================================================================
-- G. usage counts + emit_event 软依赖验收（7）
-- ===========================================================================
select is(
  (select total_count::text || '/' || running_count::text
     from public.approval_usage_counts()
    where template_version_id = (
      select id from public.approval_form_templates where code = 'designer.main' and version = 1)),
  '1/0', 'G1 v1 引用数 1/进行中 0（实例一已通过）'
);
select is(
  (select total_count::text || '/' || running_count::text
     from public.approval_usage_counts()
    where template_version_id = (
      select id from public.approval_form_templates where code = 'designer.main' and version = 2)),
  '1/1', 'G2 v2 引用数 1/进行中 1'
);
select is(
  (select count(*) from public.integration_events
    where event = 'approval.submitted'
      and payload ->> 'instance_id' = (
        select id::text from public.approval_instances where title = '设计器实例二')),
  1::bigint, 'G3 submit_instance 发射 approval.submitted（软依赖 integration/004 生效）'
);
select is(
  (select (payload ->> 'module') || '/' || (payload ->> 'template_code') from public.integration_events
    where event = 'approval.submitted'
      and payload ->> 'instance_id' = (
        select id::text from public.approval_instances where title = '设计器实例二')),
  'demo/designer.main', 'G4 submitted 事件 payload 携带 module/template_code'
);
select lives_ok(
  $$ select public.act_task(
       (select tk.id from public.approval_tasks tk
         join public.approval_instances i on i.id = tk.instance_id
        where i.title = '设计器实例二' and tk.status = 'pending'),
       'approve', '同意') $$,
  'G5 管理员通过单节点实例二（末节点）'
);
select is(
  (select count(*) from public.integration_events
    where event = 'approval.approved'
      and payload ->> 'instance_id' = (
        select id::text from public.approval_instances where title = '设计器实例二')
      and payload ->> 'status' = 'approved'),
  1::bigint, 'G6 act 通过发射 approval.approved 且 status=approved'
);
select is(
  (select running_count from public.approval_usage_counts()
    where template_version_id = (
      select id from public.approval_form_templates where code = 'designer.main' and version = 2)),
  0::bigint, 'G7 实例二通过后 v2 running 归零'
);

-- ===========================================================================
-- H. 越权拒绝：非 admin 调管理 RPC / 写核心表（11）
-- ===========================================================================
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '99999999-9999-4999-8999-999999999002', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select throws_ok(
  $$ select public.upsert_form_template('越权', 'hacker.tpl', 'demo',
       '{"fields":[{"key":"a","label":"a","type":"text"}]}'::jsonb) $$,
  '42501', '仅管理员可执行此操作', 'H1 非 admin upsert_form_template 被拒'
);
select throws_ok(
  $$ select public.publish_form_template(
       (select id from public.approval_form_templates where code = 'designer.aux')) $$,
  '42501', '仅管理员可执行此操作', 'H2 非 admin publish_form_template 被拒'
);
select throws_ok(
  $$ select public.disable_form_template(
       (select id from public.approval_form_templates where code = 'designer.aux')) $$,
  '42501', '仅管理员可执行此操作', 'H3 非 admin disable_form_template 被拒'
);
select throws_ok(
  $$ select public.new_form_template_version(
       (select id from public.approval_form_templates where code = 'designer.aux')) $$,
  '42501', '仅管理员可执行此操作', 'H4 非 admin new_form_template_version 被拒'
);
select throws_ok(
  $$ select public.upsert_flow('越权流程',
       (select id from public.approval_form_templates where code = 'designer.aux'),
       '[{"seq":1,"approver_rule":{"type":"role","value":"admin"}}]'::jsonb) $$,
  '42501', '仅管理员可执行此操作', 'H5 非 admin upsert_flow 被拒'
);
select throws_ok(
  $$ select public.publish_flow(
       (select id from public.approval_flows where name = '模拟辅助流程')) $$,
  '42501', '仅管理员可执行此操作', 'H6 非 admin publish_flow 被拒'
);
select throws_ok(
  $$ select public.disable_flow(
       (select id from public.approval_flows where name = '模拟辅助流程')) $$,
  '42501', '仅管理员可执行此操作', 'H7 非 admin disable_flow 被拒'
);
select throws_ok(
  $$ select public.new_flow_version(
       (select id from public.approval_flows where name = '模拟辅助流程')) $$,
  '42501', '仅管理员可执行此操作', 'H8 非 admin new_flow_version 被拒'
);
select throws_ok(
  $$ select public.simulate_flow(
       (select id from public.approval_flows where name = '模拟辅助流程'), '{}'::jsonb,
       '99999999-9999-4999-8999-999999999002') $$,
  '42501', '仅管理员可执行此操作', 'H9 非 admin simulate_flow 被拒'
);
select throws_ok(
  $$ select public.approval_usage_counts() $$,
  '42501', '仅管理员可执行此操作', 'H10 非 admin approval_usage_counts 被拒'
);
select throws_ok(
  $$ update public.approval_form_templates set name = '越权改名'
      where code = 'designer.aux' $$,
  '42501', null, 'H11 非 admin 无表级 UPDATE 权限（写全部经 RPC）'
);

select * from finish();
rollback;
