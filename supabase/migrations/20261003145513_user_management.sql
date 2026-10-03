-- 用户管理：profiles.email 冗余列 + 管理员更新 RPC
-- 说明：authenticated 对 profiles 没有整表 UPDATE 权限（仅两列），
--       管理员的角色/状态变更统一走受控 RPC。

-- ---------------------------------------------------------------------------
-- 1. email 列（来源 auth.users，避免前端访问 auth schema）
-- ---------------------------------------------------------------------------
alter table public.profiles add column email text;

update public.profiles p
   set email = u.email
  from auth.users u
 where u.id = p.id
   and p.email is distinct from u.email;

create index profiles_email_lower_idx on public.profiles (lower(email));

-- ---------------------------------------------------------------------------
-- 2. 注册触发器补充 email（CREATE OR REPLACE 保留原有授权）
-- ---------------------------------------------------------------------------
create or replace function app.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.user_role := 'engineer';
begin
  if new.raw_app_meta_data ? 'role' then
    begin
      v_role := (new.raw_app_meta_data ->> 'role')::public.user_role;
    exception when others then
      v_role := 'engineer';
    end;
  end if;

  insert into public.profiles (id, email, full_name, role)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
    v_role
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. 管理员更新用户档案（角色 / 状态 / 姓名 / 部门）
-- ---------------------------------------------------------------------------
create function public.admin_update_profile(
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
         status     = coalesce(p_status, status)
   where id = p_user_id
  returning * into v_row;

  if v_row.id is null then
    raise exception '用户不存在：%', p_user_id using errcode = 'P0002';
  end if;

  return v_row;
end;
$$;

revoke all on function
  public.admin_update_profile(uuid, text, text, public.user_role, public.profile_status)
  from public, anon;
grant execute on function
  public.admin_update_profile(uuid, text, text, public.user_role, public.profile_status)
  to authenticated;
