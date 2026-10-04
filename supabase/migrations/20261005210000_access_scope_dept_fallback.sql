-- 权限管理 · 数据范围：所属部门非 active 时回退「无部门」语义（access 批次 2 / 修复项 1）
--
-- 问题：profiles.department_id 指向已删除（deleted）或已停用（disabled）部门时，
--   app.resolve_user_department 仍返回该部门 id，下游出现两种错误可见性：
--   - deleted：scope_dept_ids_for 过滤 deleted 后部门集为空，scope_user_ids_for
--     按部门过滤得到空成员集 → 用户看到「空集」而不是「仅本人」；
--   - disabled：dept 范围会把停用部门当作可见部门返回（status <> 'deleted'），
--     停用只是隐藏于新编辑下拉，不应继续作为数据范围锚点。
-- 修复：department_id 存在但指向非 active 部门时视同无部门（返回 null）；
--   department_id 为空的历史行保留「按部门名 active 精确匹配」兜底（org/007 回填规则）。
--   下游无需改动，自然落入既有语义：
--   - app.scope_user_ids_for：无部门 + dept/dept_tree → 仅本人；
--   - app.scope_dept_ids_for：无部门 → 空集；
--   - app.preview_scope：department_id/department_name 展示为空（与解析一致）。
--
-- 依赖：20261004170000（函数现状）、20261003205414（departments.status 枚举）。

create or replace function app.resolve_user_department(p_user_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p.department_id is not null then
      -- department_id 已设置：必须指向 active 部门；deleted/disabled 视同无部门
      (
        select d.id
        from public.departments d
        where d.id = p.department_id
          and d.status = 'active'
      )
    else
      -- department_id 为空的历史行：按部门名 active 精确匹配兜底
      -- （多匹配取 sort_order 最小、id 兜底）
      (
        select d.id
        from public.departments d
        where d.name = p.department
          and d.status = 'active'
        order by d.sort_order, d.id
        limit 1
      )
  end
  from public.profiles p
  where p.id = p_user_id
$$;

comment on function app.resolve_user_department(uuid) is
  '解析用户所属部门 id：department_id 优先且必须为 active 部门（deleted/disabled 视同无部门）；'
  'department_id 为空的历史行按部门名 active 精确匹配兜底';
