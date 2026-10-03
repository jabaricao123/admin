-- 组织管理 · 用户管理 RPC 接入部门/岗位外键（org/009）
-- 工单：org/009（用户管理接入部门/岗位下拉）
--
-- 语义（对齐 org/007 双写过渡与 access/003 收窄先例）：
--   1. admin_update_profile 追加 p_department_id/p_position_id（可空，缺省保持现语义）；
--   2. 显式传 p_department_id 时以 id 为准直写 id 列，department 文本由 org/007
--      双写触发器回写（同一语句内不再写文本）；未传 id 时文本路径保持兼容，
--      由触发器按 active 精确匹配解析 department_id；
--   3. position_id 无文本源，仅在显式传参时写；两新参数均只校验存在性/删除态，
--      不做停用拦截（存量停用部门/岗位的档案仍可保存其他字段）；
--   4. 新参数追加在 p_status 之后，保留 5 参位置调用兼容（access/003 废弃的 p_role
--      仍在签名中并保留 warning + 转调行为）；
--   5. 必须 drop 旧签名后再建：Postgres 不支持 create or replace 变更参数列表，
--      且禁止同名重载（PostgREST 具名参数解析会歧义）。
--
-- 依赖：20261004100000（admin_update_profile 收窄现状）、
--       20261004140000（department_id/position_id 列与双写触发器）。

-- ---------------------------------------------------------------------------
-- 1. 重建函数（签名变更：追加 p_department_id/p_position_id）
-- ---------------------------------------------------------------------------
drop function public.admin_update_profile(
  uuid, text, text, public.user_role, public.profile_status
);

create function public.admin_update_profile(
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
  '（触发器回写；未传 id 时文本路径按 org/007 规则解析）；p_role 兼容期转调 app.assign_role 并 warning';

-- ---------------------------------------------------------------------------
-- 2. 授权：最小化（仅 authenticated；旧签名已 drop，按新签名重申）
-- ---------------------------------------------------------------------------
revoke all on function
  public.admin_update_profile(uuid, text, text, public.user_role, public.profile_status, uuid, uuid)
  from public, anon;
grant execute on function
  public.admin_update_profile(uuid, text, text, public.user_role, public.profile_status, uuid, uuid)
  to authenticated;
