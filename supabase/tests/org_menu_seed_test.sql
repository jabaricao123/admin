-- pgTAP：org/012 — /org/* 菜单登记（access/005 seed 断言）
-- 运行：supabase db reset && supabase test db
-- 覆盖：4 条 /org/* 路由级菜单存在且与 seed 逐字段一致（key=route、parent_key=/org、
--       module=org、label、sort_order 递增）；顶级 /org 存在；旧路径 /settings/users
--       不登记；非 admin 登录可见（数据驱动 sidebar 消费）；
--       register_menu_item 幂等重申无重复行。
-- 说明：/org/* 四条路由由 access/005 seed 全量登记，本工单不需补按钮级 key。

begin;

select plan(15);

-- ===========================================================================
-- 1. 顶级 /org（3）
-- ===========================================================================
select is(
  (select module from public.menu_items where key = '/org'),
  'org',
  '顶级菜单 /org 存在且 module=org'
);
select is(
  (select route from public.menu_items where key = '/org'),
  '/org',
  '顶级 /org 的 route 与 key 一致'
);
select is(
  (select parent_key from public.menu_items where key = '/org'),
  null,
  '顶级 /org 的 parent_key 为 NULL'
);

-- ===========================================================================
-- 2. 4 条路由级菜单与 seed 逐字段一致（2）
-- ===========================================================================
select results_eq(
  $$ select key, parent_key, module, label, route, sort_order
       from public.menu_items
      where parent_key = '/org'
        and key like '/org/%'
      order by sort_order $$,
  $$ values
       ('/org/users',       '/org', 'org', '用户管理',   '/org/users',       10),
       ('/org/departments', '/org', 'org', '部门管理',   '/org/departments', 20),
       ('/org/positions',   '/org', 'org', '岗位管理',   '/org/positions',   30),
       ('/org/chart',       '/org', 'org', '组织架构图', '/org/chart',       40) $$,
  '/org 下 4 条路由级菜单与 seed 逐字段一致'
);
select is(
  (select array_agg(sort_order order by sort_order)
     from public.menu_items
    where parent_key = '/org'
      and key like '/org/%'),
  array[10, 20, 30, 40],
  '4 条路由 sort_order 为 10/20/30/40'
);

-- ===========================================================================
-- 3. 逐条存在性与 key=route 约定（6）
-- ===========================================================================
select ok(
  exists (select 1 from public.menu_items where key = '/org/users'),
  '/org/users 已登记'
);
select ok(
  exists (select 1 from public.menu_items where key = '/org/departments'),
  '/org/departments 已登记'
);
select ok(
  exists (select 1 from public.menu_items where key = '/org/positions'),
  '/org/positions 已登记'
);
select ok(
  exists (select 1 from public.menu_items where key = '/org/chart'),
  '/org/chart 已登记'
);
select is(
  (select count(*)
     from public.menu_items
    where parent_key = '/org'
      and key like '/org/%'
      and key = route),
  4::bigint,
  '4 条路由满足路由级 key=route 约定'
);
select is(
  (select count(*)
     from public.menu_items
    where parent_key = '/org'
      and key like '/org/%'),
  4::bigint,
  '/org 下无多余路由级菜单'
);

-- ===========================================================================
-- 4. 旧路径不登记（1）
-- ===========================================================================
select ok(
  not exists (select 1 from public.menu_items where key = '/settings/users'),
  '旧路径 /settings/users 未登记（301 迁移后仅 /org/users）'
);

-- ===========================================================================
-- 5. 非 admin 登录可见（1）
-- ===========================================================================
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*)
     from public.menu_items
    where parent_key = '/org'
      and key like '/org/%'),
  4::bigint,
  '非 admin 登录可见 /org 下 4 条菜单（sidebar 数据源）'
);

-- ===========================================================================
-- 6. register_menu_item 幂等重申（2）
-- ===========================================================================
reset role;

select is(
  (select (app.register_menu_item(
     '/org/chart', '/org', 'org', '组织架构图', '/org/chart', 40)).key),
  '/org/chart',
  'register_menu_item 重申 /org/chart 幂等返回既有 key'
);
select is(
  (select count(*)
     from public.menu_items
    where parent_key = '/org'
      and key like '/org/%'),
  4::bigint,
  '重申后无重复行（仍 4 条）'
);

select * from finish();
rollback;
