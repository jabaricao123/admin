-- 权限管理 · get_role_user_counts（access/004）pgTAP 测试
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构存在性 / admin 统计口径与守卫一致 / 非 active 行计入 / 停用角色仍返回 /
--       自定义角色计数 / public 包装与 app 实现一致 / 非 admin 与 anon 拒绝

begin;

select plan(13);

-- ===========================================================================
-- 0. 装置：1 个自定义角色（无用户）
-- ===========================================================================
insert into public.roles (id, name, code, is_builtin, description, status)
values (
  '44444444-4444-4444-4444-444444440004',
  '测试-计数自定义',
  'test_count_custom',
  false,
  null,
  'active'
);

-- ===========================================================================
-- 1. 结构存在性（3）
-- ===========================================================================
select has_function('app', 'get_role_user_counts', 'app.get_role_user_counts 存在');
select has_function('public', 'get_role_user_counts', 'public.get_role_user_counts 包装存在');
select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = 'get_role_user_counts'
      and p.proconfig @> array['search_path=""']
  ),
  'app.get_role_user_counts 的 search_path 固定为空'
);

-- ===========================================================================
-- 2. admin 统计口径（seed：admin/engineer/planner/buyer/quality 各 1 人，
--    supplier/customer 各 0 人）（2）
-- ===========================================================================
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select results_eq(
  $$ select role_code, user_count
       from public.get_role_user_counts()
      where role_code in ('admin','engineer','planner','buyer','quality','supplier','customer')
      order by role_code $$,
  $$ values
       ('admin'::text,    1::bigint),
       ('buyer'::text,    1::bigint),
       ('customer'::text, 0::bigint),
       ('engineer'::text, 1::bigint),
       ('planner'::text,  1::bigint),
       ('quality'::text,  1::bigint),
       ('supplier'::text, 0::bigint) $$,
  '7 内置角色用户数与 seed 实际一致'
);
select is(
  (select count(*) from public.get_role_user_counts()),
  8::bigint,
  '统计覆盖全部角色（7 内置 + 1 自定义测试夹具）'
);

-- ===========================================================================
-- 3. 停用角色仍返回计数行（2）
-- ===========================================================================
select is(
  (select (public.disable_role((select id from public.roles where code = 'supplier'))).status),
  'disabled',
  'supplier（0 用户）可停用'
);
select is(
  (
    select count(*)
    from public.get_role_user_counts()
    where role_code = 'supplier'
  ),
  1::bigint,
  '停用后的角色仍有统计行（UI 需展示 disabled 角色）'
);

-- ===========================================================================
-- 4. 非 active 用户照常计入（与 disable_role/delete_role 守卫口径一致）（1）
-- ===========================================================================
reset role;
update public.profiles
   set status = 'inactive'
 where id = '22222222-2222-2222-2222-222222220001';

set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select is(
  (
    select user_count
    from public.get_role_user_counts()
    where role_code = 'engineer'
  ),
  1::bigint,
  '已停用用户仍计入角色用户数（与守卫全量计数一致）'
);

-- ===========================================================================
-- 5. 自定义角色计数为 0（1）
-- ===========================================================================
select is(
  (
    select user_count
    from public.get_role_user_counts()
    where role_code = 'test_count_custom'
  ),
  0::bigint,
  '无用户自定义角色统计为 0'
);

-- ===========================================================================
-- 6. public 包装与 app 实现一致（1）
-- ===========================================================================
select results_eq(
  $$ select role_id, role_code, user_count
       from public.get_role_user_counts()
      order by role_code $$,
  $$ select role_id, role_code, user_count
       from app.get_role_user_counts()
      order by role_code $$,
  'public 包装与 app 实现返回一致'
);

-- ===========================================================================
-- 7. 越权拒绝：非 admin（planner）调 public / app 均拒绝（2）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220002","role":"authenticated"}';
set local role authenticated;

select throws_ok(
  $$ select * from public.get_role_user_counts() $$,
  '42501', '仅管理员可执行此操作',
  '非 admin 调 public.get_role_user_counts 被拒'
);
select throws_ok(
  $$ select * from app.get_role_user_counts() $$,
  '42501', '仅管理员可执行此操作',
  '非 admin 直接调 app.get_role_user_counts 被拒'
);

-- ===========================================================================
-- 8. anon 无执行权限（1）
-- ===========================================================================
reset role;
set local role anon;
select throws_ok(
  $$ select * from public.get_role_user_counts() $$,
  '42501', null,
  'anon 无 get_role_user_counts 执行权限'
);
reset role;

select * from finish();
rollback;
