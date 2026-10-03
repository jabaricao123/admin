-- 权限管理 · 数据范围策略 role_data_scopes + scope helper + 管理与预检 RPC
-- 工单：access/009（role_data_scopes 表 + scope_user_ids/scope_dept_ids helper）
--       access/010（数据权限配置页的服务端契约：upsert_data_scope / preview_scope）
--
-- 规格：docs/modules/access/data-scopes.md
--   1. 四档范围 self / dept / dept_tree / all；「all」仅 admin 角色可配（功能规则）；
--   2. helper 供他模块 RLS 策略引用（INDEX 规则 6：RLS 随表走，access 只供 helper），
--      GRANT authenticated；无会话上下文（auth.uid() 为空，如定时任务）返回空集，
--      由调用方显式注入属主身份后调用（INDEX 后台执行身份模型）；
--   3. 部门树「及以下」基于 departments_v 的 path 串展开；
--   4. 存量影响：现状 internal 角色可读全部 profiles（通讯录/审批选人依赖），
--      存量角色初始 scope 显式设为 all，禁止「默认 self」造成可见范围静默收窄；
--   5. 变更写审计摘要；配置页提供「以某用户视角预检」工具。
--
-- 约定（对齐 docs/modules/INDEX.md）：
--   - role_data_scopes 为权限敏感表：表级对任何 API 角色无写授权，写仅经 upsert_data_scope；
--   - 业务实现放 app schema（沿用现有 app schema 约定），public 同名函数是 Data API
--     薄包装层（PostgREST 仅暴露 public schema）；
--   - 所有 SECURITY DEFINER 函数 set search_path = '' + 全限定名引用；
--   - fail-closed：账号非 active、角色无 scope 行均按空集处理，防漏配放大可见范围。
--
-- 依赖：20261003211025（roles 表 + 7 内置角色）、20261003205414（departments/departments_v）、
--       20261004100000（profiles.role_id 兼容双写）。

-- ---------------------------------------------------------------------------
-- 1. role_data_scopes：角色 ↔ 数据范围（一角色一行）
-- ---------------------------------------------------------------------------
create table public.role_data_scopes (
  role_id    uuid primary key references public.roles (id) on delete cascade,
  scope      text not null
             constraint role_data_scopes_scope_check
             check (scope in ('self', 'dept', 'dept_tree', 'all')),
  updated_by uuid,
  updated_at timestamptz not null default now()
);

comment on table public.role_data_scopes is
  '角色数据范围（四档：self/dept/dept_tree/all；写仅经 upsert_data_scope RPC）';
comment on column public.role_data_scopes.role_id is
  '角色 id（roles.id；角色删除级联清理范围行）';
comment on column public.role_data_scopes.scope is
  '数据范围：self=仅本人 / dept=本部门 / dept_tree=本部门及以下 / all=全部（仅 admin 角色可配）';
comment on column public.role_data_scopes.updated_by is
  '最近修改人（弱关联 auth.users，不设外键以保留追溯）';
comment on column public.role_data_scopes.updated_at is
  '最近修改时间';

create trigger role_data_scopes_set_updated_at
before update on public.role_data_scopes
for each row
execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- 2. seed：存量角色显式 scope='all'
--    data-scopes.md 存量影响：现状 internal 角色可读全部 profiles（通讯录/选人需要），
--    故存量角色显式初始化为 all；新角色无行时 helper fail-closed 空集，由管理页显式配置。
-- ---------------------------------------------------------------------------
insert into public.role_data_scopes (role_id, scope)
select r.id, 'all'
from public.roles r
on conflict (role_id) do nothing;

