-- 权限管理 · roles 表 + 7 内置角色 seed（access/001）+ RLS / 管理 RPC（access/002）
-- 工单：access/001（roles 表 migration + 7 内置角色 seed）+ access/002（RLS + pgTAP）
--
-- 约定（对齐 docs/modules/INDEX.md）：
--   1. 敏感表二分：表级对任何 API 角色都不授予 INSERT/UPDATE/DELETE（含 admin），
--      写路径全部经 SECURITY DEFINER RPC，函数内部校验当前用户为 admin；
--   2. 业务实现放 app schema（沿用现有 app schema 约定），public 同名函数是
--      Data API 薄包装层（PostgREST 仅暴露 public schema）；
--   3. 所有 SECURITY DEFINER 函数 set search_path = '' + 全限定名引用；
--   4. 内置角色（对齐 public.user_role 枚举 7 值）由触发器兜底：
--      禁止 DELETE、禁止修改 code、禁止翻转 is_builtin；
--   5. 用户数统计：现状 profiles.role 为枚举，按 code 文本映射统计（全量，含
--      个人状态非 active 的行）；access/003 引入 role_id 后改为按外键统计；
--   6. 状态只有 active/disabled：disable_role/enable_role 负责状态切换；
--      delete_role 为物理删除（有用户引用或内置角色一律拒绝），删除留审计。

