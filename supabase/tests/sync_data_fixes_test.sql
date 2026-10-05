-- pgTAP：sync 数据正确性批次 1 —— email 重复守卫 / department_name 引用解析 /
--       rejected 收敛 / 映射重复字段 / input_summary / claims 还原
-- 运行：supabase db reset && supabase test db
-- 覆盖：
--   * profiles email 重复（2 行）：执行整行 failed、0 行被改、stats 准确，dry-run 同口径（failed + notes）；
--     单 email 正常更新时 stats.update 与实际写入行数对账一致；
--   * profiles.department_name 写不存在部门：整行 failed、原 department_id/department 文本不变；
--     存在部门正常绑定（department_id 解析，双写触发器回写规范名）；
--   * 全 rejected 冲突（防环）且无失败行：run 收敛 success；rejected+failed→failed、rejected+成功→success；
--   * validate_sync_mapping：同一 target_field 重复 → 22023「映射字段重复：xxx」；不同字段不误报；
--   * input_summary：样本行数 + md5(p_sample::text)，空样本/空跑（NULL）落库正确；rerun 无样本可执行；
--   * claims 还原：cron 执行（属主=created_by）后 request.jwt.claims 恢复为调用前值（audit actor=属主）。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(51);

-- ===========================================================================
-- 0. 夹具：源 + profiles/departments 任务（admin claims）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.upsert_sync_source(
  null, '数据修复测试源', 'api', '{"base_url":"https://fix.example.com"}'::jsonb, 'tok-fix', null
) as fs \gset
select public.test_sync_source((:'fs'::jsonb ->> 'id')::uuid) as fsv \gset

select public.upsert_sync_task(
  null, '修复档案任务', (:'fs'::jsonb ->> 'id')::uuid, 'profiles', 'pull',
  '[{"source_field":"mail","target_field":"email"},{"source_field":"nm","target_field":"full_name"},{"source_field":"dept","target_field":"department_name"}]'::jsonb,
  'overwrite', null
) as ft \gset
select public.upsert_sync_task(
  null, '修复部门任务', (:'fs'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"dept","target_field":"name"},{"source_field":"parent","target_field":"parent_name"}]'::jsonb,
  'overwrite', null
) as fd \gset
reset role;

-- ===========================================================================
-- 1. email 重复守卫：2 行同 email → 整行 failed、0 行被改、stats 准确（12+4）
-- ===========================================================================
update public.profiles
   set email = 'sync-dup@example.com'
 where id in (
   '22222222-2222-2222-2222-222222220001', -- engineer
   '22222222-2222-2222-2222-222222220002'  -- planner
 );

select app.execute_sync_task(
  (:'ft'::jsonb ->> 'id')::uuid, 'manual',
  '[{"mail":"sync-dup@example.com","nm":"不应写入"}]'::jsonb
) as run_dup \gset

select is(
  (select status from public.sync_runs where id = :'run_dup'),
  'failed',
  'email 重复：唯一行失败且无成功写入 → failed'
);
select is(
  (select (stats ->> 'failed')::int from public.sync_runs where id = :'run_dup'),
  1,
  'email 重复：stats.failed=1'
);
select is(
  (select (stats ->> 'update')::int from public.sync_runs where id = :'run_dup'),
  0,
  'email 重复：stats.update=0（不写任何行）'
);
select is(
  (select (stats ->> 'insert')::int from public.sync_runs where id = :'run_dup'),
  0,
  'email 重复：stats.insert=0'
);
select ok(
  (select error like '行 sync-dup@example.com：email 重复 2 行，拒绝写入'
     from public.sync_runs where id = :'run_dup'),
  'email 重复：error 带原因「email 重复 2 行，拒绝写入」'
);
select is(
  (select count(*) from public.profiles where email = 'sync-dup@example.com'),
  2::bigint,
  'email 重复：两行均保留（未删除未合并）'
);
select is(
  (select count(*) from public.profiles
    where email = 'sync-dup@example.com' and full_name = '不应写入'),
  0::bigint,
  'email 重复：0 行被写入'
);

