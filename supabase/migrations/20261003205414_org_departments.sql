-- 组织管理 · 部门表（树形）+ 公开视图 + 受控写入 RPC
-- 工单：org/001（departments 表 migration）+ org/002（RLS + pgTAP）
--
-- 约定（对齐 docs/modules/INDEX.md）：
--   1. 表级对任何角色都不授予 INSERT/UPDATE/DELETE（含 admin），写路径全部经
--      SECURITY DEFINER RPC，函数内部校验 admin；
--   2. 业务实现放 app schema（沿用现有 app schema 约定），public 中的同名函数是
--      Data API 包装层（PostgREST 仅暴露 public schema，见 supabase/config.toml）；
--   3. 所有 SECURITY DEFINER 函数 set search_path = '' + 全限定名引用；
--   4. 停用/删除的在职人员校验不落表约束，由 RPC 运行时按 profiles.department
--      文本匹配部门名完成（profiles.department_id 由 org/007 引入后再收紧），
--      因此本迁移不依赖 org/007。

-- ---------------------------------------------------------------------------
-- 1. departments 表
-- ---------------------------------------------------------------------------
create table public.departments (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  parent_id  uuid references public.departments (id) on delete restrict,
  leader_id  uuid references public.profiles (id) on delete set null,
  sort_order integer not null default 0,
  status     text not null default 'active'
             constraint departments_status_check
             check (status in ('active', 'disabled', 'deleted')),
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint departments_no_self_parent check (parent_id is distinct from id)
);

comment on table public.departments is '组织架构部门（树形；status=deleted 为逻辑删除终态，不物理删除）';
comment on column public.departments.name is '部门名称（树展示与在职人员文本匹配的锚点）';
comment on column public.departments.parent_id is '父部门；NULL=根部门';
comment on column public.departments.leader_id is '部门负责人（profiles.id）';
comment on column public.departments.sort_order is '同级排序号（升序）';
comment on column public.departments.status is '状态：active/disabled/deleted（deleted 为终态）';
comment on column public.departments.created_by is '创建人（弱关联 auth.users，不设外键以保留追溯）';
comment on column public.departments.updated_by is '最近修改人（弱关联 auth.users，不设外键以保留追溯）';

create index departments_parent_id_idx on public.departments (parent_id);
create index departments_status_idx on public.departments (status);

create trigger departments_set_updated_at
before update on public.departments
for each row
execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- 2. departments_v 公开视图（递归 CTE 生成 path；过滤 deleted）
-- ---------------------------------------------------------------------------
create view public.departments_v
with (security_invoker = true)
as
with recursive tree as (
  select
    d.id, d.name, d.parent_id, d.leader_id, d.sort_order, d.status,
    d.created_by, d.updated_by, d.created_at, d.updated_at,
    1 as depth,
    d.name::text as path
  from public.departments d
  where d.parent_id is null
    and d.status <> 'deleted'

  union all

  select
    d.id, d.name, d.parent_id, d.leader_id, d.sort_order, d.status,
    d.created_by, d.updated_by, d.created_at, d.updated_at,
    t.depth + 1,
    t.path || '/' || d.name
  from public.departments d
  join tree t on d.parent_id = t.id
  where d.status <> 'deleted'
)
select
  id, name, parent_id, leader_id, sort_order, status,
  depth, path,
  created_by, updated_by, created_at, updated_at
from tree;

comment on view public.departments_v is '部门公开视图：含 depth/path，过滤 status=deleted；跨模块只读此视图，禁止 join 内部表';

-- ---------------------------------------------------------------------------
-- 3. RPC：校验（防环）
-- ---------------------------------------------------------------------------
create function app.validate_department_move(
  p_node       uuid,
  p_new_parent uuid
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.departments where id = p_node) then
    raise exception '部门不存在：%', p_node using errcode = 'P0002';
  end if;

  -- 移到根部门永远合法
  if p_new_parent is null then
    return;
  end if;

  if p_new_parent = p_node then
    raise exception '不能将部门移动到自身下' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.departments
    where id = p_new_parent
      and status <> 'deleted'
  ) then
    raise exception '目标部门不存在或已删除：%', p_new_parent using errcode = 'P0002';
  end if;

  -- 防环：new_parent 不得是 node 的子孙
  if exists (
    with recursive descendants as (
      select d.id
      from public.departments d
      where d.parent_id = p_node

      union all

      select d.id
      from public.departments d
      join descendants x on d.parent_id = x.id
    )
    select 1 from descendants where id = p_new_parent
  ) then
    raise exception '不能将部门移动到其子孙部门下（会形成循环）' using errcode = '22023';
  end if;
