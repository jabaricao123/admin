-- 权限管理 · 数据范围 role_data_scopes + scope helper + 管理/预检 RPC（access/009-010）pgTAP 测试
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构/约束/RLS/授权 / 存量 seed 7 行（内部角色 all / 外部角色 self）/
--       四档行为（self/dept/dept_tree/all，按真实会话）/
--       无会话空集 / 非 active 与角色未配置 fail-closed / 无部门 scope 退化为仅本人 /
--       upsert_data_scope 越权与 all 白名单 / 审计写入 / preview_scope 结构与计数 / 改配即时生效。
-- 说明：夹具仅在事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(71);

-- ===========================================================================
-- 1. 结构 / 约束 / RLS / 授权 / 存量 seed（29）
-- ===========================================================================
select has_table('public', 'role_data_scopes', 'role_data_scopes 表存在');
select has_column('public', 'role_data_scopes', 'role_id', 'role_id 列存在');
select has_column('public', 'role_data_scopes', 'scope', 'scope 列存在');
select has_column('public', 'role_data_scopes', 'updated_by', 'updated_by 列存在');
select has_column('public', 'role_data_scopes', 'updated_at', 'updated_at 列存在');
select col_is_pk('public', 'role_data_scopes', 'role_id', 'role_id 为主键');
select ok(
  exists (
    select 1
    from pg_constraint
    where conrelid = 'public.role_data_scopes'::regclass
      and contype = 'f'
      and confrelid = 'public.roles'::regclass
  ),
  'role_id 外键 → roles.id 存在'
);
select col_has_check('public', 'role_data_scopes', 'scope', 'scope 有白名单 check 约束');

select has_function('app', 'scope_user_ids', 'app.scope_user_ids 存在');
select has_function('app', 'scope_dept_ids', 'app.scope_dept_ids 存在');
select has_function('app', 'upsert_data_scope', array['uuid', 'text'], 'app.upsert_data_scope 存在');
select has_function('public', 'upsert_data_scope', array['uuid', 'text'], 'public.upsert_data_scope 包装存在');
select has_function('app', 'preview_scope', array['uuid'], 'app.preview_scope 存在');
select has_function('public', 'preview_scope', array['uuid'], 'public.preview_scope 包装存在');

