-- 权限管理 · 所属部门 deleted/disabled 回退「无部门」语义（access 批次 2 / 修复项 1）pgTAP 测试
-- 运行：supabase db reset && supabase test db
-- 覆盖：函数结构 / department_id → deleted|disabled 解析为 null / active 正常 /
--       历史行（department_id 空 + 文本匹配 active）兜底 /
--       真实会话下 dept scope：deleted|disabled 回退仅本人、active 按部门成员。
-- 说明：夹具仅在事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(12);

-- ===========================================================================
-- 1. 函数结构（2）
-- ===========================================================================
select has_function('app', 'resolve_user_department', array['uuid'],
  'app.resolve_user_department 存在');
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = 'resolve_user_department'),
  'app.resolve_user_department：security definer + search_path 固定为空'
);

-- ===========================================================================
-- 2. 夹具（as postgres）
--    d1 active / d2 deleted / d3 disabled；
--    u1@d1、u5@d1（对照组）；u2 绑 deleted d2；u3 绑 disabled d3；
--    u4 历史行：department_id 为空 + 文本 = d1 名称（临时停触发器构造）。
-- ===========================================================================
insert into public.departments (id, name, parent_id, sort_order, status) values
  ('b0000000-0000-4000-a000-000000000001', '回落测试-部门甲', null, 1, 'active'),
  ('b0000000-0000-4000-a000-000000000002', '回落测试-部门乙', null, 2, 'deleted'),
  ('b0000000-0000-4000-a000-000000000003', '回落测试-部门丙', null, 3, 'disabled');

insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
  ('b1000000-0000-4000-a000-000000000001', 'fallback-u1@example.com',
   '{"role":"engineer"}'::jsonb, '{"full_name":"回落-用户一"}'::jsonb),
  ('b1000000-0000-4000-a000-000000000002', 'fallback-u2@example.com',
   '{"role":"engineer"}'::jsonb, '{"full_name":"回落-用户二"}'::jsonb),
  ('b1000000-0000-4000-a000-000000000003', 'fallback-u3@example.com',
   '{"role":"engineer"}'::jsonb, '{"full_name":"回落-用户三"}'::jsonb),
  ('b1000000-0000-4000-a000-000000000004', 'fallback-u4@example.com',
   '{"role":"engineer"}'::jsonb, '{"full_name":"回落-用户四"}'::jsonb),
  ('b1000000-0000-4000-a000-000000000005', 'fallback-u5@example.com',
   '{"role":"engineer"}'::jsonb, '{"full_name":"回落-用户五"}'::jsonb);

update public.profiles
   set department_id = 'b0000000-0000-4000-a000-000000000001'
 where id in ('b1000000-0000-4000-a000-000000000001',
              'b1000000-0000-4000-a000-000000000005');

update public.profiles
   set department_id = 'b0000000-0000-4000-a000-000000000002'
 where id = 'b1000000-0000-4000-a000-000000000002';

update public.profiles
   set department_id = 'b0000000-0000-4000-a000-000000000003'
 where id = 'b1000000-0000-4000-a000-000000000003';

-- 历史行：department_id 为空 + 文本匹配 active 部门（构造迁移前存量形态）
alter table public.profiles disable trigger profiles_sync_department;
update public.profiles
   set department_id = null,
       department    = '回落测试-部门甲'
 where id = 'b1000000-0000-4000-a000-000000000004';
alter table public.profiles enable trigger profiles_sync_department;

-- 统一实测 dept 档语义
update public.role_data_scopes
   set scope = 'dept'
 where role_id = (select id from public.roles where code = 'engineer');

-- ===========================================================================
-- 3. resolve_user_department 解析（4）
-- ===========================================================================
select is(
  app.resolve_user_department('b1000000-0000-4000-a000-000000000002'),
  null::uuid,
  'department_id 指向 deleted 部门：解析为 null（视同无部门）'
);
select is(
  app.resolve_user_department('b1000000-0000-4000-a000-000000000003'),
  null::uuid,
  'department_id 指向 disabled 部门：解析为 null（视同无部门）'
);
select is(
  app.resolve_user_department('b1000000-0000-4000-a000-000000000001'),
  'b0000000-0000-4000-a000-000000000001'::uuid,
  'department_id 指向 active 部门：正常返回'
);
select is(
  app.resolve_user_department('b1000000-0000-4000-a000-000000000004'),
  'b0000000-0000-4000-a000-000000000001'::uuid,
  'department_id 为空的历史行：仍按部门名 active 精确匹配兜底'
);

-- ===========================================================================
-- 4. 真实会话：deleted/disabled 回退仅本人（4）
-- ===========================================================================
set local request.jwt.claims = '{"sub":"b1000000-0000-4000-a000-000000000002","role":"authenticated"}';
set local role authenticated;
select results_eq(
  $$ select u from app.scope_user_ids() as u order by u $$,
  $$ values ('b1000000-0000-4000-a000-000000000002'::uuid) $$,
  '绑定 deleted 部门 + dept scope：回退仅本人（不再空集）'
);
select is(
  (select count(*) from app.scope_dept_ids()),
  0::bigint,
  '绑定 deleted 部门 + dept scope：部门集为空'
);

reset role;
set local request.jwt.claims = '{"sub":"b1000000-0000-4000-a000-000000000003","role":"authenticated"}';
set local role authenticated;
select results_eq(
  $$ select u from app.scope_user_ids() as u order by u $$,
  $$ values ('b1000000-0000-4000-a000-000000000003'::uuid) $$,
  '绑定 disabled 部门 + dept scope：回退仅本人'
);
select is(
  (select count(*) from app.scope_dept_ids()),
  0::bigint,
  '绑定 disabled 部门 + dept scope：部门集为空'
);

-- ===========================================================================
-- 5. 对照组：active 部门仍按部门成员（含文本兜底成员）（2）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"b1000000-0000-4000-a000-000000000001","role":"authenticated"}';
set local role authenticated;
select results_eq(
  $$ select u from app.scope_user_ids() as u order by u $$,
  $$ values ('b1000000-0000-4000-a000-000000000001'::uuid),
            ('b1000000-0000-4000-a000-000000000004'::uuid),
            ('b1000000-0000-4000-a000-000000000005'::uuid) $$,
  'active 部门 + dept scope：按部门成员返回（含 id 成员与文本兜底成员）'
);
select results_eq(
  $$ select d from app.scope_dept_ids() as d order by d $$,
  $$ values ('b0000000-0000-4000-a000-000000000001'::uuid) $$,
  'active 部门 + dept scope：部门集为所属部门'
);

select * from finish();
rollback;
