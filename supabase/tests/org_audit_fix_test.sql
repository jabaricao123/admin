-- pgTAP：org 审计缺口修复（批次 1）—— 9 个写 RPC 审计摘要 + sync 部门防环/同名收紧 + 同级名称唯一索引
-- 运行：supabase db reset && supabase test db
-- 覆盖：
--   * 部门 4 RPC（upsert create/update、disable、enable、delete）逐次写操作 → module='org'
--     且 action 正确、diff 含 before/after；幂等分支不重复记审计；软删除后同名可再建；
--   * 岗位 4 RPC（upsert create/update、disable、enable、delete）同上（delete after=null）；
--   * admin_update_profile：update 审计 + diff 仅收口实际变更字段 + actor 记录；
--   * sync 防环：研发中心 parent→前端组（其子孙）→ 该行 rejected 冲突、未成环、stats.notes 标注；
--     全 rejected 且无失败行时 run 收敛 success（rejected 属策略性拒绝、非错误）；
--   * sync parent_name 收紧：同名 active 取 sort_order 最小者并标歧义；仅 disabled 不兜底；
--   * departments 同级名称唯一索引存在性 / 冲突拒绝 / 软删除豁免 / RPC 中文提示。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(30);

-- ===========================================================================
-- 0. 夹具（as postgres）：
--    同步同名场景：审计-父甲/乙 各挂一行「审计-同名父」（sort 9/2），另有仅停用父；
-- ===========================================================================
insert into public.departments (id, name, parent_id, sort_order, status, created_by)
values
  ('aaaaaaaa-0000-4000-8000-0000000000b1', '审计-父甲', null, 1, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('aaaaaaaa-0000-4000-8000-0000000000b2', '审计-父乙', null, 2, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('aaaaaaaa-0000-4000-8000-0000000000c1', '审计-同名父',
   'aaaaaaaa-0000-4000-8000-0000000000b1', 9, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('aaaaaaaa-0000-4000-8000-0000000000c2', '审计-同名父',
   'aaaaaaaa-0000-4000-8000-0000000000b2', 2, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('aaaaaaaa-0000-4000-8000-0000000000e1', '审计-仅停用父', null, 1, 'disabled',
   '11111111-1111-1111-1111-111111111111');

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

-- ===========================================================================
-- 1. 部门 RPC 审计（7）
-- ===========================================================================
select (public.upsert_department(null, '审计-部门', null, null, 1)).id as dept_id \gset

select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'org' and action = 'create'
      and object_type = 'department' and object_id = :'dept_id'
      and (diff ? 'before') and diff -> 'before' = 'null'::jsonb
      and diff -> 'after' ->> 'name' = '审计-部门'
  ),
  'upsert_department 新建：create 审计，diff.before=null / diff.after=行快照'
);

select (public.upsert_department(:'dept_id'::uuid, '审计-部门改', null, null, 2)).id as dept_id2 \gset
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'org' and action = 'update'
      and object_type = 'department' and object_id = :'dept_id'
      and diff -> 'before' ->> 'name' = '审计-部门'
      and diff -> 'after' ->> 'name' = '审计-部门改'
  ),
  'upsert_department 编辑：update 审计，diff 含变更前后'
);

select (public.disable_department(:'dept_id'::uuid)).status as dept_status \gset
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'org' and action = 'disable'
      and object_type = 'department' and object_id = :'dept_id'
      and diff -> 'before' ->> 'status' = 'active'
      and diff -> 'after' ->> 'status' = 'disabled'
  ),
  'disable_department：disable 审计，状态 before/after 正确'
);

select (public.enable_department(:'dept_id'::uuid)).status as dept_status \gset
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'org' and action = 'enable'
      and object_type = 'department' and object_id = :'dept_id'
      and diff -> 'after' ->> 'status' = 'active'
  ),
  'enable_department：enable 审计，after 状态 active'
);

-- 幂等重放：已是 active 再 enable 不产生新审计
select (public.enable_department(:'dept_id'::uuid)).status as dept_status \gset
select is(
  (select count(*) from public.audit_operations
    where module = 'org' and action = 'enable'
      and object_type = 'department' and object_id = :'dept_id'),
  1::bigint,
  '幂等 enable 未发生写入：不重复记审计'
);