-- dry-run 同口径：重复 email 计入 failed 并标注（不计 update/skip）
select app.dry_run_sync_task(
  (:'ft'::jsonb ->> 'id')::uuid,
  '[{"mail":"sync-dup@example.com","nm":"x"}]'::jsonb
) as dr_dup \gset

select is((:'dr_dup'::jsonb) ->> 'failed', '1', 'dry-run：email 重复计入 failed=1');
select is((:'dr_dup'::jsonb) ->> 'update', '0', 'dry-run：email 重复不计 update');
select is((:'dr_dup'::jsonb) ->> 'skip', '0', 'dry-run：email 重复不计 skip');
select is(
  (:'dr_dup'::jsonb) -> 'notes' -> 0 ->> 'code',
  'email_dup',
  'dry-run：notes 标注 code=email_dup'
);
select ok(
  (:'dr_dup'::jsonb) -> 'notes' -> 0 ->> 'message' like '%email 重复 2 行%',
  'dry-run：notes 文案与执行 error 同口径'
);

-- sync_apply_target 兜底：直接调用（冲突裁决 adopted 路径）同样拒绝，不写任何行
select throws_ok(
  format(
    $$ select app.sync_apply_target(%L::uuid, '{"email":"sync-dup@example.com","full_name":"x"}'::jsonb, 'update') $$,
    (:'ft'::jsonb ->> 'id')
  ),
  '23505', 'email 重复 2 行，拒绝写入',
  'sync_apply_target 兜底：email 重复直接调用同样拒绝（不写任何行）'
);

-- 单 email 正常更新：update 计数与实际写入行数对账一致
update public.profiles
   set email = 'engineer@example.com'
 where id = '22222222-2222-2222-2222-222222220001';
update public.profiles
   set email = 'planner@example.com'
 where id = '22222222-2222-2222-2222-222222220002';

select app.execute_sync_task(
  (:'ft'::jsonb ->> 'id')::uuid, 'manual',
  '[{"mail":"engineer@example.com","nm":"正常改名X","dept":"后端组"}]'::jsonb
) as run_ok \gset

select is(
  (select (stats ->> 'update')::int from public.sync_runs where id = :'run_ok'),
  1,
  '单 email：正常更新 stats.update=1'
);
select is(
  (select full_name from public.profiles where email = 'engineer@example.com'),
  '正常改名X',
  '单 email：full_name 已更新'
);
select is(
  (select (r.stats ->> 'update')::int from public.sync_runs r where r.id = :'run_ok'),
  (select count(*)::int from public.profiles where full_name = '正常改名X'),
  'stats.update 与实际写入行数一致（对账）'
);
select is(
  (select count(*) from public.profiles where full_name = '正常改名X'),
  1::bigint,
  '单 email：全表仅 1 行被改（无多行误写）'
);

-- ===========================================================================
-- 2. department_name：不存在 → failed 且原外键不变；存在 → 正常绑定（8）
-- ===========================================================================
update public.profiles
   set department    = '后端组',
       department_id = (select id from public.departments where name = '后端组')
 where email = 'engineer@example.com';

select app.execute_sync_task(
  (:'ft'::jsonb ->> 'id')::uuid, 'manual',
  '[{"mail":"engineer@example.com","dept":"不存在部门X"}]'::jsonb
) as run_dx \gset

select is(
  (select status from public.sync_runs where id = :'run_dx'),
  'failed',
  'department_name 不存在：整行 failed'
);
select is(
  (select (stats ->> 'failed')::int from public.sync_runs where id = :'run_dx'),
  1,
  'department_name 不存在：stats.failed=1'
);
select ok(
  (select error like '行 engineer@example.com：部门不存在：不存在部门X'
     from public.sync_runs where id = :'run_dx'),
  'department_name 不存在：error 原因「部门不存在：xxx」'
);
select is(
  (select department_id from public.profiles where email = 'engineer@example.com'),
  (select id from public.departments where name = '后端组'),
  'department_name 不存在：原 department_id 不变'
);
select is(
  (select department from public.profiles where email = 'engineer@example.com'),
  '后端组',
  'department_name 不存在：原 department 文本不变'
);

select app.execute_sync_task(
  (:'ft'::jsonb ->> 'id')::uuid, 'manual',
  '[{"mail":"engineer@example.com","dept":"前端组"}]'::jsonb
) as run_dy \gset

