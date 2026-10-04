-- 审批中心 · 模板设计器 + 流程配置 管理 RPC（工单 approval/008+009+010+011 后端合并交付）
-- 契约：docs/modules/approval/templates.md（字段设计器/版本化/停用守卫/schema 校验）、
--       docs/modules/approval/flows.md（节点编辑/审批人规则三型/模拟运行/版本化）、
--       docs/modules/approval/engine.md（resolve_approver 同一解析函数）、
--       docs/modules/INDEX.md 规则 2（审计摘要统一入口）、规则 10（内部 RPC 不 GRANT authenticated）。
-- 组成（admin 校验在 app 实现内，public 为 Data API 薄包装）：
--   1. app.validate_template_schema / app.validate_flow_nodes：schema/nodes 兜底校验（不授权）
--   2. 模板：upsert_form_template（p_id null 新建 v1 draft；p_id 提供改 draft 行）、
--      publish_form_template（draft→published，发布前复校 schema）、
--      disable_form_template（无 running 实例引用才可停用）、
--      new_form_template_version（复制 published/disabled 行为 v+1 draft）
--   3. 流程：upsert_flow / publish_flow / disable_flow / new_flow_version（同模板语义）
--   4. simulate_flow：逐节点 resolve_approver（与 submit_instance 同一函数），失败节点 error 标注
--   5. approval_usage_counts：版本 → 实例引用数（列表「引用中实例数」）
-- 语义：同 code（模板）/同 template_id（流程）允许存在多个 published 版本——实例绑具体版本，
--   发布新版不影响进行中旧实例（可追溯）；内容冻结由 001 触发器兜底，本迁移负责入口校验与语义化报错。
-- 依赖：20261004190000_approval_engine.sql（表/触发器/resolve_approver）、
--       20261003205349_audit_operations.sql（app.audit_log）、20261003211025_access_roles.sql（roles）、
--       20261003145039_init_profiles.sql（app.current_role / profiles）。

-- ---------------------------------------------------------------------------
-- 1. 校验 helper（app schema，不 GRANT API 角色；INDEX 规则 10）
-- ---------------------------------------------------------------------------
-- 1.1 模板 schema 校验：{"fields":[{key,label,type,required,options}]}；字段名必须合法标识符
create function app.validate_template_schema(p_schema jsonb)
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_field jsonb;
  v_key   text;
  v_label text;
  v_type  text;
  v_seen  text[] := array[]::text[];
  v_opt   jsonb;
