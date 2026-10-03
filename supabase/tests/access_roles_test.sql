-- 权限管理 · roles（access/001 表 + access/002 RLS/RPC）pgTAP 测试
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构存在性 / 7 内置角色 seed / 内置删改 DB 兜底保护 / 越权直写与越权 RPC /
--       anon 无路径 / 读范围（active vs admin 全量）/ 管理 RPC 正常与边界 / 审计摘要

begin;

select plan(65);

-- ===========================================================================
-- 1. 结构存在性（17）
-- ===========================================================================
select has_table('public', 'roles', 'roles 表存在');
select has_view('public', 'roles_v', 'roles_v 视图存在');
select has_column('public', 'roles', 'id', 'id 列存在');
select has_column('public', 'roles', 'is_builtin', 'is_builtin 列存在');
select col_is_pk('public', 'roles', 'id', 'id 为主键');
select ok(
  exists (
    select 1
    from pg_constraint
    where conrelid = 'public.roles'::regclass
      and contype = 'u'
      and conname = 'roles_code_key'
  ),
  'code 唯一约束存在'
);
select is(
  (select relrowsecurity from pg_class where oid = 'public.roles'::regclass),
  true,
  'roles 已启用 RLS'
);
select has_function('app', 'upsert_role', array['uuid', 'text', 'text', 'text', 'text'], 'app.upsert_role 存在');
select has_function('app', 'disable_role', array['uuid'], 'app.disable_role 存在');
select has_function('app', 'enable_role', array['uuid'], 'app.enable_role 存在');
select has_function('app', 'delete_role', array['uuid'], 'app.delete_role 存在');
select has_function('public', 'upsert_role', array['uuid', 'text', 'text', 'text', 'text'], 'public.upsert_role 包装存在');
select has_function('public', 'disable_role', array['uuid'], 'public.disable_role 包装存在');
select has_function('public', 'enable_role', array['uuid'], 'public.enable_role 包装存在');
select has_function('public', 'delete_role', array['uuid'], 'public.delete_role 包装存在');
select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = 'upsert_role'
      and p.proconfig @> array['search_path=""']
  ),
  'app.upsert_role 的 search_path 固定为空'
);
select has_trigger('public', 'roles', 'roles_protect_builtin', '内置保护触发器存在');

-- ===========================================================================
-- 2. 7 内置角色 seed（1）
-- ===========================================================================
select results_eq(
  $$ select code, name, is_builtin, status
       from public.roles
      where is_builtin
      order by code $$,
  $$ values
       ('admin'::text,    '系统管理员'::text, true, 'active'::text),
       ('buyer'::text,    '采购员'::text,     true, 'active'::text),
       ('customer'::text, '客户'::text,       true, 'active'::text),
       ('engineer'::text, '工程师'::text,     true, 'active'::text),
       ('planner'::text,  '计划员'::text,     true, 'active'::text),
       ('quality'::text,  '质检员'::text,     true, 'active'::text),
       ('supplier'::text, '供应商'::text,     true, 'active'::text) $$,
  '7 个内置角色 seed 完整（对齐 user_role 枚举）'
);