select ok(
  (select count(*) = 2
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname in ('scope_user_ids', 'scope_dept_ids')
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '会话级 helper：security definer + search_path 固定为空'
);
select ok(
  (select count(*) = 4
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where ((n.nspname = 'app' and p.proname in ('upsert_data_scope', 'preview_scope'))
        or (n.nspname = 'public' and p.proname in ('upsert_data_scope', 'preview_scope')))
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '管理/预检 RPC（app + public）：security definer + search_path 固定为空'
);

select ok(
  has_function_privilege('authenticated', 'app.scope_user_ids()', 'EXECUTE'),
  'authenticated 可执行 app.scope_user_ids（RLS 引用入口）'
);
select ok(
  has_function_privilege('authenticated', 'app.scope_dept_ids()', 'EXECUTE'),
  'authenticated 可执行 app.scope_dept_ids（RLS 引用入口）'
);
select ok(
  not has_function_privilege('anon', 'app.scope_user_ids()', 'EXECUTE'),
  'anon 无 app.scope_user_ids 执行权'
);
select ok(
  not has_function_privilege('anon', 'app.scope_dept_ids()', 'EXECUTE'),
  'anon 无 app.scope_dept_ids 执行权'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.role_data_scopes'::regclass),
  'role_data_scopes 启用 RLS'
);
select ok(
  exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'role_data_scopes'
      and policyname = 'role_data_scopes_select'
  ),
  'role_data_scopes_select 读策略存在（登录用户可读）'
);
select ok(
  has_table_privilege('authenticated', 'public.role_data_scopes', 'SELECT'),
  'authenticated 有 SELECT 权限'
);
select ok(
  not has_table_privilege('authenticated', 'public.role_data_scopes', 'INSERT')
  and not has_table_privilege('authenticated', 'public.role_data_scopes', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.role_data_scopes', 'DELETE'),
  'authenticated 无任何表级写权限（写仅经 RPC）'
);
select ok(
  not has_table_privilege('anon', 'public.role_data_scopes', 'SELECT'),
  'anon 无 SELECT 权限'
);

select is(
  (select count(*) from public.role_data_scopes),
  7::bigint,
  '存量 7 个内置角色各有 1 行范围配置'
);
select is(
  (select count(*)
     from public.role_data_scopes s
     join public.roles r on r.id = s.role_id
    where r.is_builtin
      and r.code in ('admin', 'engineer', 'planner', 'buyer', 'quality')
      and s.scope = 'all'),
  5::bigint,
  '内部角色存量 scope 显式 = all（禁止默认 self，防可见范围静默收窄）'
);
select is(
  (select count(*)
     from public.role_data_scopes s
     join public.roles r on r.id = s.role_id
    where r.is_builtin
      and r.code in ('supplier', 'customer')
      and s.scope = 'self'),
  2::bigint,
  '外部角色存量 scope = self（access 批次 1 安全默认，仅本人）'
);

-- ===========================================================================
-- 2. 夹具（as postgres）：部门树 + 各角色/部门用户
--    d1 总部 → d2 研发 → d3 前端；d4 行政（根）；d5 已删
--    u1 engineer@d2 / u2 engineer@d3 / u3 engineer@d4 / u4 planner@d3 /
--    u5 admin@d1 / u6 engineer 无部门 / u7 engineer@d2 停用
-- ===========================================================================
insert into public.departments (id, name, parent_id, sort_order, status) values
  ('c0000000-0000-4000-a000-000000000001', '测试范围-总部', null, 1, 'active'),
  ('c0000000-0000-4000-a000-000000000002', '测试范围-研发',
   'c0000000-0000-4000-a000-000000000001', 1, 'active'),
  ('c0000000-0000-4000-a000-000000000003', '测试范围-前端',
   'c0000000-0000-4000-a000-000000000002', 1, 'active'),
  ('c0000000-0000-4000-a000-000000000004', '测试范围-行政', null, 2, 'active'),
  ('c0000000-0000-4000-a000-000000000005', '测试范围-已删', null, 3, 'deleted');

insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
  ('d0000000-0000-4000-a000-000000000001', 'scope-u1@example.com',
   '{"role":"engineer"}'::jsonb, '{"full_name":"范围-用户一"}'::jsonb),
  ('d0000000-0000-4000-a000-000000000002', 'scope-u2@example.com',
   '{"role":"engineer"}'::jsonb, '{"full_name":"范围-用户二"}'::jsonb),
  ('d0000000-0000-4000-a000-000000000003', 'scope-u3@example.com',
   '{"role":"engineer"}'::jsonb, '{"full_name":"范围-用户三"}'::jsonb),
  ('d0000000-0000-4000-a000-000000000004', 'scope-u4@example.com',
   '{"role":"planner"}'::jsonb, '{"full_name":"范围-用户四"}'::jsonb),
  ('d0000000-0000-4000-a000-000000000005', 'scope-u5@example.com',
   '{"role":"admin"}'::jsonb, '{"full_name":"范围-管理员"}'::jsonb),
  ('d0000000-0000-4000-a000-000000000006', 'scope-u6@example.com',
   '{"role":"engineer"}'::jsonb, '{"full_name":"范围-无部门"}'::jsonb),
  ('d0000000-0000-4000-a000-000000000007', 'scope-u7@example.com',
   '{"role":"engineer"}'::jsonb, '{"full_name":"范围-停用"}'::jsonb);

update public.profiles
   set department_id = 'c0000000-0000-4000-a000-000000000002'
 where id in ('d0000000-0000-4000-a000-000000000001',
              'd0000000-0000-4000-a000-000000000007');

update public.profiles
   set department_id = 'c0000000-0000-4000-a000-000000000003'
 where id in ('d0000000-0000-4000-a000-000000000002',
              'd0000000-0000-4000-a000-000000000004');

update public.profiles
   set department_id = 'c0000000-0000-4000-a000-000000000004'
 where id = 'd0000000-0000-4000-a000-000000000003';

update public.profiles
   set department_id = 'c0000000-0000-4000-a000-000000000001'
 where id = 'd0000000-0000-4000-a000-000000000005';

update public.profiles
   set status = 'inactive'
 where id = 'd0000000-0000-4000-a000-000000000007';

-- 无会话（auth.uid() 为空，如定时任务）：helper 返回空集
reset role;
set local request.jwt.claims = '';
select is(
  (select count(*) from app.scope_user_ids()),
  0::bigint,
  '无会话：scope_user_ids 返回空集'
);
select is(
  (select count(*) from app.scope_dept_ids()),
  0::bigint,
  '无会话：scope_dept_ids 返回空集'
);

-- ===========================================================================
-- 3. 四档 scope 行为（以真实登录身份逐个验证，19）
-- ===========================================================================
-- 3.1 all（engineer 存量 seed = all）：u1 可见全部 profiles / 全部未删除部门
set local request.jwt.claims = '{"sub":"d0000000-0000-4000-a000-000000000001","role":"authenticated"}';
set local role authenticated;
select is(
  (select count(*) from app.scope_user_ids()),
  (select count(*) from public.profiles),
  'all：可见用户数 = 全部 profiles'
);
select is(
  (select count(*) from app.scope_dept_ids()),
  (select count(*) from public.departments where status <> 'deleted'),
  'all：可见部门数 = 全部未删除 departments'
);

-- 3.2 self
reset role;
update public.role_data_scopes
   set scope = 'self'
 where role_id = (select id from public.roles where code = 'engineer');

set local request.jwt.claims = '{"sub":"d0000000-0000-4000-a000-000000000001","role":"authenticated"}';
set local role authenticated;
select results_eq(
  $$ select u from app.scope_user_ids() as u order by u $$,
  $$ values ('d0000000-0000-4000-a000-000000000001'::uuid) $$,
  'self：仅本人'
);
select is(
  (select count(*) from app.scope_dept_ids()),
  0::bigint,
  'self：部门集为空'
);

-- 3.3 dept（u1 在 d2；成员含同部门非 active 档案 u7）
reset role;
update public.role_data_scopes
   set scope = 'dept'
 where role_id = (select id from public.roles where code = 'engineer');

set local request.jwt.claims = '{"sub":"d0000000-0000-4000-a000-000000000001","role":"authenticated"}';
set local role authenticated;
select results_eq(
  $$ select u from app.scope_user_ids() as u order by u $$,
  $$ values ('d0000000-0000-4000-a000-000000000001'::uuid),
            ('d0000000-0000-4000-a000-000000000007'::uuid) $$,
  'dept：本部门成员（d2；含非 active 档案，按数据归属而非账号状态）'
);
select results_eq(
  $$ select d from app.scope_dept_ids() as d order by d $$,
  $$ values ('c0000000-0000-4000-a000-000000000002'::uuid) $$,
  'dept：仅本部门'
);

reset role;
set local request.jwt.claims = '{"sub":"d0000000-0000-4000-a000-000000000003","role":"authenticated"}';
set local role authenticated;
select results_eq(
  $$ select u from app.scope_user_ids() as u order by u $$,
  $$ values ('d0000000-0000-4000-a000-000000000003'::uuid) $$,
  'dept：同角色不同部门（u3@d4）只看到本部门'
);

-- 3.4 dept_tree（d2 + 子部门 d3）
reset role;
update public.role_data_scopes
   set scope = 'dept_tree'
 where role_id = (select id from public.roles where code = 'engineer');

set local request.jwt.claims = '{"sub":"d0000000-0000-4000-a000-000000000001","role":"authenticated"}';
set local role authenticated;
select results_eq(
  $$ select u from app.scope_user_ids() as u order by u $$,
  $$ values ('d0000000-0000-4000-a000-000000000001'::uuid),
            ('d0000000-0000-4000-a000-000000000002'::uuid),
            ('d0000000-0000-4000-a000-000000000004'::uuid),
            ('d0000000-0000-4000-a000-000000000007'::uuid) $$,
  'dept_tree：本部门及以下成员（d2 + d3；不含 d4 的 u3）'
);
select results_eq(
  $$ select d from app.scope_dept_ids() as d order by d $$,
  $$ values ('c0000000-0000-4000-a000-000000000002'::uuid),
            ('c0000000-0000-4000-a000-000000000003'::uuid) $$,
  'dept_tree：部门集 = 本部门及以下（path 展开）'
);

reset role;
set local request.jwt.claims = '{"sub":"d0000000-0000-4000-a000-000000000002","role":"authenticated"}';
set local role authenticated;
select results_eq(
  $$ select u from app.scope_user_ids() as u order by u $$,
  $$ values ('d0000000-0000-4000-a000-000000000002'::uuid),
            ('d0000000-0000-4000-a000-000000000004'::uuid) $$,
  'dept_tree：叶子部门（u2@d3）无子部门时仅本部门成员'
);

-- 3.5 无部门：scope 为 dept 系时退化为仅本人
reset role;
set local request.jwt.claims = '{"sub":"d0000000-0000-4000-a000-000000000006","role":"authenticated"}';
set local role authenticated;
select results_eq(
  $$ select u from app.scope_user_ids() as u order by u $$,
  $$ values ('d0000000-0000-4000-a000-000000000006'::uuid) $$,
  '无部门 + dept 系 scope：退化为仅本人'
);
select is(
  (select count(*) from app.scope_dept_ids()),
  0::bigint,
  '无部门 + dept 系 scope：部门集为空'
);

-- 3.6 角色独立：planner 单独配 dept_tree（d3）
reset role;
update public.role_data_scopes
   set scope = 'dept_tree'
 where role_id = (select id from public.roles where code = 'planner');

set local request.jwt.claims = '{"sub":"d0000000-0000-4000-a000-000000000004","role":"authenticated"}';
set local role authenticated;
select results_eq(
  $$ select u from app.scope_user_ids() as u order by u $$,
  $$ values ('d0000000-0000-4000-a000-000000000002'::uuid),
            ('d0000000-0000-4000-a000-000000000004'::uuid) $$,
  'scope 按角色独立：planner dept_tree 只作用于 planner 用户'
);

-- 3.7 fail-closed：账号非 active / 角色无 scope 行
reset role;
update public.role_data_scopes
   set scope = 'all'
 where role_id = (select id from public.roles where code = 'engineer');

set local request.jwt.claims = '{"sub":"d0000000-0000-4000-a000-000000000007","role":"authenticated"}';
set local role authenticated;
select is(
  (select count(*) from app.scope_user_ids()),
  0::bigint,
  '账号非 active：scope=all 也返回空集（fail-closed）'
);
select is(
  (select count(*) from app.scope_dept_ids()),
  0::bigint,
  '账号非 active：部门集为空'
);

reset role;
delete from public.role_data_scopes
 where role_id = (select id from public.roles where code = 'quality');

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220004","role":"authenticated"}';
set local role authenticated;
select is(
  (select count(*) from app.scope_user_ids()),
  0::bigint,
  '角色无 scope 行：返回空集（不默认放大可见范围）'
);
select is(
  (select count(*) from app.scope_dept_ids()),
  0::bigint,
  '角色无 scope 行：部门集为空'
);

-- ===========================================================================
-- 4. upsert_data_scope：越权 / 白名单 / 审计 / 建行（14）
-- ===========================================================================
-- 4.1 非 admin 与 anon 拒绝
reset role;
set local request.jwt.claims = '{"sub":"d0000000-0000-4000-a000-000000000001","role":"authenticated"}';
set local role authenticated;
select throws_ok(
  $$ select public.upsert_data_scope(
       (select id from public.roles where code = 'engineer'), 'self') $$,
  '42501', '仅管理员可执行此操作',
  '非 admin 调 public.upsert_data_scope 被拒'
);

reset role;
set local role anon;
select throws_ok(
  $$ select public.upsert_data_scope(
       (select id from public.roles where code = 'engineer'), 'self') $$,
  '42501', null,
  'anon 无 upsert_data_scope 执行权限'
);

-- 4.2 admin 正常路径 + 审计
reset role;
set local request.jwt.claims = '{"sub":"d0000000-0000-4000-a000-000000000005","role":"authenticated"}';
set local role authenticated;
select is(
  (public.upsert_data_scope(
     (select id from public.roles where code = 'engineer'), 'self')).scope,
  'self',
  'admin 配置 engineer scope=self'
);
select is(
  (select updated_by from public.role_data_scopes
    where role_id = (select id from public.roles where code = 'engineer')),
  'd0000000-0000-4000-a000-000000000005'::uuid,
  'upsert_data_scope 记录 updated_by'
);
select is(
  (select count(*)
     from public.audit_operations
    where module = 'access'
      and action = 'update'
      and object_type = 'role_data_scope'
      and object_id = (select id::text from public.roles where code = 'engineer')
      and diff ->> 'role_code' = 'engineer'
      and diff ->> 'before' = 'all'
      and diff ->> 'after' = 'self'),
  1::bigint,
  'upsert_data_scope 写审计摘要（before/after/role_code）'
);

-- 4.3 白名单校验
select throws_ok(
  $$ select public.upsert_data_scope(
       (select id from public.roles where code = 'engineer'), 'all') $$,
  '22023', '仅系统管理员角色可配置「全部」数据范围',
  '非 admin 角色配 all 被拒（功能规则）'
);
select throws_ok(
  $$ select public.upsert_data_scope(
       (select id from public.roles where code = 'engineer'), 'everything') $$,
  '22023', '非法数据范围：everything',
  '非法 scope 值被拒'
);
select throws_ok(
  $$ select public.upsert_data_scope(
       (select id from public.roles where code = 'engineer'), null) $$,
  '22023', '非法数据范围：null',
  'scope 为空被拒'
);
select throws_ok(
  $$ select public.upsert_data_scope('eeeeeeee-eeee-4eee-aeee-000000000001', 'self') $$,
  'P0002', '角色不存在：eeeeeeee-eeee-4eee-aeee-000000000001',
  '目标角色不存在被拒'
);
select is(
  (public.upsert_data_scope(
     (select id from public.roles where code = 'admin'), 'all')).scope,
  'all',
  'admin 角色可配置 all（幂等重放）'
);

-- 4.4 缺失行补建 + 生效
select public.upsert_data_scope(
  (select id from public.roles where code = 'quality'), 'dept');
reset role;
select is(
  (select scope from public.role_data_scopes
    where role_id = (select id from public.roles where code = 'quality')),
  'dept',
  '缺失 scope 行的角色可经 RPC 补建'
);
select is(
  (select diff ->> 'before'
     from public.audit_operations
    where module = 'access'
      and object_type = 'role_data_scope'
      and object_id = (select id::text from public.roles where code = 'quality')
    order by id desc
    limit 1),
  null::text,
  '补建行审计 before 为空'
);

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220004","role":"authenticated"}';
set local role authenticated;
select results_eq(
  $$ select u from app.scope_user_ids() as u order by u $$,
  $$ values ('22222222-2222-2222-2222-222222220004'::uuid) $$,
  '无部门 + dept scope：quality 用户仅本人可见（改配即时生效）'
);
select is(
  (select count(*) from app.scope_dept_ids()),
  0::bigint,
  '无部门 + dept scope：quality 用户部门集为空'
);

-- ===========================================================================
-- 5. preview_scope：admin 专用 / 结构与计数 / 即时生效（10）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"d0000000-0000-4000-a000-000000000001","role":"authenticated"}';
set local role authenticated;
select throws_ok(
  $$ select public.preview_scope('d0000000-0000-4000-a000-000000000002') $$,
  '42501', '仅管理员可执行此操作',
  '非 admin 调 preview_scope 被拒'
);

reset role;
set local request.jwt.claims = '{"sub":"d0000000-0000-4000-a000-000000000005","role":"authenticated"}';
set local role authenticated;
select throws_ok(
  $$ select public.preview_scope('eeeeeeee-eeee-4eee-aeee-000000000002') $$,
  'P0002', '用户不存在：eeeeeeee-eeee-4eee-aeee-000000000002',
  '预检用户不存在被拒'
);

-- engineer 配 dept_tree 后预检 u1（d2，含子部门 d3）
select public.upsert_data_scope(
  (select id from public.roles where code = 'engineer'), 'dept_tree');
select ok(
  (public.preview_scope('d0000000-0000-4000-a000-000000000001'))
    ?& array['user_id', 'user_name', 'role_code', 'role_name', 'department_id',
             'department_name', 'scope', 'user_count', 'dept_count'],
  'preview 返回用户/角色/scope/可见用户数/可见部门数等键'
);
select is(
  (public.preview_scope('d0000000-0000-4000-a000-000000000001') ->> 'role_code'),
  'engineer',
  'preview 返回该用户角色 code'
);
select is(
  (public.preview_scope('d0000000-0000-4000-a000-000000000001') ->> 'department_name'),
  '测试范围-研发',
  'preview 返回该用户所属部门名'
);
select is(
  (public.preview_scope('d0000000-0000-4000-a000-000000000001') ->> 'scope'),
  'dept_tree',
  'preview 返回该用户 scope'
);
select is(
  (public.preview_scope('d0000000-0000-4000-a000-000000000001') ->> 'user_count')::bigint,
  4::bigint,
  'preview 可见用户数 = dept_tree（d2+d3）成员数'
);
select is(
  (public.preview_scope('d0000000-0000-4000-a000-000000000001') ->> 'dept_count')::bigint,
  2::bigint,
  'preview 可见部门数 = 本部门及以下'
);

-- 改配即时生效 + 非 active 预检 fail-closed
select public.upsert_data_scope(
  (select id from public.roles where code = 'engineer'), 'self');
select is(
  (public.preview_scope('d0000000-0000-4000-a000-000000000001') ->> 'user_count')::bigint,
  1::bigint,
  '改配后 preview 即时反映新范围'
);
select is(
  (public.preview_scope('d0000000-0000-4000-a000-000000000007') ->> 'scope'),
  null::text,
  '非 active 用户预检 scope 为空（无可见范围）'
);

select * from finish();
rollback;