begin
  if p_schema is null or jsonb_typeof(p_schema) <> 'object' then
    raise exception '模板 schema 非法：应为 JSON 对象' using errcode = '22023';
  end if;
  if not (p_schema ? 'fields') or jsonb_typeof(p_schema -> 'fields') <> 'array' then
    raise exception '模板 schema 非法：缺少 fields 数组' using errcode = '22023';
  end if;
  if jsonb_array_length(p_schema -> 'fields') = 0 then
    raise exception '模板 schema 非法：至少需要一个字段' using errcode = '22023';
  end if;

  for v_field in
    select e.value from pg_catalog.jsonb_array_elements(p_schema -> 'fields') as e
  loop
    if jsonb_typeof(v_field) <> 'object' then
      raise exception '模板 schema 非法：字段定义应为 JSON 对象' using errcode = '22023';
    end if;

    v_key := v_field ->> 'key';
    if v_key is null or v_key !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' then
      raise exception '模板 schema 非法：字段名 % 不是合法标识符（字母/下划线开头，仅字母数字下划线）',
        coalesce(v_key, '<null>') using errcode = '22023';
    end if;
    if v_key = any(v_seen) then
      raise exception '模板 schema 非法：字段名重复：%', v_key using errcode = '22023';
    end if;
    v_seen := pg_catalog.array_append(v_seen, v_key);

    v_label := v_field ->> 'label';
    if v_label is not null and btrim(v_label) = '' then
      raise exception '模板 schema 非法：字段 % 的 label 不能为空', v_key using errcode = '22023';
    end if;

    v_type := coalesce(v_field ->> 'type', 'text');
    if v_type not in ('text', 'number', 'date', 'boolean', 'select', 'multiselect', 'attachment', 'file') then
      raise exception '模板 schema 非法：字段 % 的类型不支持：%', v_key, v_type using errcode = '22023';
    end if;

    if v_type in ('select', 'multiselect') then
      v_opt := v_field -> 'options';
      if v_opt is null or jsonb_typeof(v_opt) <> 'array' or jsonb_array_length(v_opt) = 0 then
        raise exception '模板 schema 非法：字段 % 的选项不能为空', v_key using errcode = '22023';
      end if;
      if exists (
        select 1 from pg_catalog.jsonb_array_elements(v_opt) as o
        where jsonb_typeof(o.value) <> 'string' or btrim(o.value #>> '{}') = ''
      ) then
        raise exception '模板 schema 非法：字段 % 的选项应为非空字符串数组', v_key using errcode = '22023';
      end if;
    end if;

    if v_field ? 'required' and jsonb_typeof(v_field -> 'required') <> 'boolean' then
      raise exception '模板 schema 非法：字段 % 的 required 应为布尔值', v_key using errcode = '22023';
    end if;
  end loop;
end;
$$;

comment on function app.validate_template_schema(jsonb) is
  '模板 schema 兜底校验：fields 非空数组；key 合法标识符且不重复；type 在引擎支持集合内；select/multiselect 选项非空';

-- 1.2 流程 nodes 校验：seq 从 1 连续；审批人规则三型（role 值须为 active 角色 code / dept_leader / user 须为 active 用户）
create function app.validate_flow_nodes(p_nodes jsonb)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_node     jsonb;
  v_expected integer := 0;
  v_rule     jsonb;
  v_type     text;
  v_value    text;
  v_user     uuid;
  v_timeout  jsonb;
begin
  if p_nodes is null or jsonb_typeof(p_nodes) <> 'array' then
    raise exception '流程节点非法：nodes 应为数组' using errcode = '22023';
  end if;
  if jsonb_array_length(p_nodes) = 0 then
    raise exception '流程节点非法：至少需要一个节点' using errcode = '22023';
  end if;

  for v_node in
    select e.value from pg_catalog.jsonb_array_elements(p_nodes) as e
  loop
    if jsonb_typeof(v_node) <> 'object' then
      raise exception '流程节点非法：节点定义应为 JSON 对象' using errcode = '22023';
    end if;

    v_expected := v_expected + 1;
    if (v_node ->> 'seq') is null
       or (v_node ->> 'seq') !~ '^[0-9]+$'
       or (v_node ->> 'seq')::integer <> v_expected then
      raise exception '流程节点非法：seq 必须从 1 连续编号（第 % 个节点期望 seq=%）', v_expected, v_expected
        using errcode = '22023';
    end if;

    v_rule := v_node -> 'approver_rule';
    if v_rule is null or jsonb_typeof(v_rule) <> 'object' then
      raise exception '流程节点非法：seq=% 缺少审批人规则', v_expected using errcode = '22023';
    end if;

    v_type  := v_rule ->> 'type';
    v_value := nullif(btrim(coalesce(v_rule ->> 'value', '')), '');

    if v_type = 'role' then
      if v_value is null then
        raise exception '流程节点非法：seq=% 的 role 规则缺少 value', v_expected using errcode = '22023';
      end if;
      if not exists (
        select 1 from public.roles r where r.code = v_value and r.status = 'active'
      ) then
        raise exception '审批角色不存在或已停用：%', v_value using errcode = 'P0002';
      end if;
    elsif v_type = 'dept_leader' then
      -- 无需 value：运行时按发起人 department_id → departments.leader_id 解析
      null;
    elsif v_type = 'user' then
      if v_value is null then
        raise exception '流程节点非法：seq=% 的 user 规则缺少 value', v_expected using errcode = '22023';
      end if;
      begin
        v_user := v_value::uuid;
      exception when invalid_text_representation then
        raise exception '流程节点非法：seq=% 的指定审批人 value 不是有效用户 id：%', v_expected, v_value
          using errcode = '22023';
      end;
      if not exists (
        select 1 from public.profiles p where p.id = v_user and p.status = 'active'
      ) then
        raise exception '指定审批人不存在或已停用：%', v_value using errcode = 'P0002';
      end if;
    else
      raise exception '流程节点非法：审批人规则 type 非法：%', coalesce(v_type, '<null>')
        using errcode = '22023';
    end if;

    v_timeout := v_node -> 'timeout_hours';
    if v_timeout is not null and v_timeout <> 'null'::jsonb then
      if jsonb_typeof(v_timeout) <> 'number' then
        raise exception '流程节点非法：seq=% 的超时时长应为数字', v_expected using errcode = '22023';
      end if;
      if (v_timeout #>> '{}')::numeric < 0 then
        raise exception '流程节点非法：seq=% 的超时时长不能为负数', v_expected using errcode = '22023';
      end if;
    end if;
  end loop;
end;
$$;

comment on function app.validate_flow_nodes(jsonb) is
  '流程 nodes 兜底校验：seq 从 1 连续；approver_rule.type ∈ role/dept_leader/user；role 须为 active 角色、'
  'user 须为 active 用户；timeout_hours 可选且非负';

-- ---------------------------------------------------------------------------
-- 2. 模板 RPC（admin）
-- ---------------------------------------------------------------------------
-- 2.1 upsert_form_template：p_id null → 新建 v1 draft；p_id 提供 → 仅 draft 行可改全字段
create function app.upsert_form_template(
  p_name   text,
  p_code   text,
  p_module text,
  p_schema jsonb,
  p_id     uuid default null
)
returns public.approval_form_templates
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_row public.approval_form_templates;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_name is null or btrim(p_name) = '' then
    raise exception '模板名称不能为空' using errcode = '22023';
  end if;
  if p_code is null or btrim(p_code) = '' then
    raise exception '模板 code 不能为空' using errcode = '22023';
  end if;
  if btrim(p_code) !~ '^[a-z0-9][a-z0-9_.-]*$' then
    raise exception '模板 code 仅允许小写字母、数字、点、下划线与连字符：%', btrim(p_code)
      using errcode = '22023';
  end if;
  if p_module is null or btrim(p_module) = '' then
    raise exception '来源模块不能为空' using errcode = '22023';
  end if;

  perform app.validate_template_schema(p_schema);

  if p_id is null then
    begin
      insert into public.approval_form_templates
        (name, code, module, version, schema, status, created_by, updated_by)
      values
        (btrim(p_name), btrim(p_code), btrim(p_module), 1, p_schema, 'draft', v_uid, v_uid)
      returning * into v_row;
    exception when unique_violation then
      raise exception '模板 code 已存在：%（请基于现有版本使用「新版本」）', btrim(p_code)
        using errcode = '22023';
    end;

    perform app.audit_log(
      'approval', 'create', 'form_template', v_row.id::text,
      jsonb_build_object('code', v_row.code, 'version', v_row.version,
                         'name', v_row.name, 'module', v_row.module)
    );
  else
    select * into v_row
    from public.approval_form_templates
    where id = p_id
    for update;

    if not found then
      raise exception '审批表单模板不存在：%', p_id using errcode = 'P0002';
    end if;
    if v_row.status <> 'draft' then
      raise exception '模板 % 当前为 % 状态，仅草稿可编辑（已发布内容冻结，请使用「新版本」）',
        v_row.code, v_row.status using errcode = '22023';
    end if;

    begin
      update public.approval_form_templates
         set name       = btrim(p_name),
             code       = btrim(p_code),
             module     = btrim(p_module),
             schema     = p_schema,
             updated_by = v_uid
       where id = p_id
      returning * into v_row;
    exception when unique_violation then
      raise exception '模板 code 已存在：%（请基于现有版本使用「新版本」）', btrim(p_code)
        using errcode = '22023';
    end;

    perform app.audit_log(
      'approval', 'update', 'form_template', v_row.id::text,
      jsonb_build_object('code', v_row.code, 'version', v_row.version,
                         'name', v_row.name, 'module', v_row.module)
    );
  end if;

  return v_row;
end;
$$;

comment on function app.upsert_form_template(text, text, text, jsonb, uuid) is
  '模板保存（admin）：p_id null 新建 version=1 draft；p_id 提供仅 draft 行可改（全字段），'
  'schema 经 validate_template_schema 校验；写审计 create/update';

-- 2.2 publish_form_template：draft → published（发布前复校 schema；同 code 允许多个 published）
create function app.publish_form_template(p_id uuid)
returns public.approval_form_templates
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_row public.approval_form_templates;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.approval_form_templates
  where id = p_id
  for update;

  if not found then
    raise exception '审批表单模板不存在：%', p_id using errcode = 'P0002';
  end if;
  if v_row.status <> 'draft' then
    raise exception '模板 % 当前为 % 状态，仅草稿可发布', v_row.code, v_row.status
      using errcode = '22023';
  end if;

  perform app.validate_template_schema(v_row.schema);

  update public.approval_form_templates
     set status = 'published', updated_by = v_uid
   where id = p_id
  returning * into v_row;

  perform app.audit_log(
    'approval', 'publish', 'form_template', v_row.id::text,
    jsonb_build_object('code', v_row.code, 'version', v_row.version,
                       'name', v_row.name, 'module', v_row.module)
  );

  return v_row;
end;
$$;

comment on function app.publish_form_template(uuid) is
  '模板发布（admin）：仅 draft 可发布，schema 复校通过后置 published；同 code 允许多个 published 版本（实例绑版本）';

-- 2.3 disable_form_template：无 running 实例引用才允许；否则拒绝并报实例数
create function app.disable_form_template(p_id uuid)
returns public.approval_form_templates
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_row     public.approval_form_templates;
  v_running bigint;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.approval_form_templates
  where id = p_id
  for update;

  if not found then
    raise exception '审批表单模板不存在：%', p_id using errcode = 'P0002';
  end if;
  if v_row.status = 'disabled' then
    return v_row;  -- 幂等：已停用直接返回，不重复写审计
  end if;

  select count(*) into v_running
  from public.approval_instances i
  where i.template_version_id = p_id
    and i.status = 'running';

  if v_running > 0 then
    raise exception '模板 % 仍有 % 个进行中实例引用，不可停用', v_row.code, v_running
      using errcode = '22023';
  end if;

  update public.approval_form_templates
     set status = 'disabled', updated_by = v_uid
   where id = p_id
  returning * into v_row;

  perform app.audit_log(
    'approval', 'disable', 'form_template', v_row.id::text,
    jsonb_build_object('code', v_row.code, 'version', v_row.version)
  );

  return v_row;
end;
$$;

comment on function app.disable_form_template(uuid) is
  '模板停用（admin，幂等）：running 实例引用数 >0 时报错拒绝；否则置 disabled（published/draft 均可，内容冻结触发器放行）';

-- 2.4 new_form_template_version：复制 published/disabled 行为 version+1 draft（不改旧版）
create function app.new_form_template_version(p_id uuid)
returns public.approval_form_templates
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_src     public.approval_form_templates;
  v_row     public.approval_form_templates;
  v_version integer;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_src
  from public.approval_form_templates
  where id = p_id;

  if not found then
    raise exception '审批表单模板不存在：%', p_id using errcode = 'P0002';
  end if;
  if v_src.status = 'draft' then
    raise exception '草稿版本无需复制新版本（可直接编辑）：% v%', v_src.code, v_src.version
      using errcode = '22023';
  end if;

  -- 锁同 code 全部版本，串行化 version 计算（并发点「新版本」不撞唯一约束）
  perform 1
  from public.approval_form_templates t
  where t.code = v_src.code
  for update;

  select coalesce(max(t.version), 0) + 1 into v_version
  from public.approval_form_templates t
  where t.code = v_src.code;

  insert into public.approval_form_templates
    (name, code, module, version, schema, status, created_by, updated_by)
  values
    (v_src.name, v_src.code, v_src.module, v_version, v_src.schema, 'draft', v_uid, v_uid)
  returning * into v_row;

  perform app.audit_log(
    'approval', 'new_version', 'form_template', v_row.id::text,
    jsonb_build_object('code', v_row.code, 'from_version', v_src.version, 'to_version', v_row.version)
  );

  return v_row;
end;
$$;

comment on function app.new_form_template_version(uuid) is
  '模板「新版本」（admin）：复制 published/disabled 行为 version=max+1 draft；旧版保持不变（可追溯）';

-- ---------------------------------------------------------------------------
-- 3. 流程 RPC（admin；结构与模板 RPC 对称）
-- ---------------------------------------------------------------------------
-- 3.1 upsert_flow：p_id null → 新建 version=1 draft；p_id 提供 → 仅 draft 行可改
create function app.upsert_flow(
  p_name        text,
  p_template_id uuid,
  p_nodes       jsonb,
  p_id          uuid default null
)
returns public.approval_flows
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_row    public.approval_flows;
  v_tpl    public.approval_form_templates;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_name is null or btrim(p_name) = '' then
    raise exception '流程名称不能为空' using errcode = '22023';
  end if;
  if p_template_id is null then
    raise exception '绑定模板不能为空' using errcode = '22023';
  end if;

  select * into v_tpl
  from public.approval_form_templates
  where id = p_template_id;

  if not found then
    raise exception '绑定模板不存在：%', p_template_id using errcode = 'P0002';
  end if;
  if v_tpl.status = 'disabled' then
    raise exception '绑定模板已停用，不可绑定流程：% v%', v_tpl.code, v_tpl.version
      using errcode = '22023';
  end if;

  perform app.validate_flow_nodes(p_nodes);

  if p_id is null then
    begin
      insert into public.approval_flows
        (name, template_id, version, nodes, branches, status, created_by, updated_by)
      values
        (btrim(p_name), p_template_id, 1, p_nodes, null, 'draft', v_uid, v_uid)
      returning * into v_row;
    exception when unique_violation then
      raise exception '该模板下已存在流程（唯一 template_id+version，请使用「新版本」）：% v%',
        v_tpl.code, v_tpl.version using errcode = '22023';
    end;

    perform app.audit_log(
      'approval', 'create', 'flow', v_row.id::text,
      jsonb_build_object('name', v_row.name, 'template_id', v_row.template_id,
                         'version', v_row.version, 'node_count', jsonb_array_length(v_row.nodes))
    );
  else
    select * into v_row
    from public.approval_flows
    where id = p_id
    for update;

    if not found then
      raise exception '审批流程不存在：%', p_id using errcode = 'P0002';
    end if;
    if v_row.status <> 'draft' then
      raise exception '流程 % v% 当前为 % 状态，仅草稿可编辑（已发布内容冻结，请使用「新版本」）',
        v_row.name, v_row.version, v_row.status using errcode = '22023';
    end if;

    begin
      update public.approval_flows
         set name        = btrim(p_name),
             template_id = p_template_id,
             nodes       = p_nodes,
             updated_by  = v_uid
       where id = p_id
      returning * into v_row;
    exception when unique_violation then
      raise exception '该模板下已存在流程（唯一 template_id+version，请使用「新版本」）：% v%',
        v_tpl.code, v_tpl.version using errcode = '22023';
    end;

    perform app.audit_log(
      'approval', 'update', 'flow', v_row.id::text,
      jsonb_build_object('name', v_row.name, 'template_id', v_row.template_id,
                         'version', v_row.version, 'node_count', jsonb_array_length(v_row.nodes))
    );
  end if;

  return v_row;
end;
$$;

comment on function app.upsert_flow(text, uuid, jsonb, uuid) is
  '流程保存（admin）：p_id null 新建 version=1 draft；p_id 提供仅 draft 行可改；nodes 经 validate_flow_nodes 校验；'
  'branches 保持 NULL（P1 二期条件分支，仅建模预留）';

-- 3.2 publish_flow：draft → published（发布前复校 nodes）
create function app.publish_flow(p_id uuid)
returns public.approval_flows
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_row public.approval_flows;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.approval_flows
  where id = p_id
  for update;

  if not found then
    raise exception '审批流程不存在：%', p_id using errcode = 'P0002';
  end if;
  if v_row.status <> 'draft' then
    raise exception '流程 % v% 当前为 % 状态，仅草稿可发布', v_row.name, v_row.version, v_row.status
      using errcode = '22023';
  end if;

  perform app.validate_flow_nodes(v_row.nodes);

  update public.approval_flows
     set status = 'published', updated_by = v_uid
   where id = p_id
  returning * into v_row;

  perform app.audit_log(
    'approval', 'publish', 'flow', v_row.id::text,
    jsonb_build_object('name', v_row.name, 'template_id', v_row.template_id, 'version', v_row.version)
  );

  return v_row;
end;
$$;

comment on function app.publish_flow(uuid) is
  '流程发布（admin）：仅 draft 可发布，nodes 复校（角色/用户此刻仍有效）后置 published';

-- 3.3 disable_flow：running 实例引用数 >0 拒绝
create function app.disable_flow(p_id uuid)
returns public.approval_flows
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_row     public.approval_flows;
  v_running bigint;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.approval_flows
  where id = p_id
  for update;

  if not found then
    raise exception '审批流程不存在：%', p_id using errcode = 'P0002';
  end if;
  if v_row.status = 'disabled' then
    return v_row;  -- 幂等
  end if;

  select count(*) into v_running
  from public.approval_instances i
  where i.flow_version_id = p_id
    and i.status = 'running';

  if v_running > 0 then
    raise exception '流程 % v% 仍有 % 个进行中实例引用，不可停用', v_row.name, v_row.version, v_running
      using errcode = '22023';
  end if;

  update public.approval_flows
     set status = 'disabled', updated_by = v_uid
   where id = p_id
  returning * into v_row;

  perform app.audit_log(
    'approval', 'disable', 'flow', v_row.id::text,
    jsonb_build_object('name', v_row.name, 'template_id', v_row.template_id, 'version', v_row.version)
  );

  return v_row;
end;
$$;

comment on function app.disable_flow(uuid) is
  '流程停用（admin，幂等）：running 实例引用数 >0 时报错拒绝；否则置 disabled';

-- 3.4 new_flow_version：复制 published/disabled 流程为 version+1 draft
create function app.new_flow_version(p_id uuid)
returns public.approval_flows
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_src     public.approval_flows;
  v_row     public.approval_flows;
  v_version integer;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_src
  from public.approval_flows
  where id = p_id;

  if not found then
    raise exception '审批流程不存在：%', p_id using errcode = 'P0002';
  end if;
  if v_src.status = 'draft' then
    raise exception '草稿版本无需复制新版本（可直接编辑）：% v%', v_src.name, v_src.version
      using errcode = '22023';
  end if;

  perform 1
  from public.approval_flows f
  where f.template_id = v_src.template_id
  for update;

  select coalesce(max(f.version), 0) + 1 into v_version
  from public.approval_flows f
  where f.template_id = v_src.template_id;

  insert into public.approval_flows
    (name, template_id, version, nodes, branches, status, created_by, updated_by)
  values
    (v_src.name, v_src.template_id, v_version, v_src.nodes, null, 'draft', v_uid, v_uid)
  returning * into v_row;

  perform app.audit_log(
    'approval', 'new_version', 'flow', v_row.id::text,
    jsonb_build_object('name', v_row.name, 'template_id', v_row.template_id,
                       'from_version', v_src.version, 'to_version', v_row.version)
  );

  return v_row;
end;
$$;

comment on function app.new_flow_version(uuid) is
  '流程「新版本」（admin）：复制 published/disabled 为 version=max+1 draft；旧版保持不变';

-- ---------------------------------------------------------------------------
-- 4. 模拟运行 simulate_flow（admin；与 submit_instance 共用 app.resolve_approver）
-- ---------------------------------------------------------------------------
create function app.simulate_flow(
  p_flow_id   uuid,
  p_form_data jsonb default '{}'::jsonb,
  p_initiator uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_flow       public.approval_flows;
  v_initiator  uuid := p_initiator;
  v_init_name  text;
  v_node       jsonb;
  v_seq        integer;
  v_approver   uuid;
  v_name       text;
  v_step       jsonb;
  v_result     jsonb := '[]'::jsonb;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_form_data is not null and jsonb_typeof(p_form_data) <> 'object' then
    raise exception 'form_data 必须是 JSON 对象' using errcode = '22023';
  end if;

  select * into v_flow
  from public.approval_flows
  where id = p_flow_id;

  if not found then
    raise exception '审批流程不存在：%', p_flow_id using errcode = 'P0002';
  end if;

  if v_initiator is null then
    v_initiator := (select auth.uid());
  end if;

  select p.full_name into v_init_name
  from public.profiles p
  where p.id = v_initiator and p.status = 'active';

  if not found then
    raise exception '模拟发起人不存在或已停用：%', coalesce(v_initiator::text, '<null>')
      using errcode = '22023';
  end if;

  -- 逐节点解析：与 submit_instance / act_task 完全相同的 app.resolve_approver；
  -- 单节点解析失败不中断整体模拟，该节点标注 error（前端逐行展示）。
  for v_node in
    select e.value
    from pg_catalog.jsonb_array_elements(v_flow.nodes) as e
    order by (e.value ->> 'seq')::integer
  loop
    v_seq := (v_node ->> 'seq')::integer;
    begin
      v_approver := app.resolve_approver(v_node -> 'approver_rule', v_initiator);
      select p.full_name into v_name
      from public.profiles p
      where p.id = v_approver;
      v_step := jsonb_build_object(
        'seq',           v_seq,
        'approver_id',   v_approver,
        'approver_name', v_name,
        'approver_rule', v_node -> 'approver_rule',
        'timeout_hours', v_node -> 'timeout_hours',
        'error',         null
      );
    exception when others then
      v_step := jsonb_build_object(
        'seq',           v_seq,
        'approver_id',   null,
        'approver_name', null,
        'approver_rule', v_node -> 'approver_rule',
        'timeout_hours', v_node -> 'timeout_hours',
        'error',         sqlerrm
      );
    end;
    v_result := v_result || pg_catalog.jsonb_build_array(v_step);
  end loop;

  return v_result;
end;
$$;

comment on function app.simulate_flow(uuid, jsonb, uuid) is
  '流程模拟（admin）：按 nodes 顺序逐节点调用 app.resolve_approver（与 submit_instance/act_task 同一函数），'
  '返回 [{seq, approver_id, approver_name, approver_rule, timeout_hours, error}]；单节点解析失败仅标注 error 不中断；'
  'p_form_data 本期仅校验对象形态（条件分支 P2 启用后参与判定），p_initiator 缺省为当前管理员';

-- ---------------------------------------------------------------------------
-- 5. 实例引用数 approval_usage_counts（admin；列表「实例引用数」）
-- ---------------------------------------------------------------------------
create function app.approval_usage_counts()
returns table (
  template_version_id uuid,
  flow_version_id     uuid,
  total_count         bigint,
  running_count       bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  return query
  select
    i.template_version_id,
    i.flow_version_id,
    count(*)                                   as total_count,
    count(*) filter (where i.status = 'running') as running_count
  from public.approval_instances i
  group by i.template_version_id, i.flow_version_id;
end;
$$;

comment on function app.approval_usage_counts() is
  '模板/流程版本实例引用数（admin）：按 (template_version_id, flow_version_id) 分组，total/running 计数供管理列表展示';

-- ---------------------------------------------------------------------------
-- 6. public 薄包装（PostgREST Data API 入口）
-- ---------------------------------------------------------------------------
create function public.upsert_form_template(
  p_name   text,
  p_code   text,
  p_module text,
  p_schema jsonb,
  p_id     uuid default null
)
returns public.approval_form_templates
language sql
security definer
set search_path = ''
as $$
  select app.upsert_form_template(p_name, p_code, p_module, p_schema, p_id)
$$;

create function public.publish_form_template(p_id uuid)
returns public.approval_form_templates
language sql
security definer
set search_path = ''
as $$
  select app.publish_form_template(p_id)
$$;

create function public.disable_form_template(p_id uuid)
returns public.approval_form_templates
language sql
security definer
set search_path = ''
as $$
  select app.disable_form_template(p_id)
$$;

create function public.new_form_template_version(p_id uuid)
returns public.approval_form_templates
language sql
security definer
set search_path = ''
as $$
  select app.new_form_template_version(p_id)
$$;

create function public.upsert_flow(
  p_name        text,
  p_template_id uuid,
  p_nodes       jsonb,
  p_id          uuid default null
)
returns public.approval_flows
language sql
security definer
set search_path = ''
as $$
  select app.upsert_flow(p_name, p_template_id, p_nodes, p_id)
$$;

create function public.publish_flow(p_id uuid)
returns public.approval_flows
language sql
security definer
set search_path = ''
as $$
  select app.publish_flow(p_id)
$$;

create function public.disable_flow(p_id uuid)
returns public.approval_flows
language sql
security definer
set search_path = ''
as $$
  select app.disable_flow(p_id)
$$;

create function public.new_flow_version(p_id uuid)
returns public.approval_flows
language sql
security definer
set search_path = ''
as $$
  select app.new_flow_version(p_id)
$$;

create function public.simulate_flow(
  p_flow_id   uuid,
  p_form_data jsonb default '{}'::jsonb,
  p_initiator uuid default null
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.simulate_flow(p_flow_id, p_form_data, p_initiator)
$$;

create function public.approval_usage_counts()
returns table (
  template_version_id uuid,
  flow_version_id     uuid,
  total_count         bigint,
  running_count       bigint
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.approval_usage_counts()
$$;

comment on function public.upsert_form_template(text, text, text, jsonb, uuid) is 'upsert_form_template Data API 薄包装（admin）';
comment on function public.publish_form_template(uuid) is 'publish_form_template Data API 薄包装（admin）';
comment on function public.disable_form_template(uuid) is 'disable_form_template Data API 薄包装（admin）';
comment on function public.new_form_template_version(uuid) is 'new_form_template_version Data API 薄包装（admin）';
comment on function public.upsert_flow(text, uuid, jsonb, uuid) is 'upsert_flow Data API 薄包装（admin）';
comment on function public.publish_flow(uuid) is 'publish_flow Data API 薄包装（admin）';
comment on function public.disable_flow(uuid) is 'disable_flow Data API 薄包装（admin）';
comment on function public.new_flow_version(uuid) is 'new_flow_version Data API 薄包装（admin）';
comment on function public.simulate_flow(uuid, jsonb, uuid) is 'simulate_flow Data API 薄包装（admin）';
comment on function public.approval_usage_counts() is 'approval_usage_counts Data API 薄包装（admin）';

-- ---------------------------------------------------------------------------
-- 7. 权限：管理 RPC app+public 授 authenticated（admin 校验在实现内）；helper/包装不授 anon（规则 10）
-- ---------------------------------------------------------------------------
revoke all on function app.validate_template_schema(jsonb) from public, anon, authenticated;
revoke all on function app.validate_flow_nodes(jsonb) from public, anon, authenticated;

revoke all on function app.upsert_form_template(text, text, text, jsonb, uuid) from public, anon;
grant execute on function app.upsert_form_template(text, text, text, jsonb, uuid) to authenticated;

revoke all on function app.publish_form_template(uuid) from public, anon;
grant execute on function app.publish_form_template(uuid) to authenticated;

revoke all on function app.disable_form_template(uuid) from public, anon;
grant execute on function app.disable_form_template(uuid) to authenticated;

revoke all on function app.new_form_template_version(uuid) from public, anon;
grant execute on function app.new_form_template_version(uuid) to authenticated;

revoke all on function app.upsert_flow(text, uuid, jsonb, uuid) from public, anon;
grant execute on function app.upsert_flow(text, uuid, jsonb, uuid) to authenticated;

revoke all on function app.publish_flow(uuid) from public, anon;
grant execute on function app.publish_flow(uuid) to authenticated;

revoke all on function app.disable_flow(uuid) from public, anon;
grant execute on function app.disable_flow(uuid) to authenticated;

revoke all on function app.new_flow_version(uuid) from public, anon;
grant execute on function app.new_flow_version(uuid) to authenticated;

revoke all on function app.simulate_flow(uuid, jsonb, uuid) from public, anon;
grant execute on function app.simulate_flow(uuid, jsonb, uuid) to authenticated;

revoke all on function app.approval_usage_counts() from public, anon;
grant execute on function app.approval_usage_counts() to authenticated;

revoke all on function public.upsert_form_template(text, text, text, jsonb, uuid) from public, anon;
grant execute on function public.upsert_form_template(text, text, text, jsonb, uuid) to authenticated;

revoke all on function public.publish_form_template(uuid) from public, anon;
grant execute on function public.publish_form_template(uuid) to authenticated;

revoke all on function public.disable_form_template(uuid) from public, anon;
grant execute on function public.disable_form_template(uuid) to authenticated;

revoke all on function public.new_form_template_version(uuid) from public, anon;
grant execute on function public.new_form_template_version(uuid) to authenticated;

revoke all on function public.upsert_flow(text, uuid, jsonb, uuid) from public, anon;
grant execute on function public.upsert_flow(text, uuid, jsonb, uuid) to authenticated;

revoke all on function public.publish_flow(uuid) from public, anon;
grant execute on function public.publish_flow(uuid) to authenticated;

revoke all on function public.disable_flow(uuid) from public, anon;
grant execute on function public.disable_flow(uuid) to authenticated;

revoke all on function public.new_flow_version(uuid) from public, anon;
grant execute on function public.new_flow_version(uuid) to authenticated;

revoke all on function public.simulate_flow(uuid, jsonb, uuid) from public, anon;
grant execute on function public.simulate_flow(uuid, jsonb, uuid) to authenticated;

revoke all on function public.approval_usage_counts() from public, anon;
grant execute on function public.approval_usage_counts() to authenticated;
