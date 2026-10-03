-- 用户档案：记录最近一次修改人（updated_by）
-- 背景：用户管理的角色/状态变更直接影响他人权限，
--       「可追溯优先于便利」原则要求界面能回答「谁改的」。
-- 做法：profiles 增加 updated_by 列（弱关联 auth.users，不加强外键，
--       避免用户删除时级联抹掉审计痕迹），由 admin_update_profile 自动填充。

alter table public.profiles
  add column if not exists updated_by uuid;

comment on column public.profiles.updated_by is '最近一次修改人的用户 ID（admin_update_profile 自动填充）';

-- 管理员更新 RPC 顺带记录操作人
create or replace function public.admin_update_profile(
  p_user_id    uuid,
  p_full_name  text default null,
  p_department text default null,
  p_role       public.user_role default null,
  p_status     public.profile_status default null
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

  update public.profiles
     set full_name  = coalesce(p_full_name, full_name),
         department = coalesce(p_department, department),
         role       = coalesce(p_role, role),
         status     = coalesce(p_status, status),
         updated_by = (select auth.uid())
   where id = p_user_id
  returning * into v_row;

  if v_row.id is null then
    raise exception '用户不存在：%', p_user_id using errcode = 'P0002';
  end if;

  return v_row;
end;
$$;

-- 授权与既有迁移保持一致（authenticated 可执行）
revoke all on function
  public.admin_update_profile(uuid, text, text, public.user_role, public.profile_status)
  from public, anon;
grant execute on function
  public.admin_update_profile(uuid, text, text, public.user_role, public.profile_status)
  to authenticated;
