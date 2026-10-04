-- 组织管理 · 部门/岗位清空语义打通（org 数据层批次 3 · 修复项 1）
-- 背景：admin_update_profile 的 p_department_id/p_position_id 缺省 null 表示「不改」，
--       前端下拉选「未指定」时无法把存量归属清空（用户管理页回显与保存不一致）。
--
-- 语义：
--   1. 追加 p_clear_department/p_clear_position（boolean，缺省 false）；true 时显式
--      置 null：department_id 置空后由 org/007 双写触发器 null→null 回写文本；
--      同语句内亦显式置 department = null，兜底历史「id 为 NULL、文本非 NULL」行；
--   2. 清空参数与对应指定参数互斥（clear=true 时不允许再传 id/文本），冲突报 22023；
--   3. p_clear_* 缺省 false 时逐字保持 org/009 + 20261005180000 现语义（id 优先、
--      文本路径兼容、审计、emit_event、p_role 兼容全部原样保留）；
--   4. 必须 drop 旧签名后再建：Postgres 不支持 create or replace 变更参数列表，
--      且迁移执行期禁止同名重载（PostgREST 具名参数解析会歧义，同 org/009 先例）。
--
-- 依赖：20261004140000（双写触发器 null→null 回写）、
--       20261005180000（admin_update_profile 最新实现：audit_log + emit_event）。

-- ---------------------------------------------------------------------------
-- 1. 重建函数（签名变更：追加 p_clear_department/p_clear_position）
-- ---------------------------------------------------------------------------
drop function public.admin_update_profile(
  uuid, text, text, public.user_role, public.profile_status, uuid, uuid
);

create function public.admin_update_profile(
  p_user_id          uuid,
  p_full_name        text default null,
  p_department       text default null,
  p_role             public.user_role default null,
  p_status           public.profile_status default null,
  p_department_id    uuid default null,
  p_position_id      uuid default null,
  p_clear_department boolean default false,
  p_clear_position   boolean default false
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

  -- 清空与指定互斥：显式清空时不得再传对应归属（含文本路径），避免语义歧义
  if p_clear_department
     and (p_department_id is not null or p_department is not null) then
    raise exception '不能同时清空并指定部门' using errcode = '22023';
  end if;

  if p_clear_position and p_position_id is not null then
    raise exception '不能同时清空并指定岗位' using errcode = '22023';
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

  -- 传 department_id 时不直写文本（触发器回写，保证 id 优先）；未传时保持文本路径；
  -- clear=true 时显式置 null（触发器 null→null 回写，历史文本行亦兜底清空）
  update public.profiles
     set full_name     = coalesce(p_full_name, full_name),
         department    = case
                           when p_clear_department then null
                           when p_department_id is not null then department
                           else coalesce(p_department, department)
                         end,
         department_id = case
                           when p_clear_department then null
                           else coalesce(p_department_id, department_id)
                         end,
         position_id   = case
                           when p_clear_position then null
                           else coalesce(p_position_id, position_id)
                         end,
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

comment on function public.admin_update_profile(uuid, text, text, public.user_role, public.profile_status, uuid, uuid, boolean, boolean) is
  '管理员更新用户档案（姓名/部门/状态/部门 id/岗位 id/清空部门/清空岗位）：p_department_id 优先于 '
  'p_department 文本（触发器回写；未传 id 时文本路径按 org/007 规则解析）；p_clear_department/'
  'p_clear_position 为 true 时显式置 null（文本由双写触发器 null→null 回写）；clear 与对应指定参数互斥 '
  '（22023）；成功写后写 audit_log（update，diff 仅含实际变更字段 before/after）并 emit_event('
  '''org.user_changed'', {user_id, action:profile_updated, ...})（软依赖 integration/004）；'
  'p_role 兼容期转调 app.assign_role 并 warning';

-- ---------------------------------------------------------------------------
-- 2. 授权：最小化（仅 authenticated；旧签名已 drop，按新签名重申）
-- ---------------------------------------------------------------------------
revoke all on function
  public.admin_update_profile(
    uuid, text, text, public.user_role, public.profile_status, uuid, uuid,
    boolean, boolean
  )
  from public, anon;
grant execute on function
  public.admin_update_profile(
    uuid, text, text, public.user_role, public.profile_status, uuid, uuid,
    boolean, boolean
  )
  to authenticated;