select (public.delete_department(:'dept_id'::uuid)).status as dept_status \gset
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'org' and action = 'delete'
      and object_type = 'department' and object_id = :'dept_id'
      and diff -> 'after' ->> 'status' = 'deleted'
  ),
  'delete_department：delete 审计，after 状态 deleted'
);

-- 软删除行不占用唯一索引：同名同级可再建
select lives_ok(
  $$ select public.upsert_department(null, '审计-部门', null, null, 9) $$,
  '软删除（deleted）同名行不占用唯一索引：同级同名可再建'
);

-- ===========================================================================
-- 2. 岗位 RPC 审计（5）
-- ===========================================================================
select (public.upsert_position(
  null, '审计-岗位', 'AUDIT-P1', null, 1, null, 'active'
)).id as pos_id \gset

select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'org' and action = 'create'
      and object_type = 'position' and object_id = :'pos_id'
      and (diff ? 'before') and diff -> 'before' = 'null'::jsonb
      and diff -> 'after' ->> 'code' = 'AUDIT-P1'
  ),
  'upsert_position 新建：create 审计，diff.before=null / after 含 code'
);

select (public.upsert_position(
  :'pos_id'::uuid, '审计-岗位改', 'AUDIT-P1', null, 2, null, 'active'
)).id as pos_id2 \gset
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'org' and action = 'update'
      and object_type = 'position' and object_id = :'pos_id'
      and diff -> 'before' ->> 'name' = '审计-岗位'
      and diff -> 'after' ->> 'name' = '审计-岗位改'
  ),
  'upsert_position 编辑：update 审计，diff 含变更前后'
);

select (public.disable_position(:'pos_id'::uuid)).status as pos_status \gset
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'org' and action = 'disable'
      and object_type = 'position' and object_id = :'pos_id'
      and diff -> 'after' ->> 'status' = 'disabled'
  ),
  'disable_position：disable 审计，after 状态 disabled'
);

select (public.enable_position(:'pos_id'::uuid)).status as pos_status \gset
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'org' and action = 'enable'
      and object_type = 'position' and object_id = :'pos_id'
      and diff -> 'after' ->> 'status' = 'active'
  ),
  'enable_position：enable 审计，after 状态 active'
);

select (public.delete_position(:'pos_id'::uuid)).name as pos_name \gset
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'org' and action = 'delete'
      and object_type = 'position' and object_id = :'pos_id'
      and diff -> 'before' ->> 'code' = 'AUDIT-P1'
      and diff -> 'after' = 'null'::jsonb
  ),
  'delete_position（物理删除）：delete 审计，before=原行 / after=null'
);

-- ===========================================================================
-- 3. 用户档案 RPC 审计（3）
-- ===========================================================================
select (public.admin_update_profile(
  '22222222-2222-2222-2222-222222220002', '审计-改名'
)).full_name as prof_name \gset

select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'org' and action = 'update'
      and object_type = 'profile' and object_id = '22222222-2222-2222-2222-222222220002'
      and (diff -> 'before') ? 'full_name'
      and diff -> 'after' ->> 'full_name' = '审计-改名'
  ),
  'admin_update_profile：update 审计，diff 含变更字段 before/after'
);

select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'org' and action = 'update'
      and object_type = 'profile' and object_id = '22222222-2222-2222-2222-222222220002'
      and not ((diff -> 'before') ? 'status')
      and not ((diff -> 'after') ? 'status')
  ),
  'admin_update_profile：未变更字段不进 diff（status 未传不记录）'
);

select is(
  (select actor_id from public.audit_operations
    where module = 'org' and action = 'update'
      and object_type = 'profile' and object_id = '22222222-2222-2222-2222-222222220002'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  '审计 actor_id = 操作人（auth.uid）'
);

-- ===========================================================================
-- 4. sync 防环：研发中心 parent→前端组（其子孙）（5）
-- ===========================================================================
select public.upsert_sync_source(
  null, '审计防环源', 'api', '{"base_url":"https://guard.example.com"}'::jsonb, 'tok-guard', null
) as gs \gset
select public.test_sync_source((:'gs'::jsonb ->> 'id')::uuid) as gsv \gset
select public.upsert_sync_task(
  null, '审计部门防环任务', (:'gs'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"dept","target_field":"name"},{"source_field":"parent","target_field":"parent_name"}]'::jsonb,
  'overwrite', null
) as gt \gset
reset role;

