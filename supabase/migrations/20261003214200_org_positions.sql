-- 组织管理 · 岗位表 + 公开视图 + 受控写入 RPC
-- 工单：org/004（positions 表 migration）+ org/005（RLS + pgTAP）
--
-- 约定（对齐 docs/modules/INDEX.md）：
--   1. 表级对任何角色都不授予 INSERT/UPDATE/DELETE（含 admin），写路径全部经
--      SECURITY DEFINER RPC，函数内部校验 admin；
--   2. 业务实现放 app schema（沿用现有 app schema 约定），public 中的同名函数是
--      Data API 包装层（PostgREST 仅暴露 public schema，见 supabase/config.toml）；
--   3. 所有 SECURITY DEFINER 函数 set search_path = '' + 全限定名引用；
--   4. profiles.position_id 由 org/007 引入；本期在岗/引用统计按 profiles.department
--      文本匹配岗位所属部门名兜底（TODO org/007 后改 position_id 精确统计），
--      因此本迁移不依赖 org/007；
--   5. 岗位停用（disabled）允许存在在职引用：停用后仅从新编辑下拉过滤（非 admin
--      经 RLS 只读 active 岗位，编辑用户下拉消费 positions_v 时自然排除），存量引用
--      保留展示；删除才拒绝引用（物理删除会丢存量展示锚点）。

