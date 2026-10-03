-- 组织管理 · positions（org/004 表 + org/005 RLS/RPC + org/007 在岗统计改 id 口径）pgTAP 测试
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构存在性 / code 唯一 / 非 admin 写拒 / RLS 读范围 /
--       在岗统计（org/007 起按 profiles.position_id 精确统计）/ 停用允许引用且幂等 /
--       删除被引用岗位拒绝（position_id 计数 + FK restrict 兜底）
-- 说明：position_id 由 org/007 引入，页面写入在 org/009；本测试以 postgres 直写模拟。

begin;

select plan(55);

-- ===========================================================================
-- 1. 结构存在性（19）
-- ===========================================================================
select has_table('public', 'positions', 'positions 表存在');
select has_view('public', 'positions_v', 'positions_v 视图存在');
select has_function('app', 'upsert_position',
  array['uuid', 'text', 'text', 'uuid', 'integer', 'text', 'text'],
  'app.upsert_position 存在');
select has_function('app', 'disable_position', array['uuid'], 'app.disable_position 存在');
select has_function('app', 'enable_position', array['uuid'], 'app.enable_position 存在');
select has_function('app', 'delete_position', array['uuid'], 'app.delete_position 存在');
select has_function('app', 'position_headcount', array['uuid'], 'app.position_headcount 存在');
select has_function('public', 'upsert_position',
  array['uuid', 'text', 'text', 'uuid', 'integer', 'text', 'text'],
  'public.upsert_position 包装存在');
