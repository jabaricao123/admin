-- 权限管理 · assign_role + 存量角色迁移（access/003）pgTAP 测试
-- 运行：supabase db reset && supabase test db
-- 覆盖：role_id 列/外键/索引与回填完整性 / 双写触发器两向同步与置空回填 /
--       assign_role 越权（authenticated/anon）与 admin 正常路径 / 自保护 /
--       不存在、停用、自定义角色与空标识拒绝 / 审计摘要写入 /
--       admin_update_profile p_role 兼容与废弃 warning / handle_new_user 双列一致 /
--       current_role role_id 优先与枚举兜底 / role 与 role_id 列级 UPDATE 收口。
-- 说明：pgTAP 无「断言 warning」原语，废弃 warning 以函数源包含 raise warning 断言。

begin;

select plan(42);

-- ---------------------------------------------------------------------------
-- 夹具（as postgres）：自定义 active 角色（兼容期应在 assign_role 拒绝）
-- ---------------------------------------------------------------------------
insert into public.roles (id, name, code, is_builtin, description, status) values
  ('44444444-4444-4444-4444-444444440005', '测试-自定义在用', 'test_assign_custom', false, null, 'active');

-- ===========================================================================
-- 1. 结构存在性（9）
-- ===========================================================================
select has_column('public', 'profiles', 'role_id', 'profiles.role_id 列存在');
select ok(
  exists (
    select 1
    from pg_constraint
    where conrelid = 'public.profiles'::regclass
      and contype = 'f'
      and conname = 'profiles_role_id_fkey'
  ),
  'role_id 外键 → roles.id 存在'
);
select has_index('public', 'profiles', 'profiles_role_id_idx', 'role_id 索引存在');
select has_function('app', 'assign_role', array['uuid', 'text'], 'app.assign_role 存在');
select has_function('public', 'assign_role', array['uuid', 'text'], 'public.assign_role 包装存在');
select has_function('app', 'sync_profile_role', 'app.sync_profile_role 存在');
select has_trigger('public', 'profiles', 'profiles_sync_role', '双写触发器存在');
select ok(
  (select count(*) = 2
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname in ('assign_role', 'sync_profile_role')
      and p.prosecdef
      and p.proconfig = array['search_path=""']),
  'app 侧 assign_role/sync_profile_role：security definer + search_path 固定为空'
);
select ok(
  (select count(*) = 1
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'assign_role'
      and p.prosecdef
      and p.proconfig = array['search_path=""']),
  'public.assign_role 包装：security definer + search_path 固定为空'
);

-- ===========================================================================
-- 2. 回填完整性（3）
-- ===========================================================================
select is(
  (select count(*) from public.profiles where role_id is null),
  0::bigint,
  '存量档案 role_id 全部回填（无 NULL）'
);
select is(
  (select count(*)
     from public.profiles p
     join public.roles r on r.id = p.role_id
    where r.code is distinct from p.role::text),
  0::bigint,
  'role_id 与 role 枚举逐行一致'
);
select is(
  (select count(*)
     from pg_catalog.unnest(pg_catalog.enum_range(null::public.user_role)) e
     join public.roles r on r.code = e::text),
  7::bigint,
  '7 个枚举值全部映射到 roles 行'
);

-- ===========================================================================
-- 3. 双写触发器两向同步（4；as postgres 直写表）
-- ===========================================================================
update public.profiles
   set role_id = (select id from public.roles where code = 'planner')
 where id = '22222222-2222-2222-2222-222222220001';
select is(
  (select role from public.profiles where id = '22222222-2222-2222-2222-222222220001'),
  'planner'::public.user_role,
  '改 role_id 回写 role 枚举'
);

update public.profiles
   set role = 'quality'::public.user_role
 where id = '22222222-2222-2222-2222-222222220001';
select is(
  (select role_id from public.profiles where id = '22222222-2222-2222-2222-222222220001'),
  (select id from public.roles where code = 'quality'),
  '改 role 枚举回写 role_id'
);

update public.profiles
   set role_id = null
 where id = '22222222-2222-2222-2222-222222220001';
select is(
  (select role_id from public.profiles where id = '22222222-2222-2222-2222-222222220001'),
  (select id from public.roles where code = 'quality'),
  'role_id 置空被枚举回填（兼容期双写不变量）'
);

