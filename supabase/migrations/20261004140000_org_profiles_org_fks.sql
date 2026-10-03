-- 组织管理 · profiles 部门/岗位外键（双写过渡）
-- 工单：org/007（department_id/position_id 外键 + 回填 + 双写触发器 +
--       disable/delete_department 与 position_headcount 升级为 id 语义）
--
-- 兼容期不变量（对齐 access/003 role_id 先例）：
--   1. profiles.department 文本列仍可写（用户管理页现状），department_id 与文本由
--      触发器双写一致；单一写源目标为 department_id，org/009 页面切换后才收紧；
--   2. position_id 本期无文本源（profiles 无岗位字段），全部 NULL；岗位在岗统计
--      改按 position_id 精确统计，过渡期恒为 0，引用完整性由 FK restrict 兜底；
--   3. 回填与文本→id 解析统一规则：departments.name 精确匹配且 status='active'，
--      多匹配取 sort_order 最小（同值取 id 兜底，保证确定性），无匹配留 NULL；
--   4. department_id 清空时文本同步清空（null→null）；两列同改时以 department_id
--      为准（目标事实源优先）。
--
-- 依赖：20261003145039（profiles）、20261003145137（列级授权）、
--       20261003205414（departments）、20261003214200（positions）。

-- ---------------------------------------------------------------------------
-- 1. 列 + 外键 + 索引
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column department_id uuid references public.departments (id) on delete restrict,
  add column position_id   uuid references public.positions (id) on delete restrict;

comment on column public.profiles.department_id is
  '部门外键（org/007 引入）：兼容期与 department 文本双写，单一写源目标；文本列最终删除';
comment on column public.profiles.position_id is
  '岗位外键（org/007 引入）：本期无文本源（全部 NULL），由 org/009 页面工单接入写入';

create index profiles_department_id_idx on public.profiles (department_id);
create index profiles_position_id_idx on public.profiles (position_id);

-- ---------------------------------------------------------------------------
-- 2. 回填：department 文本 → department_id（active 精确匹配、sort_order 最小）
--    position_id 本期无文本源，保持全 NULL
-- ---------------------------------------------------------------------------
update public.profiles p
   set department_id = d.id
  from (
    select distinct on (name) name, id
    from public.departments
    where status = 'active'
    order by name, sort_order, id
  ) d
 where p.department = d.name
   and p.department_id is null;

do $$
declare
  v_total   bigint;
  v_text    bigint;
  v_matched bigint;
begin
  select count(*), count(department), count(department_id)
    into v_total, v_text, v_matched
  from public.profiles;

  raise notice 'org/007 回填统计：profiles % 行，department 文本 % 行，department_id 匹配 % 行',
    v_total, v_text, v_matched;
end $$;

-- ---------------------------------------------------------------------------
-- 3. 兼容期双写：department_id ⇄ department 文本（BEFORE 触发器，改 NEW 不产生嵌套 UPDATE）
--    优先级：以实际变更的列为准；两列同改时 department_id 优先（目标模型为事实源）。
--    防递归：BEFORE 触发器只改 NEW 不会递归，pg_trigger_depth() 守卫为嵌套触发器兜底
--    （如 handle_new_user 内插入 profiles），与 app.sync_profile_role 同策略。
-- ---------------------------------------------------------------------------
create function app.sync_profile_department()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text;
begin
  if pg_catalog.pg_trigger_depth() > 1 then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.department_id is not null then
      select d.name into v_name
      from public.departments d
      where d.id = new.department_id;

      if v_name is null then
        raise exception '部门不存在：%', new.department_id using errcode = 'P0002';
      end if;

      new.department := v_name;
    else
      select d.id into new.department_id
      from public.departments d
      where d.name = new.department
        and d.status = 'active'
      order by d.sort_order, d.id
      limit 1;
    end if;

    return new;
  end if;

  -- UPDATE
  if new.department_id is distinct from old.department_id then
    if new.department_id is null then
      new.department := null; -- null→null：清空 id 即清空文本
    else
      select d.name into v_name
      from public.departments d
      where d.id = new.department_id;

      if v_name is null then
        raise exception '部门不存在：%', new.department_id using errcode = 'P0002';
      end if;

      new.department := v_name;
    end if;
  elsif new.department is distinct from old.department then
    -- 文本→id：同回填规则（active + sort_order 最小 + 无匹配 NULL）
    select d.id into new.department_id
    from public.departments d
    where d.name = new.department
      and d.status = 'active'
    order by d.sort_order, d.id
    limit 1;
  end if;

  return new;
