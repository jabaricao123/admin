-- 组织管理 · departments（org/001 表 + org/002 RLS/RPC）pgTAP 测试
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构存在性 / 越权直写拒绝 / 非 admin 读范围 / deleted 隐藏 /
--       防环校验 / RPC 写入 / 停用与删除的在职人数校验

begin;

select plan(35);

-- ===========================================================================
-- 1. 结构存在性（11）
-- ===========================================================================
select has_table('public', 'departments', 'departments 表存在');
select has_view('public', 'departments_v', 'departments_v 视图存在');
select has_function('app', 'department_tree', 'app.department_tree 存在');
select has_function('app', 'validate_department_move', array['uuid', 'uuid'], 'app.validate_department_move 存在');
select has_function('app', 'upsert_department', array['uuid', 'text', 'uuid', 'uuid', 'integer'], 'app.upsert_department 存在');
select has_function('app', 'disable_department', array['uuid'], 'app.disable_department 存在');
select has_function('public', 'department_tree', 'public.department_tree 包装存在');
select has_function('public', 'upsert_department', array['uuid', 'text', 'uuid', 'uuid', 'integer'], 'public.upsert_department 包装存在');
select has_index('public', 'departments', 'departments_parent_id_idx', 'parent_id 索引存在');
select has_index('public', 'departments', 'departments_status_idx', 'status 索引存在');
select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = 'upsert_department'
      and p.proconfig @> array['search_path=""']
  ),
  'app.upsert_department 的 search_path 固定为空'
);

