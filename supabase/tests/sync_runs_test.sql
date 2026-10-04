-- pgTAP：sync/005 —— sync_runs + sync_conflicts 表结构 / 执行函数面 / 读取 RPC / 清理策略
-- 运行：supabase db reset && supabase test db
-- 覆盖：两表列/类型/约束/外键/索引/RLS；函数存在性 + SECURITY/volatility/search_path；
--       GRANT 面（execute/cleanup 无 API 直调；管理/读取 RPC 仅 authenticated；service_role 零使用）；
--       读取 RPC 行为（列表过滤/分页/pending 冲突计数/执行人姓名/最近执行摘要/越权 42501）；
--       30 天清理（pending 冲突保护、running 保护、超期无冲突删除、参数校验）；
--       RLS（engineer 直查 0 行；表级无写）。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(102);

-- ===========================================================================
-- 1. 结构：sync_runs / sync_conflicts
-- ===========================================================================
select has_table('public', 'sync_runs', 'sync_runs 表存在');
select has_table('public', 'sync_conflicts', 'sync_conflicts 表存在');

select col_is_pk('public', 'sync_runs', 'id', 'sync_runs.id 为主键');
select col_is_pk('public', 'sync_conflicts', 'id', 'sync_conflicts.id 为主键');
select col_is_fk('public', 'sync_runs', 'task_id', 'sync_runs.task_id 外键 → sync_tasks');
select col_is_fk('public', 'sync_conflicts', 'run_id', 'sync_conflicts.run_id 外键 → sync_runs');

select col_type_is('public', 'sync_runs', 'task_id', 'uuid', 'runs.task_id 为 uuid');
select col_type_is('public', 'sync_runs', 'trigger_type', 'text', 'runs.trigger_type 为 text');
select col_type_is('public', 'sync_runs', 'status', 'text', 'runs.status 为 text');
select col_type_is('public', 'sync_runs', 'stats', 'jsonb', 'runs.stats 为 jsonb');
select col_type_is('public', 'sync_runs', 'error', 'text', 'runs.error 为 text');
select col_type_is('public', 'sync_runs', 'started_at', 'timestamp with time zone', 'runs.started_at 为 timestamptz');
select col_type_is('public', 'sync_runs', 'finished_at', 'timestamp with time zone', 'runs.finished_at 为 timestamptz');
select col_type_is('public', 'sync_runs', 'executed_by', 'uuid', 'runs.executed_by 为 uuid');
select col_type_is('public', 'sync_conflicts', 'row_key', 'text', 'conflicts.row_key 为 text');
select col_type_is('public', 'sync_conflicts', 'source_data', 'jsonb', 'conflicts.source_data 为 jsonb');
select col_type_is('public', 'sync_conflicts', 'target_data', 'jsonb', 'conflicts.target_data 为 jsonb');
select col_type_is('public', 'sync_conflicts', 'resolution', 'text', 'conflicts.resolution 为 text');
select col_type_is('public', 'sync_conflicts', 'resolved_by', 'uuid', 'conflicts.resolved_by 为 uuid');
select col_type_is('public', 'sync_conflicts', 'resolved_at', 'timestamp with time zone', 'conflicts.resolved_at 为 timestamptz');

select col_not_null('public', 'sync_runs', 'task_id', 'runs.task_id 非空');
select col_not_null('public', 'sync_runs', 'trigger_type', 'runs.trigger_type 非空');
select col_not_null('public', 'sync_runs', 'status', 'runs.status 非空');
select col_not_null('public', 'sync_runs', 'stats', 'runs.stats 非空');
select col_not_null('public', 'sync_conflicts', 'row_key', 'conflicts.row_key 非空');
select col_not_null('public', 'sync_conflicts', 'source_data', 'conflicts.source_data 非空');
select col_has_default('public', 'sync_runs', 'trigger_type', 'runs.trigger_type 有默认值');
select col_has_default('public', 'sync_runs', 'status', 'runs.status 有默认值');
select col_has_default('public', 'sync_runs', 'stats', 'runs.stats 有默认值');
select col_has_default('public', 'sync_runs', 'started_at', 'runs.started_at 有默认值');
select col_has_default('public', 'sync_conflicts', 'resolution', 'conflicts.resolution 默认 pending');
select col_has_check('public', 'sync_runs', 'trigger_type', 'runs.trigger_type 有取值 check');
select col_has_check('public', 'sync_runs', 'status', 'runs.status 有取值 check');
select col_has_check('public', 'sync_conflicts', 'resolution', 'conflicts.resolution 有取值 check');
select ok(
  exists (
    select 1 from pg_constraint
    where conrelid = 'public.sync_conflicts'::regclass
      and conname = 'sync_conflicts_resolved_check'
  ),
  'conflicts resolved 状态一致性 check 存在'
);

