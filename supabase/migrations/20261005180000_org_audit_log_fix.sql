-- 组织管理 · 关键写 RPC 审计摘要补齐（审计缺口修复 · 批次 1）
-- 背景：org 关键写 RPC（部门 4 个 + 岗位 4 个 + 用户档案 1 个）尚未按 INDEX 规则 2
--       调 app.audit_log 写合规摘要，audit/合规报告与数据变更页存在留痕缺口。
--
-- 语义：
--   * 成功写后调用 app.audit_log(p_module='org', p_action, p_object_type, p_object_id,
--     p_diff)（5 参），diff 统一含 before/after：新建 before=null / 删除 after=null /
--     更新为变更前后行快照；档案更新仅收口实际变更字段的 before/after；
--   * 幂等分支（已是目标状态直接 return，未发生写入）不记审计；
--   * 除审计调用外，函数体与既有实现保持一致（签名/校验/错误码不变）；
--     create or replace 保留既有 REVOKE/GRANT（authenticated 可达性不变）；
--   * audit_log 不授予 authenticated（INDEX 规则 10），这些函数均为 SECURITY DEFINER
--     属主 postgres，可在函数内直调（先例：access/003 app.assign_role）。
--
-- 依赖：audit/001（app.audit_log）、org/007（disable/delete 按 department_id 语义）、
--       org/014（admin_update_profile 7 参 + emit_event 现状）。
--
-- 覆盖清单（action）：
--   app.upsert_department     create / update（按 p_id 是否 null）
--   app.disable_department    disable（含 org/007 重定义行为）
--   app.enable_department     enable
--   app.delete_department     delete（含 org/007 重定义行为）
--   app.upsert_position       create / update
--   app.disable_position      disable
--   app.enable_position       enable
--   app.delete_position       delete（物理删除，after=null）
--   public.admin_update_profile  update（diff 仅含变更字段）

-- ---------------------------------------------------------------------------
-- 1. app.upsert_department：成功写后补审计（create/update）
--    另：协同 sync_dept_guard 的同级名称唯一索引，将 23505 转为中文提示
-- ---------------------------------------------------------------------------
create or replace function app.upsert_department(
  p_id         uuid,
  p_name       text,
  p_parent_id  uuid,
  p_leader_id  uuid,
  p_sort_order integer
)
returns public.departments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row    public.departments;
  v_before public.departments;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_name is null or btrim(p_name) = '' then
    raise exception '部门名称不能为空' using errcode = '22023';
  end if;

  if p_leader_id is not null
     and not exists (select 1 from public.profiles where id = p_leader_id) then
    raise exception '负责人不存在：%', p_leader_id using errcode = 'P0002';
  end if;

  -- 新建（p_id 为 null）
  if p_id is null then
    if p_parent_id is not null
       and not exists (
         select 1
         from public.departments
         where id = p_parent_id
           and status <> 'deleted'
       ) then
      raise exception '父部门不存在或已删除：%', p_parent_id using errcode = 'P0002';
    end if;

    insert into public.departments
      (name, parent_id, leader_id, sort_order, created_by, updated_by)
    values
      (btrim(p_name), p_parent_id, p_leader_id, coalesce(p_sort_order, 0),
       (select auth.uid()), (select auth.uid()))
    returning * into v_row;

    perform app.audit_log(
      'org', 'create', 'department', v_row.id::text,
      jsonb_build_object('before', null, 'after', to_jsonb(v_row))
    );

    return v_row;
  end if;

  -- 更新：p_parent_id 为全量写入（null = 移到根）
  select * into v_before
  from public.departments
  where id = p_id;

  if not found then
    raise exception '部门不存在：%', p_id using errcode = 'P0002';
  end if;

  if v_before.status = 'deleted' then
    raise exception '已删除的部门不可编辑' using errcode = '22023';
  end if;

  perform app.validate_department_move(p_id, p_parent_id);

  update public.departments
     set name       = btrim(p_name),
         parent_id  = p_parent_id,
         leader_id  = p_leader_id,
         sort_order = coalesce(p_sort_order, 0),
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  perform app.audit_log(
    'org', 'update', 'department', v_row.id::text,
    jsonb_build_object('before', to_jsonb(v_before), 'after', to_jsonb(v_row))
  );

  return v_row;
exception
  when unique_violation then
    -- 同级名称唯一索引（departments_parent_name_key）兜底转中文提示
    raise exception '同级部门名称已存在：%', btrim(p_name) using errcode = '23505';