select is(
  (select status from public.sync_runs where id = :'run_dy'),
  'success',
  'department_name 存在：执行 success'
);
select is(
  (select department from public.profiles where email = 'engineer@example.com'),
  '前端组',
  'department_name 存在：text 列写入（双写触发器回写规范名）'
);
select is(
  (select department_id from public.profiles where email = 'engineer@example.com'),
  (select id from public.departments where name = '前端组'),
  'department_name 存在：department_id 解析为 departments.id'
);

-- ===========================================================================
-- 3. rejected 收敛：全 rejected → success；rejected+failed → failed；rejected+成功 → success（14）
-- ===========================================================================
select app.execute_sync_task(
  (:'fd'::jsonb ->> 'id')::uuid, 'manual',
  '[{"dept":"研发中心","parent":"前端组"}]'::jsonb
) as run_rej \gset

select is(
  (select (stats ->> 'conflict')::int from public.sync_runs where id = :'run_rej'),
  1,
  '防环拒绝：stats.conflict=1'
);
select is(
  (select status from public.sync_runs where id = :'run_rej'),
  'success',
  '全 rejected 且无失败行：run 收敛 success（rejected 属策略性拒绝、非错误）'
);
select is(
  (select resolution from public.sync_conflicts where run_id = :'run_rej'),
  'rejected',
  '防环拒绝：冲突 resolution=rejected'
);
select ok(
  (select target_data ->> 'reject_reason' like '%循环%'
     from public.sync_conflicts where run_id = :'run_rej'),
  '防环拒绝：target_data.reject_reason 标注原因'
);
select is(
  (select parent_id from public.departments where name = '研发中心'),
  (select id from public.departments where name = '总部'),
  '防环拒绝：parent_id 未改写（未成环）'
);
select ok(
  (select error is null from public.sync_runs where id = :'run_rej'),
  '防环拒绝：error 为空（策略性拒绝不是错误）'
);

-- rejected + failed（无成功写入）→ failed（语义不变）
select app.execute_sync_task(
  (:'fd'::jsonb ->> 'id')::uuid, 'manual',
  '[{"dept":"研发中心","parent":"前端组"},{"dept":"批次一新建部","parent":"不存在父Z"}]'::jsonb
) as run_rf \gset

select is(
  (select status from public.sync_runs where id = :'run_rf'),
  'failed',
  'rejected+failed 且无成功写入：status=failed（语义不变）'
);
select is(
  (select (stats ->> 'failed')::int from public.sync_runs where id = :'run_rf'),
  1,
  'rejected+failed：stats.failed=1'
);
select is(
  (select (stats ->> 'conflict')::int from public.sync_runs where id = :'run_rf'),
  1,
  'rejected+failed：stats.conflict=1（rejected 仍入冲突队列）'
);
select is(
  (select count(*) from public.departments where name = '批次一新建部'),
  0::bigint,
  'rejected+failed：失败行不产生写入'
);

-- rejected + 成功写入 → success（rejected 不拉低状态）
select app.execute_sync_task(
  (:'fd'::jsonb ->> 'id')::uuid, 'manual',
  '[{"dept":"研发中心","parent":"前端组"},{"dept":"批次一新建部","parent":"总部"}]'::jsonb
) as run_rm \gset

select is(
  (select status from public.sync_runs where id = :'run_rm'),
  'success',
  'rejected+成功写入：status=success'
);
select is(
  (select (stats ->> 'insert')::int from public.sync_runs where id = :'run_rm'),
  1,
  'rejected+成功写入：stats.insert=1'
);
select is(
  (select (stats ->> 'conflict')::int from public.sync_runs where id = :'run_rm'),
  1,
  'rejected+成功写入：stats.conflict=1'
);
select is(
  (select parent_id from public.departments where name = '批次一新建部'),
  (select id from public.departments where name = '总部'),
  'rejected+成功写入：成功行正常落库'
);