-- ---------------------------------------------------------------------------
-- 1. roles 表
-- ---------------------------------------------------------------------------
create table public.roles (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  code        text not null unique,
  is_builtin  boolean not null default false,
  description text,
  status      text not null default 'active'
              constraint roles_status_check
              check (status in ('active', 'disabled')),
  created_by  uuid,
  updated_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.roles is '角色定义（内置角色对齐 user_role 枚举；写路径仅经管理 RPC）';
comment on column public.roles.name is '角色名称（界面展示）';
comment on column public.roles.code is '角色标识（唯一；内置角色不可修改）';
comment on column public.roles.is_builtin is '内置标记：true 时 DB 触发器禁止删除/改 code';
comment on column public.roles.description is '角色说明（内置角色允许修改的唯一字段）';
comment on column public.roles.status is '状态：active/disabled（写经 disable_role/enable_role）';
comment on column public.roles.created_by is '创建人（弱关联 auth.users，不设外键以保留追溯）';
comment on column public.roles.updated_by is '最近修改人（弱关联 auth.users，不设外键以保留追溯）';

create trigger roles_set_updated_at
before update on public.roles
for each row
execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- 2. 7 个内置角色 seed（对齐 user_role 枚举：admin/engineer/planner/buyer/
--    quality/supplier/customer）
-- ---------------------------------------------------------------------------
insert into public.roles (name, code, is_builtin, description)
values
  ('系统管理员', 'admin',    true, '内部：系统管理员，拥有全部权限'),
  ('工程师',    'engineer', true, '内部：工程师'),
  ('计划员',    'planner',  true, '内部：计划员'),
  ('采购员',    'buyer',    true, '内部：采购员'),
  ('质检员',    'quality',  true, '内部：质检员'),
  ('供应商',    'supplier', true, '外部：供应商，仅可读本人档案，不可分配内部权限'),
  ('客户',      'customer', true, '外部：客户，仅可读本人档案，不可分配内部权限')
on conflict (code) do nothing;

-- ---------------------------------------------------------------------------
-- 3. 内置保护触发器（DB 兜底，RPC 与超级用户均无法绕过）
-- ---------------------------------------------------------------------------
create function app.protect_builtin_role()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if old.is_builtin then
      raise exception '内置角色不可删除：%', old.code using errcode = '22023';
    end if;
    return old;
  end if;

  -- UPDATE：内置标记不可翻转（防自定义角色伪装内置，或内置角色改标记绕过保护）
  if new.is_builtin is distinct from old.is_builtin then
    raise exception '角色内置标记不可修改：%', old.code using errcode = '22023';
  end if;

  if old.is_builtin and new.code is distinct from old.code then
    raise exception '内置角色不可修改标识：%', old.code using errcode = '22023';
  end if;

  return new;
end;
$$;

comment on function app.protect_builtin_role() is
  '内置角色 DB 兜底保护：禁止 DELETE、禁止改 code、禁止翻转 is_builtin';

create trigger roles_protect_builtin
before update or delete on public.roles
for each row
execute function app.protect_builtin_role();

-- ---------------------------------------------------------------------------
-- 4. roles_v 公开视图（选人/分配 UI 名录；行过滤随底层表 RLS）
-- ---------------------------------------------------------------------------
create view public.roles_v
with (security_invoker = true)
as
select
  id, name, code, is_builtin, description, status,
  created_by, updated_by, created_at, updated_at
from public.roles;

comment on view public.roles_v is
  '角色公开视图：登录用户可读角色名录（选人/分配 UI）；普通用户仅见 active，admin 全量';

-- ---------------------------------------------------------------------------
-- 5. RPC：新建/编辑角色（admin）
--    内置角色仅可修改说明；自定义角色可改 name/code/description/status
-- ---------------------------------------------------------------------------
create function app.upsert_role(
  p_id          uuid,
  p_name        text,
  p_code        text,
  p_description text default null,
  p_status      text default 'active'
)
returns public.roles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row    public.roles;
  v_before jsonb;
  v_status text;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  -- 新建（p_id 为 null）
  if p_id is null then
    if p_name is null or btrim(p_name) = '' then
      raise exception '角色名称不能为空' using errcode = '22023';
    end if;
    if p_code is null or btrim(p_code) = '' then
      raise exception '角色标识不能为空' using errcode = '22023';
    end if;

    v_status := coalesce(p_status, 'active');
    if v_status not in ('active', 'disabled') then
      raise exception '非法状态：%', v_status using errcode = '22023';
    end if;

    begin
      insert into public.roles
        (name, code, is_builtin, description, status, created_by, updated_by)
      values
        (btrim(p_name), btrim(p_code), false, p_description, v_status,
         (select auth.uid()), (select auth.uid()))
      returning * into v_row;
    exception when unique_violation then
      raise exception '角色标识已存在：%', btrim(p_code) using errcode = '22023';
    end;

    perform app.audit_log(
      'access', 'create', 'role', v_row.id::text,
      jsonb_build_object(
        'code', v_row.code, 'name', v_row.name, 'status', v_row.status
      )
    );

    return v_row;
  end if;

  -- 编辑
  select * into v_row
  from public.roles
  where id = p_id
  for update;

  if not found then
    raise exception '角色不存在：%', p_id using errcode = 'P0002';
  end if;

  v_before := jsonb_build_object(
    'name', v_row.name, 'code', v_row.code, 'status', v_row.status,
    'description', v_row.description
  );

  if v_row.is_builtin then
    -- 内置角色仅可修改说明；name/code/status 需省略或传原值
    if (p_name is not null and btrim(p_name) <> v_row.name)
       or (p_code is not null and btrim(p_code) <> v_row.code)
       or (p_status is not null and p_status <> v_row.status) then
      raise exception '内置角色仅可修改说明' using errcode = '22023';
    end if;

    update public.roles
       set description = p_description,
           updated_by  = (select auth.uid())
     where id = p_id
    returning * into v_row;
  else
    if p_name is not null and btrim(p_name) = '' then
      raise exception '角色名称不能为空' using errcode = '22023';
    end if;
    if p_code is not null and btrim(p_code) = '' then
      raise exception '角色标识不能为空' using errcode = '22023';
    end if;

    v_status := coalesce(p_status, v_row.status);
    if v_status not in ('active', 'disabled') then
      raise exception '非法状态：%', v_status using errcode = '22023';
    end if;

    begin
      update public.roles
         set name        = coalesce(btrim(p_name), name),
             code        = coalesce(btrim(p_code), code),
             description = p_description,
             status      = v_status,
             updated_by  = (select auth.uid())
       where id = p_id
      returning * into v_row;
    exception when unique_violation then
      raise exception '角色标识已存在：%', btrim(p_code) using errcode = '22023';
    end;
  end if;

  perform app.audit_log(
    'access', 'update', 'role', v_row.id::text,
    jsonb_build_object(
      'before', v_before,
      'after', jsonb_build_object(
        'name', v_row.name, 'code', v_row.code, 'status', v_row.status,
        'description', v_row.description
      )
    )
  );

  return v_row;
end;
$$;

comment on function app.upsert_role(uuid, text, text, text, text) is
  '角色新建/编辑 RPC（admin）：id 为 null 新建；内置角色仅可改说明；写审计摘要';

-- ---------------------------------------------------------------------------
-- 6. RPC：停用/启用/删除（admin）
-- ---------------------------------------------------------------------------
create function app.disable_role(p_id uuid)
returns public.roles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row   public.roles;
  v_count bigint;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.roles
  where id = p_id
  for update;

  if not found then
    raise exception '角色不存在：%', p_id using errcode = 'P0002';
  end if;

  if v_row.status = 'disabled' then
    return v_row; -- 幂等
  end if;

  if v_row.code = 'admin' then
    raise exception '系统管理员角色不可停用' using errcode = '22023';
  end if;

  -- 有用户引用的角色不可停用（全量计数：引用即拒绝）
  select count(*) into v_count
  from public.profiles p
  where p.role::text = v_row.code;

  if v_count > 0 then
    raise exception '该角色下仍有 % 名用户，无法停用', v_count using errcode = '22023';
  end if;

  update public.roles
     set status     = 'disabled',
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  perform app.audit_log(
    'access', 'disable', 'role', v_row.id::text,
    jsonb_build_object('code', v_row.code, 'name', v_row.name)
  );

  return v_row;
end;
$$;

comment on function app.disable_role(uuid) is
  '角色停用 RPC（admin）：有用户引用时拒绝并提示人数；admin 角色不可停用';

create function app.enable_role(p_id uuid)
returns public.roles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.roles;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.roles
  where id = p_id
  for update;

  if not found then
    raise exception '角色不存在：%', p_id using errcode = 'P0002';
  end if;

  if v_row.status = 'active' then
    return v_row; -- 幂等
  end if;

  update public.roles
     set status     = 'active',
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  perform app.audit_log(
    'access', 'enable', 'role', v_row.id::text,
    jsonb_build_object('code', v_row.code, 'name', v_row.name)
  );

  return v_row;
end;
$$;

comment on function app.enable_role(uuid) is '角色启用 RPC（admin）：幂等';

create function app.delete_role(p_id uuid)
returns public.roles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row   public.roles;
  v_count bigint;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.roles
  where id = p_id
  for update;

  if not found then
    raise exception '角色不存在：%', p_id using errcode = 'P0002';
  end if;

  -- 先做人数诊断，再判内置（两者都拒绝，人数提示更具体）
  select count(*) into v_count
  from public.profiles p
  where p.role::text = v_row.code;

  if v_count > 0 then
    raise exception '该角色下仍有 % 名用户，无法删除', v_count using errcode = '22023';
  end if;

  if v_row.is_builtin then
    raise exception '内置角色不可删除：%', v_row.code using errcode = '22023';
  end if;

  delete from public.roles where id = p_id;

  perform app.audit_log(
    'access', 'delete', 'role', p_id::text,
    jsonb_build_object('code', v_row.code, 'name', v_row.name)
  );

  return v_row;
end;
$$;

comment on function app.delete_role(uuid) is
  '角色删除 RPC（admin）：有用户引用或内置角色一律拒绝；删除留审计';

-- ---------------------------------------------------------------------------
-- 7. public 包装层（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.upsert_role(
  p_id          uuid,
  p_name        text,
  p_code        text,
  p_description text default null,
  p_status      text default 'active'
)
returns public.roles
language sql
security definer
set search_path = ''
as $$
  select app.upsert_role(p_id, p_name, p_code, p_description, p_status)
$$;

create function public.disable_role(p_id uuid)
returns public.roles
language sql
security definer
set search_path = ''
as $$
  select app.disable_role(p_id)
$$;

create function public.enable_role(p_id uuid)
returns public.roles
language sql
security definer
set search_path = ''
as $$
  select app.enable_role(p_id)
$$;

create function public.delete_role(p_id uuid)
returns public.roles
language sql
security definer
set search_path = ''
as $$
  select app.delete_role(p_id)
$$;

-- ---------------------------------------------------------------------------
-- 8. 权限：表/视图/函数最小授权
-- ---------------------------------------------------------------------------
-- 表级：无任何 API 角色的写授权（含 admin），读取按 RLS 过滤
revoke all on public.roles from anon, authenticated;
grant select on public.roles to authenticated;
grant all on public.roles to service_role;

revoke all on public.roles_v from anon, authenticated;
grant select on public.roles_v to authenticated;
grant select on public.roles_v to service_role;

-- 触发器函数：保持与 app.set_updated_at 相同授权口径
revoke all on function app.protect_builtin_role() from public, anon;
grant execute on function app.protect_builtin_role() to authenticated;

-- app 业务函数：仅登录用户可执行；实现内部再做 admin 校验
revoke all on function app.upsert_role(uuid, text, text, text, text) from public, anon;
grant execute on function app.upsert_role(uuid, text, text, text, text) to authenticated;

revoke all on function app.disable_role(uuid) from public, anon;
grant execute on function app.disable_role(uuid) to authenticated;

revoke all on function app.enable_role(uuid) from public, anon;
grant execute on function app.enable_role(uuid) to authenticated;

revoke all on function app.delete_role(uuid) from public, anon;
grant execute on function app.delete_role(uuid) to authenticated;

-- public 包装层：Data API 入口
revoke all on function public.upsert_role(uuid, text, text, text, text) from public, anon;
grant execute on function public.upsert_role(uuid, text, text, text, text) to authenticated;

revoke all on function public.disable_role(uuid) from public, anon;
grant execute on function public.disable_role(uuid) to authenticated;

revoke all on function public.enable_role(uuid) from public, anon;
grant execute on function public.enable_role(uuid) to authenticated;

revoke all on function public.delete_role(uuid) from public, anon;
grant execute on function public.delete_role(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. RLS：登录用户可读 active 角色，admin 可读全部；无写策略（写仅经 RPC）
-- ---------------------------------------------------------------------------
alter table public.roles enable row level security;

create policy roles_select
on public.roles
for select
to authenticated
using (
  (select app.current_role()) = 'admin'
  or status = 'active'
);