-- ===========================================================================
-- 3. 内置保护 DB 兜底：全部 7 值均不可删除 / 不可改 code（15）
--    postgres 超级用户直写也会被触发器拒绝（pgTAP 覆盖全部 7 值）
-- ===========================================================================
select throws_ok(
  $$ delete from public.roles where code = 'admin' $$,
  '22023', '内置角色不可删除：admin', '内置角色 admin 删除被拒（DB 兜底）'
);
select throws_ok(
  $$ update public.roles set code = 'admin_x' where code = 'admin' $$,
  '22023', '内置角色不可修改标识：admin', '内置角色 admin 改 code 被拒（DB 兜底）'
);
select throws_ok(
  $$ delete from public.roles where code = 'buyer' $$,
  '22023', '内置角色不可删除：buyer', '内置角色 buyer 删除被拒（DB 兜底）'
);
select throws_ok(
  $$ update public.roles set code = 'buyer_x' where code = 'buyer' $$,
  '22023', '内置角色不可修改标识：buyer', '内置角色 buyer 改 code 被拒（DB 兜底）'
);
select throws_ok(
  $$ delete from public.roles where code = 'customer' $$,
  '22023', '内置角色不可删除：customer', '内置角色 customer 删除被拒（DB 兜底）'
);
select throws_ok(
  $$ update public.roles set code = 'customer_x' where code = 'customer' $$,
  '22023', '内置角色不可修改标识：customer', '内置角色 customer 改 code 被拒（DB 兜底）'
);
select throws_ok(
  $$ delete from public.roles where code = 'engineer' $$,
  '22023', '内置角色不可删除：engineer', '内置角色 engineer 删除被拒（DB 兜底）'
);
select throws_ok(
  $$ update public.roles set code = 'engineer_x' where code = 'engineer' $$,
  '22023', '内置角色不可修改标识：engineer', '内置角色 engineer 改 code 被拒（DB 兜底）'
);
select throws_ok(
  $$ delete from public.roles where code = 'planner' $$,
  '22023', '内置角色不可删除：planner', '内置角色 planner 删除被拒（DB 兜底）'
);
select throws_ok(
  $$ update public.roles set code = 'planner_x' where code = 'planner' $$,
  '22023', '内置角色不可修改标识：planner', '内置角色 planner 改 code 被拒（DB 兜底）'
);
select throws_ok(
  $$ delete from public.roles where code = 'quality' $$,
  '22023', '内置角色不可删除：quality', '内置角色 quality 删除被拒（DB 兜底）'
);
select throws_ok(
  $$ update public.roles set code = 'quality_x' where code = 'quality' $$,
  '22023', '内置角色不可修改标识：quality', '内置角色 quality 改 code 被拒（DB 兜底）'
);
select throws_ok(
  $$ delete from public.roles where code = 'supplier' $$,
  '22023', '内置角色不可删除：supplier', '内置角色 supplier 删除被拒（DB 兜底）'
);
select throws_ok(
  $$ update public.roles set code = 'supplier_x' where code = 'supplier' $$,
  '22023', '内置角色不可修改标识：supplier', '内置角色 supplier 改 code 被拒（DB 兜底）'
);

select throws_ok(
  $$ update public.roles set is_builtin = false where code = 'admin' $$,
  '22023', '角色内置标记不可修改：admin',
  '内置角色翻转 is_builtin 被拒（防绕过保护）'
);

-- ===========================================================================
-- 4. 越权：非 admin 直写表 / 调用管理 RPC（7）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;

select throws_ok(
  $$ insert into public.roles (name, code) values ('越权新增', 'evil_role') $$,
  '42501', null, '非 admin 表级 INSERT 被拒'
);
select throws_ok(
  $$ update public.roles set name = '越权改名' where code = 'engineer' $$,
  '42501', null, '非 admin 表级 UPDATE 被拒'
);
select throws_ok(
  $$ delete from public.roles where code = 'supplier' $$,
  '42501', null, '非 admin 表级 DELETE 被拒'
);
select throws_ok(
  $$ select public.upsert_role(null, '越权', 'evil_role', null, 'active') $$,
  '42501', '仅管理员可执行此操作', '非 admin 调 upsert_role 被拒'
);
select throws_ok(
  $$ select public.disable_role((select id from public.roles where code = 'supplier')) $$,
  '42501', '仅管理员可执行此操作', '非 admin 调 disable_role 被拒'
);
select throws_ok(
  $$ select public.enable_role((select id from public.roles where code = 'supplier')) $$,
  '42501', '仅管理员可执行此操作', '非 admin 调 enable_role 被拒'
);
select throws_ok(
  $$ select public.delete_role((select id from public.roles where code = 'supplier')) $$,
  '42501', '仅管理员可执行此操作', '非 admin 调 delete_role 被拒'
);

-- ===========================================================================
-- 5. anon 无任何路径（2）
-- ===========================================================================
reset role;
set local role anon;
select throws_ok(
  $$ select count(*) from public.roles $$,
  '42501', null, 'anon 无 roles 读取权限'
);
select throws_ok(
  $$ select public.upsert_role(null, '越权', 'evil_role', null, 'active') $$,
  '42501', null, 'anon 无管理 RPC 执行权限'
);
reset role;

-- ===========================================================================
-- 6. 读范围：普通用户仅 active，admin 全量（5）
--    装置：1 个 active + 1 个 disabled 自定义角色
-- ===========================================================================
insert into public.roles (id, name, code, is_builtin, description, status)
values
  ('44444444-4444-4444-4444-444444440001', '测试-自定义在用', 'test_custom_a', false, null, 'active'),
  ('44444444-4444-4444-4444-444444440002', '测试-自定义停用', 'test_custom_d', false, null, 'disabled');

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*) from public.roles),
  8::bigint,
  'engineer 可见 7 内置 + 1 active 自定义角色'
);
select is(
  (select count(*) from public.roles where code = 'test_custom_d'),
  0::bigint,
  'engineer 不可见 disabled 自定义角色'
);
select is(
  (select count(*) from public.roles_v),
  8::bigint,
  'roles_v 对所有登录用户同样过滤 disabled'
);