select has_function('public', 'disable_position', array['uuid'], 'public.disable_position 包装存在');
select has_function('public', 'enable_position', array['uuid'], 'public.enable_position 包装存在');
select has_function('public', 'delete_position', array['uuid'], 'public.delete_position 包装存在');
select has_function('public', 'position_headcount', array['uuid'], 'public.position_headcount 包装存在');
select has_index('public', 'positions', 'positions_code_key', 'code 唯一索引存在');
select has_index('public', 'positions', 'positions_department_id_idx', 'department_id 索引存在');
select has_index('public', 'positions', 'positions_status_idx', 'status 索引存在');
select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = 'upsert_position'
      and p.proconfig @> array['search_path=""']
  ),
  'app.upsert_position 的 search_path 固定为空'
);
select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'upsert_position'
      and p.proconfig @> array['search_path=""']
  ),
  'public.upsert_position 包装的 search_path 固定为空'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.positions'::regclass),
  'positions 表已启用 RLS'
);
select ok(
  exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'positions'
      and policyname = 'positions_select'
  ),
  'positions_select 策略存在'
);
select ok(
  not has_table_privilege('authenticated', 'public.positions', 'INSERT')
  and not has_table_privilege('authenticated', 'public.positions', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.positions', 'DELETE'),
  'authenticated 无 positions 表级写权限'
);

-- ===========================================================================
-- 2. 固定装置（以 postgres 超级用户写入，绕过 RLS）
--    部门 A/B；岗位 A1(active)/A2(disabled)/B1(active)
-- ===========================================================================
insert into public.departments (id, name, parent_id, sort_order, status, created_by)
values
  ('44444444-4444-4444-4444-444444440001', '测试-岗位部A', null, 1, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('44444444-4444-4444-4444-444444440002', '测试-岗位部B', null, 2, 'active',
   '11111111-1111-1111-1111-111111111111');

insert into public.positions (id, name, code, department_id, headcount, description, status, created_by)
values
  ('55555555-5555-4555-8555-555555550001', '测试-岗位A1', 'TEST-POS-A1',
   '44444444-4444-4444-4444-444444440001', 3, '岗位A1', 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('55555555-5555-4555-8555-555555550002', '测试-岗位A2', 'TEST-POS-A2',
   '44444444-4444-4444-4444-444444440001', 0, '岗位A2', 'disabled',
   '11111111-1111-1111-1111-111111111111'),
  ('55555555-5555-4555-8555-555555550003', '测试-岗位B1', 'TEST-POS-B1',
   '44444444-4444-4444-4444-444444440002', 5, '岗位B1', 'active',
   '11111111-1111-1111-1111-111111111111');

-- ===========================================================================
-- 3. 读范围：非 admin 登录用户（engineer）只读 active 岗位
-- ===========================================================================
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;

-- 20
select is(
  (select count(*) from public.positions where id::text like '55555555-5555-4555-8555-%'),
  2::bigint,
  '非 admin 表级可见 2 个 active 岗位'
);
-- 21
select is(
  (select count(*) from public.positions where id = '55555555-5555-4555-8555-555555550002'),
  0::bigint,
  '非 admin 不可见 disabled 岗位（RLS 过滤，供新编辑下拉）'
);
-- 22
select is(
  (select count(*) from public.positions_v where id::text like '55555555-5555-4555-8555-%'),
  2::bigint,
  '非 admin 经 positions_v 只读 active 岗位'
);
-- 23
select is(
  (select department_name from public.positions_v
    where id = '55555555-5555-4555-8555-555555550001'),
  '测试-岗位部A',
  'positions_v.department_name 关联部门名正确'
);

-- ===========================================================================
-- 4. anon 无任何读取路径
-- ===========================================================================
-- 24
set local role anon;
select throws_ok(
  $$ select count(*) from public.positions $$,
  '42501', null, 'anon 无 positions 读取权限'
);

-- ===========================================================================
-- 5. 越权直写与越权 RPC（engineer）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;

-- 25
select throws_ok(
  $$ insert into public.positions (name, code) values ('越权新增', 'TEST-HACK-1') $$,
  '42501', null, '非 admin 表级 INSERT 被拒'
);
-- 26
select throws_ok(
  $$ update public.positions set name = '越权改名'
     where id = '55555555-5555-4555-8555-555555550001' $$,
  '42501', null, '非 admin 表级 UPDATE 被拒'
);
-- 27
select throws_ok(
  $$ delete from public.positions
     where id = '55555555-5555-4555-8555-555555550001' $$,
  '42501', null, '非 admin 表级 DELETE 被拒'
);
-- 28
select throws_ok(
  $$ select public.upsert_position(null, '越权 RPC', 'TEST-HACK-2',
       null, 0, null, 'active') $$,
  '42501', '仅管理员可执行此操作', '非 admin 调用 upsert_position 被拒'
);
-- 29
select throws_ok(
  $$ select public.disable_position('55555555-5555-4555-8555-555555550001') $$,
  '42501', '仅管理员可执行此操作', '非 admin 调用 disable_position 被拒'
);
-- 30
select throws_ok(
  $$ select public.delete_position('55555555-5555-4555-8555-555555550001') $$,
  '42501', '仅管理员可执行此操作', '非 admin 调用 delete_position 被拒'
);

-- ===========================================================================
-- 6. admin：读全量（含 disabled）、经 RPC 写入
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

-- 31
select is(
  (select count(*) from public.positions where id::text like '55555555-5555-4555-8555-%'),
  3::bigint,
  'admin 表级可见全部岗位（含 disabled）'
);
-- 32
select is(
  (select count(*) from public.positions_v where id::text like '55555555-5555-4555-8555-%'),
  3::bigint,
  'admin 经 positions_v 可见全部岗位（含 disabled）'
);
-- 33
select is(
  (select (public.upsert_position(
     null, '测试-岗位C1', 'TEST-POS-C1',
     '44444444-4444-4444-4444-444444440002', 2, '岗位C1描述', 'active')).name),
  '测试-岗位C1',
  'admin 经 RPC 新建岗位'
);
-- 34
select is(
  (select headcount from public.positions where code = 'TEST-POS-C1'),
  2,
  '新建岗位编制数落库正确'
);
-- 35
select is(
  (select department_id::text from public.positions where code = 'TEST-POS-C1'),
  '44444444-4444-4444-4444-444444440002',
  '新建岗位所属部门落库正确'
);
-- 36
select throws_ok(
  $$ select public.upsert_position(null, '测试-岗位C2', 'TEST-POS-A1',
       null, 0, null, 'active') $$,
  '23505', '岗位编码已存在：TEST-POS-A1',
  '新建时 code 唯一冲突被 DB 兜底并转中文提示'
);
-- 37
select is(
  (select (public.upsert_position(
     '55555555-5555-4555-8555-555555550001', '测试-岗位A1改', 'TEST-POS-A1',
     '44444444-4444-4444-4444-444444440001', 4, '岗位A1改', 'active')).name),
  '测试-岗位A1改',
  'admin 经 RPC 编辑岗位名称/编制'
);
-- 38
select throws_ok(
  $$ select public.upsert_position(
       '55555555-5555-4555-8555-555555550001', '测试-岗位A1改', 'TEST-POS-B1',
       '44444444-4444-4444-4444-444444440001', 4, '岗位A1改', 'active') $$,
  '23505', '岗位编码已存在：TEST-POS-B1',
  '编辑时 code 唯一冲突被 DB 兜底'
);
-- 39
select throws_ok(
  $$ select public.upsert_position(null, '测试-岗位D', 'TEST-POS-D',
       null, -1, null, 'active') $$,
  '22023', '编制数不能为负数', '编制数为负被拒'
);
-- 40
select is(
  (select (public.disable_position('55555555-5555-4555-8555-555555550001')).status),
  'disabled',
  '被引用前停用岗位成功（停用不拒绝引用）'
);
-- 41
select is(
  (select (public.disable_position('55555555-5555-4555-8555-555555550001')).status),
  'disabled',
  '重复停用幂等'
);
-- 42
select is(
  (select (public.enable_position('55555555-5555-4555-8555-555555550002')).status),
  'active',
  'admin 启用岗位成功（幂等语义）'
);
-- 43
select is(
  (select app.position_headcount('55555555-5555-4555-8555-555555550001')),
  0::bigint,
  '无在职引用时在岗数为 0'
);

-- ===========================================================================
-- 7. 在岗统计：org/007 起按 profiles.position_id 精确统计（文本兜底口径退役）
-- ===========================================================================
-- 44
select is(
  (select (public.admin_update_profile(
     '22222222-2222-2222-2222-222222220001', null, '测试-岗位部A', null, null)).department),
  '测试-岗位部A',
  '装置：engineer 挂到测试-岗位部A'
);
-- 45：position_id 全 NULL 过渡期，文本口径退役后恒为 0
select is(
  (select app.position_headcount('55555555-5555-4555-8555-555555550001')),
  0::bigint,
  'position_id 全 NULL 期在岗统计为 0（文本兜底口径退役）'
);
-- 46
select is(
  (select staff_count from public.positions_v
    where id = '55555555-5555-4555-8555-555555550001'),
  0::bigint,
  'positions_v.staff_count 与在岗统计一致（0）'
);
-- 46b：直写 position_id（org/009 前无页面入口，测试用 postgres 模拟）
reset role;
update public.profiles
   set position_id = '55555555-5555-4555-8555-555555550001',
       department  = null
 where id = '22222222-2222-2222-2222-222222220001';
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select is(
  (select app.position_headcount('55555555-5555-4555-8555-555555550001')),
  1::bigint,
  '按 position_id 精确统计：绑定岗位后为 1（部门文本已清空，证明非文本口径）'
);
-- 46c
select is(
  (select staff_count from public.positions_v
    where id = '55555555-5555-4555-8555-555555550001'),
  1::bigint,
  'positions_v.staff_count 按 position_id 统计（1）'
);
-- 47
select throws_ok(
  $$ select public.delete_position('55555555-5555-4555-8555-555555550001') $$,
  '22023', '该岗位仍有 1 名在职人员（按所属部门统计），无法删除',
  '删除被 position_id 引用的岗位被拒（FK 前友好提示）'
);
-- 47b：被引用时停用允许（仅新编辑下拉过滤）
select is(
  (select (public.disable_position('55555555-5555-4555-8555-555555550002')).status),
  'disabled',
  '存在在职引用时停用岗位仍成功（仅过滤新编辑下拉）'
);

-- ===========================================================================
-- 8. postgres 直插：DB 唯一约束本身兜底；随后清空引用
-- ===========================================================================
reset role;
-- 48
select throws_ok(
  $$ insert into public.positions (name, code) values ('重复编码', 'TEST-POS-C1') $$,
  '23505', null, 'DB 层 code 唯一约束兜底（绕过 RPC 直插同样被拒）'
);
-- 49
update public.profiles
   set position_id = null
 where id = '22222222-2222-2222-2222-222222220001';

-- ===========================================================================
-- 9. 删除：清空引用后可删；无引用岗位可删
-- ===========================================================================
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

-- 49
select is(
  (select (public.delete_position('55555555-5555-4555-8555-555555550001')).name),
  '测试-岗位A1改',
  '清空引用后删除岗位成功'
);
-- 50
select is(
  (select count(*) from public.positions
    where id = '55555555-5555-4555-8555-555555550001'),
  0::bigint,
  '删除为物理删除，行已消失'
);
-- 51
select is(
  (select (public.delete_position('55555555-5555-4555-8555-555555550003')).code),
  'TEST-POS-B1',
  '无引用岗位可直接删除'
);

reset role;
select * from finish();
rollback;