end;
$$;

comment on function app.upsert_department(uuid, text, uuid, uuid, integer) is
  '部门新建/编辑 RPC（admin）：id 为 null 新建；更新时 parent 为全量写入，内部做防环校验；'
  '成功写后写 audit_log（create/update，diff 含 before/after）；同级名称冲突转 23505 中文提示';

-- ---------------------------------------------------------------------------
-- 2. app.disable_department（org/007 重定义版 + 审计）
-- ---------------------------------------------------------------------------
create or replace function app.disable_department(p_id uuid)
returns public.departments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row    public.departments;
  v_before public.departments;
  v_count  bigint;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.departments
  where id = p_id;

  if not found then
    raise exception '部门不存在：%', p_id using errcode = 'P0002';
  end if;

  if v_row.status = 'deleted' then
    raise exception '已删除的部门不可停用' using errcode = '22023';
  end if;

  if v_row.status = 'disabled' then
    return v_row; -- 幂等（未发生写入，不记审计）
  end if;

  -- 在职人员检查（org/007）：department_id 精确匹配为主；
  -- department_id 为 NULL 的历史行按部门名文本兜底
  select count(*) into v_count
  from public.profiles
  where status = 'active'
    and (
      department_id = p_id
      or (department_id is null and department = v_row.name)
    );

  if v_count > 0 then
    raise exception '该部门下仍有 % 名在职人员，无法停用', v_count using errcode = '22023';
  end if;

  v_before := v_row;

  update public.departments
     set status     = 'disabled',
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  perform app.audit_log(
    'org', 'disable', 'department', v_row.id::text,
    jsonb_build_object('before', to_jsonb(v_before), 'after', to_jsonb(v_row))
  );

  return v_row;
end;
$$;

comment on function app.disable_department(uuid) is
  '部门停用 RPC（admin）：按 department_id 统计在职人员（NULL 行文本兜底）拒绝并提示人数；'
  '成功写后写 audit_log（disable，diff 含 before/after）；幂等分支不记审计';

-- ---------------------------------------------------------------------------
-- 3. app.enable_department（原行为 + 审计）
-- ---------------------------------------------------------------------------
create or replace function app.enable_department(p_id uuid)
returns public.departments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row    public.departments;
  v_before public.departments;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.departments
  where id = p_id;

  if not found then
    raise exception '部门不存在：%', p_id using errcode = 'P0002';
  end if;

  if v_row.status = 'deleted' then
    raise exception '已删除的部门不可启用' using errcode = '22023';
  end if;

  if v_row.status = 'active' then
    return v_row; -- 幂等（未发生写入，不记审计）
  end if;

  v_before := v_row;

  update public.departments
     set status     = 'active',
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  perform app.audit_log(
    'org', 'enable', 'department', v_row.id::text,
    jsonb_build_object('before', to_jsonb(v_before), 'after', to_jsonb(v_row))
  );

  return v_row;
end;
$$;

comment on function app.enable_department(uuid) is
  '部门启用 RPC（admin）：deleted 为终态不可启用；成功写后写 audit_log（enable，diff 含 before/after）；'
  '幂等分支不记审计';

-- ---------------------------------------------------------------------------
-- 4. app.delete_department（org/007 重定义版 + 审计）
-- ---------------------------------------------------------------------------
create or replace function app.delete_department(p_id uuid)
returns public.departments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row      public.departments;
  v_before   public.departments;
  v_children bigint;
  v_members  bigint;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.departments
  where id = p_id;

  if not found then
    raise exception '部门不存在：%', p_id using errcode = 'P0002';
  end if;

  if v_row.status = 'deleted' then
    raise exception '部门已删除' using errcode = '22023';
  end if;

  -- 只允许删空部门：无未删除子部门
  select count(*) into v_children
  from public.departments
  where parent_id = p_id
    and status <> 'deleted';

  if v_children > 0 then
    raise exception '该部门下仍有 % 个子部门，无法删除', v_children using errcode = '22023';
  end if;

  -- 无在职人员（org/007：department_id 精确匹配为主，NULL 行文本兜底）
  select count(*) into v_members
  from public.profiles
  where status = 'active'
    and (
      department_id = p_id
      or (department_id is null and department = v_row.name)
    );

  if v_members > 0 then
    raise exception '该部门下仍有 % 名在职人员，无法删除', v_members using errcode = '22023';
  end if;

  v_before := v_row;

  update public.departments
     set status     = 'deleted',
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  perform app.audit_log(
    'org', 'delete', 'department', v_row.id::text,
    jsonb_build_object('before', to_jsonb(v_before), 'after', to_jsonb(v_row))
  );

  return v_row;