end;
$$;

comment on function app.validate_department_move(uuid, uuid) is '部门移动防环校验：new_parent 不得为 node 自身或其子孙；违规 raise exception';

-- ---------------------------------------------------------------------------
-- 4. RPC：写入（admin 校验 + 业务规则）
-- ---------------------------------------------------------------------------
create function app.upsert_department(
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
  v_row public.departments;
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

    return v_row;
  end if;

  -- 更新：p_parent_id 为全量写入（null = 移到根）
  select * into v_row
  from public.departments
  where id = p_id;

  if not found then
    raise exception '部门不存在：%', p_id using errcode = 'P0002';
  end if;

  if v_row.status = 'deleted' then
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

  return v_row;
end;
$$;

comment on function app.upsert_department(uuid, text, uuid, uuid, integer) is
  '部门新建/编辑 RPC（admin）：id 为 null 新建；更新时 parent 为全量写入，内部做防环校验';

create function app.disable_department(p_id uuid)
returns public.departments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row   public.departments;
  v_count bigint;
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
    return v_row; -- 幂等
  end if;

  -- 在职人员检查：profiles.department 文本 = 部门名（department_id 由 org/007 引入后收紧）
  select count(*) into v_count
  from public.profiles
  where department = v_row.name
    and status = 'active';

  if v_count > 0 then
    raise exception '该部门下仍有 % 名在职人员，无法停用', v_count using errcode = '22023';
  end if;

  update public.departments
     set status     = 'disabled',
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  return v_row;
end;
$$;

comment on function app.disable_department(uuid) is
  '部门停用 RPC（admin）：含在职人员（profiles.department 文本匹配）时拒绝并提示人数';

create function app.enable_department(p_id uuid)
returns public.departments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.departments;
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
    return v_row; -- 幂等
  end if;

  update public.departments
     set status     = 'active',
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  return v_row;
end;
$$;

comment on function app.enable_department(uuid) is '部门启用 RPC（admin）：deleted 为终态不可启用';

create function app.delete_department(p_id uuid)
returns public.departments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row      public.departments;
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

  -- 无在职人员（文本匹配兜底，department_id 由 org/007 引入后收紧）
  select count(*) into v_members
  from public.profiles
  where department = v_row.name
    and status = 'active';

  if v_members > 0 then
    raise exception '该部门下仍有 % 名在职人员，无法删除', v_members using errcode = '22023';
  end if;

  update public.departments
     set status     = 'deleted',
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  return v_row;
end;
$$;

comment on function app.delete_department(uuid) is
  '部门逻辑删除 RPC（admin）：仅允许删空部门（无子部门、无在职人员），置 status=deleted';

-- ---------------------------------------------------------------------------
-- 5. RPC：树查询
-- ---------------------------------------------------------------------------
create function app.department_tree()
returns setof public.departments_v
language sql
stable
security definer
set search_path = ''
as $$
  with recursive tree as (
    select
      d.id, d.name, d.parent_id, d.leader_id, d.sort_order, d.status,
      d.created_by, d.updated_by, d.created_at, d.updated_at,
      1 as depth,
      d.name::text as path,
      lpad(d.sort_order::text, 6, '0') as sort_key
    from public.departments d
    where d.parent_id is null
      and d.status <> 'deleted'

    union all

    select
      d.id, d.name, d.parent_id, d.leader_id, d.sort_order, d.status,
      d.created_by, d.updated_by, d.created_at, d.updated_at,
      t.depth + 1,
      t.path || '/' || d.name,
      t.sort_key || '/' || lpad(d.sort_order::text, 6, '0')
    from public.departments d
    join tree t on d.parent_id = t.id
    where d.status <> 'deleted'
  )
  select
    id, name, parent_id, leader_id, sort_order, status,
    depth, path,
    created_by, updated_by, created_at, updated_at
  from tree
  order by sort_key
$$;

comment on function app.department_tree() is '部门树 RPC：按同级 sort_order 深度优先排序，过滤 deleted';

-- ---------------------------------------------------------------------------
-- 6. public 包装层（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.validate_department_move(
  p_node       uuid,
  p_new_parent uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.validate_department_move(p_node, p_new_parent);
end;
$$;

create function public.upsert_department(
  p_id         uuid,
  p_name       text,
  p_parent_id  uuid,
  p_leader_id  uuid,
  p_sort_order integer
)
returns public.departments
language sql
security definer
set search_path = ''
as $$
  select app.upsert_department(p_id, p_name, p_parent_id, p_leader_id, p_sort_order)
$$;

create function public.disable_department(p_id uuid)
returns public.departments
language sql
security definer
set search_path = ''
as $$
  select app.disable_department(p_id)
$$;

create function public.enable_department(p_id uuid)
returns public.departments
language sql
security definer
set search_path = ''
as $$
  select app.enable_department(p_id)
$$;

create function public.delete_department(p_id uuid)
returns public.departments
language sql
security definer
set search_path = ''
as $$
  select app.delete_department(p_id)
$$;

create function public.department_tree()
returns setof public.departments_v
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.department_tree()
$$;

-- ---------------------------------------------------------------------------
-- 7. 权限：表/视图/函数最小授权
-- ---------------------------------------------------------------------------
-- 表级：无任何角色的 INSERT/UPDATE/DELETE（含 admin），读取按 RLS 过滤
revoke all on public.departments from anon, authenticated;
grant select on public.departments to authenticated;
grant all on public.departments to service_role;

revoke all on public.departments_v from anon, authenticated;
grant select on public.departments_v to authenticated;
grant select on public.departments_v to service_role;

-- app 业务函数：仅登录用户可执行；实现内部再做 admin 校验
revoke all on function app.validate_department_move(uuid, uuid) from public, anon;
grant execute on function app.validate_department_move(uuid, uuid) to authenticated;

revoke all on function app.upsert_department(uuid, text, uuid, uuid, integer) from public, anon;
grant execute on function app.upsert_department(uuid, text, uuid, uuid, integer) to authenticated;

revoke all on function app.disable_department(uuid) from public, anon;
grant execute on function app.disable_department(uuid) to authenticated;

revoke all on function app.enable_department(uuid) from public, anon;
grant execute on function app.enable_department(uuid) to authenticated;

revoke all on function app.delete_department(uuid) from public, anon;
grant execute on function app.delete_department(uuid) to authenticated;

revoke all on function app.department_tree() from public, anon;
grant execute on function app.department_tree() to authenticated;

-- public 包装层：Data API 入口
revoke all on function public.validate_department_move(uuid, uuid) from public, anon;
grant execute on function public.validate_department_move(uuid, uuid) to authenticated;

revoke all on function public.upsert_department(uuid, text, uuid, uuid, integer) from public, anon;
grant execute on function public.upsert_department(uuid, text, uuid, uuid, integer) to authenticated;

revoke all on function public.disable_department(uuid) from public, anon;
grant execute on function public.disable_department(uuid) to authenticated;

revoke all on function public.enable_department(uuid) from public, anon;
grant execute on function public.enable_department(uuid) to authenticated;

revoke all on function public.delete_department(uuid) from public, anon;
grant execute on function public.delete_department(uuid) to authenticated;

revoke all on function public.department_tree() from public, anon;
grant execute on function public.department_tree() to authenticated;

-- ---------------------------------------------------------------------------
-- 8. RLS：admin 全量（含 deleted），其他登录用户只读未删除树；写仅经 RPC
-- ---------------------------------------------------------------------------
alter table public.departments enable row level security;

create policy departments_select
on public.departments
for select
to authenticated
using (
  (select app.current_role()) = 'admin'
  or status <> 'deleted'
);