select app.execute_sync_task(
  (:'gt'::jsonb ->> 'id')::uuid, 'manual',
  '[{"dept":"研发中心","parent":"前端组"}]'::jsonb
) as run_guard \gset

select is(
  (select (stats ->> 'conflict')::int from public.sync_runs where id = :'run_guard'),
  1,
  '防环拒绝行计入 stats.conflict=1'
);
select is(
  (select status from public.sync_runs where id = :'run_guard'),
  'success',
  '全 rejected 无失败行：status=success（rejected 属策略性拒绝、非错误）'
);
select is(
  (select resolution from public.sync_conflicts where run_id = :'run_guard'),
  'rejected',
  '防环拒绝冲突 resolution=rejected（不可人工采纳）'
);
select ok(
  (select target_data ->> 'reject_reason' like '%循环%'
     from public.sync_conflicts where run_id = :'run_guard'),
  '冲突 target_data.reject_reason 标注防环原因'
);
select is(
  (select parent_id from public.departments where id = '33333333-3333-3333-3333-333333330002'),
  '33333333-3333-3333-3333-333333330001'::uuid,
  '研发中心 parent 未被改写：部门树未成环'
);
select ok(
  (select stats::text like '%防环拒绝%' from public.sync_runs where id = :'run_guard'),
  'stats.notes 标注防环拒绝'
);

-- ===========================================================================
-- 5. sync parent_name 收紧：同名取 sort_order 最小 active / 仅 disabled 不兜底（4）
-- ===========================================================================
select app.execute_sync_task(
  (:'gt'::jsonb ->> 'id')::uuid, 'manual',
  '[{"dept":"审计-待挂部","parent":"审计-同名父"}]'::jsonb
) as run_amb \gset

select is(
  (select parent_id from public.departments where name = '审计-待挂部'),
  'aaaaaaaa-0000-4000-8000-0000000000c2'::uuid,
  '同名多 active：parent_name 取 sort_order 最小者（c2 sort=2）'
);
select ok(
  (select stats::text like '%同名%' from public.sync_runs where id = :'run_amb'),
  'stats.notes 标注 parent_name 同名歧义'
);

select app.execute_sync_task(
  (:'gt'::jsonb ->> 'id')::uuid, 'manual',
  '[{"dept":"审计-停用挂载","parent":"审计-仅停用父"}]'::jsonb
) as run_dis \gset

select is(
  (select (stats ->> 'failed')::int from public.sync_runs where id = :'run_dis'),
  1,
  '仅 disabled 同名不再兜底：parent 解析失败计 failed'
);
select is(
  (select count(*) from public.departments where name = '审计-停用挂载'),
  0::bigint,
  'parent 解析失败不新建目标部门'
);

-- ===========================================================================
-- 6. departments 同级名称唯一索引（5）
-- ===========================================================================
select has_index(
  'public', 'departments', 'departments_parent_name_key',
  '同级名称唯一索引 departments_parent_name_key 存在'
);
select is(
  (select count(*) from public.departments
    where name = '审计-同名父' and status = 'active'),
  2::bigint,
  '不同父级下同名 active 部门允许共存'
);

insert into public.departments (id, name, parent_id, sort_order, status, created_by)
values ('aaaaaaaa-0000-4000-8000-0000000000d1', '审计-唯部',
        'aaaaaaaa-0000-4000-8000-0000000000b1', 1, 'active',
        '11111111-1111-1111-1111-111111111111');

select throws_ok(
  $$ insert into public.departments (name, parent_id, sort_order, status)
     values ('审计-唯部', 'aaaaaaaa-0000-4000-8000-0000000000b1', 2, 'active') $$,
  '23505', null,
  '同父级同名再插入被唯一索引拒绝（23505）'
);
select lives_ok(
  $$ insert into public.departments (name, parent_id, sort_order, status)
     values ('审计-唯部', 'aaaaaaaa-0000-4000-8000-0000000000b1', 3, 'deleted') $$,
  '软删除行不参与唯一索引（同父级同名 deleted 允许）'
);

set local role authenticated;
select throws_ok(
  $$ select public.upsert_department(null, '审计-唯部', 'aaaaaaaa-0000-4000-8000-0000000000b1', null, 3) $$,
  '23505', '同级部门名称已存在：审计-唯部',
  'upsert_department 同级重名转 23505 中文提示'
);
reset role;

select * from finish();
rollback;
