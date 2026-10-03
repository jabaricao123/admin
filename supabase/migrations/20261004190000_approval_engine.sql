-- 审批中心 · 引擎核心（工单 approval/001+002+003 合并交付）
-- 契约：docs/modules/approval/engine.md（核心表/状态机/提交契约）、todo.md（act_task/my_todos）、
--       INDEX 规则 2（审计摘要统一入口）、3（通知发送单通道）、8（「审批表单模板」命名）、
--       10（内部 RPC 不 GRANT authenticated）。
-- 约定：
--   * 业务实现放 app schema，public 同名函数为 Data API 薄包装（PostgREST 仅暴露 public）；
--   * 敏感表二分：六张新表对 API 角色均无表级写，写全部经 SECURITY DEFINER RPC；
--     表级 SELECT 按 RLS（本人相关 / admin），且不授予 service_role（同 message/001 先例）；
--   * 所有 SECURITY DEFINER 函数/触发器 set search_path = '' + 全限定名引用；
--   * 模板/流程仅 draft 可编辑：published/disabled 内容不可变，改动需递增 version；
--   * emit_event 为 integration/004 软依赖：未合入则跳过（同 message/001 对 audit_log 的先例）。
-- 依赖：20261003145039（profiles）、20261003205349（audit_log）、20261003205454（send_notification）、
--       20261003211025（roles）、20261003205414（departments）、20261004100000（profiles.role_id）、
--       20261004140000（profiles.department_id）。

-- ---------------------------------------------------------------------------
-- 1. 审批表单模板 approval_form_templates（版本化；唯一 (code, version)）
-- ---------------------------------------------------------------------------
create table public.approval_form_templates (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  code       text not null,
  module     text not null,
  version    integer not null default 1,
  schema     jsonb not null,
  status     text not null default 'draft'
             constraint approval_form_templates_status_check
             check (status in ('draft', 'published', 'disabled')),
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint approval_form_templates_code_version_uq unique (code, version),
  constraint approval_form_templates_schema_object_check check (jsonb_typeof(schema) = 'object'),
  constraint approval_form_templates_version_check check (version >= 1)
);

comment on table public.approval_form_templates is
  '审批表单模板（版本化；仅 draft 可编辑，published/disabled 内容由触发器冻结；写路径后续模板设计器 RPC）';
comment on column public.approval_form_templates.code is '模板稳定标识（同 code 递增 version）';
comment on column public.approval_form_templates.module is '适用来源模块（submit_instance 校验一致）';
comment on column public.approval_form_templates.schema is '字段定义 jsonb：{"fields":[{key,label,type,required,options...}]}；DB 仅做兜底校验';
comment on column public.approval_form_templates.status is 'draft 可编辑 / published 可提交 / disabled 停用（终态即冻结）';
comment on column public.approval_form_templates.created_by is '创建人（弱关联 auth.users，不设外键以保留追溯）';

create trigger approval_form_templates_set_updated_at
before update on public.approval_form_templates
for each row
execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- 2. 审批流程 approval_flows（版本化；唯一 (template_id, version)）
-- ---------------------------------------------------------------------------
create table public.approval_flows (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  template_id uuid not null references public.approval_form_templates (id) on delete restrict,
  version     integer not null default 1,
  nodes       jsonb not null,
  branches    jsonb,
  status      text not null default 'draft'
              constraint approval_flows_status_check
              check (status in ('draft', 'published', 'disabled')),
  created_by  uuid,
  updated_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint approval_flows_template_version_uq unique (template_id, version),
  constraint approval_flows_nodes_shape_check
    check (jsonb_typeof(nodes) = 'array' and jsonb_array_length(nodes) > 0),
  constraint approval_flows_version_check check (version >= 1)
);

comment on table public.approval_flows is
  '审批流程定义（线性节点；仅 draft 可编辑；branches 为条件分支预留，P1 二期启用）';
comment on column public.approval_flows.nodes is
  '[{seq, approver_rule:{type:role|dept_leader|user, value}, timeout_hours}]，seq 从 1 连续编号';
comment on column public.approval_flows.branches is '条件分支预留（本期恒 NULL；P1 二期启用）';
comment on column public.approval_flows.status is 'draft 可编辑 / published 可提交 / disabled 停用（内容冻结）';

create trigger approval_flows_set_updated_at
before update on public.approval_flows
for each row
execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. 审批实例 approval_instances（绑定模板/流程具体版本）
-- ---------------------------------------------------------------------------
create table public.approval_instances (
  id                  uuid primary key default gen_random_uuid(),
  title               text not null,
  module              text not null,
  ref_type            text,
  ref_id              text,
  template_version_id uuid not null references public.approval_form_templates (id) on delete restrict,
  flow_version_id     uuid not null references public.approval_flows (id) on delete restrict,
  form_data           jsonb not null,
  status              text not null default 'running'
                      constraint approval_instances_status_check
                      check (status in ('running', 'approved', 'rejected', 'withdrawn')),
  current_seq         integer not null default 1,
  initiator_id        uuid not null references public.profiles (id) on delete restrict,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint approval_instances_form_data_object_check check (jsonb_typeof(form_data) = 'object'),
  constraint approval_instances_current_seq_check check (current_seq >= 1)
);

