-- 用户档案 + 角色枚举 + RLS 基线
-- 权限体系第一块：profiles 与角色，以及供 RLS 使用的辅助函数。

-- ---------------------------------------------------------------------------
-- 1. 内部 schema（不暴露给 Data API，用于放辅助函数）
-- ---------------------------------------------------------------------------
create schema if not exists app;
comment on schema app is 'PLM 内部辅助函数 schema，不通过 Data API 暴露';

-- ---------------------------------------------------------------------------
-- 2. 枚举
-- ---------------------------------------------------------------------------
create type public.user_role as enum (
  'admin', 'engineer', 'planner', 'buyer', 'quality', 'supplier', 'customer'
);
comment on type public.user_role is '系统角色：内部（admin/engineer/planner/buyer/quality）与外部（supplier/customer）';

create type public.profile_status as enum ('active', 'inactive');

-- ---------------------------------------------------------------------------
-- 3. 用户档案表（与 auth.users 1:1）
-- ---------------------------------------------------------------------------
create table public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  full_name  text,
  department text,
  role       public.user_role not null default 'engineer',
  status     public.profile_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is '用户档案（与 auth.users 1:1）';
comment on column public.profiles.role is '角色，决定数据访问权限（RLS）';

-- ---------------------------------------------------------------------------
-- 4. updated_at 维护
-- ---------------------------------------------------------------------------
create function app.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_set_updated_at
before update on public.profiles
for each row
execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- 5. 新用户自动建档（auth.users insert → profiles）
--    角色优先取 raw_app_meta_data.role（仅服务端可写），否则默认 engineer
-- ---------------------------------------------------------------------------
create function app.handle_new_user()
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

  insert into public.profiles (id, full_name, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
    v_role
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row
execute function app.handle_new_user();

-- ---------------------------------------------------------------------------
-- 6. RLS 辅助函数
-- ---------------------------------------------------------------------------
create function app.current_role()
returns public.user_role
language sql
stable
security definer
set search_path = ''
as $$
  select p.role
  from public.profiles p
  where p.id = (select auth.uid())
    and p.status = 'active'
$$;

comment on function app.current_role() is '当前登录用户角色；security definer 避免 profiles RLS 递归';

create function app.is_internal()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select p.role in ('admin', 'engineer', 'planner', 'buyer', 'quality')
      from public.profiles p
      where p.id = (select auth.uid())
        and p.status = 'active'
    ),
    false
  )
$$;

-- ---------------------------------------------------------------------------
-- 7. 权限：先收口 schema 与函数，再给 authenticated 最小必需权限
-- ---------------------------------------------------------------------------
revoke all on schema app from public, anon, authenticated;
grant usage on schema app to authenticated;

revoke all on function app.current_role() from public, anon;
grant execute on function app.current_role() to authenticated;

revoke all on function app.is_internal() from public, anon;
grant execute on function app.is_internal() to authenticated;

revoke all on function app.set_updated_at() from public, anon;
grant execute on function app.set_updated_at() to authenticated;

revoke all on function app.handle_new_user() from public, anon, authenticated;
grant execute on function app.handle_new_user() to supabase_auth_admin;

-- profiles：读给 authenticated（RLS 再按行过滤）；更新做列级限制
grant select on public.profiles to authenticated, service_role;
grant update (full_name, department) on public.profiles to authenticated;
grant all on public.profiles to service_role;

-- ---------------------------------------------------------------------------
-- 8. RLS
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;

-- 本人可读
create policy profiles_select_self
on public.profiles
for select
to authenticated
using ((select auth.uid()) = id);

-- 内部员工可读全部（通讯录 / 审批人选择）
create policy profiles_select_internal
on public.profiles
for select
to authenticated
using (app.is_internal());

-- 本人可改姓名/部门（role/status 无列权限，无法自助提权）
create policy profiles_update_self
on public.profiles
for update
to authenticated
using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

-- ---------------------------------------------------------------------------
-- 9. 回填已有 auth 用户
-- ---------------------------------------------------------------------------
insert into public.profiles (id, full_name)
select u.id,
       coalesce(u.raw_user_meta_data ->> 'full_name', split_part(u.email, '@', 1))
from auth.users u
on conflict (id) do nothing;