end;
$$;

comment on function app.delete_department(uuid) is
  '部门逻辑删除 RPC（admin）：仅允许删空部门（无子部门、无在职人员），按 department_id 统计'
  '（NULL 行文本兜底）；成功写后写 audit_log（delete，diff 含 before/after）';

-- ---------------------------------------------------------------------------
-- 5. app.upsert_position：成功写后补审计（create/update）
-- ---------------------------------------------------------------------------
create or replace function app.upsert_position(
  p_id            uuid    default null,
  p_name          text    default null,
  p_code          text    default null,
  p_department_id uuid    default null,
  p_headcount     integer default null,
  p_description   text    default null,
  p_status        text    default null
)
returns public.positions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row    public.positions;
  v_before public.positions;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_name is null or btrim(p_name) = '' then
    raise exception '岗位名称不能为空' using errcode = '22023';
  end if;

  if p_code is null or btrim(p_code) = '' then
    raise exception '岗位编码不能为空' using errcode = '22023';
  end if;

  if p_headcount is not null and p_headcount < 0 then
    raise exception '编制数不能为负数' using errcode = '22023';
  end if;

  if p_status is not null and p_status not in ('active', 'disabled') then
    raise exception '岗位状态不合法：%', p_status using errcode = '22023';
  end if;

  if p_department_id is not null
     and not exists (
       select 1
       from public.departments
       where id = p_department_id
         and status <> 'deleted'
     ) then
    raise exception '所属部门不存在或已删除：%', p_department_id using errcode = 'P0002';
  end if;

  -- 新建（p_id 为 null）
  if p_id is null then
    insert into public.positions
      (name, code, department_id, headcount, description, status, created_by, updated_by)
    values
      (btrim(p_name), btrim(p_code), p_department_id, coalesce(p_headcount, 0),
       nullif(btrim(coalesce(p_description, '')), ''), coalesce(p_status, 'active'),
       (select auth.uid()), (select auth.uid()))
    returning * into v_row;

    perform app.audit_log(
      'org', 'create', 'position', v_row.id::text,
      jsonb_build_object('before', null, 'after', to_jsonb(v_row))
    );

    return v_row;
  end if;

  -- 更新（全量写入）
  select * into v_before
  from public.positions
  where id = p_id;

  if not found then
    raise exception '岗位不存在：%', p_id using errcode = 'P0002';
  end if;

  update public.positions
     set name          = btrim(p_name),
         code          = btrim(p_code),
         department_id = p_department_id,
         headcount     = coalesce(p_headcount, 0),
         description   = nullif(btrim(coalesce(p_description, '')), ''),
         status        = coalesce(p_status, 'active'),
         updated_by    = (select auth.uid())
   where id = p_id
  returning * into v_row;

  perform app.audit_log(
    'org', 'update', 'position', v_row.id::text,
    jsonb_build_object('before', to_jsonb(v_before), 'after', to_jsonb(v_row))
  );

  return v_row;
exception
  when unique_violation then
    -- positions 仅 code 一个业务唯一约束（id 为 gen_random_uuid），可直接归因
    raise exception '岗位编码已存在：%', btrim(p_code) using errcode = '23505';
end;
$$;

comment on function app.upsert_position(uuid, text, text, uuid, integer, text, text) is
  '岗位新建/编辑 RPC（admin）：id 为 null 新建；code 唯一冲突转 23505 中文提示；不拦截超编；'
  '成功写后写 audit_log（create/update，diff 含 before/after）';

-- ---------------------------------------------------------------------------
-- 6. app.disable_position（原行为 + 审计）
-- ---------------------------------------------------------------------------
create or replace function app.disable_position(p_id uuid)
returns public.positions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row    public.positions;
  v_before public.positions;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.positions
  where id = p_id;

  if not found then
    raise exception '岗位不存在：%', p_id using errcode = 'P0002';
  end if;

  if v_row.status = 'disabled' then
    return v_row; -- 幂等（未发生写入，不记审计）
  end if;

  -- 明确允许停用被引用岗位：存量引用保留展示，仅新编辑下拉过滤（RLS 只读 active）
  v_before := v_row;

  update public.positions
     set status     = 'disabled',
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  perform app.audit_log(
    'org', 'disable', 'position', v_row.id::text,
    jsonb_build_object('before', to_jsonb(v_before), 'after', to_jsonb(v_row))
  );

  return v_row;