-- ===========================================================================
-- 4. validate_sync_mapping：重复 target_field 拒绝 / 不同字段不误报（3）
-- ===========================================================================
select throws_ok(
  $$ select app.validate_sync_mapping(
       'departments',
       '[{"source_field":"a","target_field":"name"},{"source_field":"b","target_field":"name"}]'::jsonb
     ) $$,
  '22023', '映射字段重复：name',
  '重复 target_field：22023「映射字段重复：name」'
);

set local role authenticated;
select throws_ok(
  format(
    $$ select public.upsert_sync_task(
         null, '重复字段任务', %L::uuid, 'profiles', 'pull',
         '[{"source_field":"a","target_field":"email"},{"source_field":"b","target_field":"email"}]'::jsonb,
         'overwrite', null
       ) $$,
    (:'fs'::jsonb ->> 'id')
  ),
  '22023', '映射字段重复：email',
  'upsert 入口同样拒绝重复 target_field'
);
reset role;

select lives_ok(
  $$ select app.validate_sync_mapping(
       'departments',
       '[{"source_field":"a","target_field":"name"},{"source_field":"b","target_field":"sort_order"}]'::jsonb
     ) $$,
  '不同 target_field 的映射不误报'
);

-- ===========================================================================
-- 5. input_summary：样本行数 + md5；空样本 / 空跑 / rerun 无样本（6）
-- ===========================================================================
select app.execute_sync_task(
  (:'fd'::jsonb ->> 'id')::uuid, 'manual',
  '[{"dept":"批次一快照部","parent":"总部"}]'::jsonb
) as run_snap \gset

select is(
  (select input_summary ->> 'sample_rows' from public.sync_runs where id = :'run_snap'),
  '1',
  'input_summary：sample_rows=1'
);
select is(
  (select input_summary ->> 'sample_hash' from public.sync_runs where id = :'run_snap'),
  md5('[{"dept":"批次一快照部","parent":"总部"}]'::jsonb::text),
  'input_summary：sample_hash=md5(p_sample::text)'
);

select app.execute_sync_task(
  (:'fd'::jsonb ->> 'id')::uuid, 'manual', '[]'::jsonb
) as run_empty \gset

select is(
  (select input_summary ->> 'sample_rows' from public.sync_runs where id = :'run_empty'),
  '0',
  'input_summary：空样本 sample_rows=0'
);
select is(
  (select input_summary ->> 'sample_hash' from public.sync_runs where id = :'run_empty'),
  md5('[]'::text),
  'input_summary：空样本 sample_hash=md5 空数组'
);

select app.execute_sync_task(
  (:'fd'::jsonb ->> 'id')::uuid, 'manual', null
) as run_nil \gset

select ok(
  (select input_summary is null from public.sync_runs where id = :'run_nil'),
  'input_summary：无样本（NULL）空跑为 NULL'
);

-- rerun 无样本：照常执行（raise notice 提示历史快照，不阻断）
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select public.rerun_sync_task((:'fd'::jsonb ->> 'id')::uuid, null) as run_rerun \gset
reset role;

select ok(
  (select input_summary is null from public.sync_runs where id = :'run_rerun'),
  'rerun 无样本：仍创建 run（历史快照仅提示，不用于重放）'
);

-- ===========================================================================
-- 6. claims 还原：cron 执行后恢复调用前 claims（3）
-- ===========================================================================
update public.sync_tasks
   set created_by = '22222222-2222-2222-2222-222222220001'
 where id = (:'fd'::jsonb ->> 'id')::uuid;

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
select app.execute_sync_task(
  (:'fd'::jsonb ->> 'id')::uuid, 'cron', '[]'::jsonb
) as run_cron \gset

select is(
  current_setting('request.jwt.claims', true),
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  'cron 执行后 claims 还原为调用前值（未被属主身份残留覆盖）'
);
select is(
  (select executed_by from public.sync_runs where id = :'run_cron'),
  '22222222-2222-2222-2222-222222220001'::uuid,
  'cron 执行身份=任务 created_by'
);
select is(
  (select actor_id from public.audit_operations
    where module = 'sync' and action = 'execute' and object_id = :'run_cron'::text),
  '22222222-2222-2222-2222-222222220001'::uuid,
  '执行期 claims 注入属主（audit actor=属主）'
);

select * from finish();
rollback;
