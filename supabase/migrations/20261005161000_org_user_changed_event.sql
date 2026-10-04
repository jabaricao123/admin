-- 组织管理 · 用户变更事件发射点（org/014）
-- 工单：org/014（org.user_changed 发射点：profiles 写路径调 integration emit_event）
--
-- 契约：docs/modules/integration/webhooks.md「首期发射点契约：approval（3）、org
--       （org.user_changed）、sync（run_finished）」、docs/modules/INDEX.md 规则 10
--       （emit_event 不 GRANT authenticated，各模块经自身 SECURITY DEFINER RPC 调用）。
--
-- 语义：
--   * 发射点位于 org 用户写路径的唯一两个入口：public.admin_update_profile
--     （姓名/部门/状态；p_role 兼容路径转调 assign_role 时两条都会发）与
--     app.assign_role（角色单通道写入，INDEX 规则 7）；
--   * 成功写后发射（校验/更新失败不产生事件），与写操作同一事务：写与事件同成同败；
--   * payload：{user_id, action: profile_updated|role_assigned, ...}（action 与后续字段
--     按实际变更维度附带）；user_id 为断言锚点；
--   * 软依赖 integration/004（同 approval 引擎/sync 执行先例）：to_regprocedure 判存，
--     未合入自动跳过，不阻塞 org 迁移链。
--
-- 依赖：20261004150000（admin_update_profile 7 参现状）、20261004100000（assign_role
--       现状）、integration/004（app.emit_event，软依赖）。
-- 授权不变：create or replace 保留原 REVOKE/GRANT；emit_event 依旧不授予 API 角色。

-- ---------------------------------------------------------------------------
-- 1. public.admin_update_profile：原逻辑不变；成功写后追加 org.user_changed
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
  v_row public.profiles;
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
  '（触发器回写；未传 id 时文本路径按 org/007 规则解析）；p_role 兼容期转调 app.assign_role 并 warning；'
  '成功写后 emit_event(''org.user_changed'', {user_id, action:profile_updated, ...})（软依赖 integration/004）';

-- ---------------------------------------------------------------------------
-- 2. app.assign_role：原逻辑不变；成功写后追加 org.user_changed
-- ---------------------------------------------------------------------------
create or replace function app.assign_role(
  p_target_user uuid,
  p_new_role    text
)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role_id  uuid;
  v_target   public.profiles;
  v_old_role public.user_role;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_new_role is null or pg_catalog.btrim(p_new_role) = '' then
    raise exception '角色标识不能为空' using errcode = '22023';
  end if;

  -- 自保护：沿用 admin_update_profile 语义，不能修改自己的管理员角色
  if p_target_user = (select auth.uid()) and p_new_role is distinct from 'admin' then
    raise exception '不能修改自己的管理员角色' using errcode = '22023';
  end if;

  -- 目标角色必须存在
  select r.id into v_role_id
  from public.roles r
  where r.code = p_new_role;

  if v_role_id is null then
    raise exception '角色不存在：%', p_new_role using errcode = 'P0002';
  end if;

  -- 兼容期：role 枚举列无法表达自定义角色，暂不可分配（删枚举后放开）
  if not exists (
    select 1
    from pg_catalog.unnest(pg_catalog.enum_range(null::public.user_role)) e
    where e::text = p_new_role
  ) then
    raise exception '角色不可分配（兼容期仅支持内置角色）：%', p_new_role using errcode = '22023';
  end if;

  -- 目标角色必须是 active 行
  if not exists (
    select 1 from public.roles r where r.id = v_role_id and r.status = 'active'
  ) then
    raise exception '角色已停用，无法分配：%', p_new_role using errcode = '22023';
  end if;

  select * into v_target
  from public.profiles
  where id = p_target_user
  for update;

  if not found then
    raise exception '用户不存在：%', p_target_user using errcode = 'P0002';
  end if;

  v_old_role := v_target.role;

  update public.profiles
     set role_id    = v_role_id,
         updated_by = (select auth.uid())
   where id = p_target_user
  returning * into v_target;

  perform app.audit_log(
    'access', 'assign', 'profile_role', p_target_user::text,
    jsonb_build_object(
      'before', v_old_role,
      'after', v_target.role,
      'role_id', v_role_id
    )
  );

  -- org/014：用户变更事件（软依赖 integration/004，同 approval 引擎先例）
  if to_regprocedure('app.emit_event(text,jsonb)') is not null then
    perform app.emit_event(
      'org.user_changed',
      jsonb_build_object(
        'user_id', p_target_user,
        'action', 'role_assigned',
        'role', p_new_role,
        'role_id', v_role_id
      )
    );
  elsif to_regprocedure('public.emit_event(text,jsonb)') is not null then
    perform public.emit_event(
      'org.user_changed',
      jsonb_build_object(
        'user_id', p_target_user,
        'action', 'role_assigned',
        'role', p_new_role,
        'role_id', v_role_id
      )
    );
  end if;

  return v_target;
end;
$$;

comment on function app.assign_role(uuid, text) is
  '角色分配单通道（admin）：写 role_id 并由触发器同步枚举；校验角色存在/active/兼容期内置；'
  '自保护；写审计摘要；成功写后 emit_event(''org.user_changed'', {user_id, action:role_assigned, ...})'
  '（软依赖 integration/004）';

-- ---------------------------------------------------------------------------
-- 3. 授权：create or replace 保留既有 ACL，此处重申保持迁移自洽
-- ---------------------------------------------------------------------------
revoke all on function
  public.admin_update_profile(uuid, text, text, public.user_role, public.profile_status, uuid, uuid)
  from public, anon;
grant execute on function
  public.admin_update_profile(uuid, text, text, public.user_role, public.profile_status, uuid, uuid)
  to authenticated;

revoke all on function app.assign_role(uuid, text) from public, anon;
grant execute on function app.assign_role(uuid, text) to authenticated;