end;
$$;

comment on function app.disable_position(uuid) is
  '岗位停用 RPC（admin）：被 profiles 引用时同样允许（存量保留展示，仅新编辑下拉过滤）；'
  '成功写后写 audit_log（disable，diff 含 before/after）；幂等分支不记审计';

-- ---------------------------------------------------------------------------
-- 7. app.enable_position（原行为 + 审计）
-- ---------------------------------------------------------------------------
create or replace function app.enable_position(p_id uuid)
returns public.positions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row    public.positions;
  v_before public.positions;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.positions
  where id = p_id;

  if not found then
    raise exception '岗位不存在：%', p_id using errcode = 'P0002';
  end if;

  if v_row.status = 'active' then
    return v_row; -- 幂等（未发生写入，不记审计）
  end if;

  v_before := v_row;

  update public.positions
     set status     = 'active',
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  perform app.audit_log(
    'org', 'enable', 'position', v_row.id::text,
    jsonb_build_object('before', to_jsonb(v_before), 'after', to_jsonb(v_row))
  );

  return v_row;
end;
$$;

comment on function app.enable_position(uuid) is
  '岗位启用 RPC（admin）：幂等；成功写后写 audit_log（enable，diff 含 before/after）；'
  '幂等分支不记审计';

-- ---------------------------------------------------------------------------
-- 8. app.delete_position（物理删除 + 审计，after=null）
-- ---------------------------------------------------------------------------
create or replace function app.delete_position(p_id uuid)
returns public.positions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row   public.positions;
  v_count bigint;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.positions
  where id = p_id;

  if not found then
    raise exception '岗位不存在：%', p_id using errcode = 'P0002';
  end if;

  -- 删除才拒绝引用：物理删除会丢存量展示锚点（停用则允许）
  v_count := app.position_headcount(p_id);

  if v_count > 0 then
    raise exception '该岗位仍有 % 名在职人员（按所属部门统计），无法删除', v_count
      using errcode = '22023';
  end if;

  delete from public.positions where id = p_id;

  perform app.audit_log(
    'org', 'delete', 'position', p_id::text,
    jsonb_build_object('before', to_jsonb(v_row), 'after', null)
  );

  return v_row;
end;
$$;

comment on function app.delete_position(uuid) is
  '岗位删除 RPC（admin，物理删除）：有在职引用（按 position_id 统计）时拒绝；'
  '成功写后写 audit_log（delete，diff 含 before，after=null）';

