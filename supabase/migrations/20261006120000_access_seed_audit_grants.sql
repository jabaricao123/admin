-- audit 批次 1 / 修复项 2：审计菜单默认授权补授（engineer/planner/buyer/quality）
--
-- 问题：20261005221000 为内置角色 seed 安全默认授权后（fallback=false），
--   非 admin 角色看不到审计中心（/audit 未授权），登录日志本人自查入口被菜单遮蔽；
--   但 /audit 下 operations/changes/compliance 仅 admin 可访问（页面守卫 403），
--   不应随本次补授进入非 admin 菜单。
-- 修复：为 4 个内部角色补授 /audit（顶级分组）+ /audit/logins（登录日志，本人自查视图）；
--   supplier/customer 不授（外部角色保持最小菜单）；
--   /audit/operations、/audit/changes、/audit/compliance 不授（admin 专属）。
-- 幂等：on conflict (role_id, menu_key) do nothing（沿用 20261005221000 模式，不覆盖人工调整）。
-- 依赖：20261004091000（menu_items / role_menu_grants）、20261005221000（安全默认 seed）。

-- ---------------------------------------------------------------------------
-- 1. 内部角色审计菜单（engineer / planner / buyer / quality，一次 INSERT 覆盖 4 角色）
-- ---------------------------------------------------------------------------
insert into public.role_menu_grants (role_id, menu_key, granted_by)
select r.id, m.key, null
from public.roles r
cross join (
  select key
  from public.menu_items
  where key in ('/audit', '/audit/logins')
) m
where r.code in ('engineer', 'planner', 'buyer', 'quality')
on conflict (role_id, menu_key) do nothing;
