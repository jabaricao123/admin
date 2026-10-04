-- 权限管理 · 内置角色默认菜单授权 seed（access 批次 1 / 修复项 2）pgTAP 测试
-- 运行：supabase db reset && supabase test db
-- 覆盖：seed 结构（内部角色基础菜单 + 顶级分组；外部角色最小菜单；admin 不 seed；
--       granted_by=null）/ visible_menus 新语义（engineer 不再 fallback、只含授权集；
--       supplier/customer 仅 dashboard + inbox 相关；admin 仍全量 fallback=false）。
-- 说明：夹具仅在事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(22);

-- ===========================================================================
-- 1. seed 授权结构（7）
-- ===========================================================================
select is(
  (select count(*)
     from public.role_menu_grants g
     join public.roles r on r.id = g.role_id
    where r.code = 'engineer'
      and g.granted_by is null),
  15::bigint,
  'engineer 系统默认授权 15 条（granted_by=null，含报表菜单 5）'
);
select results_eq(
  $$ select g.menu_key
       from public.role_menu_grants g
       join public.roles r on r.id = g.role_id
      where r.code = 'engineer'
      order by g.menu_key $$,
  $$ values
       ('/dashboard'::text),
       ('/dashboard/notifications'),
       ('/dashboard/todos'),
       ('/message'),
       ('/message/history'),
       ('/message/inbox'),
       ('/org'),
       ('/org/chart'),
       ('/report'),
       ('/report/builtin'),
       ('/report/custom'),
       ('/report/exports'),
       ('/report/subscriptions'),
       ('/system'),
       ('/system/about') $$,
  'engineer 授权集 = 基础菜单 + 顶级分组 + 报表菜单（含完整祖先链）'
);
select is(
  (select count(*)
     from public.role_menu_grants g
     join public.roles r on r.id = g.role_id
    where r.code in ('engineer', 'planner', 'buyer', 'quality')
      and g.granted_by is null),
  60::bigint,
  '4 个内部角色系统默认授权共 60 条（各 15 条，含报表菜单）'
);
select results_eq(
  $$ select g.menu_key
       from public.role_menu_grants g
       join public.roles r on r.id = g.role_id
      where r.code = 'supplier'
      order by g.menu_key $$,
  $$ values ('/dashboard'::text), ('/message'), ('/message/inbox') $$,
  'supplier 授权集 = 工作台 + 站内信 + 顶级分组'
);
select results_eq(
  $$ select g.menu_key
       from public.role_menu_grants g
       join public.roles r on r.id = g.role_id
      where r.code = 'customer'
      order by g.menu_key $$,
  $$ values ('/dashboard'::text), ('/message'), ('/message/inbox') $$,
  'customer 授权集 = 工作台 + 站内信 + 顶级分组'
);
select is(
  (select count(*)
     from public.role_menu_grants g
     join public.roles r on r.id = g.role_id
    where r.code in ('supplier', 'customer')
      and g.granted_by is null),
  6::bigint,
  '外部角色系统默认授权共 6 条（各 3 条）'
);
select is(
  (select count(*)
     from public.role_menu_grants g
     join public.roles r on r.id = g.role_id
    where r.code = 'admin'),
  0::bigint,
  'admin 不 seed（visible_menus 对 admin 全量，不依赖 grants）'
);

-- ===========================================================================
-- 2. engineer：不再零授权兜底，只含授权集（4）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*) from public.visible_menus()),
  15::bigint,
  'engineer：恰见 15 条默认授权菜单（含报表菜单）'
);
select ok(
  (select bool_and(not fallback) from public.visible_menus()),
  'engineer：fallback=false（不再触发零授权兜底）'
);
select ok(
  exists (select 1 from public.visible_menus() where key = '/org/chart')
    and exists (select 1 from public.visible_menus() where key = '/dashboard/todos'),
  'engineer：含授权叶子 /org/chart、/dashboard/todos'
);
select ok(
  exists (select 1 from public.visible_menus() where key = '/report/builtin')
    and exists (select 1 from public.visible_menus() where key = '/report/subscriptions'),
  'engineer：含报表菜单 /report/builtin、/report/subscriptions'
);
select ok(
  not exists (select 1 from public.visible_menus() where key = '/org/users')
    and not exists (select 1 from public.visible_menus() where key = '/access/roles'),
  'engineer：不含未授权菜单 /org/users、/access/roles'
);

-- ===========================================================================
-- 3. 夹具（as postgres）：supplier / customer 用户
-- ===========================================================================
reset role;

insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
  ('d0000000-0000-4000-a000-000000000201', 'batch1-grant-supplier@example.com',
   '{"role":"supplier"}'::jsonb, '{"full_name":"默认授权-供应商"}'::jsonb),
  ('d0000000-0000-4000-a000-000000000202', 'batch1-grant-customer@example.com',
   '{"role":"customer"}'::jsonb, '{"full_name":"默认授权-客户"}'::jsonb);

-- ===========================================================================
-- 4. supplier：仅 dashboard + inbox 相关（4）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"d0000000-0000-4000-a000-000000000201","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*) from public.visible_menus()),
  3::bigint,
  'supplier：恰见 3 条菜单（工作台 + 站内信 + 顶级分组）'
);
select results_eq(
  $$ select key from public.visible_menus() order by key $$,
  $$ values ('/dashboard'::text), ('/message'), ('/message/inbox') $$,
  'supplier：key 集合 = /dashboard、/message、/message/inbox'
);
select ok(
  (select bool_and(not fallback) from public.visible_menus()),
  'supplier：fallback=false'
);
select ok(
  not exists (select 1 from public.visible_menus() where key = '/dashboard/todos')
    and not exists (select 1 from public.visible_menus() where key = '/org/chart')
    and not exists (select 1 from public.visible_menus() where key = '/system/about'),
  'supplier：不含内部基础菜单（待办/组织图/关于）'
);
select ok(
  not exists (select 1 from public.visible_menus() where key = '/report/builtin')
    and not exists (select 1 from public.visible_menus() where key = '/report'),
  'supplier：不含报表菜单（/report、/report/builtin）'
);

-- ===========================================================================
-- 5. customer：仅 dashboard + inbox 相关（2）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"d0000000-0000-4000-a000-000000000202","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*) from public.visible_menus()),
  3::bigint,
  'customer：恰见 3 条菜单（工作台 + 站内信 + 顶级分组）'
);
select ok(
  (select bool_and(not fallback) from public.visible_menus()),
  'customer：fallback=false'
);

-- ===========================================================================
-- 6. admin：仍全量且 fallback=false（3）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*) from public.visible_menus()),
  (select count(*) from public.menu_items),
  'admin：返回全量菜单（与注册表行数一致）'
);
select ok(
  (select bool_and(not fallback) from public.visible_menus()),
  'admin：fallback=false'
);
select is(
  (select count(distinct key) from public.visible_menus()),
  (select count(*) from public.visible_menus()),
  'admin：菜单 key 无重复'
);

reset role;
select * from finish();
rollback;