select has_index('public', 'sync_runs', 'sync_runs_task_started_idx', 'runs (task_id, started_at desc) 索引存在');
select has_index('public', 'sync_runs', 'sync_runs_running_idx', 'runs running 部分索引存在');
select has_index('public', 'sync_conflicts', 'sync_conflicts_pending_idx', 'conflicts pending 部分索引存在');

select is(
  (select relrowsecurity from pg_class where oid = 'public.sync_runs'::regclass),
  true,
  'sync_runs 已启用 RLS'
);
select is(
  (select relrowsecurity from pg_class where oid = 'public.sync_conflicts'::regclass),
  true,
  'sync_conflicts 已启用 RLS'
);
select ok(
  (select count(*) = 1 from pg_policies
    where schemaname = 'public' and tablename = 'sync_runs'
      and policyname = 'sync_runs_select_admin' and cmd = 'SELECT'),
  'sync_runs 仅 1 条 admin SELECT 策略'
);
select ok(
  (select count(*) = 1 from pg_policies
    where schemaname = 'public' and tablename = 'sync_conflicts'
      and policyname = 'sync_conflicts_select_admin' and cmd = 'SELECT'),
  'sync_conflicts 仅 1 条 admin SELECT 策略'
);

-- ===========================================================================
-- 2. 函数存在性 + SECURITY/volatility/search_path + GRANT 面
-- ===========================================================================
select has_function('app', 'sync_resolve_ref', array['text', 'text', 'text'], 'app.sync_resolve_ref 存在');
select has_function('app', 'sync_apply_target', array['uuid', 'jsonb', 'text'], 'app.sync_apply_target 存在');
select has_function('app', 'execute_sync_task', array['uuid', 'text', 'jsonb'], 'app.execute_sync_task 存在');
select has_function('app', 'run_sync_task', array['uuid', 'jsonb'], 'app.run_sync_task 存在');
select has_function('app', 'rerun_sync_task', array['uuid', 'jsonb'], 'app.rerun_sync_task 存在');
select has_function('app', 'resolve_sync_conflict', array['uuid', 'text'], 'app.resolve_sync_conflict 存在');
select has_function('app', 'get_sync_runs', array['uuid', 'integer', 'integer'], 'app.get_sync_runs 存在');
select has_function('app', 'get_sync_run_conflicts', array['uuid'], 'app.get_sync_run_conflicts 存在');
select has_function('app', 'get_sync_task_run_summaries', array[]::text[], 'app.get_sync_task_run_summaries 存在');
select has_function('app', 'cleanup_sync_runs', array['integer'], 'app.cleanup_sync_runs 存在');
select has_function('public', 'run_sync_task', array['uuid', 'jsonb'], 'public.run_sync_task 薄包装存在');
select has_function('public', 'rerun_sync_task', array['uuid', 'jsonb'], 'public.rerun_sync_task 薄包装存在');
select has_function('public', 'resolve_sync_conflict', array['uuid', 'text'], 'public.resolve_sync_conflict 薄包装存在');
select has_function('public', 'get_sync_runs', array['uuid', 'integer', 'integer'], 'public.get_sync_runs 薄包装存在');
select has_function('public', 'get_sync_run_conflicts', array['uuid'], 'public.get_sync_run_conflicts 薄包装存在');
select has_function('public', 'get_sync_task_run_summaries', array[]::text[], 'public.get_sync_task_run_summaries 薄包装存在');

select ok(
  (select count(*) = 2
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
      ('app', 'execute_sync_task'),
      ('app', 'cleanup_sync_runs')
    )
      and not p.prosecdef
      and p.proconfig @> array['search_path=""']),
  'execute_sync_task / cleanup_sync_runs 为 SECURITY INVOKER + search_path 固定为空'
);
select ok(
  (select count(*) = 2
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
      ('app', 'sync_resolve_ref'),
      ('app', 'sync_apply_target')
    )
      and not p.prosecdef
      and p.proconfig @> array['search_path=""']),
  'sync_resolve_ref / sync_apply_target 为 SECURITY INVOKER + search_path 固定为空'
);
select ok(
  (select count(*) = 12
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
      ('app', 'run_sync_task'), ('app', 'rerun_sync_task'),
      ('app', 'resolve_sync_conflict'), ('app', 'get_sync_runs'),
      ('app', 'get_sync_run_conflicts'), ('app', 'get_sync_task_run_summaries'),
      ('public', 'run_sync_task'), ('public', 'rerun_sync_task'),
      ('public', 'resolve_sync_conflict'), ('public', 'get_sync_runs'),
      ('public', 'get_sync_run_conflicts'), ('public', 'get_sync_task_run_summaries')
    )
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '12 个管理/读取函数（app+public）全部 SECURITY DEFINER + search_path 固定为空'
);