-- ---------------------------------------------------------------------------
-- 3. 内部解析函数（app schema；不 GRANT API 角色，仅 SECURITY DEFINER 内部调用）
-- ---------------------------------------------------------------------------
create function app.resolve_data_scope(p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  -- 账号非 active 或角色无 scope 行 → NULL（调用方按空集处理，fail-closed）；
  -- 角色解析优先 role_id，为空回退枚举（兼容 access/003 双写过渡，同 app.current_role）
  select rds.scope
  from public.profiles p
  join public.roles r
    on r.id = coalesce(
         p.role_id,
         (select r2.id from public.roles r2 where r2.code = p.role::text)
       )
  left join public.role_data_scopes rds on rds.role_id = r.id
  where p.id = p_user_id
    and p.status = 'active'
$$;

comment on function app.resolve_data_scope(uuid) is
  '解析指定用户数据范围：active 账号 + 角色 scope 行；优先 role_id 回退枚举；无行返回 NULL（空集语义）';

create function app.resolve_user_department(p_user_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  -- department_id 为主；为空的历史行按 org/007 回填规则文本兜底
  -- （active 精确匹配，多匹配取 sort_order 最小、id 兜底）
  select coalesce(
    p.department_id,
    (
      select d.id
      from public.departments d
      where d.name = p.department
        and d.status = 'active'
      order by d.sort_order, d.id
      limit 1
    )
  )
  from public.profiles p
  where p.id = p_user_id
$$;

comment on function app.resolve_user_department(uuid) is
  '解析用户所属部门 id：department_id 为主，为空的历史行按部门名 active 精确匹配兜底';

create function app.scope_dept_ids_for(p_user_id uuid)
returns setof uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_scope text;
  v_dept  uuid;
begin
  if p_user_id is null then
    return; -- 无会话
  end if;

  v_scope := app.resolve_data_scope(p_user_id);

  if v_scope is null or v_scope = 'self' then
    return; -- 无配置 / 仅本人：部门集为空
  end if;

  if v_scope = 'all' then
    return query
    select d.id
    from public.departments d
    where d.status <> 'deleted';
    return;
  end if;

  v_dept := app.resolve_user_department(p_user_id);
  if v_dept is null then
    return; -- 无部门：部门集为空（scope_user_ids 此时退化为仅本人）
  end if;

  if v_scope = 'dept' then
    return query
    select d.id
    from public.departments d
    where d.id = v_dept
      and d.status <> 'deleted';
    return;
  end if;

  -- dept_tree：按 departments_v.path 串展开本部门及以下（含自身）
  return query
  select dv.id
  from public.departments_v dv
  join public.departments_v base on base.id = v_dept
  where dv.id = v_dept
     or pg_catalog.starts_with(dv.path, base.path || '/');
end;
$$;

comment on function app.scope_dept_ids_for(uuid) is
  '指定用户的可见部门 id 集：all=全部未删除 / dept=本部门 / dept_tree=本部门及以下（path 展开）/ self=空集；无会话或无部门返回空集';

create function app.scope_user_ids_for(p_user_id uuid)
returns setof uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_scope    text;
  v_dept     uuid;
  v_dept_ids uuid[];
begin
  if p_user_id is null then
    return; -- 无会话
  end if;

  v_scope := app.resolve_data_scope(p_user_id);

  if v_scope is null then
    return; -- 无配置：空集（fail-closed）
  end if;

  if v_scope = 'all' then
    return query select p.id from public.profiles p;
    return;
  end if;

  if v_scope = 'self' then
    return query select p_user_id;
    return;
  end if;

  -- dept / dept_tree
  v_dept := app.resolve_user_department(p_user_id);
  if v_dept is null then
    return query select p_user_id; -- 无部门：仅本人（data-scopes.md）
    return;
  end if;

  v_dept_ids := array(select app.scope_dept_ids_for(p_user_id));

  return query
  select p.id
  from public.profiles p
  where p.department_id = any (v_dept_ids)
     or (
       p.department_id is null
       and p.department in (
         select d.name
         from public.departments d
         where d.id = any (v_dept_ids)
       )
     );
end;
$$;

comment on function app.scope_user_ids_for(uuid) is
  '指定用户的可见用户 id 集：all=全部 / self=本人 / dept=本部门成员 / dept_tree=本部门及以下成员；无部门时仅本人；无会话或无配置为空集';

-- ---------------------------------------------------------------------------
-- 4. 会话级 helper（他模块 RLS 引用入口；GRANT authenticated）
-- ---------------------------------------------------------------------------
create function app.scope_user_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.scope_user_ids_for((select auth.uid()))
$$;

comment on function app.scope_user_ids() is
  '当前登录用户可见用户 id 集（RLS 策略引用入口）；无会话（auth.uid() 为空）返回空集，'
  '后台任务需显式注入属主身份后调用（INDEX 后台执行身份模型）';

create function app.scope_dept_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.scope_dept_ids_for((select auth.uid()))
$$;

comment on function app.scope_dept_ids() is
  '当前登录用户可见部门 id 集（RLS 策略引用入口）；无会话返回空集，后台任务需显式注入属主身份';

-- ---------------------------------------------------------------------------
-- 5. 管理 RPC：upsert_data_scope（admin；all 仅 admin 角色可配；写审计）
-- ---------------------------------------------------------------------------
create function app.upsert_data_scope(
  p_role_id uuid,
  p_scope   text
)
returns public.role_data_scopes
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role   public.roles;
  v_before text;
  v_row    public.role_data_scopes;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_scope is null or p_scope not in ('self', 'dept', 'dept_tree', 'all') then
    raise exception '非法数据范围：%', coalesce(p_scope, 'null') using errcode = '22023';
  end if;

  select * into v_role
  from public.roles
  where id = p_role_id;

  if not found then
    raise exception '角色不存在：%', p_role_id using errcode = 'P0002';
  end if;

  -- 「all」仅 admin 角色可配（data-scopes.md 功能规则）
  if p_scope = 'all' and v_role.code <> 'admin' then
    raise exception '仅系统管理员角色可配置「全部」数据范围' using errcode = '22023';
  end if;

  select scope into v_before
  from public.role_data_scopes
  where role_id = p_role_id;

  insert into public.role_data_scopes (role_id, scope, updated_by, updated_at)
  values (p_role_id, p_scope, (select auth.uid()), now())
  on conflict (role_id) do update
    set scope      = excluded.scope,
        updated_by = excluded.updated_by,
        updated_at = now()
  returning * into v_row;

  perform app.audit_log(
    'access', 'update', 'role_data_scope', p_role_id::text,
    jsonb_build_object(
      'role_code', v_role.code,
      'before', v_before,
      'after', p_scope
    )
  );

  return v_row;
end;
$$;

comment on function app.upsert_data_scope(uuid, text) is
  '数据范围配置 RPC（admin）：upsert role_data_scopes；all 仅 admin 角色可配；写审计摘要';

-- ---------------------------------------------------------------------------
-- 6. 预检 RPC：preview_scope（admin；以指定用户视角统计可见范围）
-- ---------------------------------------------------------------------------
create function app.preview_scope(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles;
  v_role    public.roles;
  v_dept    uuid;
  v_scope   text;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_profile
  from public.profiles
  where id = p_user_id;

  if not found then
    raise exception '用户不存在：%', p_user_id using errcode = 'P0002';
  end if;

  select r.* into v_role
  from public.roles r
  where r.id = coalesce(
    v_profile.role_id,
    (select r2.id from public.roles r2 where r2.code = v_profile.role::text)
  );

  v_dept  := app.resolve_user_department(p_user_id);
  v_scope := app.resolve_data_scope(p_user_id);

  return jsonb_build_object(
    'user_id',         v_profile.id,
    'user_name',       v_profile.full_name,
    'user_status',     v_profile.status,
    'role_code',       v_role.code,
    'role_name',       v_role.name,
    'department_id',   v_dept,
    'department_name', (select d.name from public.departments d where d.id = v_dept),
    'scope',           v_scope,
    'user_count',      (select count(*) from app.scope_user_ids_for(p_user_id)),
    'dept_count',      (select count(*) from app.scope_dept_ids_for(p_user_id))
  );
end;
$$;

comment on function app.preview_scope(uuid) is
  '数据范围预检（admin）：返回指定用户角色、scope、可见用户数、可见部门数（按真实会话语义计算，含 fail-closed）';

-- ---------------------------------------------------------------------------
-- 7. public 包装层（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.upsert_data_scope(
  p_role_id uuid,
  p_scope   text
)
returns public.role_data_scopes
language sql
security definer
set search_path = ''
as $$
  select app.upsert_data_scope(p_role_id, p_scope)
$$;

comment on function public.upsert_data_scope(uuid, text) is
  '数据范围配置 Data API 薄包装（函数内 admin 校验）';

create function public.preview_scope(p_user_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.preview_scope(p_user_id)
$$;

comment on function public.preview_scope(uuid) is
  '数据范围预检 Data API 薄包装（函数内 admin 校验）';

-- ---------------------------------------------------------------------------
-- 8. 授权：表级只读；内部解析函数不 GRANT；helper 与管理 RPC 最小授权
-- ---------------------------------------------------------------------------
-- 表级：无任何 API 角色写授权，读取按 RLS 过滤
revoke all on public.role_data_scopes from public, anon, authenticated, service_role;
grant select on public.role_data_scopes to authenticated, service_role;

-- 内部解析函数：仅 SECURITY DEFINER 内部调用，不暴露给 API 角色
revoke all on function app.resolve_data_scope(uuid) from public, anon, authenticated, service_role;
revoke all on function app.resolve_user_department(uuid) from public, anon, authenticated, service_role;
revoke all on function app.scope_user_ids_for(uuid) from public, anon, authenticated, service_role;
revoke all on function app.scope_dept_ids_for(uuid) from public, anon, authenticated, service_role;

-- 会话级 helper：他模块 RLS 策略引用入口（GRANT authenticated）
revoke all on function app.scope_user_ids() from public, anon;
grant execute on function app.scope_user_ids() to authenticated;

revoke all on function app.scope_dept_ids() from public, anon;
grant execute on function app.scope_dept_ids() to authenticated;

-- 管理 / 预检 RPC：仅 authenticated，函数内部再校验 admin
revoke all on function app.upsert_data_scope(uuid, text) from public, anon;
grant execute on function app.upsert_data_scope(uuid, text) to authenticated;

revoke all on function public.upsert_data_scope(uuid, text) from public, anon;
grant execute on function public.upsert_data_scope(uuid, text) to authenticated;

revoke all on function app.preview_scope(uuid) from public, anon;
grant execute on function app.preview_scope(uuid) to authenticated;

revoke all on function public.preview_scope(uuid) from public, anon;
grant execute on function public.preview_scope(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. RLS：登录用户可读（配置页展示），无写策略（写仅经 RPC）
-- ---------------------------------------------------------------------------
alter table public.role_data_scopes enable row level security;

create policy role_data_scopes_select
on public.role_data_scopes
for select
to authenticated
using (true);
