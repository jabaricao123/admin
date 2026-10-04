-- 权限管理 · 外部角色数据范围锁定 self（access 批次 1 / 修复项 1）pgTAP 测试
-- 运行：supabase db reset && supabase test db
-- 覆盖：存量收敛（supplier/customer scope=self；内部角色不受影响）/
--       app.upsert_data_scope 加固（外部角色非 self 拒绝 22023；all 仅 admin
--       规则保留；self 幂等允许；内部角色不误伤）/ 函数安全属性与授权保持 /
--       supplier 会话 scope_user_ids 仅本人、部门集为空 / preview_scope 一致。
-- 说明：夹具仅在事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(20);

-- ===========================================================================
-- 1. 存量收敛（3）
-- ===========================================================================
select is(
  (select scope
     from public.role_data_scopes
    where role_id = (select id from public.roles where code = 'supplier')),
  'self',
  '存量收敛：supplier scope = self'
);
select is(
  (select scope
     from public.role_data_scopes
    where role_id = (select id from public.roles where code = 'customer')),
  'self',
  '存量收敛：customer scope = self'
);
select is(
  (select scope
     from public.role_data_scopes
    where role_id = (select id from public.roles where code = 'engineer')),
  'all',
  '内部角色不受影响：engineer 仍为 all'
);

-- ===========================================================================
-- 2. 加固后函数安全属性与授权（3）
-- ===========================================================================
select ok(
  (select count(*) = 1
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = 'upsert_data_scope'
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '加固后 app.upsert_data_scope：security definer + search_path 固定为空'
);
select ok(
  has_function_privilege('authenticated', 'app.upsert_data_scope(uuid, text)', 'EXECUTE'),
  '加固后 authenticated 仍可执行 app.upsert_data_scope'
);
select ok(
  not has_function_privilege('anon', 'app.upsert_data_scope(uuid, text)', 'EXECUTE'),
  '加固后 anon 仍无执行权'
);

-- ===========================================================================
-- 3. 夹具（as postgres）：supplier 用户（handle_new_user 自动建档）
-- ===========================================================================
insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
  ('d0000000-0000-4000-a000-000000000101', 'batch1-supplier@example.com',
   '{"role":"supplier"}'::jsonb, '{"full_name":"批次一供应商"}'::jsonb);

select is(
  (select p.role_id
     from public.profiles p
    where p.id = 'd0000000-0000-4000-a000-000000000101'),
  (select id from public.roles where code = 'supplier'),
  '夹具：supplier 档案 role_id 指向 supplier 角色'
);

-- ===========================================================================
-- 4. RPC 加固：外部角色仅 self / all 仅 admin 保留（as admin，7）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select throws_ok(
  $$ select public.upsert_data_scope(
       (select id from public.roles where code = 'supplier'), 'dept') $$,
  '22023', '外部角色仅可配置「仅本人」数据范围：supplier',
  'supplier 配 dept 被拒（外部角色仅 self）'
);
select throws_ok(
  $$ select public.upsert_data_scope(
       (select id from public.roles where code = 'supplier'), 'dept_tree') $$,
  '22023', '外部角色仅可配置「仅本人」数据范围：supplier',
  'supplier 配 dept_tree 被拒（外部角色仅 self）'
);
select throws_ok(
  $$ select public.upsert_data_scope(
       (select id from public.roles where code = 'supplier'), 'all') $$,
  '22023', '外部角色仅可配置「仅本人」数据范围：supplier',
  'supplier 配 all 被拒（外部规则先于 all 规则）'
);
select throws_ok(
  $$ select public.upsert_data_scope(
       (select id from public.roles where code = 'customer'), 'dept') $$,
  '22023', '外部角色仅可配置「仅本人」数据范围：customer',
  'customer 配 dept 被拒（外部角色仅 self）'
);
select is(
  (public.upsert_data_scope(
     (select id from public.roles where code = 'supplier'), 'self')).scope,
  'self',
  'supplier 配 self 允许（幂等重放）'
);
select throws_ok(
  $$ select public.upsert_data_scope(
       (select id from public.roles where code = 'engineer'), 'all') $$,
  '22023', '仅系统管理员角色可配置「全部」数据范围',
  '「all 仅 admin」规则保留（engineer 配 all 仍被拒）'
);
select is(
  (public.upsert_data_scope(
     (select id from public.roles where code = 'quality'), 'dept')).scope,
  'dept',
  '内部角色不受外部规则误伤（quality 可配 dept）'
);

-- ===========================================================================
-- 5. supplier 会话：scope_user_ids 仅本人（4）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"d0000000-0000-4000-a000-000000000101","role":"authenticated"}';
set local role authenticated;

select throws_ok(
  $$ select public.upsert_data_scope(
       (select id from public.roles where code = 'supplier'), 'self') $$,
  '42501', '仅管理员可执行此操作',
  '加固后非 admin 调 upsert_data_scope 仍被拒'
);
select results_eq(
  $$ select u from app.scope_user_ids() as u order by u $$,
  $$ values ('d0000000-0000-4000-a000-000000000101'::uuid) $$,
  'supplier（scope=self）：scope_user_ids 仅返回本人'
);
select is(
  (select count(*) from app.scope_user_ids()),
  1::bigint,
  'supplier：可见用户数 = 1'
);
select is(
  (select count(*) from app.scope_dept_ids()),
  0::bigint,
  'supplier（scope=self）：部门集为空'
);

-- ===========================================================================
-- 6. preview_scope 一致（as admin，2）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select is(
  (public.preview_scope('d0000000-0000-4000-a000-000000000101') ->> 'scope'),
  'self',
  'preview_scope：supplier 用户 scope=self'
);
select is(
  (public.preview_scope('d0000000-0000-4000-a000-000000000101') ->> 'user_count')::bigint,
  1::bigint,
  'preview_scope：supplier 用户可见用户数 = 1'
);

reset role;
select * from finish();
rollback;
