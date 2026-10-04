-- 权限管理 · 安全默认修复：7 内置角色默认菜单授权 seed（access 批次 1 / 修复项 2）
--
-- 问题：visible_menus 对「可解析角色 + role_menu_grants 零记录」fail-open 返回全量
--   菜单（fallback=true），非 admin 角色（含外部 supplier/customer）在未配置授权时
--   默认可见全部侧边栏，与最小权限原则冲突。
-- 修复：为内置角色 seed 最小默认授权（granted_by=null 表示系统默认）：
--   - 内部角色（engineer/planner/buyer/quality）：工作台（概览/待办/通知）
--     + 组织架构图 + 站内信 + 发送记录 + 关于/版本 + 顶级分组（/org、/message、/system）；
--   - 外部角色（supplier/customer）：工作台 + 站内信 + 顶级分组 /message；
--   - admin 不 seed（visible_menus 对 admin 本就全量，不依赖 grants）。
-- 效果：非 admin 角色不再零授权 → visible_menus fallback=false → 仅见授权集；
--   fallback 机制保留，作为「角色尚未配置授权」的兜底。
-- 幂等：on conflict (role_id, menu_key) do nothing；不覆盖后续人工授权调整。
--
-- 依赖：20261004091000（menu_items / role_menu_grants）、20261004110000（visible_menus）。

-- ---------------------------------------------------------------------------
-- 1. 内部角色基础菜单（engineer / planner / buyer / quality，逐角色一段）
-- ---------------------------------------------------------------------------
insert into public.role_menu_grants (role_id, menu_key, granted_by)
select r.id, m.key, null
from public.roles r
cross join (
  select key
  from public.menu_items
  where key in (
    '/dashboard', '/dashboard/todos', '/dashboard/notifications',
    '/org', '/org/chart',
    '/message', '/message/inbox', '/message/history',
    '/system', '/system/about'
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
    '/dashboard', '/dashboard/todos', '/dashboard/notifications',
    '/org', '/org/chart',
    '/message', '/message/inbox', '/message/history',
    '/system', '/system/about'
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
    '/dashboard', '/dashboard/todos', '/dashboard/notifications',
    '/org', '/org/chart',
    '/message', '/message/inbox', '/message/history',
    '/system', '/system/about'
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
    '/dashboard', '/dashboard/todos', '/dashboard/notifications',
    '/org', '/org/chart',
    '/message', '/message/inbox', '/message/history',
    '/system', '/system/about'
  )
) m
where r.code = 'quality'
on conflict (role_id, menu_key) do nothing;

-- ---------------------------------------------------------------------------
-- 2. 外部角色最小菜单（supplier / customer，逐角色一段）
-- ---------------------------------------------------------------------------
insert into public.role_menu_grants (role_id, menu_key, granted_by)
select r.id, m.key, null
from public.roles r
cross join (
  select key
  from public.menu_items
  where key in ('/dashboard', '/message', '/message/inbox')
) m
where r.code = 'supplier'
on conflict (role_id, menu_key) do nothing;

insert into public.role_menu_grants (role_id, menu_key, granted_by)
select r.id, m.key, null
from public.roles r
cross join (
  select key
  from public.menu_items
  where key in ('/dashboard', '/message', '/message/inbox')
) m
where r.code = 'customer'
on conflict (role_id, menu_key) do nothing;
