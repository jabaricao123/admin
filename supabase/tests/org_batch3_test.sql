-- pgTAP：org 数据层批次 3 —— 部门/岗位清空语义 + 部门改名级联 + 删除岗位引用拦截
-- 运行：supabase db reset && supabase test db
-- 覆盖：
--   * admin_update_profile p_clear_department/p_clear_position：显式清空 id + 文本
--     （null→null 回写与历史文本行兜底）、互斥冲突 22023、幂等重放、审计 diff；
--   * upsert_department 改名级联：profiles.department 文本同步、department_id 保持
--     （含 disabled 部门改名与跨父级同名 active 抢绑防护）、文本解析规则未改（对照组）；
--   * delete_department 岗位引用：active/disabled 岗位均拦截并提示数量，
--     岗位移出（department_id 置空）后删除成功，无岗位部门不受影响。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。
--       RPC 调用与状态断言分语句执行，避免同一表达式内求值顺序不确定。

begin;

select plan(19);

-- ===========================================================================
-- 0. 夹具（as postgres；admin = 11111111-1111-1111-1111-111111111111）
--    部门：清空部 / 改名部 / 停用改名部 / 岗位部×2 / 跨父级同名对照组；
--    岗位：挂部门一 / 挂部门二 / 通用（无部门）；
--    用户：handle_new_user 建档（department_id 为 NULL）
-- ===========================================================================
insert into public.departments (id, name, parent_id, sort_order, status, created_by)
values
  ('e0000000-0000-4000-8000-000000000001', 'B3-清空部', null, 1, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('e0000000-0000-4000-8000-000000000002', 'B3-改名部', null, 2, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('e0000000-0000-4000-8000-000000000003', 'B3-停用改名部', null, 3, 'disabled',
   '11111111-1111-1111-1111-111111111111'),
  ('e0000000-0000-4000-8000-000000000010', 'B3-挂载甲', null, 10, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('e0000000-0000-4000-8000-000000000011', 'B3-挂载乙', null, 11, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('e0000000-0000-4000-8000-000000000004', 'B3-同名部',
   'e0000000-0000-4000-8000-000000000010', 1, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('e0000000-0000-4000-8000-000000000005', 'B3-待改名',
   'e0000000-0000-4000-8000-000000000011', 9, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('e0000000-0000-4000-8000-000000000006', 'B3-岗位部', null, 20, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('e0000000-0000-4000-8000-000000000007', 'B3-岗位部二', null, 21, 'active',
   '11111111-1111-1111-1111-111111111111');

insert into public.positions (id, name, code, department_id, status, created_by, updated_by)
values
  ('e1000000-0000-4000-8000-000000000001', 'B3-岗位一', 'B3-P1',
   'e0000000-0000-4000-8000-000000000006', 'active',
   '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111'),
  ('e1000000-0000-4000-8000-000000000002', 'B3-岗位二', 'B3-P2',
   'e0000000-0000-4000-8000-000000000007', 'active',
   '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111'),
  ('e1000000-0000-4000-8000-000000000003', 'B3-岗位三', 'B3-P3', null, 'active',
   '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111');

insert into auth.users (id, email, raw_app_meta_data) values
  ('e2000000-0000-4000-8000-000000000001', 'org-b3-u1@example.com', '{}'::jsonb),
  ('e2000000-0000-4000-8000-000000000002', 'org-b3-u2@example.com', '{}'::jsonb),
  ('e2000000-0000-4000-8000-000000000003', 'org-b3-u3@example.com', '{}'::jsonb),
  ('e2000000-0000-4000-8000-000000000004', 'org-b3-u4@example.com', '{}'::jsonb),
  ('e2000000-0000-4000-8000-000000000005', 'org-b3-u5@example.com', '{}'::jsonb),
  ('e2000000-0000-4000-8000-000000000006', 'org-b3-u6@example.com', '{}'::jsonb);

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

-- ===========================================================================
-- 1. 清空语义（7）：p_clear_department/p_clear_position 显式置 null
-- ===========================================================================
select (public.admin_update_profile(
  'e2000000-0000-4000-8000-000000000001', null, null, null, null,
  'e0000000-0000-4000-8000-000000000001',
  'e1000000-0000-4000-8000-000000000003'
)).id as u1_bind_id \gset

select is(
  (select department_id::text || '|' || department || '|' || position_id::text
     from public.profiles
    where id = 'e2000000-0000-4000-8000-000000000001'),
  'e0000000-0000-4000-8000-000000000001|B3-清空部|e1000000-0000-4000-8000-000000000003',
  '装置：u1 绑定部门一 + 通用岗位三（文本回写一致）'
);

select (public.admin_update_profile(
  'e2000000-0000-4000-8000-000000000001', null, null, null, null,
  null, null, true, false
)).id as u1_clear_dept_id \gset

select is(
  (select department_id is null
      and department is null
      and position_id = 'e1000000-0000-4000-8000-000000000003'
     from public.profiles
    where id = 'e2000000-0000-4000-8000-000000000001'),
  true,
  'p_clear_department：department_id 与文本均置空，岗位绑定不受影响'
);

select (public.admin_update_profile(
  'e2000000-0000-4000-8000-000000000001', null, null, null, null,
  null, null, false, true
)).id as u1_clear_pos_id \gset

select is(
  (select position_id from public.profiles
    where id = 'e2000000-0000-4000-8000-000000000001'),
  null::uuid,
  'p_clear_position：position_id 置空'
);

select lives_ok(
  $$ select public.admin_update_profile(
       'e2000000-0000-4000-8000-000000000001', null, null, null, null,
       null, null, true, true) $$,
  '已为空时重复 clear 幂等（无异常）'
);

select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'org' and action = 'update' and object_type = 'profile'
      and object_id = 'e2000000-0000-4000-8000-000000000001'
      and diff -> 'before' ->> 'department_id' = 'e0000000-0000-4000-8000-000000000001'
      and diff -> 'after' -> 'department_id' = 'null'::jsonb
  ),
  '清空部门写入审计 diff（before=原 id / after=null）'
);

select throws_ok(
  $$ select public.admin_update_profile(
       'e2000000-0000-4000-8000-000000000001', null, null, null, null,
       'e0000000-0000-4000-8000-000000000001', null, true, false) $$,
  '22023', '不能同时清空并指定部门',
  'clear 与指定部门互斥（22023）'
);

select throws_ok(
  $$ select public.admin_update_profile(
       'e2000000-0000-4000-8000-000000000001', null, null, null, null,
       null, 'e1000000-0000-4000-8000-000000000003', false, true) $$,
  '22023', '不能同时清空并指定岗位',
  'clear 与指定岗位互斥（22023）'
);

-- ===========================================================================
-- 2. 改名级联（6）：文本同步 + department_id 保持
-- ===========================================================================
select (public.admin_update_profile(
  'e2000000-0000-4000-8000-000000000002', null, null, null, null,
  'e0000000-0000-4000-8000-000000000002', null
)).id as u2_bind_id \gset

select is(
  (select department_id::text || '|' || department
     from public.profiles
    where id = 'e2000000-0000-4000-8000-000000000002'),
  'e0000000-0000-4000-8000-000000000002|B3-改名部',
  '装置：u2 绑定改名部'
);

select (public.upsert_department(
  'e0000000-0000-4000-8000-000000000002', 'B3-改名部改', null, null, 2
)).id as rename_active_id \gset

select is(
  (select d.name || '|' || p.department_id::text || '|' || p.department
     from public.departments d
     join public.profiles p on p.id = 'e2000000-0000-4000-8000-000000000002'
    where d.id = :'rename_active_id'),
  'B3-改名部改|e0000000-0000-4000-8000-000000000002|B3-改名部改',
  'active 部门改名：profiles.department 文本级联同步（id 保持）'
);

select (public.admin_update_profile(
  'e2000000-0000-4000-8000-000000000003', null, null, null, null,
  'e0000000-0000-4000-8000-000000000003', null
)).id as u3_bind_id \gset

select is(
  (select department_id::text || '|' || department
     from public.profiles
    where id = 'e2000000-0000-4000-8000-000000000003'),
  'e0000000-0000-4000-8000-000000000003|B3-停用改名部',
  '装置：u3 绑定停用部门（允许存量写入）'
);

select (public.upsert_department(
  'e0000000-0000-4000-8000-000000000003', 'B3-停用改名部改', null, null, 3
)).id as rename_disabled_id \gset

select is(
  (select d.name || '|' || p.department_id::text || '|' || p.department
     from public.departments d
     join public.profiles p on p.id = 'e2000000-0000-4000-8000-000000000003'
    where d.id = :'rename_disabled_id'),
  'B3-停用改名部改|e0000000-0000-4000-8000-000000000003|B3-停用改名部改',
  'disabled 部门改名：文本同步且 department_id 不被 active 解析清空'
);

select (public.admin_update_profile(
  'e2000000-0000-4000-8000-000000000004', null, null, null, null,
  'e0000000-0000-4000-8000-000000000005', null
)).id as u4_bind_id \gset

select is(
  (select department_id::text || '|' || department
     from public.profiles
    where id = 'e2000000-0000-4000-8000-000000000004'),
  'e0000000-0000-4000-8000-000000000005|B3-待改名',
  '装置：u4 绑定待改名部（sort=9，同名部 sort=1 存在于另一父级）'
);

select (public.upsert_department(
  'e0000000-0000-4000-8000-000000000005', 'B3-同名部',
  'e0000000-0000-4000-8000-000000000011', null, 9
)).id as rename_collide_id \gset

select is(
  (select d.name || '|' || p.department_id::text || '|' || p.department
     from public.departments d
     join public.profiles p on p.id = 'e2000000-0000-4000-8000-000000000004'
    where d.id = :'rename_collide_id'),
  'B3-同名部|e0000000-0000-4000-8000-000000000005|B3-同名部',
  '跨父级同名 active：改名部门下人员不被 sort_order 最小者抢绑'
);

-- ===========================================================================
-- 3. 文本解析规则未改 + 历史文本行清空兜底（2）
-- ===========================================================================
select (public.admin_update_profile(
  'e2000000-0000-4000-8000-000000000005', null, 'B3-同名部', null, null
)).department_id as u5_resolved \gset

select is(
  (select department_id::text from public.profiles
    where id = 'e2000000-0000-4000-8000-000000000005'),
  'e0000000-0000-4000-8000-000000000004',
  '对照组：无绑定的文本路径仍按 active + sort_order 最小解析（取同名部 sort=1）'
);

select (public.admin_update_profile(
  'e2000000-0000-4000-8000-000000000006', null, 'B3-遗留文本', null, null
)).id as u6_legacy_id \gset

select (public.admin_update_profile(
  'e2000000-0000-4000-8000-000000000006', null, null, null, null,
  null, null, true, false
)).id as u6_clear_id \gset

select is(
  (select department_id is null and department is null
     from public.profiles
    where id = 'e2000000-0000-4000-8000-000000000006'),
  true,
  '历史「id 为 NULL、文本非 NULL」行：clear 后文本兜底清空'
);

-- ===========================================================================
-- 4. delete_department 岗位引用拦截（3）
-- ===========================================================================
select throws_ok(
  $$ select public.delete_department('e0000000-0000-4000-8000-000000000006') $$,
  '22023', '该部门下仍有 1 个岗位，无法删除',
  '部门挂 active 岗位：删除被拒并提示岗位数'
);

select (public.disable_position(
  'e1000000-0000-4000-8000-000000000001'
)).id as p1_disabled_id \gset

select throws_ok(
  $$ select public.delete_department('e0000000-0000-4000-8000-000000000006') $$,
  '22023', '该部门下仍有 1 个岗位，无法删除',
  '岗位停用（disabled）仍计入引用拦截'
);

select (public.upsert_position(
  'e1000000-0000-4000-8000-000000000001', 'B3-岗位一', 'B3-P1',
  null, 0, null, 'disabled'
)).id as p1_moved_id \gset

select is(
  (select (public.delete_department(
     'e0000000-0000-4000-8000-000000000006')).status),
  'deleted',
  '岗位移出部门后（department_id 置空）：部门可逻辑删除'
);

-- ===========================================================================
-- 5. 无岗位部门删除不受影响（1）
-- ===========================================================================
select is(
  (select (public.delete_department(
     'e0000000-0000-4000-8000-000000000001')).status),
  'deleted',
  '无岗位引用的空部门删除路径不受影响'
);

reset role;
select * from finish();
rollback;