select ok(
  has_function_privilege('authenticated', 'app.run_sync_task(uuid,jsonb)', 'EXECUTE')
    and has_function_privilege('authenticated', 'app.rerun_sync_task(uuid,jsonb)', 'EXECUTE')
    and has_function_privilege('authenticated', 'app.resolve_sync_conflict(uuid,text)', 'EXECUTE')
    and has_function_privilege('authenticated', 'app.get_sync_runs(uuid,integer,integer)', 'EXECUTE')
    and has_function_privilege('authenticated', 'app.get_sync_run_conflicts(uuid)', 'EXECUTE')
    and has_function_privilege('authenticated', 'app.get_sync_task_run_summaries()', 'EXECUTE'),
  'authenticated 可执行 app 管理/读取 RPC'
);
select ok(
  has_function_privilege('authenticated', 'public.run_sync_task(uuid,jsonb)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.rerun_sync_task(uuid,jsonb)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.resolve_sync_conflict(uuid,text)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.get_sync_runs(uuid,integer,integer)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.get_sync_run_conflicts(uuid)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.get_sync_task_run_summaries()', 'EXECUTE'),
  'authenticated 可执行 public 管理/读取薄包装'
);
select ok(
  not has_function_privilege('authenticated', 'app.execute_sync_task(uuid,text,jsonb)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'app.sync_apply_target(uuid,jsonb,text)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'app.sync_resolve_ref(text,text,text)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'app.cleanup_sync_runs(integer)', 'EXECUTE'),
  'authenticated 无执行/写入/清理函数执行权（仅 wrapper 可达）'
);
select ok(
  not has_function_privilege('anon', 'public.run_sync_task(uuid,jsonb)', 'EXECUTE')
    and not has_function_privilege('anon', 'app.execute_sync_task(uuid,text,jsonb)', 'EXECUTE'),
  'anon 无手动触发/执行函数执行权'
);
select ok(
  not has_function_privilege('service_role', 'app.execute_sync_task(uuid,text,jsonb)', 'EXECUTE')
    and not has_function_privilege('service_role', 'app.cleanup_sync_runs(integer)', 'EXECUTE')
    and not has_function_privilege('service_role', 'public.get_sync_runs(uuid,integer,integer)', 'EXECUTE')
    and not has_function_privilege('service_role', 'public.resolve_sync_conflict(uuid,text)', 'EXECUTE'),
  'service_role 零执行权（全局禁 service_role）'
);

select ok(
  has_table_privilege('authenticated', 'public.sync_runs', 'SELECT')
    and not has_table_privilege('authenticated', 'public.sync_runs', 'INSERT')
    and not has_table_privilege('authenticated', 'public.sync_runs', 'UPDATE')
    and not has_table_privilege('authenticated', 'public.sync_runs', 'DELETE'),
  'authenticated 对 sync_runs 仅 SELECT（写仅经受控函数）'
);
select ok(
  has_table_privilege('authenticated', 'public.sync_conflicts', 'SELECT')
    and not has_table_privilege('authenticated', 'public.sync_conflicts', 'INSERT')
    and not has_table_privilege('authenticated', 'public.sync_conflicts', 'UPDATE'),
  'authenticated 对 sync_conflicts 仅 SELECT'
);

select is(
  (select count(*) from cron.job where jobname = 'sync-cleanup-runs'),
  1::bigint,
  'pg_cron 已注册执行明细清理 job'
);
select is(
  (select schedule from cron.job where jobname = 'sync-cleanup-runs'),
  '30 3 * * *',
  '清理 job 为每日 03:30'
);

-- ===========================================================================
-- 3. 夹具：admin 建源 + 任务 + 两次执行（不同统计）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.upsert_sync_source(
  null, '执行记录测试源', 'api', '{"base_url":"https://runs.example.com"}'::jsonb, 'tok-runs', null
) as rs \gset
select public.test_sync_source((:'rs'::jsonb ->> 'id')::uuid) as rsv \gset
select public.upsert_sync_task(
  null, '执行记录测试任务', (:'rs'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"dept","target_field":"name"},{"source_field":"sort","target_field":"sort_order"}]'::jsonb,
  'skip', null
) as rt \gset
reset role;