-- ---------------------------------------------------------------------------
-- 9. public.admin_update_profile（org/014 现状 + 审计）
--    diff 仅收口实际变更字段（full_name/department/department_id/position_id/status）
-- ---------------------------------------------------------------------------
create or replace function public.admin_update_profile(
  p_user_id       uuid,
  p_full_name     text default null,
  p_department    text default null,
  p_role          public.user_role default null,
  p_status        public.profile_status default null,
  p_department_id uuid default null,
  p_position_id   uuid default null
)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row         public.profiles;
  v_old         public.profiles;
  v_before_diff jsonb := '{}'::jsonb;
  v_after_diff  jsonb := '{}'::jsonb;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_user_id = (select auth.uid()) then
    if p_role is not null and p_role is distinct from 'admin' then
      raise exception '不能修改自己的管理员角色' using errcode = '22023';
    end if;
    if p_status = 'inactive' then
      raise exception '不能停用自己的账号' using errcode = '22023';
    end if;
  end if;

  -- 新参数：仅显式传参时校验（缺省 null = 不改）
  if p_department_id is not null
     and not exists (
       select 1
       from public.departments
       where id = p_department_id
         and status <> 'deleted'
     ) then
    raise exception '部门不存在或已删除：%', p_department_id using errcode = 'P0002';
  end if;

  if p_position_id is not null
     and not exists (
       select 1
       from public.positions
       where id = p_position_id
     ) then
    raise exception '岗位不存在：%', p_position_id using errcode = 'P0002';
  end if;

  -- 审计 diff 的 before 基准（不存在时下行更新不命中，随后统一抛 P0002）
  select * into v_old
  from public.profiles
  where id = p_user_id;

  -- 传 department_id 时不直写文本（触发器回写，保证 id 优先）；未传时保持文本路径
  update public.profiles
     set full_name     = coalesce(p_full_name, full_name),
         department    = case
                           when p_department_id is not null then department
                           else coalesce(p_department, department)
                         end,
         department_id = coalesce(p_department_id, department_id),
         position_id   = coalesce(p_position_id, position_id),
         status        = coalesce(p_status, status),
         updated_by    = (select auth.uid())
   where id = p_user_id
  returning * into v_row;

  if v_row.id is null then
    raise exception '用户不存在：%', p_user_id using errcode = 'P0002';
  end if;

  -- 审计摘要：仅记录实际变更字段的 before/after
  if v_old.full_name is distinct from v_row.full_name then
    v_before_diff := v_before_diff || jsonb_build_object('full_name', v_old.full_name);
    v_after_diff  := v_after_diff  || jsonb_build_object('full_name', v_row.full_name);
  end if;
  if v_old.department is distinct from v_row.department then
    v_before_diff := v_before_diff || jsonb_build_object('department', v_old.department);
    v_after_diff  := v_after_diff  || jsonb_build_object('department', v_row.department);
  end if;
  if v_old.department_id is distinct from v_row.department_id then
    v_before_diff := v_before_diff || jsonb_build_object('department_id', v_old.department_id);
    v_after_diff  := v_after_diff  || jsonb_build_object('department_id', v_row.department_id);
  end if;
  if v_old.position_id is distinct from v_row.position_id then
    v_before_diff := v_before_diff || jsonb_build_object('position_id', v_old.position_id);
    v_after_diff  := v_after_diff  || jsonb_build_object('position_id', v_row.position_id);
  end if;
  if v_old.status is distinct from v_row.status then
    v_before_diff := v_before_diff || jsonb_build_object('status', v_old.status);
    v_after_diff  := v_after_diff  || jsonb_build_object('status', v_row.status);
  end if;

  perform app.audit_log(
    'org', 'update', 'profile', p_user_id::text,
    jsonb_build_object('before', v_before_diff, 'after', v_after_diff)
  );

  -- org/014：用户变更事件（软依赖 integration/004，同 approval 引擎先例）
  if to_regprocedure('app.emit_event(text,jsonb)') is not null then
    perform app.emit_event(
      'org.user_changed',
      jsonb_build_object(
        'user_id', p_user_id,
        'action', 'profile_updated',
        'full_name', v_row.full_name,
        'department_id', v_row.department_id,
        'position_id', v_row.position_id,
        'status', v_row.status
      )
    );
  elsif to_regprocedure('public.emit_event(text,jsonb)') is not null then
    perform public.emit_event(
      'org.user_changed',
      jsonb_build_object(
        'user_id', p_user_id,
        'action', 'profile_updated',
        'full_name', v_row.full_name,
        'department_id', v_row.department_id,
        'position_id', v_row.position_id,
        'status', v_row.status
      )
    );
  end if;

  -- 兼容期：p_role 仍在签名中（前端旧版本调用不中断），内部转调 assign_role；
  -- 本函数角色路径已废弃，下次签名变更（删 p_role）独立迁移。
  if p_role is not null then
    raise warning 'admin_update_profile(p_role) 已废弃：请改用 assign_role 分配角色';
    v_row := app.assign_role(p_user_id, p_role::text);
  end if;

  return v_row;
end;
$$;

comment on function public.admin_update_profile(uuid, text, text, public.user_role, public.profile_status, uuid, uuid) is
  '管理员更新用户档案（姓名/部门/状态/部门 id/岗位 id）：p_department_id 优先于 p_department 文本'
  '（触发器回写；未传 id 时文本路径按 org/007 规则解析）；成功写后写 audit_log（update，'
  'diff 仅含实际变更字段 before/after）并 emit_event(''org.user_changed'', {user_id, action:profile_updated, ...})'
  '（软依赖 integration/004）；p_role 兼容期转调 app.assign_role 并 warning';

-- ---------------------------------------------------------------------------
-- 10. 授权：create or replace 保留既有 ACL，此处仅重申审计函数不经 API 暴露
--     （INDEX 规则 10；audit_log 由 SECURITY DEFINER 属主内部调用）
-- ---------------------------------------------------------------------------
revoke all on function app.audit_log(text, text, text, text, jsonb)
  from public, anon, authenticated;