end;
$$;

comment on function app.sync_profile_department() is
  '双写触发器（org/007）：department_id 变化回写 department 文本（查询 departments.name，null→null）；'
  'department 文本变化按回填规则回写 department_id；两列同改时以 department_id 为准；'
  'pg_trigger_depth 守卫防嵌套';

create trigger profiles_sync_department
before insert or update on public.profiles
for each row
execute function app.sync_profile_department();

-- ---------------------------------------------------------------------------
-- 4. disable/delete_department：在职检查升级为 department_id 语义
--    （department_id 为 NULL 的历史行按部门名文本兜底，兼容期结束后随文本列删除）
-- ---------------------------------------------------------------------------
create or replace function app.disable_department(p_id uuid)
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

  -- 在职人员检查（org/007）：department_id 精确匹配为主；
  -- department_id 为 NULL 的历史行按部门名文本兜底
  select count(*) into v_count
  from public.profiles
  where status = 'active'
    and (
      department_id = p_id
      or (department_id is null and department = v_row.name)
    );

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
  '部门停用 RPC（admin）：按 department_id 统计在职人员（NULL 行文本兜底）拒绝并提示人数';

create or replace function app.delete_department(p_id uuid)
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

  -- 无在职人员（org/007：department_id 精确匹配为主，NULL 行文本兜底）
  select count(*) into v_members
  from public.profiles
  where status = 'active'
    and (
      department_id = p_id
      or (department_id is null and department = v_row.name)
    );

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
  '部门逻辑删除 RPC（admin）：仅允许删空部门（无子部门、无在职人员），按 department_id 统计（NULL 行文本兜底）';

-- ---------------------------------------------------------------------------
-- 5. 岗位在岗统计升级为 position_id 语义（文本兜底口径退役）
-- ---------------------------------------------------------------------------
create or replace function app.position_headcount(p_position_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  -- org/007 起按 position_id 精确统计；此前口径为 profiles.department 文本=岗位所属部门名，
  -- 属过渡期兜底（已退役）。过渡期 profiles.position_id 全为 NULL，结果恒为 0。
  select count(*)
  from public.profiles pr
  where pr.status = 'active'
    and pr.position_id = p_position_id
$$;

comment on function app.position_headcount(uuid) is
  '岗位在岗人数（org/007 起：按 profiles.position_id 精确统计；position_id 全 NULL 期恒为 0）';

create or replace view public.positions_v
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
  -- org/007：按 position_id 精确统计（profiles.department 文本兜底口径已退役）
  (
    select count(*)
    from public.profiles pr
    where pr.status = 'active'
      and pr.position_id = p.id
  ) as staff_count,
  p.created_by,
  p.updated_by,
  p.created_at,
  p.updated_at
from public.positions p
left join public.departments d on d.id = p.department_id;

comment on view public.positions_v is
  '岗位公开视图：含 department_name 与 staff_count（org/007 起按 position_id 精确统计）；非 admin 由底层 RLS 过滤到 active，跨模块只读此视图';

-- delete_position 的函数注释同步 id 语义（具体实现无需变更：其调用 position_headcount）
comment on function app.delete_position(uuid) is
  '岗位删除 RPC（admin，物理删除）：有在职引用（按 position_id 统计）时拒绝；FK restrict 兜底引用完整性';

-- ---------------------------------------------------------------------------
-- 6. 授权：新触发器函数与既有先例（app.sync_profile_role）保持一致
-- ---------------------------------------------------------------------------
revoke all on function app.sync_profile_department() from public, anon;
grant execute on function app.sync_profile_department() to authenticated;