reset role;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*) from public.roles),
  9::bigint,
  'admin 可见全部角色（含 disabled）'
);
select is(
  (select count(*) from public.roles_v where status = 'disabled'),
  1::bigint,
  'roles_v 对 admin 可见 disabled 角色'
);

-- ===========================================================================
-- 7. 管理 RPC：admin 正常路径与边界（14）
-- ===========================================================================
select is(
  (select (public.upsert_role(null, '测试-角色A', 'test_role_a', '说明A', 'active')).code),
  'test_role_a',
  'admin 经 RPC 新建自定义角色'
);
select is(
  (select (public.upsert_role(
     (select id from public.roles where code = 'test_role_a'),
     '测试-角色A2', 'test_role_a2', '说明A2', 'active')).name),
  '测试-角色A2',
  'admin 经 RPC 编辑自定义角色（改名/改 code）'
);
select is(
  (select (public.upsert_role(
     (select id from public.roles where code = 'supplier'),
     null, null, '外部：供应商（修订）', null)).description),
  '外部：供应商（修订）',
  '内置角色仅改说明成功'
);
select throws_ok(
  $$ select public.upsert_role(
       (select id from public.roles where code = 'engineer'),
       '工程师2', null, null, null) $$,
  '22023', '内置角色仅可修改说明',
  '内置角色改 name 被拒'
);
select throws_ok(
  $$ select public.upsert_role(null, '重复角色', 'test_role_a2', null, 'active') $$,
  '22023', '角色标识已存在：test_role_a2',
  '重复 code 新建被拒'
);
select throws_ok(
  $$ select public.disable_role((select id from public.roles where code = 'engineer')) $$,
  '22023', '该角色下仍有 1 名用户，无法停用',
  '含用户角色停用被拒并提示人数'
);
select throws_ok(
  $$ select public.disable_role((select id from public.roles where code = 'admin')) $$,
  '22023', '系统管理员角色不可停用',
  'admin 角色不可停用'
);
select is(
  (select (public.disable_role((select id from public.roles where code = 'supplier'))).status),
  'disabled',
  '无用户角色可停用'
);
select is(
  (select (public.enable_role((select id from public.roles where code = 'supplier'))).status),
  'active',
  '停用后可重新启用'
);
select throws_ok(
  $$ select public.delete_role((select id from public.roles where code = 'engineer')) $$,
  '22023', '该角色下仍有 1 名用户，无法删除',
  '含用户角色删除被拒并提示人数'
);
select throws_ok(
  $$ select public.delete_role((select id from public.roles where code = 'supplier')) $$,
  '22023', '内置角色不可删除：supplier',
  '内置角色删除被拒（RPC 层）'
);
select is(
  (select (public.delete_role((select id from public.roles where code = 'test_role_a2'))).code),
  'test_role_a2',
  '无用户自定义角色可删除'
);
select is(
  (select count(*) from public.roles where code = 'test_role_a2'),
  0::bigint,
  '删除后行不存在'
);
select is(
  (select (public.delete_role('44444444-4444-4444-4444-444444440002')).code),
  'test_custom_d',
  '无用户自定义角色（disabled）可删除'
);

-- ===========================================================================
-- 8. 审计摘要：每次写操作均落 audit_operations（4）
-- ===========================================================================
select is(
  (select count(*) from public.audit_operations
    where module = 'access' and action = 'create' and object_type = 'role'
      and actor_id = '11111111-1111-1111-1111-111111111111'
      and diff ->> 'code' = 'test_role_a'),
  1::bigint,
  '新建角色写审计摘要'
);
select is(
  (select count(*) from public.audit_operations
    where module = 'access' and action = 'update' and object_type = 'role'
      and diff -> 'after' ->> 'code' = 'test_role_a2'),
  1::bigint,
  '编辑角色写审计摘要（含前后 diff）'
);
select is(
  (select count(*) from public.audit_operations
    where module = 'access' and action = 'disable' and object_type = 'role'
      and diff ->> 'code' = 'supplier'),
  1::bigint,
  '停用角色写审计摘要'
);
select is(
  (select count(*) from public.audit_operations
    where module = 'access' and action = 'delete' and object_type = 'role'
      and diff ->> 'code' = 'test_role_a2'),
  1::bigint,
  '删除角色写审计摘要'
);

reset role;
select * from finish();
rollback;