update public.profiles
   set role_id = (select id from public.roles where code = 'engineer')
 where id = '22222222-2222-2222-2222-222222220001';
select is(
  (select role from public.profiles where id = '22222222-2222-2222-2222-222222220001'),
  'engineer'::public.user_role,
  '夹具还原：engineer/engineer'
);

-- ===========================================================================
-- 4. 越权：非 admin / anon（3）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;

select throws_ok(
  $$ select public.assign_role('22222222-2222-2222-2222-222222220002', 'buyer') $$,
  '42501', '仅管理员可执行此操作',
  '非 admin 调 public.assign_role 被拒'
);
select throws_ok(
  $$ select app.assign_role('22222222-2222-2222-2222-222222220002', 'buyer') $$,
  '42501', '仅管理员可执行此操作',
  '非 admin 直调 app.assign_role 被拒'
);

reset role;
set local role anon;
select throws_ok(
  $$ select public.assign_role('22222222-2222-2222-2222-222222220002', 'buyer') $$,
  '42501', null,
  'anon 无 assign_role 执行权限'
);

-- ===========================================================================
-- 5. assign_role：admin 正常路径（4）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select is(
  (public.assign_role('22222222-2222-2222-2222-222222220002', 'buyer')).role,
  'buyer'::public.user_role,
  'admin 经 RPC 分配角色（返回值同步枚举）'
);
select is(
  (select role_id from public.profiles where id = '22222222-2222-2222-2222-222222220002'),
  (select id from public.roles where code = 'buyer'),
  'assign_role 写入 role_id'
);
select is(
  (select updated_by from public.profiles where id = '22222222-2222-2222-2222-222222220002'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'assign_role 记录 updated_by'
);
select is(
  (select count(*)
     from public.audit_operations
    where module = 'access'
      and action = 'assign'
      and object_type = 'profile_role'
      and object_id = '22222222-2222-2222-2222-222222220002'
      and diff ->> 'before' = 'planner'
      and diff ->> 'after' = 'buyer'),
  1::bigint,
  'assign_role 写审计摘要（before/after）'
);

-- ===========================================================================
-- 6. assign_role：边界拒绝（6）
-- ===========================================================================
select throws_ok(
  $$ select public.assign_role('11111111-1111-1111-1111-111111111111', 'engineer') $$,
  '22023', '不能修改自己的管理员角色',
  '不能修改自己的角色（沿用 admin_update_profile 自保护语义）'
);
select throws_ok(
  $$ select public.assign_role('22222222-2222-2222-2222-222222220002', 'ghost_role') $$,
  'P0002', '角色不存在：ghost_role',
  '不存在的角色被拒'
);
select throws_ok(
  $$ select public.assign_role('00000000-0000-4000-c000-000000000099', 'buyer') $$,
  'P0002', '用户不存在：00000000-0000-4000-c000-000000000099',
  '目标用户不存在被拒'
);
select public.disable_role((select id from public.roles where code = 'supplier'));
select throws_ok(
  $$ select public.assign_role('22222222-2222-2222-2222-222222220002', 'supplier') $$,
  '22023', '角色已停用，无法分配：supplier',
  '停用角色被拒'
);
select throws_ok(
  $$ select public.assign_role('22222222-2222-2222-2222-222222220002', 'test_assign_custom') $$,
  '22023', '角色不可分配（兼容期仅支持内置角色）：test_assign_custom',
  '自定义角色兼容期被拒（role 枚举无法表达）'
);
select throws_ok(
  $$ select public.assign_role('22222222-2222-2222-2222-222222220002', '') $$,
  '22023', '角色标识不能为空',
  '空角色标识被拒'
);

-- ===========================================================================
-- 7. admin_update_profile 收窄兼容（5）
-- ===========================================================================
select is(
  (public.admin_update_profile(
     '22222222-2222-2222-2222-222222220003', null, null, 'quality'::public.user_role, null
   )).role,
  'quality'::public.user_role,
  'admin_update_profile 传 p_role 兼容生效（内部转调 assign_role）'
);
select is(
  (select role_id from public.profiles where id = '22222222-2222-2222-2222-222222220003'),
  (select id from public.roles where code = 'quality'),
  '兼容路径同步写 role_id'
);
select is(
  (public.admin_update_profile(
     '22222222-2222-2222-2222-222222220003', '改名测试', '测试部', null, null
   )).full_name,
  '改名测试',
  '姓名/部门/状态仍由 admin_update_profile 负责'
);

reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;
select throws_ok(
  $$ select public.admin_update_profile('22222222-2222-2222-2222-222222220003', null, null, 'buyer', null) $$,
  '42501', '仅管理员可执行此操作',
  '非 admin 调 admin_update_profile 被拒'
);

reset role;
select ok(
  (select p.prosrc like '%raise warning%' and p.prosrc like '%已废弃%'
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'admin_update_profile'
      and p.pronargs = 5),
  'admin_update_profile 保留 p_role 并 raise warning（pgTAP 无 warning 断言语，查函数源）'
);

-- ===========================================================================
-- 8. handle_new_user 双列一致（3；as postgres 经 auth.users 触发器）
-- ===========================================================================
insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-4000-b000-000000000001', 'assign-hn-1@example.com', '{"role":"buyer"}'::jsonb),
  ('00000000-0000-4000-b000-000000000002', 'assign-hn-2@example.com', '{"role":"hacker"}'::jsonb),
  ('00000000-0000-4000-b000-000000000003', 'assign-hn-3@example.com', null);

select results_eq(
  $$ select p.role::text, r.code::text
       from public.profiles p
       join public.roles r on r.id = p.role_id
      where p.id = '00000000-0000-4000-b000-000000000001' $$,
  $$ values ('buyer'::text, 'buyer'::text) $$,
  'raw_app_meta_data.role=buyer：role 与 role_id 一致'
);
select results_eq(
  $$ select p.role::text, r.code::text
       from public.profiles p
       join public.roles r on r.id = p.role_id
      where p.id = '00000000-0000-4000-b000-000000000002' $$,
  $$ values ('engineer'::text, 'engineer'::text) $$,
  '非法 meta role 回退 engineer：role 与 role_id 一致'
);
select results_eq(
  $$ select p.role::text, r.code::text
       from public.profiles p
       join public.roles r on r.id = p.role_id
      where p.id = '00000000-0000-4000-b000-000000000003' $$,
  $$ values ('engineer'::text, 'engineer'::text) $$,
  '无 meta role 默认 engineer：role 与 role_id 一致'
);

-- ===========================================================================
-- 9. current_role：role_id 优先 + 枚举兜底（3）
--    装置：临时停用双写触发器制造不一致（事务内回滚）
-- ===========================================================================
alter table public.profiles disable trigger profiles_sync_role;

update public.profiles
   set role = 'engineer'::public.user_role,
       role_id = (select id from public.roles where code = 'quality')
 where id = '22222222-2222-2222-2222-222222220001';

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;
select is(
  app.current_role(),
  'quality'::public.user_role,
  'current_role 优先读 role_id（枚举故意滞后）'
);

reset role;
update public.profiles
   set role = 'engineer'::public.user_role,
       role_id = null
 where id = '22222222-2222-2222-2222-222222220001';

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;
select is(
  app.current_role(),
  'engineer'::public.user_role,
  'current_role 在 role_id 为空时回退枚举列'
);

reset role;
alter table public.profiles enable trigger profiles_sync_role;
update public.profiles
   set role_id = (select id from public.roles where code = 'engineer')
 where id = '22222222-2222-2222-2222-222222220001';
select is(
  (select role from public.profiles where id = '22222222-2222-2222-2222-222222220001'),
  'engineer'::public.user_role,
  '恢复触发器后双写继续生效'
);

-- ===========================================================================
-- 10. 列级 UPDATE 收口：role / role_id 不可被 authenticated 直改（2）
-- ===========================================================================
select ok(
  not has_column_privilege('authenticated', 'public.profiles', 'role', 'UPDATE'),
  'authenticated 无 role 列 UPDATE 权限'
);
select ok(
  not has_column_privilege('authenticated', 'public.profiles', 'role_id', 'UPDATE'),
  'authenticated 无 role_id 列 UPDATE 权限'
);

select * from finish();
rollback;
