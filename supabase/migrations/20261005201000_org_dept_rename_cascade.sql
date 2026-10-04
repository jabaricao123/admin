-- 组织管理 · 部门改名级联 + 双写触发器改名保护（org 数据层批次 3 · 修复项 2）
-- 背景：upsert_department 改名只写 departments.name，profiles.department 文本停留在旧名
--       （兼容期双写不一致：列表按文本展示旧名，按 department_id 校验却指向新名）。
--
-- 语义：
--   1. create or replace app.upsert_department（在 20261005180000 含 audit_log 的最新版
--      基础上）：改名成功后同步 `update public.profiles set department = 新名
--      where department_id = p_id and department is distinct from 新名`；
--      不改 updated_by（属 RPC 内系统级联动，追溯以 departments 审计为准）；
--   2. 双写触发器 app.sync_profile_department 追加改名保护：文本变化时，若新文本
--      恰为「当前绑定部门（未删除）的现名」，保持绑定不变。否则：
--        * 停用（disabled）部门改名后，文本→id 解析仅认 active，会把存量
--          department_id 清成 NULL（丢引用）；
--        * 跨父级同名 active 部门存在时，解析按 sort_order 最小者，会把改名部门
--          下的人员「抢绑」到同名的其他部门。
--      保护仅在该场景生效，普通文本→id 解析规则（active + sort_order 最小 +
--      无匹配 NULL）与既有测试语义不变。
--
-- 依赖：20261005180000（upsert_department 含审计现状）、
--       20261004140000（sync_profile_department 现状）、
--       20261005181000（同级名称唯一索引，23505 中文提示保留）。

-- ---------------------------------------------------------------------------
-- 1. app.upsert_department：改名级联同步 profiles.department 文本（create/update 审计保留）
-- ---------------------------------------------------------------------------
create or replace function app.upsert_department(
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
  v_row    public.departments;
  v_before public.departments;
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

    perform app.audit_log(
      'org', 'create', 'department', v_row.id::text,
      jsonb_build_object('before', null, 'after', to_jsonb(v_row))
    );

    return v_row;
  end if;

  -- 更新：p_parent_id 为全量写入（null = 移到根）
  select * into v_before
  from public.departments
  where id = p_id;

  if not found then
    raise exception '部门不存在：%', p_id using errcode = 'P0002';
  end if;

  if v_before.status = 'deleted' then
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

  -- 改名级联（批次 3）：department 文本双写一致；双写触发器保证 id 不被
  -- active 解析清空/抢绑（见本文件第 2 节）
  if v_before.name is distinct from v_row.name then
    update public.profiles
       set department = v_row.name
     where department_id = p_id
       and department is distinct from v_row.name;
  end if;

  perform app.audit_log(
    'org', 'update', 'department', v_row.id::text,
    jsonb_build_object('before', to_jsonb(v_before), 'after', to_jsonb(v_row))
  );

  return v_row;
exception
  when unique_violation then
    -- 同级名称唯一索引（departments_parent_name_key）兜底转中文提示
    raise exception '同级部门名称已存在：%', btrim(p_name) using errcode = '23505';
end;
$$;

comment on function app.upsert_department(uuid, text, uuid, uuid, integer) is
  '部门新建/编辑 RPC（admin）：id 为 null 新建；更新时 parent 为全量写入，内部做防环校验；'
  '改名后级联同步 profiles.department 文本（where department_id = p_id，兼容期双写一致）；'
  '成功写后写 audit_log（create/update，diff 含 before/after）；同级名称冲突转 23505 中文提示';

-- ---------------------------------------------------------------------------
-- 2. app.sync_profile_department：改名保护（保持绑定优先于文本→id 解析）
-- ---------------------------------------------------------------------------
create or replace function app.sync_profile_department()
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
    -- 改名保护（批次 3）：新文本与当前绑定部门（未删除）现名一致时保持绑定，
    -- 避免停用部门改名清空 id、跨父级同名 active 抢绑
    if old.department_id is not null then
      select d.name into v_name
      from public.departments d
      where d.id = old.department_id
        and d.status <> 'deleted';

      if v_name = new.department then
        return new;
      end if;
    end if;

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
  '改名保护（批次 3）：文本等于当前绑定部门（未删除）现名时保持绑定；'
  'pg_trigger_depth 守卫防嵌套';
