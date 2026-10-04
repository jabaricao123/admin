-- 权限管理 · 报表菜单默认授权（report 批次 2 / 修复项 5）
-- 问题：20261005221000 为内置角色 seed 安全默认授权后（fallback=false），
--   非 admin 角色（engineer/planner/buyer/quality）看不到报表中心（/report 系列未授权）。
-- 修复：为 4 个内部角色补授报表菜单 5 项（顶级分组 /report + 4 叶子）；
--   supplier/customer 不授（外部角色保持最小菜单）。
-- 幂等：on conflict (role_id, menu_key) do nothing（沿用 20261005221000 模式，不覆盖人工调整）。
-- 依赖：20261004091000（menu_items / role_menu_grants）、20261005221000（安全默认 seed）。

-- ---------------------------------------------------------------------------
-- 1. 内部角色报表菜单（engineer / planner / buyer / quality，逐角色一段）
-- ---------------------------------------------------------------------------
insert into public.role_menu_grants (role_id, menu_key, granted_by)
select r.id, m.key, null
from public.roles r
cross join (
  select key
  from public.menu_items
  where key in (
    '/report',
    '/report/builtin',
    '/report/custom',
    '/report/exports',
    '/report/subscriptions'
  )
) m
where r.code = 'engineer'
on conflict (role_id, menu_key) do nothing;

insert into public.role_menu_grants (role_id, menu_key, granted_by)
select r.id, m.key, null
from public.roles r
cross join (
  select key
  from public.menu_items
  where key in (
    '/report',
    '/report/builtin',
    '/report/custom',
    '/report/exports',
    '/report/subscriptions'
  )
) m
where r.code = 'planner'
on conflict (role_id, menu_key) do nothing;

insert into public.role_menu_grants (role_id, menu_key, granted_by)
select r.id, m.key, null
from public.roles r
cross join (
  select key
  from public.menu_items
  where key in (
    '/report',
    '/report/builtin',
    '/report/custom',
    '/report/exports',
    '/report/subscriptions'
  )
) m
where r.code = 'buyer'
on conflict (role_id, menu_key) do nothing;

insert into public.role_menu_grants (role_id, menu_key, granted_by)
select r.id, m.key, null
from public.roles r
cross join (
  select key
  from public.menu_items
  where key in (
    '/report',
    '/report/builtin',
    '/report/custom',
    '/report/exports',
    '/report/subscriptions'
  )
) m
where r.code = 'quality'
on conflict (role_id, menu_key) do nothing;