-- ===========================================================================
-- 2. 固定装置（以 postgres 超级用户写入，绕过 RLS）
--    树 A→B→C：测试-总部 → 测试-研发 → 测试-前端；另有 测试-行政、测试-已删(deleted)
-- ===========================================================================
insert into public.departments (id, name, parent_id, leader_id, sort_order, status, created_by)
values
  ('00000000-0000-4000-8000-000000000001', '测试-总部', null,
   '22222222-2222-2222-2222-222222220001', 1, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('00000000-0000-4000-8000-000000000002', '测试-研发',
   '00000000-0000-4000-8000-000000000001', null, 1, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('00000000-0000-4000-8000-000000000003', '测试-前端',
   '00000000-0000-4000-8000-000000000002', null, 1, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('00000000-0000-4000-8000-000000000004', '测试-行政', null, null, 2, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('00000000-0000-4000-8000-000000000005', '测试-已删', null, null, 3, 'deleted',
   '11111111-1111-1111-1111-111111111111');

-- ===========================================================================
-- 3. 读范围：非 admin 登录用户（engineer）可见未删部门，不可见 deleted
-- ===========================================================================
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;

-- 12
select is(
  (select count(*) from public.departments where id::text like '00000000-0000-4000-8000-%'),
  4::bigint,
  '非 admin 可见 4 个未删除部门'
);
-- 13
select is(
  (select count(*) from public.departments where id = '00000000-0000-4000-8000-000000000005'),
  0::bigint,
  '非 admin 不可见 deleted 部门（表级 RLS）'
);
-- 14
select is(
  (select count(*) from public.departments_v where id::text like '00000000-0000-4000-8000-%'),
  4::bigint,
  'departments_v 过滤 deleted'
);
-- 15
select is(
  (select path from public.departments_v where id = '00000000-0000-4000-8000-000000000003'),
  '测试-总部/测试-研发/测试-前端',
  'departments_v.path 递归路径串正确'
);
-- 16
select is(
  (select count(*) from public.department_tree() where id::text like '00000000-0000-4000-8000-%'),
  4::bigint,
  'department_tree() 返回未删除部门'
);

-- ===========================================================================
-- 4. 越权直写：表级无任何写授权
-- ===========================================================================
-- 17
select throws_ok(
  $$ insert into public.departments (name) values ('越权新增') $$,
  '42501', null, '非 admin 表级 INSERT 被拒'
);
-- 18
select throws_ok(
  $$ update public.departments set name = '越权改名' where id = '00000000-0000-4000-8000-000000000001' $$,
  '42501', null, '非 admin 表级 UPDATE 被拒'
);
-- 19
select throws_ok(
  $$ delete from public.departments where id = '00000000-0000-4000-8000-000000000001' $$,
  '42501', null, '非 admin 表级 DELETE 被拒'
);
-- 20
select throws_ok(
  $$ select public.upsert_department(null, '越权 RPC', null, null, 0) $$,
  '42501', '仅管理员可执行此操作', '非 admin 调用写 RPC 被拒'
);

-- ===========================================================================
-- 5. anon 无任何读取路径
-- ===========================================================================
-- 21
set local role anon;
select throws_ok(
  $$ select count(*) from public.departments $$,
  '42501', null, 'anon 无 departments 读取权限'
);

-- ===========================================================================
-- 6. admin：可见 deleted；表级同样不可直写
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

-- 22
select is(
  (select count(*) from public.departments where id::text like '00000000-0000-4000-8000-%'),
  5::bigint,
  'admin 可见全部部门（含 deleted）'
);
-- 23
select throws_ok(
  $$ insert into public.departments (name) values ('admin 直写') $$,
  '42501', null, 'admin 表级 INSERT 同样被拒（无表级写授权）'
);

-- ===========================================================================
-- 7. 防环校验（A→B→C：不能把 A 移到其孙 C 下）
-- ===========================================================================
-- 24
select throws_ok(
  $$ select app.validate_department_move(
       '00000000-0000-4000-8000-000000000001',
       '00000000-0000-4000-8000-000000000003') $$,
  '22023', '不能将部门移动到其子孙部门下（会形成循环）',
  'validate_department_move 拒绝 A 移到子孙 C 下'
);
-- 25
select lives_ok(
  $$ select app.validate_department_move('00000000-0000-4000-8000-000000000003', null) $$,
  'validate_department_move 允许移动到根'
);
-- 26
select throws_ok(
  $$ select public.upsert_department(
       '00000000-0000-4000-8000-000000000001', '测试-总部',
       '00000000-0000-4000-8000-000000000003', null, 1) $$,
  '22023', '不能将部门移动到其子孙部门下（会形成循环）',
  '写 RPC 路径同样拒绝形成循环'
);

-- ===========================================================================
-- 8. admin 经 RPC 写入（新建、改名）
-- ===========================================================================
-- 27
select is(
  (select (public.upsert_department(null, '测试-新增', null, null, 0)).name),
  '测试-新增',
  'admin 经 RPC 新建部门'
);
-- 28
select is(
  (select (public.upsert_department(
     '00000000-0000-4000-8000-000000000002', '测试-研发二部',
     '00000000-0000-4000-8000-000000000001', null, 5)).name),
  '测试-研发二部',
  'admin 经 RPC 改名/排序'
);

-- ===========================================================================
-- 9. 停用/删除：在职人数与子部门校验（profiles.department 文本匹配）
-- ===========================================================================
-- 29 装置：engineer 挂到 测试-行政（经 admin RPC，真实路径）
select is(
  (select (public.admin_update_profile(
     '22222222-2222-2222-2222-222222220001', null, '测试-行政', null, null)).department),
  '测试-行政',
  '装置：engineer 挂到测试-行政'
);
-- 30
select throws_ok(
  $$ select public.disable_department('00000000-0000-4000-8000-000000000004') $$,
  '22023', '该部门下仍有 1 名在职人员，无法停用',
  '停用含在职人员的部门被拒并提示人数'
);

-- 清空在职归属（postgres 直改，模拟人员调离）
reset role;
update public.profiles
   set department = null
 where id = '22222222-2222-2222-2222-222222220001';
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

-- 31
select is(
  (select (public.disable_department('00000000-0000-4000-8000-000000000004')).status),
  'disabled',
  '清空在职人员后停用成功'
);
-- 32
select is(
  (select count(*) from public.departments_v where id = '00000000-0000-4000-8000-000000000004'),
  1::bigint,
  'disabled 部门保留在 departments_v 中'
);
-- 33
select throws_ok(
  $$ select public.delete_department('00000000-0000-4000-8000-000000000002') $$,
  '22023', '该部门下仍有 1 个子部门，无法删除',
  '有子部门的部门不可删除'
);
-- 34
select is(
  (select (public.delete_department('00000000-0000-4000-8000-000000000004')).status),
  'deleted',
  '空部门可逻辑删除（status=deleted）'
);
-- 35
select is(
  (select (public.upsert_department(
     '00000000-0000-4000-8000-000000000003', '测试-前端', null, null, 1)).parent_id is null),
  true,
  'admin 经 RPC 可将部门移动到根'
);

reset role;
select * from finish();
rollback;