comment on table public.approval_instances is
  '审批实例（单据）：绑定具体模板/流程版本；写路径仅 submit_instance/act_task/withdraw_instance';
comment on column public.approval_instances.ref_type is '来源业务对象类型（业务模块自定义，如 leave_request）';
comment on column public.approval_instances.ref_id is '来源业务对象 id（文本，业务模块自管）';
comment on column public.approval_instances.template_version_id is
  '绑定的模板具体版本（发布新版本不影响进行中实例，可追溯）';
comment on column public.approval_instances.current_seq is '当前审批节点 seq（线性流程）';

create index approval_instances_initiator_created_idx
  on public.approval_instances (initiator_id, created_at desc);
create index approval_instances_status_idx
  on public.approval_instances (status);
create index approval_instances_ref_idx
  on public.approval_instances (module, ref_type, ref_id);

create trigger approval_instances_set_updated_at
before update on public.approval_instances
for each row
execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- 4. 审批任务 approval_tasks（每节点一行；并发双审由唯一约束兜底）
-- ---------------------------------------------------------------------------
create table public.approval_tasks (
  id          uuid primary key default gen_random_uuid(),
  instance_id uuid not null references public.approval_instances (id) on delete cascade,
  seq         integer not null,
  assignee_id uuid not null references public.profiles (id) on delete restrict,
  status      text not null default 'pending'
              constraint approval_tasks_status_check
              check (status in ('pending', 'approved', 'rejected', 'skipped')),
  acted_at    timestamptz,
  comment     text,
  created_at  timestamptz not null default now(),
  constraint approval_tasks_instance_seq_uq unique (instance_id, seq),
  constraint approval_tasks_seq_check check (seq >= 1)
);

comment on table public.approval_tasks is
  '审批任务：唯一 (instance_id, seq) 防并发双审的第一道防线；写仅经 act_task/withdraw_instance';
comment on column public.approval_tasks.seq is '节点序号（与实例 current_seq 对应）';
comment on column public.approval_tasks.acted_at is '处理时间（pending 时为 NULL）';
comment on column public.approval_tasks.comment is '审批意见（reject 必填由 RPC 强制）';

-- 同一实例同时最多一个 pending（线性流程第二道防线；并发建任务的竞态兜底）
create unique index approval_tasks_one_pending_uq
  on public.approval_tasks (instance_id)
  where status = 'pending';

create index approval_tasks_assignee_status_idx
  on public.approval_tasks (assignee_id, status, created_at desc);

-- ---------------------------------------------------------------------------
-- 5. 抄送 approval_ccs（P1 页面消费；本期仅建表与 RLS）
-- ---------------------------------------------------------------------------
create table public.approval_ccs (
  instance_id uuid not null references public.approval_instances (id) on delete cascade,
  cc_user_id  uuid not null references public.profiles (id) on delete cascade,
  read_at     timestamptz,
  created_at  timestamptz not null default now(),
  primary key (instance_id, cc_user_id)
);

comment on table public.approval_ccs is
  '审批抄送：read_at 为业务标记（未读唯一事实源仍是 messages.read_at，避免双计数）';

