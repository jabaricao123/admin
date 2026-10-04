-- 组织管理 · 部门删除拦截未删除岗位引用（org 数据层批次 3 · 修复项 3）
-- 背景：delete_department 只拦截「未删除子部门 + 在职人员」，部门下挂着岗位
--       （positions.department_id = p_id）时仍可逻辑删除，存量岗位失去部门锚点，
--       且后续同名部门重建会造成岗位归属歧义。
--
-- 语义：
--   1. create or replace app.delete_department（在 20261005180000 含 audit_log 的最新版
--      基础上）：删除前统计 positions 引用数（department_id = p_id 且 status <> 'deleted'；
--      当前 positions 无 deleted 状态，为防御性写法，未来引入软删除后自动生效）；
--   2. 引用数 > 0 拒绝并报「该部门下仍有 N 个岗位，无法删除」（errcode 22023）；
--   3. 校验顺序与提示：未删除子部门 → 岗位引用 → 在职人员（口径与既有一致，
--      department_id 精确匹配 + NULL 行文本兜底）；
--   4. 成功写后的 audit_log（delete，diff 含 before/after）原样保留。
--
-- 依赖：20261005180000（delete_department 含审计现状）、20261003214200（positions 表）。

-- ---------------------------------------------------------------------------
-- 1. app.delete_department：岗位引用拦截 + 审计保留
-- ---------------------------------------------------------------------------
create or replace function app.delete_department(p_id uuid)
returns public.departments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row       public.departments;
  v_before    public.departments;
  v_children  bigint;
  v_positions bigint;
  v_members   bigint;
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

  -- 未删除岗位引用拦截（批次 3；当前 positions 无 deleted 状态，防御性条件）
  select count(*) into v_positions
  from public.positions
  where department_id = p_id
    and status <> 'deleted';

  if v_positions > 0 then
    raise exception '该部门下仍有 % 个岗位，无法删除', v_positions using errcode = '22023';
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

  v_before := v_row;

  update public.departments
     set status     = 'deleted',
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  perform app.audit_log(
    'org', 'delete', 'department', v_row.id::text,
    jsonb_build_object('before', to_jsonb(v_before), 'after', to_jsonb(v_row))
  );

  return v_row;
end;
$$;

comment on function app.delete_department(uuid) is
  '部门逻辑删除 RPC（admin）：仅允许删空部门（无未删除子部门、无未删除岗位引用、无在职人员），'
  '按 department_id 统计（人员对 NULL 行文本兜底）；岗位引用拦截提示「该部门下仍有 N 个岗位」；'
  '成功写后写 audit_log（delete，diff 含 before/after）';