-- ---------------------------------------------------------------------------
-- 1. positions 表
-- ---------------------------------------------------------------------------
create table public.positions (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  code          text not null
                constraint positions_code_key unique,
  department_id uuid references public.departments (id) on delete restrict,
  headcount     integer not null default 0
                constraint positions_headcount_check check (headcount >= 0),
  description   text,
  status        text not null default 'active'
                constraint positions_status_check
                check (status in ('active', 'disabled')),
  created_by    uuid,
  updated_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

comment on table public.positions is
  '岗位名录（编码唯一；status=disabled 仅隐藏于新编辑下拉，不拒绝存量引用）';
comment on column public.positions.name is '岗位名称';
comment on column public.positions.code is '岗位编码（唯一，由 DB 约束兜底）';
comment on column public.positions.department_id is '所属部门（departments.id，可为空）';
comment on column public.positions.headcount is '编制数（>=0，超编仅前端警示）';
comment on column public.positions.description is '职责描述';
comment on column public.positions.status is '状态：active/disabled（停用不拒绝存量引用，删除才拒绝）';
comment on column public.positions.created_by is '创建人（弱关联 auth.users，不设外键以保留追溯）';
comment on column public.positions.updated_by is '最近修改人（弱关联 auth.users，不设外键以保留追溯）';

create index positions_department_id_idx on public.positions (department_id);
create index positions_status_idx on public.positions (status);

create trigger positions_set_updated_at
before update on public.positions
for each row
execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- 2. 在岗统计函数（org/007 前的部门文本匹配兜底）
-- ---------------------------------------------------------------------------
create function app.position_headcount(p_position_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  -- TODO(org/007)：profiles.position_id 引入后改为按 position_id 精确统计
  select count(*)
  from public.profiles pr
  where pr.status = 'active'
    and pr.department = (
      select d.name
      from public.positions p
      join public.departments d on d.id = p.department_id
      where p.id = p_position_id
    )
$$;

comment on function app.position_headcount(uuid) is
  '岗位在岗人数（org/007 前兜底：profiles.department 文本 = 岗位所属部门名的在职人数）';

-- ---------------------------------------------------------------------------
-- 3. positions_v 公开视图（含部门名与在岗数；跨模块只读此视图）
-- ---------------------------------------------------------------------------
create view public.positions_v
with (security_invoker = true)
as
select
  p.id,
  p.name,
  p.code,
  p.department_id,
  d.name as department_name,
  p.headcount,
  p.description,
  p.status,
  -- TODO(org/007)：profiles.position_id 引入后改为按 position_id 精确统计
  (
    select count(*)
    from public.profiles pr
    where pr.status = 'active'
      and pr.department = d.name
  ) as staff_count,
  p.created_by,
  p.updated_by,
  p.created_at,
  p.updated_at
from public.positions p
left join public.departments d on d.id = p.department_id;

comment on view public.positions_v is
  '岗位公开视图：含 department_name 与 staff_count（兜底口径）；非 admin 由底层 RLS 过滤到 active，跨模块只读此视图';

-- ---------------------------------------------------------------------------
-- 4. RPC：写入（admin 校验 + 业务规则；code 唯一冲突由 DB 兜底）
-- ---------------------------------------------------------------------------
create function app.upsert_position(
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
  v_row public.positions;
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

    return v_row;
  end if;

  -- 更新（全量写入）
  select * into v_row
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

  return v_row;
exception
  when unique_violation then
    -- positions 仅 code 一个业务唯一约束（id 为 gen_random_uuid），可直接归因
    raise exception '岗位编码已存在：%', btrim(p_code) using errcode = '23505';
end;
$$;

comment on function app.upsert_position(uuid, text, text, uuid, integer, text, text) is
  '岗位新建/编辑 RPC（admin）：id 为 null 新建；code 唯一冲突转 23505 中文提示；不拦截超编';

create function app.disable_position(p_id uuid)
returns public.positions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.positions;
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
    return v_row; -- 幂等
  end if;

  -- 明确允许停用被引用岗位：存量引用保留展示，仅新编辑下拉过滤（RLS 只读 active）
  update public.positions
     set status     = 'disabled',
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  return v_row;
end;
$$;

comment on function app.disable_position(uuid) is
  '岗位停用 RPC（admin）：被 profiles 引用时同样允许（存量保留展示，仅新编辑下拉过滤）';

create function app.enable_position(p_id uuid)
returns public.positions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.positions;
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
    return v_row; -- 幂等
  end if;

  update public.positions
     set status     = 'active',
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  return v_row;
end;
$$;

comment on function app.enable_position(uuid) is '岗位启用 RPC（admin）：幂等';

create function app.delete_position(p_id uuid)
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

  return v_row;
end;
$$;

comment on function app.delete_position(uuid) is
  '岗位删除 RPC（admin，物理删除）：有在职引用（org/007 前按所属部门文本兜底）时拒绝';

-- ---------------------------------------------------------------------------
-- 5. public 包装层（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.upsert_position(
  p_id            uuid    default null,
  p_name          text    default null,
  p_code          text    default null,
  p_department_id uuid    default null,
  p_headcount     integer default null,
  p_description   text    default null,
  p_status        text    default null
)
returns public.positions
language sql
security definer
set search_path = ''
as $$
  select app.upsert_position(p_id, p_name, p_code, p_department_id,
                             p_headcount, p_description, p_status)
$$;

create function public.disable_position(p_id uuid)
returns public.positions
language sql
security definer
set search_path = ''
as $$
  select app.disable_position(p_id)
$$;

create function public.enable_position(p_id uuid)
returns public.positions
language sql
security definer
set search_path = ''
as $$
  select app.enable_position(p_id)
$$;

create function public.delete_position(p_id uuid)
returns public.positions
language sql
security definer
set search_path = ''
as $$
  select app.delete_position(p_id)
$$;

create function public.position_headcount(p_position_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select app.position_headcount(p_position_id)
$$;

-- ---------------------------------------------------------------------------
-- 6. 权限：表/视图/函数最小授权
-- ---------------------------------------------------------------------------
-- 表级：无任何角色的 INSERT/UPDATE/DELETE（含 admin），读取按 RLS 过滤
revoke all on public.positions from anon, authenticated;
grant select on public.positions to authenticated;
grant all on public.positions to service_role;

revoke all on public.positions_v from anon, authenticated;
grant select on public.positions_v to authenticated;
grant select on public.positions_v to service_role;

-- app 业务函数：仅登录用户可执行；实现内部再做 admin 校验
revoke all on function app.upsert_position(uuid, text, text, uuid, integer, text, text)
  from public, anon;
grant execute on function app.upsert_position(uuid, text, text, uuid, integer, text, text)
  to authenticated;

revoke all on function app.disable_position(uuid) from public, anon;
grant execute on function app.disable_position(uuid) to authenticated;

revoke all on function app.enable_position(uuid) from public, anon;
grant execute on function app.enable_position(uuid) to authenticated;

revoke all on function app.delete_position(uuid) from public, anon;
grant execute on function app.delete_position(uuid) to authenticated;

revoke all on function app.position_headcount(uuid) from public, anon;
grant execute on function app.position_headcount(uuid) to authenticated;

-- public 包装层：Data API 入口
revoke all on function public.upsert_position(uuid, text, text, uuid, integer, text, text)
  from public, anon;
grant execute on function public.upsert_position(uuid, text, text, uuid, integer, text, text)
  to authenticated;

revoke all on function public.disable_position(uuid) from public, anon;
grant execute on function public.disable_position(uuid) to authenticated;

revoke all on function public.enable_position(uuid) from public, anon;
grant execute on function public.enable_position(uuid) to authenticated;

revoke all on function public.delete_position(uuid) from public, anon;
grant execute on function public.delete_position(uuid) to authenticated;

revoke all on function public.position_headcount(uuid) from public, anon;
grant execute on function public.position_headcount(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. RLS：admin 全量（含 disabled）；其他登录用户只读 active（编辑用户选岗位）；
--    写仅经 RPC
-- ---------------------------------------------------------------------------
alter table public.positions enable row level security;

create policy positions_select
on public.positions
for select
to authenticated
using (
  (select app.current_role()) = 'admin'
  or status = 'active'
);