create index approval_ccs_user_created_idx
  on public.approval_ccs (cc_user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- 6. 表单渲染注册表 form_renderers（契约：module+ref_type → renderer_key）
-- ---------------------------------------------------------------------------
create table public.form_renderers (
  module       text not null,
  ref_type     text not null,
  renderer_key text not null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  primary key (module, ref_type)
);

comment on table public.form_renderers is
  '表单渲染注册表（契约）：业务模块注册 module+ref_type → renderer_key，审批详情页据此渲染只读表单';
comment on column public.form_renderers.renderer_key is '渲染组件 key（由各业务模块前端维护映射）';

create trigger form_renderers_set_updated_at
before update on public.form_renderers
for each row
execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- 7. published/disabled 冻结触发器（仅 draft 可编辑；published → disabled 才可流转）
-- ---------------------------------------------------------------------------
create function app.protect_published_template()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status <> 'draft' then
    if new.name       is distinct from old.name
       or new.code    is distinct from old.code
       or new.module  is distinct from old.module
       or new.version is distinct from old.version
       or new.schema  is distinct from old.schema then
      raise exception '审批表单模板 % 非 draft 状态，内容不可修改（请递增 version 发布新版本）', old.code
        using errcode = '22023';
    end if;
  end if;

  if old.status = 'published'
     and new.status is distinct from old.status
     and new.status <> 'disabled' then
    raise exception '已发布模板仅可流转为 disabled（当前状态：%）', old.status using errcode = '22023';
  end if;

  return new;
end;
$$;

comment on function app.protect_published_template() is
  '模板冻结触发器：非 draft 行内容不可变；published 仅可流转 disabled';

create trigger approval_form_templates_protect_published
before update on public.approval_form_templates
for each row
execute function app.protect_published_template();

create function app.protect_published_flow()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status <> 'draft' then
    if new.name        is distinct from old.name
       or new.template_id is distinct from old.template_id
       or new.version   is distinct from old.version
       or new.nodes     is distinct from old.nodes
       or new.branches  is distinct from old.branches then
      raise exception '审批流程 % 非 draft 状态，内容不可修改（请递增 version 发布新版本）', old.id
        using errcode = '22023';
    end if;
  end if;

  if old.status = 'published'
     and new.status is distinct from old.status
     and new.status <> 'disabled' then
    raise exception '已发布流程仅可流转为 disabled（当前状态：%）', old.status using errcode = '22023';
  end if;

  return new;
end;
$$;

comment on function app.protect_published_flow() is
  '流程冻结触发器：非 draft 行内容不可变；published 仅可流转 disabled';

create trigger approval_flows_protect_published
before update on public.approval_flows
for each row
execute function app.protect_published_flow();

-- ---------------------------------------------------------------------------
-- 8. 内部辅助函数（app schema，不 GRANT API 角色）
-- ---------------------------------------------------------------------------
-- 8.1 取流程指定 seq 的节点（节点数组 [{seq,...}]）
create function app.flow_node(p_nodes jsonb, p_seq integer)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select e.value
  from pg_catalog.jsonb_array_elements(coalesce(p_nodes, '[]'::jsonb)) as e
  where e.value ->> 'seq' = p_seq::text
  limit 1
$$;

comment on function app.flow_node(jsonb, integer) is '取流程 nodes 中 seq 指定节点；不存在返回 NULL';

-- 8.2 form_data 兜底校验（完整 Zod 在前端；DB 校验 required 存在 + 类型粗检）
create function app.validate_form_data(p_schema jsonb, p_form_data jsonb)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_data  jsonb := coalesce(p_form_data, '{}'::jsonb);
  v_field jsonb;
  v_key   text;
  v_type  text;
  v_label text;
  v_value jsonb;
begin
  if p_schema is null
     or jsonb_typeof(p_schema) <> 'object'
     or not (p_schema ? 'fields')
     or jsonb_typeof(p_schema -> 'fields') <> 'array' then
    raise exception '模板 schema 非法：应为 {"fields":[...]}' using errcode = '22023';
  end if;

  if jsonb_typeof(v_data) <> 'object' then
    raise exception 'form_data 必须是 JSON 对象' using errcode = '22023';
  end if;

  for v_field in select e.value from pg_catalog.jsonb_array_elements(p_schema -> 'fields') as e
  loop
    v_key := v_field ->> 'key';
    if v_key is null or btrim(v_key) = '' then
      raise exception '模板 schema 非法：字段缺少 key' using errcode = '22023';
    end if;

    v_label := coalesce(v_field ->> 'label', v_key);
    v_type  := coalesce(v_field ->> 'type', 'text');
    v_value := v_data -> v_key;

    -- required：存在 + 非 null + 非空串/空数组
    if v_field @> '{"required": true}'::jsonb then
      if v_value is null
         or v_value = 'null'::jsonb
         or (jsonb_typeof(v_value) = 'string' and v_value = '""'::jsonb)
         or (jsonb_typeof(v_value) = 'array' and jsonb_array_length(v_value) = 0) then
        raise exception '字段「%」为必填', v_label using errcode = '22023';
      end if;
    end if;

    continue when v_value is null or v_value = 'null'::jsonb;

    -- 类型粗检：未知类型跳过（向前兼容模板设计器后续扩展）
    if v_type in ('text', 'date') then
      if jsonb_typeof(v_value) <> 'string' then
        raise exception '字段「%」应为文本', v_label using errcode = '22023';
      end if;
    elsif v_type = 'number' then
      if jsonb_typeof(v_value) <> 'number' then
        raise exception '字段「%」应为数字', v_label using errcode = '22023';
      end if;
    elsif v_type = 'boolean' then
      if jsonb_typeof(v_value) <> 'boolean' then
        raise exception '字段「%」应为布尔值', v_label using errcode = '22023';
      end if;
    elsif v_type = 'select' then
      if jsonb_typeof(v_value) not in ('string', 'number') then
        raise exception '字段「%」应为单选值（文本或数字）', v_label using errcode = '22023';
      end if;
    elsif v_type = 'multiselect' then
      if jsonb_typeof(v_value) <> 'array' then
        raise exception '字段「%」应为多选数组', v_label using errcode = '22023';
      end if;
    elsif v_type in ('attachment', 'file') then
      if jsonb_typeof(v_value) not in ('array', 'string') then
        raise exception '字段「%」应为附件数组', v_label using errcode = '22023';
      end if;
    end if;
  end loop;
end;
$$;

comment on function app.validate_form_data(jsonb, jsonb) is
  'form_data 兜底校验：required 存在 + 类型粗检（text/date/number/boolean/select/multiselect/attachment）；完整校验在业务前端';

-- 8.3 审批人解析（v1 单审批人；v2 多人会签再扩展返回值）
create function app.resolve_approver(p_rule jsonb, p_initiator uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_type        text;
  v_value       text;
  v_role_status text;
  v_user        uuid;
begin
  if p_rule is null or jsonb_typeof(p_rule) <> 'object' then
    raise exception '审批人规则非法：应为 JSON 对象' using errcode = '22023';
  end if;

  v_type  := p_rule ->> 'type';
  v_value := nullif(btrim(coalesce(p_rule ->> 'value', '')), '');

  if v_type = 'role' then
    if v_value is null then
      raise exception '审批人规则非法：role 缺少 value' using errcode = '22023';
    end if;

    select r.status into v_role_status
    from public.roles r
    where r.code = v_value;

    if v_role_status is null then
      raise exception '审批人角色不存在：%', v_value using errcode = 'P0002';
    end if;
    if v_role_status <> 'active' then
      raise exception '审批人角色已停用：%', v_value using errcode = '22023';
    end if;

    -- v1 取该角色 created_at 最早的 active 用户（确定性）；v2 多人会签改返回集合
    select p.id into v_user
    from public.profiles p
    left join public.roles r on r.id = p.role_id
    where p.status = 'active'
      and (r.code = v_value or (p.role_id is null and p.role::text = v_value))
    order by p.created_at, p.id
    limit 1;

    if v_user is null then
      raise exception '角色 % 下无可用审批人', v_value using errcode = 'P0002';
    end if;

    return v_user;
  end if;

  if v_type = 'dept_leader' then
    -- org/007 起按 profiles.department_id → departments.leader_id（id 语义，非部门名文本）
    select d.leader_id into v_user
    from public.profiles p
    join public.departments d on d.id = p.department_id
    join public.profiles l on l.id = d.leader_id and l.status = 'active'
    where p.id = p_initiator;

    if v_user is null then
      raise exception '发起人无可用部门负责人，无法解析审批人' using errcode = '22023';
    end if;

    return v_user;
  end if;

  if v_type = 'user' then
    if v_value is null then
      raise exception '审批人规则非法：user 缺少 value' using errcode = '22023';
    end if;

    begin
      v_user := v_value::uuid;
    exception when invalid_text_representation then
      raise exception '审批人规则非法：value 不是有效用户 id：%', v_value using errcode = '22023';
    end;

    if not exists (
      select 1 from public.profiles p where p.id = v_user and p.status = 'active'
    ) then
      raise exception '指定审批人不存在或已停用：%', v_value using errcode = 'P0002';
    end if;

    return v_user;
  end if;

  raise exception '审批人规则 type 非法：%', coalesce(v_type, '<null>') using errcode = '22023';
end;
$$;

comment on function app.resolve_approver(jsonb, uuid) is
  '审批人解析：role=角色任一 active 用户（v1 取建档最早，v2 会签扩展）× dept_leader=发起人部门负责人（department_id→leader_id）× user=指定用户';

-- 8.4 RLS 可见性 helper（SECURITY DEFINER 防策略递归）
create function app.is_instance_participant(p_instance_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.approval_instances i
    where i.id = p_instance_id
      and (
        i.initiator_id = (select auth.uid())
        or exists (
          select 1 from public.approval_tasks t
          where t.instance_id = i.id and t.assignee_id = (select auth.uid())
        )
        or exists (
          select 1 from public.approval_ccs c
          where c.instance_id = i.id and c.cc_user_id = (select auth.uid())
        )
        or (select app.current_role()) = 'admin'
      )
  )
$$;

comment on function app.is_instance_participant(uuid) is
  '实例 RLS 可见性 helper：initiator / assignee / cc / admin；security definer 防策略跨表递归';

-- ---------------------------------------------------------------------------
-- 9. 表单渲染注册（内部入口，INDEX 规则 10：不 GRANT authenticated）
-- ---------------------------------------------------------------------------
create function app.register_form_renderer(
  p_module       text,
  p_ref_type     text,
  p_renderer_key text
)
returns public.form_renderers
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.form_renderers;
begin
  if p_module is null or btrim(p_module) = '' then
    raise exception 'module 不能为空' using errcode = '22023';
  end if;
  if p_ref_type is null or btrim(p_ref_type) = '' then
    raise exception 'ref_type 不能为空' using errcode = '22023';
  end if;
  if p_renderer_key is null or btrim(p_renderer_key) = '' then
    raise exception 'renderer_key 不能为空' using errcode = '22023';
  end if;

  insert into public.form_renderers (module, ref_type, renderer_key)
  values (btrim(p_module), btrim(p_ref_type), btrim(p_renderer_key))
  on conflict (module, ref_type) do update
    set renderer_key = excluded.renderer_key,
        updated_at   = now()
  returning * into v_row;

  return v_row;
end;
$$;

comment on function app.register_form_renderer(text, text, text) is
  '表单渲染注册唯一入口（业务模块迁移内调用或后端 wrapper；不 GRANT authenticated）';

-- ---------------------------------------------------------------------------
-- 10. 提交实例 submit_instance（GRANT authenticated；事务内建实例 + 首节点任务）
-- ---------------------------------------------------------------------------
create function app.submit_instance(
  p_module        text,
  p_ref_type      text,
  p_ref_id        text,
  p_template_code text,
  p_form_data     jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_initiator   uuid := (select auth.uid());
  v_template    public.approval_form_templates;
  v_flow        public.approval_flows;
  v_node        jsonb;
  v_assignee    uuid;
  v_instance_id uuid;
  v_title       text;
  v_init_name   text;
  v_module      text := nullif(btrim(coalesce(p_module, '')), '');
  v_ref_type    text := nullif(btrim(coalesce(p_ref_type, '')), '');
  v_ref_id      text := nullif(btrim(coalesce(p_ref_id, '')), '');
begin
  if v_initiator is null then
    raise exception '未登录，无法提交审批' using errcode = '42501';
  end if;
  if v_module is null then
    raise exception '来源模块不能为空' using errcode = '22023';
  end if;
  if p_template_code is null or btrim(p_template_code) = '' then
    raise exception '模板 code 不能为空' using errcode = '22023';
  end if;

  -- 当前 published 最新版本模板
  select * into v_template
  from public.approval_form_templates
  where code = p_template_code
    and status = 'published'
  order by version desc
  limit 1;

  if not found then
    raise exception '审批表单模板不存在或未发布：%', p_template_code using errcode = 'P0002';
  end if;
  if v_template.module <> v_module then
    raise exception '模板 % 不适用于来源模块 %', v_template.code, v_module using errcode = '22023';
  end if;

  perform app.validate_form_data(v_template.schema, p_form_data);

  -- 绑定 flow：该模板当前 published 最新版本
  select * into v_flow
  from public.approval_flows
  where template_id = v_template.id
    and status = 'published'
  order by version desc
  limit 1;

  if not found then
    raise exception '模板 % 未绑定已发布流程', v_template.code using errcode = 'P0002';
  end if;

  v_node := app.flow_node(v_flow.nodes, 1);
  if v_node is null then
    raise exception '流程 % 节点配置非法：缺少 seq=1 节点', v_flow.id using errcode = '22023';
  end if;

  v_assignee := app.resolve_approver(v_node -> 'approver_rule', v_initiator);
  v_title    := coalesce(nullif(btrim(coalesce(p_form_data ->> 'title', '')), ''), v_template.name);

  insert into public.approval_instances (
    title, module, ref_type, ref_id,
    template_version_id, flow_version_id, form_data,
    status, current_seq, initiator_id
  )
  values (
    v_title, v_module, v_ref_type, v_ref_id,
    v_template.id, v_flow.id, coalesce(p_form_data, '{}'::jsonb),
    'running', 1, v_initiator
  )
  returning id into v_instance_id;

  insert into public.approval_tasks (instance_id, seq, assignee_id)
  values (v_instance_id, 1, v_assignee);

  perform app.audit_log(
    'approval', 'submit', 'instance', v_instance_id::text,
    jsonb_build_object(
      'module', v_module,
      'template_code', v_template.code,
      'template_version', v_template.version,
      'flow_version', v_flow.version,
      'ref_type', v_ref_type,
      'ref_id', v_ref_id,
      'assignee_id', v_assignee
    )
  );

  select p.full_name into v_init_name
  from public.profiles p
  where p.id = v_initiator;

  perform app.send_notification(
    v_assignee,
    'approval.pending',
    jsonb_build_object(
      'title', '待审批：' || v_title,
      'body', coalesce(v_init_name, '发起人') || ' 提交的审批申请待你处理',
      'source_module', 'approval',
      'ref_type', 'approval_instance',
      'ref_id', v_instance_id::text
    )
  );

  -- TODO(integration/004)：emit_event('approval.submitted', ...) 待 integration/004 合入；
  -- 软依赖同 message/001 对 audit_log 的先例：存在则调用，未合入自动跳过。
  if to_regprocedure('app.emit_event(text,jsonb)') is not null then
    perform app.emit_event(
      'approval.submitted',
      jsonb_build_object(
        'instance_id', v_instance_id, 'module', v_module,
        'template_code', v_template.code, 'initiator_id', v_initiator
      )
    );
  elsif to_regprocedure('public.emit_event(text,jsonb)') is not null then
    perform public.emit_event(
      'approval.submitted',
      jsonb_build_object(
        'instance_id', v_instance_id, 'module', v_module,
        'template_code', v_template.code, 'initiator_id', v_initiator
      )
    );
  end if;

  return v_instance_id;
end;
$$;

comment on function app.submit_instance(text, text, text, text, jsonb) is
  '提交审批入口：取 published 最新模板+流程，schema 兜底校验，事务内建实例+首节点任务（resolve_approver），写审计+通知';

-- ---------------------------------------------------------------------------
-- 11. 审批动作 act_task（GRANT authenticated；原子更新任务 + 实例 + 下一节点）
-- ---------------------------------------------------------------------------
create function app.act_task(
  p_task_id uuid,
  p_action  text,
  p_comment text
)
returns public.approval_instances
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid           uuid := (select auth.uid());
  v_task          public.approval_tasks;
  v_instance      public.approval_instances;
  v_nodes         jsonb;
  v_next          jsonb;
  v_next_assignee uuid;
  v_comment       text := nullif(btrim(coalesce(p_comment, '')), '');
begin
  if v_uid is null then
    raise exception '未登录，无法处理审批' using errcode = '42501';
  end if;
  if p_action is null or p_action not in ('approve', 'reject') then
    raise exception '非法审批动作：%', coalesce(p_action, '<null>') using errcode = '22023';
  end if;
  if p_action = 'reject' and v_comment is null then
    raise exception '驳回必须填写意见' using errcode = '22023';
  end if;

  select * into v_task
  from public.approval_tasks
  where id = p_task_id;

  if not found then
    raise exception '审批任务不存在：%', p_task_id using errcode = 'P0002';
  end if;
  if v_task.assignee_id <> v_uid then
    raise exception '无权处理该审批任务' using errcode = '42501';
  end if;

  -- 锁序统一：先实例后任务（与 withdraw_instance 一致，防交叉死锁）
  select * into v_instance
  from public.approval_instances
  where id = v_task.instance_id
  for update;

  select * into v_task
  from public.approval_tasks
  where id = p_task_id
  for update;

  if v_task.status <> 'pending' then
    raise exception '任务已处理，不可重复操作' using errcode = '22023';
  end if;
  if v_instance.status <> 'running' then
    raise exception '审批实例已结束，不可操作' using errcode = '22023';
  end if;
  if v_task.seq <> v_instance.current_seq then
    raise exception '该任务不是当前审批节点' using errcode = '22023';
  end if;

  if p_action = 'reject' then
    update public.approval_tasks
       set status = 'rejected', acted_at = now(), comment = v_comment
     where id = p_task_id;

    -- 线性流程正常情况下无其他 pending；兜底清场保持「同实例多 pending」不变量
    update public.approval_tasks
       set status = 'skipped'
     where instance_id = v_instance.id
       and status = 'pending';

    update public.approval_instances
       set status = 'rejected'
     where id = v_instance.id
    returning * into v_instance;

    perform app.audit_log(
      'approval', 'reject', 'instance', v_instance.id::text,
      jsonb_build_object('task_id', p_task_id, 'seq', v_task.seq, 'comment', v_comment)
    );

    perform app.send_notification(
      v_instance.initiator_id,
      'approval.rejected',
      jsonb_build_object(
        'title', '审批已驳回：' || v_instance.title,
        'body', '驳回意见：' || v_comment,
        'source_module', 'approval',
        'ref_type', 'approval_instance',
        'ref_id', v_instance.id::text
      )
    );

    -- TODO(integration/004)：emit_event('approval.rejected', ...)
    if to_regprocedure('app.emit_event(text,jsonb)') is not null then
      perform app.emit_event(
        'approval.rejected',
        jsonb_build_object('instance_id', v_instance.id, 'task_id', p_task_id, 'comment', v_comment)
      );
    elsif to_regprocedure('public.emit_event(text,jsonb)') is not null then
      perform public.emit_event(
        'approval.rejected',
        jsonb_build_object('instance_id', v_instance.id, 'task_id', p_task_id, 'comment', v_comment)
      );
    end if;

    return v_instance;
  end if;

  -- approve：推进实例后生成下一节点任务
  select f.nodes into v_nodes
  from public.approval_flows f
  where f.id = v_instance.flow_version_id;

  v_next := app.flow_node(v_nodes, v_instance.current_seq + 1);

  update public.approval_tasks
     set status = 'approved', acted_at = now(), comment = v_comment
   where id = p_task_id;

  if v_next is null then
    -- 末节点：实例通过
    update public.approval_instances
       set status = 'approved'
     where id = v_instance.id
    returning * into v_instance;

    perform app.send_notification(
      v_instance.initiator_id,
      'approval.approved',
      jsonb_build_object(
        'title', '审批已通过：' || v_instance.title,
        'body', coalesce('审批意见：' || v_comment, '你的审批申请已通过'),
        'source_module', 'approval',
        'ref_type', 'approval_instance',
        'ref_id', v_instance.id::text
      )
    );
  else
    v_next_assignee := app.resolve_approver(v_next -> 'approver_rule', v_instance.initiator_id);

    update public.approval_instances
       set current_seq = v_instance.current_seq + 1
     where id = v_instance.id
    returning * into v_instance;

    insert into public.approval_tasks (instance_id, seq, assignee_id)
    values (v_instance.id, v_instance.current_seq, v_next_assignee);

    perform app.send_notification(
      v_next_assignee,
      'approval.pending',
      jsonb_build_object(
        'title', '待审批：' || v_instance.title,
        'body', '上一节点已通过，该申请待你处理',
        'source_module', 'approval',
        'ref_type', 'approval_instance',
        'ref_id', v_instance.id::text
      )
    );
  end if;

  perform app.audit_log(
    'approval', 'approve', 'instance', v_instance.id::text,
    jsonb_build_object(
      'task_id', p_task_id,
      'seq', v_task.seq,
      'comment', v_comment,
      'instance_status', v_instance.status,
      'current_seq', v_instance.current_seq
    )
  );

  -- TODO(integration/004)：emit_event('approval.approved', ...)
  if to_regprocedure('app.emit_event(text,jsonb)') is not null then
    perform app.emit_event(
      'approval.approved',
      jsonb_build_object('instance_id', v_instance.id, 'task_id', p_task_id, 'status', v_instance.status)
    );
  elsif to_regprocedure('public.emit_event(text,jsonb)') is not null then
    perform public.emit_event(
      'approval.approved',
      jsonb_build_object('instance_id', v_instance.id, 'task_id', p_task_id, 'status', v_instance.status)
    );
  end if;

  return v_instance;
end;
$$;

comment on function app.act_task(uuid, text, text) is
  '审批动作（approve/reject）：校验 assignee+当前节点+状态，原子推进实例（下一节点/终态），写审计+通知；驳回意见必填';

-- ---------------------------------------------------------------------------
-- 12. 撤回 withdraw_instance（GRANT authenticated；仅发起人 + running + 当前任务 pending）
-- ---------------------------------------------------------------------------
create function app.withdraw_instance(p_instance_id uuid)
returns public.approval_instances
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_instance public.approval_instances;
  v_task     public.approval_tasks;
begin
  if v_uid is null then
    raise exception '未登录，无法撤回审批' using errcode = '42501';
  end if;

  select * into v_instance
  from public.approval_instances
  where id = p_instance_id
  for update;

  if not found then
    raise exception '审批实例不存在：%', p_instance_id using errcode = 'P0002';
  end if;
  if v_instance.initiator_id <> v_uid then
    raise exception '仅发起人可撤回审批' using errcode = '42501';
  end if;
  if v_instance.status <> 'running' then
    raise exception '审批实例已结束，不可撤回' using errcode = '22023';
  end if;

  select * into v_task
  from public.approval_tasks
  where instance_id = p_instance_id
    and seq = v_instance.current_seq
  for update;

  if not found or v_task.status <> 'pending' then
    raise exception '当前审批任务已处理，不可撤回' using errcode = '22023';
  end if;

  update public.approval_tasks
     set status = 'skipped'
   where instance_id = p_instance_id
     and status = 'pending';

  update public.approval_instances
     set status = 'withdrawn'
   where id = p_instance_id
  returning * into v_instance;

  perform app.audit_log(
    'approval', 'withdraw', 'instance', p_instance_id::text,
    jsonb_build_object('seq', v_instance.current_seq)
  );

  return v_instance;
end;
$$;

comment on function app.withdraw_instance(uuid) is
  '撤回审批：仅发起人、实例 running 且当前节点任务 pending；置 withdrawn + pending 任务 skipped + 写审计';

-- ---------------------------------------------------------------------------
-- 13. 我的待办 my_todos（GRANT authenticated；dashboard/待办页消费）
-- ---------------------------------------------------------------------------
create function app.my_todos(
  p_pending boolean default true,
  p_limit   integer default 20
)
returns table (
  task_id         uuid,
  instance_id     uuid,
  title           text,
  module          text,
  ref_type        text,
  ref_id          text,
  form_data       jsonb,
  instance_status text,
  current_seq     integer,
  seq             integer,
  task_status     text,
  initiator_id    uuid,
  initiator_name  text,
  comment         text,
  created_at      timestamptz,
  acted_at        timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    t.id            as task_id,
    i.id            as instance_id,
    i.title         as title,
    i.module        as module,
    i.ref_type      as ref_type,
    i.ref_id        as ref_id,
    i.form_data     as form_data,
    i.status        as instance_status,
    i.current_seq   as current_seq,
    t.seq           as seq,
    t.status        as task_status,
    i.initiator_id  as initiator_id,
    p.full_name     as initiator_name,
    t.comment       as comment,
    t.created_at    as created_at,
    t.acted_at      as acted_at
  from public.approval_tasks t
  join public.approval_instances i on i.id = t.instance_id
  left join public.profiles p on p.id = i.initiator_id
  where t.assignee_id = (select auth.uid())
    and (
      (coalesce(p_pending, true) and t.status = 'pending')
      or (not coalesce(p_pending, true) and t.status <> 'pending')
    )
  order by
    case when coalesce(p_pending, true) then t.created_at end asc,
    case when not coalesce(p_pending, true) then t.acted_at end desc nulls last,
    t.created_at desc
  limit least(greatest(coalesce(p_limit, 20), 1), 200)
$$;

comment on function app.my_todos(boolean, integer) is
  '本人待办（pending=true，等待最久在前）/已办（pending=false，处理时间倒序）；limit 夹取 1..200';

-- ---------------------------------------------------------------------------
-- 14. public 包装层（PostgREST Data API 入口）
-- ---------------------------------------------------------------------------
create function public.submit_instance(
  p_module        text,
  p_ref_type      text,
  p_ref_id        text,
  p_template_code text,
  p_form_data     jsonb
)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select app.submit_instance(p_module, p_ref_type, p_ref_id, p_template_code, p_form_data)
$$;

create function public.act_task(
  p_task_id uuid,
  p_action  text,
  p_comment text
)
returns public.approval_instances
language sql
security definer
set search_path = ''
as $$
  select app.act_task(p_task_id, p_action, p_comment)
$$;

create function public.withdraw_instance(p_instance_id uuid)
returns public.approval_instances
language sql
security definer
set search_path = ''
as $$
  select app.withdraw_instance(p_instance_id)
$$;

create function public.my_todos(
  p_pending boolean default true,
  p_limit   integer default 20
)
returns table (
  task_id         uuid,
  instance_id     uuid,
  title           text,
  module          text,
  ref_type        text,
  ref_id          text,
  form_data       jsonb,
  instance_status text,
  current_seq     integer,
  seq             integer,
  task_status     text,
  initiator_id    uuid,
  initiator_name  text,
  comment         text,
  created_at      timestamptz,
  acted_at        timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.my_todos(p_pending, p_limit)
$$;

comment on function public.submit_instance(text, text, text, text, jsonb) is 'submit_instance Data API 薄包装';
comment on function public.act_task(uuid, text, text) is 'act_task Data API 薄包装（返回推进后的实例）';
comment on function public.withdraw_instance(uuid) is 'withdraw_instance Data API 薄包装';
comment on function public.my_todos(boolean, integer) is 'my_todos Data API 薄包装（dashboard 聚合消费）';

-- ---------------------------------------------------------------------------
-- 15. 权限：表级最小化（敏感表二分：无任何 API 角色的表级写）
-- ---------------------------------------------------------------------------
revoke all on public.approval_form_templates from public, anon, authenticated, service_role;
revoke all on public.approval_flows          from public, anon, authenticated, service_role;
revoke all on public.approval_instances      from public, anon, authenticated, service_role;
revoke all on public.approval_tasks          from public, anon, authenticated, service_role;
revoke all on public.approval_ccs            from public, anon, authenticated, service_role;
revoke all on public.form_renderers          from public, anon, authenticated, service_role;

grant select on public.approval_form_templates to authenticated;
grant select on public.approval_flows          to authenticated;
grant select on public.approval_instances      to authenticated;
grant select on public.approval_tasks          to authenticated;
grant select on public.approval_ccs            to authenticated;
grant select on public.form_renderers          to authenticated;

-- 内部辅助函数：不 GRANT API 角色（函数属主/SECURITY DEFINER wrapper 天然可调）
revoke all on function app.flow_node(jsonb, integer) from public, anon, authenticated;
revoke all on function app.validate_form_data(jsonb, jsonb) from public, anon, authenticated;
revoke all on function app.resolve_approver(jsonb, uuid) from public, anon, authenticated;
revoke all on function app.register_form_renderer(text, text, text) from public, anon, authenticated;

-- RLS 策略内调用：需 authenticated 可执行
revoke all on function app.is_instance_participant(uuid) from public, anon;
grant execute on function app.is_instance_participant(uuid) to authenticated;

-- 冻结触发器函数：与 app.set_updated_at 相同授权口径（触发器运行时调用）
revoke all on function app.protect_published_template() from public, anon;
grant execute on function app.protect_published_template() to authenticated;
revoke all on function app.protect_published_flow() from public, anon;
grant execute on function app.protect_published_flow() to authenticated;

-- 业务 RPC（app 实现 + public 包装）：登录用户可执行，内部校验属主/状态
revoke all on function app.submit_instance(text, text, text, text, jsonb) from public, anon;
grant execute on function app.submit_instance(text, text, text, text, jsonb) to authenticated;

revoke all on function app.act_task(uuid, text, text) from public, anon;
grant execute on function app.act_task(uuid, text, text) to authenticated;

revoke all on function app.withdraw_instance(uuid) from public, anon;
grant execute on function app.withdraw_instance(uuid) to authenticated;

revoke all on function app.my_todos(boolean, integer) from public, anon;
grant execute on function app.my_todos(boolean, integer) to authenticated;

revoke all on function public.submit_instance(text, text, text, text, jsonb) from public, anon;
grant execute on function public.submit_instance(text, text, text, text, jsonb) to authenticated;

revoke all on function public.act_task(uuid, text, text) from public, anon;
grant execute on function public.act_task(uuid, text, text) to authenticated;

revoke all on function public.withdraw_instance(uuid) from public, anon;
grant execute on function public.withdraw_instance(uuid) to authenticated;

revoke all on function public.my_todos(boolean, integer) from public, anon;
grant execute on function public.my_todos(boolean, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 16. RLS
-- ---------------------------------------------------------------------------
alter table public.approval_form_templates enable row level security;
alter table public.approval_flows          enable row level security;
alter table public.approval_instances      enable row level security;
alter table public.approval_tasks          enable row level security;
alter table public.approval_ccs            enable row level security;
alter table public.form_renderers          enable row level security;

-- 模板/流程：仅 admin 可读（管理页后续工单）；无写策略（写仅经 RPC）
create policy approval_form_templates_select_admin
on public.approval_form_templates
for select
to authenticated
using ((select app.current_role()) = 'admin');

create policy approval_flows_select_admin
on public.approval_flows
for select
to authenticated
using ((select app.current_role()) = 'admin');

-- 实例：发起人 / 任务审批人 / 抄送人 / admin 可见
create policy approval_instances_select_participant
on public.approval_instances
for select
to authenticated
using (app.is_instance_participant(id));

-- 任务：本人任务 + 所属实例的发起人/抄送人/admin
create policy approval_tasks_select_participant
on public.approval_tasks
for select
to authenticated
using (
  assignee_id = (select auth.uid())
  or app.is_instance_participant(instance_id)
);

-- 抄送：本人 + 所属实例参与方/admin
create policy approval_ccs_select_participant
on public.approval_ccs
for select
to authenticated
using (
  cc_user_id = (select auth.uid())
  or app.is_instance_participant(instance_id)
);

-- 渲染注册表：登录用户可读映射（详情页渲染需要）
create policy form_renderers_select_authenticated
on public.form_renderers
for select
to authenticated
using (true);