select is((:'rsv'::jsonb) ->> 'verify_status', 'verified', '夹具：数据源已验证');

select app.execute_sync_task(
  (:'rt'::jsonb ->> 'id')::uuid, 'manual',
  '[{"dept":"运行记录部门A","sort":"11"}]'::jsonb
) as run1 \gset
-- 同一测试事务内 now() 相同：显式错开开始时间，保证「倒序」断言确定
update public.sync_runs set started_at = now() - interval '2 hours' where id = :'run1';

select app.execute_sync_task(
  (:'rt'::jsonb ->> 'id')::uuid, 'manual',
  '[{"dept":"运行记录部门B","sort":"12"},{"dept":"运行记录部门A","sort":"99"}]'::jsonb
) as run2 \gset
update public.sync_runs set started_at = now() - interval '1 hour' where id = :'run2';

select is(
  (select status from public.sync_runs where id = :'run1'),
  'success',
  '夹具：第一次执行 success'
);
select is(
  (select (stats ->> 'insert')::int from public.sync_runs where id = :'run2'),
  1,
  '夹具：第二次执行 insert=1（skip=1）'
);

-- ===========================================================================
-- 4. 读取 RPC 行为
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select is(
  (select count(*) from public.get_sync_runs(null, 50, 0) r
    where r.task_id = (:'rt'::jsonb ->> 'id')::uuid),
  2::bigint,
  'get_sync_runs 返回该任务两次执行'
);
select is(
  (select r.task_name from public.get_sync_runs((:'rt'::jsonb ->> 'id')::uuid, 1, 0) r),
  '执行记录测试任务',
  'get_sync_runs 联表返回任务名'
);
select is(
  (select r.id from public.get_sync_runs((:'rt'::jsonb ->> 'id')::uuid, 1, 0) r),
  :'run2'::uuid,
  'get_sync_runs 按开始时间倒序：最新在前'
);
select is(
  (select r.executed_by_name from public.get_sync_runs((:'rt'::jsonb ->> 'id')::uuid, 1, 0) r),
  (select full_name from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'get_sync_runs 返回执行人姓名'
);
select is(
  (select r.target_table from public.get_sync_runs((:'rt'::jsonb ->> 'id')::uuid, 1, 0) r),
  'departments',
  'get_sync_runs 返回目标表'
);

select is(
  (select count(*) from public.get_sync_task_run_summaries() s
    where s.task_id = (:'rt'::jsonb ->> 'id')::uuid),
  1::bigint,
  'get_sync_task_run_summaries 每任务一行'
);
select is(
  (select s.run_id from public.get_sync_task_run_summaries() s
    where s.task_id = (:'rt'::jsonb ->> 'id')::uuid),
  :'run2'::uuid,
  '最近执行摘要取最新 run'
);
select is(
  (select s.status from public.get_sync_task_run_summaries() s
    where s.task_id = (:'rt'::jsonb ->> 'id')::uuid),
  'success',
  '第二次执行（skip 策略）成功'
);

-- manual 冲突夹具：第三次执行产生 1 条 pending 冲突
reset role;
update public.sync_tasks
   set conflict_policy = 'manual'
 where id = (:'rt'::jsonb ->> 'id')::uuid;
select app.execute_sync_task(
  (:'rt'::jsonb ->> 'id')::uuid, 'manual',
  '[{"dept":"运行记录部门A","sort":"100"}]'::jsonb
) as run3 \gset

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select is(
  (select r.pending_conflicts from public.get_sync_runs((:'rt'::jsonb ->> 'id')::uuid, 1, 0) r),
  1::bigint,
  'get_sync_runs 返回 pending 冲突计数'
);
select is(
  (select s.run_id from public.get_sync_task_run_summaries() s
    where s.task_id = (:'rt'::jsonb ->> 'id')::uuid),
  :'run3'::uuid,
  '最近执行摘要更新为最新 run'
);
select is(
  (select s.status from public.get_sync_task_run_summaries() s
    where s.task_id = (:'rt'::jsonb ->> 'id')::uuid),
  'partial',
  'manual 策略冲突执行标记为 partial'
);
select is(
  (select count(*) from public.get_sync_run_conflicts(:'run3')),
  1::bigint,
  'get_sync_run_conflicts 返回该 run 的冲突'
);
select is(
  (select c.row_key from public.get_sync_run_conflicts(:'run3') c),
  '运行记录部门A',
  '冲突 row_key 正确'
);
select is(
  (select c.resolution from public.get_sync_run_conflicts(:'run3') c),
  'pending',
  '冲突初始为 pending'
);
select is(
  (select c.resolved_by_name from public.get_sync_run_conflicts(:'run3') c),
  null::text,
  '未裁决冲突无裁决人'
);

select throws_ok(
  $$ select public.get_sync_run_conflicts('00000000-0000-0000-0000-000000000000'::uuid) $$,
  'P0002', null, '不存在的 run 查询冲突被拒'
);

-- engineer 越权
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
select throws_ok(
  $$ select public.get_sync_runs(null, 10, 0) $$,
  '42501', null, 'engineer 读执行记录被拒（admin 专属）'
);
select throws_ok(
  $$ select public.get_sync_task_run_summaries() $$,
  '42501', null, 'engineer 读最近执行摘要被拒'
);
select is(
  (select count(*) from public.sync_runs),
  0::bigint,
  'engineer 直查 sync_runs RLS 收窄为 0 行'
);
select is(
  (select count(*) from public.sync_conflicts),
  0::bigint,
  'engineer 直查 sync_conflicts RLS 收窄为 0 行'
);
reset role;

-- anon 无路径
set local role anon;
select throws_ok(
  $$ select public.get_sync_runs(null, 10, 0) $$,
  '42501', null, 'anon 读执行记录被拒（无 GRANT）'
);
reset role;

-- ===========================================================================
-- 5. 30 天清理（pending 冲突保护 / running 保护 / 超期删除）
-- ===========================================================================
insert into public.sync_runs (id, task_id, trigger_type, status, stats, started_at, finished_at)
values
  ('aaaa0000-0000-4000-8000-000000000001', (:'rt'::jsonb ->> 'id')::uuid,
   'manual', 'success', '{"insert":0,"update":0,"conflict":0,"skip":0,"failed":0}'::jsonb,
   now() - interval '40 days', now() - interval '40 days' + interval '1 minute'),
  ('aaaa0000-0000-4000-8000-000000000002', (:'rt'::jsonb ->> 'id')::uuid,
   'manual', 'partial', '{"insert":0,"update":0,"conflict":1,"skip":0,"failed":0}'::jsonb,
   now() - interval '40 days', now() - interval '40 days' + interval '1 minute'),
  ('aaaa0000-0000-4000-8000-000000000003', (:'rt'::jsonb ->> 'id')::uuid,
   'manual', 'running', '{"insert":0,"update":0,"conflict":0,"skip":0,"failed":0}'::jsonb,
   now() - interval '40 days', null);

insert into public.sync_conflicts (run_id, row_key, source_data, target_data)
values (
  'aaaa0000-0000-4000-8000-000000000002',
  '运行记录部门A', '{"name":"运行记录部门A","sort_order":"7"}'::jsonb,
  '{"name":"运行记录部门A","sort_order":"1"}'::jsonb
);

select throws_ok(
  $$ select app.cleanup_sync_runs(0) $$,
  '22023', null, '清理天数 < 1 被拒'
);
select throws_ok(
  $$ select app.cleanup_sync_runs(null) $$,
  '22023', null, '清理天数 NULL 被拒'
);
select is(
  app.cleanup_sync_runs(30),
  1::bigint,
  '清理仅删除超期且无 pending 冲突的 run（1 条）'
);
select is(
  (select count(*) from public.sync_runs where id = 'aaaa0000-0000-4000-8000-000000000001'),
  0::bigint,
  '超期无冲突 run 已删除'
);
select is(
  (select count(*) from public.sync_runs where id = 'aaaa0000-0000-4000-8000-000000000002'),
  1::bigint,
  '超期但含 pending 冲突的 run 保留（不受清理影响）'
);
select is(
  (select count(*) from public.sync_runs where id = 'aaaa0000-0000-4000-8000-000000000003'),
  1::bigint,
  'running run 保留不清理'
);
select is(
  (select count(*) from public.sync_runs where id = :'run3'),
  1::bigint,
  '近期 run 保留'
);

-- 裁决后 pending 消失 → 下一次清理可删（数据一致性）
update public.sync_conflicts set resolution = 'ignored', resolved_at = now()
 where run_id = 'aaaa0000-0000-4000-8000-000000000002';
select is(
  app.cleanup_sync_runs(30),
  1::bigint,
  '冲突裁决后超期 run 可被清理'
);

reset role;

select * from finish();
rollback;
