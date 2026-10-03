-- 审批中心 · demo 数据（本地开发，仅用于 supabase db reset）
-- 1 个已发布模板（demo.leave 请假示例）+ 1 条单节点流程（审批人规则 role=admin）
-- 来源模块 = demo（仅演示用；submit_instance 校验模板 module 与入参一致）

insert into public.approval_form_templates
  (id, name, code, module, version, schema, status, created_by, updated_by)
values (
  '44444444-4444-4444-4444-444444444401',
  '请假申请',
  'demo.leave',
  'demo',
  1,
  jsonb_build_object(
    'fields', jsonb_build_array(
      jsonb_build_object('key', 'title',  'label', '申请标题', 'type', 'text',   'required', true),
      jsonb_build_object('key', 'days',   'label', '请假天数', 'type', 'number', 'required', true),
      jsonb_build_object('key', 'reason', 'label', '请假事由', 'type', 'text',   'required', true)
    )
  ),
  'published',
  '11111111-1111-1111-1111-111111111111',
  '11111111-1111-1111-1111-111111111111'
)
on conflict (id) do nothing;

insert into public.approval_flows
  (id, name, template_id, version, nodes, status, created_by, updated_by)
values (
  '44444444-4444-4444-4444-444444444402',
  '请假单节点审批',
  '44444444-4444-4444-4444-444444444401',
  1,
  jsonb_build_array(
    jsonb_build_object(
      'seq', 1,
      'approver_rule', jsonb_build_object('type', 'role', 'value', 'admin'),
      'timeout_hours', 24
    )
  ),
  'published',
  '11111111-1111-1111-1111-111111111111',
  '11111111-1111-1111-1111-111111111111'
)
on conflict (id) do nothing;
