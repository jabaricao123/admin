-- 权限管理 · visible_menus RPC（access/006）pgTAP 测试
-- 运行：supabase db reset && supabase test db
-- 覆盖：函数存在性 / SECURITY DEFINER + search_path 固定 / GRANT（authenticated 有、anon 无）/
--       admin 全量且 fallback=false / 其他角色零授权 fail-open 全量且 fallback=true /
--       部分授权仅回授权集 + 祖先链且 fallback=false（叶子上溯；仅授权顶层不带出子级）/
--       无角色（档案停用）fail-closed 空集 / public 包装与 app 实现一致 / anon 调用被拒。
-- 说明：夹具（授权、停用档案）只在事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(26);

-- ===========================================================================
-- 1. 函数存在性、SECURITY DEFINER / search_path、GRANT（8）
-- ===========================================================================
select has_function('app', 'visible_menus', 'app.visible_menus 存在');
select has_function('public', 'visible_menus', 'public.visible_menus 包装存在');

select ok(
  (select count(*) = 1
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = 'visible_menus'
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  'app.visible_menus：security definer + search_path 固定为空'
);
select ok(
  (select count(*) = 1
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'visible_menus'
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  'public.visible_menus 包装：security definer + search_path 固定为空'
);

select ok(
  has_function_privilege('authenticated', 'app.visible_menus()', 'EXECUTE'),
  'authenticated 可执行 app.visible_menus'
);
select ok(
  has_function_privilege('authenticated', 'public.visible_menus()', 'EXECUTE'),
  'authenticated 可执行 public.visible_menus'
);
select ok(
  not has_function_privilege('anon', 'app.visible_menus()', 'EXECUTE'),
  'anon 无 app.visible_menus 执行权'
);
select ok(
  not has_function_privilege('anon', 'public.visible_menus()', 'EXECUTE'),
  'anon 无 public.visible_menus 执行权'
);

-- ===========================================================================
-- 2. admin：全量菜单，fallback=false（3）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*) from public.visible_menus()),
  (select count(*) from public.menu_items),
  'admin：返回全量菜单（与注册表行数一致）'
);
select is(
  (select count(distinct key) from public.visible_menus()),
  (select count(*) from public.visible_menus()),
  'admin：菜单 key 无重复'
);
select results_eq(
  $$ select key, parent_key, module, label, route, sort_order, fallback
       from public.visible_menus()
      order by sort_order, key $$,
  $$ select key, parent_key, module, label, route, sort_order, false
       from public.menu_items
      order by sort_order, key $$,
  'admin：全量字段与注册表一致且 fallback=false'
);

-- ===========================================================================
-- 3. 其他角色零授权：fail-open 全量 + fallback=true（3）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*)
     from public.role_menu_grants g
     join public.roles r on r.id = g.role_id
    where r.code = 'engineer'),
  0::bigint,
  '前置：engineer 零授权记录'
);
select is(
  (select count(*) from public.visible_menus()),
  (select count(*) from public.menu_items),
  '零授权角色 fail-open：返回全量菜单'
);
select results_eq(
  $$ select key, fallback from public.visible_menus() order by key $$,
  $$ select key, true from public.menu_items order by key $$,
  '零授权角色：全量且 fallback=true'
);

-- ===========================================================================
-- 4. 部分授权：只回授权集 + 祖先链，fallback=false（7）
--    planner 被授予叶子 /org/users + /system/jobs，另单独验证「仅授权顶层」。
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select is(
  (select (public.grant_menu(
     (select id from public.roles where code = 'planner'), '/org/users')).menu_key),
  '/org/users',
  '装置：planner 被授予叶子 /org/users'
);
select is(
  (select (public.grant_menu(
     (select id from public.roles where code = 'planner'), '/system/jobs')).menu_key),
  '/system/jobs',
  '装置：planner 被授予叶子 /system/jobs'
);

reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220002","role":"authenticated"}';
set local role authenticated;

select results_eq(
  $$ select key, parent_key, fallback
       from public.visible_menus()
      order by key $$,
  $$ values
       ('/org'::text,         null::text,  false),
       ('/org/users',         '/org',      false),
       ('/system',            null,        false),
       ('/system/jobs',       '/system',   false) $$,
  '部分授权：仅回授权集 + 祖先链（不含未授权兄弟），fallback=false'
);
select is(
  (select count(*) from public.visible_menus()),
  4::bigint,
  '部分授权：结果恰为 4 条（2 授权 + 2 祖先）'
);
select ok(
  (select bool_and(not fallback) from public.visible_menus()),
  '部分授权：全部 fallback=false'
);

reset role;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select is(
  (select (public.grant_menu(
     (select id from public.roles where code = 'planner'), '/approval')).menu_key),
  '/approval',
  '装置：planner 额外被授予顶层 /approval'
);

reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220002","role":"authenticated"}';
set local role authenticated;

select results_eq(
  $$ select key from public.visible_menus() order by key $$,
  $$ values
       ('/approval'::text),
       ('/org'),
       ('/org/users'),
       ('/system'),
       ('/system/jobs') $$,
  '仅授权顶层：只回顶层本身，不带出未授权子级'
);

-- ===========================================================================
-- 5. 无角色：fail-closed 空集（2）
-- ===========================================================================
reset role;
update public.profiles
   set status = 'inactive'
 where id = '22222222-2222-2222-2222-222222220003';

select is(
  (select status from public.profiles where id = '22222222-2222-2222-2222-222222220003'),
  'inactive'::public.profile_status,
  '装置：buyer 档案停用（current_role 为空）'
);

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220003","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*) from public.visible_menus()),
  0::bigint,
  '无角色（档案停用）：fail-closed 返回空集'
);

-- ===========================================================================
-- 6. public 薄包装与 app 实现结果一致（1）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;

select results_eq(
  $$ select key, fallback from app.visible_menus() order by key $$,
  $$ select key, fallback from public.visible_menus() order by key $$,
  'public 薄包装与 app 实现结果一致'
);

-- ===========================================================================
-- 7. anon 调用被拒（2）
-- ===========================================================================
reset role;
set local role anon;

select throws_ok(
  $$ select * from public.visible_menus() $$,
  '42501', null,
  'anon 调 public.visible_menus 被拒（无 GRANT）'
);
select throws_ok(
  $$ select * from app.visible_menus() $$,
  '42501', null,
  'anon 调 app.visible_menus 被拒（无 GRANT）'
);

reset role;
select * from finish();
rollback;
