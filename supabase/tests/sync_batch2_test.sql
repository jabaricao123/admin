-- pgTAP：sync 批次 2 修复 —— 动态 job 登记联动 / 任务停用联动调度 / webhook 限流原子化 /
--       pending 瞬态收敛 / 删除任务孤儿 job 清理 / 执行日聚合长期保留 / 凭据掩码与显式清空
-- 运行：supabase db reset && supabase test db
-- 覆盖：
--   1. 结构与授权：sync_run_stats_daily 表/RLS/索引；新函数存在性与 SECURITY/GRANT 面；
--      不变量触发器与 token 哈希索引存在；聚合 cron job + 登记处行；
--   2. cron 登记联动：注册后 system_cron_registry 有 sync-task-* 行（module/route/时区），
--      停用→登记 disabled + job 删除，重新启用→登记恢复 active，改 manual→登记 disabled；
--   3. 任务停用联动：active→disabled 立即停用调度 + 注销 job/登记；反向启用不自动启用调度；
--      有运行中 run 时置待注销，run 结束后编辑收敛；
--   4. pending 瞬态收敛：无运行中 run / 改 trigger_type → 立即 disabled + 注销；
--      直接 GET 收敛路径由 sync_schedules_disable_cleanup 触发器兜底；
--   5. webhook 限流边界：60 受理 / 61 拒绝（53400）；不同 token 互不影响（锁粒度）；
--      并发语义以迁移注释说明（pgTAP 单会话无法并发，锁竞争路径以代码审查为准）；
--   6. 删除任务：DELETE 前注销 job/登记（无残留），级联清调度与版本；
--   7. 日聚合：按上海业务日分日、计数口径、running 不计、幂等；cleanup 先聚合后删、
--      pending 保护行与其历史聚合不丢数；聚合表 RLS/授权；
--   8. 凭据：≤8 全掩码 / >8 尾 4 位；空白串保留；显式清空 + 已验证降级；旧 6 参调用兼容。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(123);

-- ===========================================================================
-- 1. 结构 / 函数 / 授权（34）
-- ===========================================================================
select has_table('public', 'sync_run_stats_daily', 'sync_run_stats_daily 表存在');
select col_is_pk('public', 'sync_run_stats_daily', array['day', 'task_id'], '(day, task_id) 联合主键');
select col_is_fk('public', 'sync_run_stats_daily', 'task_id', 'task_id 外键 → sync_tasks');
select col_type_is('public', 'sync_run_stats_daily', 'day', 'date', 'day 为 date');
select col_type_is('public', 'sync_run_stats_daily', 'task_id', 'uuid', 'task_id 为 uuid');
select col_type_is('public', 'sync_run_stats_daily', 'runs', 'bigint', 'runs 为 bigint');
select col_type_is('public', 'sync_run_stats_daily', 'success', 'bigint', 'success 为 bigint');
select col_type_is('public', 'sync_run_stats_daily', 'failed', 'bigint', 'failed 为 bigint');
select col_type_is('public', 'sync_run_stats_daily', 'rows_insert', 'bigint', 'rows_insert 为 bigint');
select col_type_is('public', 'sync_run_stats_daily', 'rows_update', 'bigint', 'rows_update 为 bigint');
select col_type_is('public', 'sync_run_stats_daily', 'rows_failed', 'bigint', 'rows_failed 为 bigint');
select col_not_null('public', 'sync_run_stats_daily', 'day', 'day 非空');
select col_not_null('public', 'sync_run_stats_daily', 'task_id', 'task_id 非空');
select col_has_default('public', 'sync_run_stats_daily', 'runs', 'runs 有默认值');
select ok(
  exists (
    select 1 from pg_constraint
    where conrelid = 'public.sync_run_stats_daily'::regclass
      and conname = 'sync_run_stats_daily_runs_check'
  ),
  'runs 有 >=0 一致性 check'
);
select has_index('public', 'sync_run_stats_daily', 'sync_run_stats_daily_day_idx', 'day 索引存在');
select is(
  (select relrowsecurity from pg_class where oid = 'public.sync_run_stats_daily'::regclass),
  true,
  'sync_run_stats_daily 已启用 RLS'
);
select ok(
  (select count(*) = 1 from pg_policies
    where schemaname = 'public' and tablename = 'sync_run_stats_daily'
      and policyname = 'sync_run_stats_daily_select_admin' and cmd = 'SELECT'),
  'sync_run_stats_daily 仅 1 条 admin SELECT 策略'
);

select has_function('app', 'aggregate_sync_run_stats_daily', array['date'], 'app.aggregate_sync_run_stats_daily(date) 存在');
select has_function('app', 'sync_schedule_register_cron', array['uuid', 'text', 'text'], 'app.sync_schedule_register_cron(uuid,text,text) 存在（含时区）');
select has_function('app', 'sync_disable_schedule_for_task', array['uuid'], 'app.sync_disable_schedule_for_task(uuid) 存在');
select has_function('app', 'sync_schedule_disable_cleanup', array[]::text[], 'app.sync_schedule_disable_cleanup() 触发器函数存在');
select has_function('app', 'sync_task_delete_cron_cleanup', array[]::text[], 'app.sync_task_delete_cron_cleanup() 触发器函数存在');
select has_trigger('public', 'sync_tasks', 'sync_tasks_delete_cron_cleanup', '删除任务注销 job 触发器存在');
select has_trigger('public', 'sync_schedules', 'sync_schedules_disable_cleanup', 'disabled 兜底注销触发器存在');
select has_index('public', 'sync_schedules', 'sync_schedules_webhook_token_hash_idx', 'token 哈希索引存在');

select ok(
  (select count(*) = 1
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'aggregate_sync_run_stats_daily'
      and not p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '聚合函数为 SECURITY INVOKER + search_path 固定为空'
);
select ok(
  (select count(*) = 3
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
      ('app', 'sync_disable_schedule_for_task'),
      ('app', 'sync_schedule_disable_cleanup'),
      ('app', 'sync_task_delete_cron_cleanup')
    )
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '3 个新内部 helper/触发器函数为 SECURITY DEFINER + search_path 固定为空'
);

select ok(
  (select count(*) = 1 from cron.job where jobname = 'sync-aggregate-run-stats'),
  '聚合 cron job 已注册'
);
select is(
  (select schedule from cron.job where jobname = 'sync-aggregate-run-stats'),
  '0 3 * * *',
  '聚合 cron 为每日 03:00'
);
select is(
  (select module || '|' || owner_route from public.system_cron_registry
    where job_name = 'sync-aggregate-run-stats'),
  'sync|/sync/runs',
  '聚合 job 已登记（module=sync、owner_route=/sync/runs）'
);

select ok(
  not has_function_privilege('authenticated', 'app.aggregate_sync_run_stats_daily(date)', 'EXECUTE'),
  'authenticated 无聚合函数执行权（仅 pg_cron）'
);
select ok(
  has_table_privilege('authenticated', 'public.sync_run_stats_daily', 'SELECT')
    and not has_table_privilege('authenticated', 'public.sync_run_stats_daily', 'INSERT')
    and not has_table_privilege('authenticated', 'public.sync_run_stats_daily', 'UPDATE'),
  'authenticated 对聚合表仅 SELECT'
);
select ok(
  not has_table_privilege('service_role', 'public.sync_run_stats_daily', 'SELECT')
    and not has_function_privilege('service_role', 'app.aggregate_sync_run_stats_daily(date)', 'EXECUTE'),
  'service_role 零访问/零执行权（全局禁 service_role）'
);

-- ===========================================================================
-- 2. 夹具：源 + 任务（3）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.upsert_sync_source(
  null, '批次2测试源', 'api', '{"base_url":"https://b2.example.com"}'::jsonb, 'tok-b2', null
) as src \gset
select public.test_sync_source((:'src'::jsonb ->> 'id')::uuid) as srcv \gset

select public.upsert_sync_task(
  null, '批次2任务A', (:'src'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"d","target_field":"name"}]'::jsonb, 'skip', null
) as ta \gset
select public.upsert_sync_task(
  null, '批次2任务B', (:'src'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"d","target_field":"name"}]'::jsonb, 'skip', null
) as tb \gset
select public.upsert_sync_task(
  null, '批次2任务C', (:'src'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"d","target_field":"name"}]'::jsonb, 'skip', null
) as tc \gset
select public.upsert_sync_task(
  null, '批次2任务D', (:'src'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"d","target_field":"name"}]'::jsonb, 'skip', null
) as td \gset
select public.upsert_sync_task(
  null, '批次2任务E', (:'src'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"d","target_field":"name"}]'::jsonb, 'skip', null
) as te \gset
select public.upsert_sync_task(
  null, '批次2任务G', (:'src'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"d","target_field":"name"}]'::jsonb, 'skip', null
) as tg \gset
select public.upsert_sync_task(
  null, '批次2任务H', (:'src'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"d","target_field":"name"}]'::jsonb, 'skip', null
) as th \gset
select public.upsert_sync_task(
  null, '批次2任务I', (:'src'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"d","target_field":"name"}]'::jsonb, 'skip', null
) as ti \gset
reset role;

select is((:'srcv'::jsonb) ->> 'verify_status', 'verified', '夹具：数据源已验证');
select is((:'ta'::jsonb) ->> 'status', 'active', '夹具：任务默认 active');
select is((:'te'::jsonb) ->> 'config_version', '1', '夹具：任务初始 config_version=1');

-- ===========================================================================
-- 3. cron 登记联动（14）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select public.upsert_sync_schedule(
  (:'ta'::jsonb ->> 'id')::uuid, 'cron', '*/5 * * * *', 'UTC', 'active', false
) as sa \gset
reset role;

select is((:'sa'::jsonb) ->> 'status', 'active', 'A：cron 调度启用');
select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'ta'::jsonb ->> 'id')),
  1::bigint,
  'A：pg_cron job 已注册'
);
select is(
  (select status from public.system_cron_registry where job_name = 'sync-task-' || (:'ta'::jsonb ->> 'id')),
  'active',
  'A：登记处出现 sync-task-* 行且 active'
);
select is(
  (select module from public.system_cron_registry where job_name = 'sync-task-' || (:'ta'::jsonb ->> 'id')),
  'sync',
  'A：登记 module=sync'
);
select is(
  (select owner_route from public.system_cron_registry where job_name = 'sync-task-' || (:'ta'::jsonb ->> 'id')),
  '/sync/schedules',
  'A：登记 owner_route=/sync/schedules'
);
select is(
  (select timezone from public.system_cron_registry where job_name = 'sync-task-' || (:'ta'::jsonb ->> 'id')),
  'UTC',
  'A：登记时区随调度配置（UTC）'
);
select is(
  (select cron_expr from public.system_cron_registry where job_name = 'sync-task-' || (:'ta'::jsonb ->> 'id')),
  '*/5 * * * *',
  'A：登记 cron 表达式正确'
);

set local role authenticated;
select public.set_sync_schedule_status((:'ta'::jsonb ->> 'id')::uuid, 'disabled') as sa_dis \gset
reset role;
select is((:'sa_dis'::jsonb) ->> 'status', 'disabled', 'A：停用立即 disabled');
select is(
  (select status from public.system_cron_registry where job_name = 'sync-task-' || (:'ta'::jsonb ->> 'id')),
  'disabled',
  'A：停用后登记 disabled（历史保留）'
);
select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'ta'::jsonb ->> 'id')),
  0::bigint,
  'A：停用后 job 删除'
);

set local role authenticated;
select public.set_sync_schedule_status((:'ta'::jsonb ->> 'id')::uuid, 'active') as sa_en \gset
reset role;
select is(
  (select status from public.system_cron_registry where job_name = 'sync-task-' || (:'ta'::jsonb ->> 'id')),
  'active',
  'A：重新启用登记恢复 active'
);

-- 改 manual：注销 job 且登记 disabled
set local role authenticated;
select public.upsert_sync_schedule(
  (:'ti'::jsonb ->> 'id')::uuid, 'cron', '20 5 * * *', 'Asia/Shanghai', 'active', false
) as si \gset
select public.upsert_sync_schedule(
  (:'ti'::jsonb ->> 'id')::uuid, 'manual', null, 'Asia/Shanghai', null, false
) as si_manual \gset
reset role;
select is((:'si_manual'::jsonb) ->> 'cron_expr', null::text, 'I：改 manual 清空 cron_expr');
select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'ti'::jsonb ->> 'id')),
  0::bigint,
  'I：改 manual 注销 job'
);
select is(
  (select status from public.system_cron_registry where job_name = 'sync-task-' || (:'ti'::jsonb ->> 'id')),
  'disabled',
  'I：改 manual 登记 disabled'
);

-- ===========================================================================
-- 4. 任务停用联动调度（16）
-- ===========================================================================
set local role authenticated;
select public.upsert_sync_task(
  (:'ta'::jsonb ->> 'id')::uuid, '批次2任务A', (:'src'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"d","target_field":"name"}]'::jsonb, 'skip', 'disabled'
) as ta_dis \gset
reset role;

select is((:'ta_dis'::jsonb) ->> 'status', 'disabled', 'A：任务停用成功');
select is(
  (select status from public.sync_schedules where task_id = (:'ta'::jsonb ->> 'id')::uuid),
  'disabled',
  'A：任务停用联动调度 disabled'
);
select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'ta'::jsonb ->> 'id')),
  0::bigint,
  'A：任务停用联动注销 pg_cron job'
);
select is(
  (select status from public.system_cron_registry where job_name = 'sync-task-' || (:'ta'::jsonb ->> 'id')),
  'disabled',
  'A：任务停用联动登记 disabled'
);
select is(
  (select next_run_at from public.sync_schedules where task_id = (:'ta'::jsonb ->> 'id')::uuid),
  null::timestamptz,
  'A：任务停用联动清空 next_run_at'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'sync' and action = 'set_status' and object_type = 'sync_schedule'
      and diff ->> 'reason' = 'task_disabled'
      and diff ->> 'task_id' = (:'ta'::jsonb ->> 'id')
  ),
  'A：任务停用联动写调度审计（reason=task_disabled）'
);
select is(
  (select count(*) from public.sync_schedules where task_id = (:'ta'::jsonb ->> 'id')::uuid),
  1::bigint,
  'A：任务停用只停用调度，调度行保留'
);

-- 反向：任务重新启用不自动启用调度（需人工在调度页启用）
set local role authenticated;
select public.upsert_sync_task(
  (:'ta'::jsonb ->> 'id')::uuid, '批次2任务A', (:'src'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"d","target_field":"name"}]'::jsonb, 'skip', 'active'
) as ta_en \gset
reset role;
select is((:'ta_en'::jsonb) ->> 'status', 'active', 'A：任务重新启用成功');
select is(
  (select status from public.sync_schedules where task_id = (:'ta'::jsonb ->> 'id')::uuid),
  'disabled',
  'A：任务启用不自动启用调度（保持 disabled）'
);
select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'ta'::jsonb ->> 'id')),
  0::bigint,
  'A：任务启用不自动注册 job'
);

-- 有运行中 run：任务停用 → 调度待注销（job 保留），run 结束后编辑收敛
set local role authenticated;
select public.upsert_sync_schedule(
  (:'td'::jsonb ->> 'id')::uuid, 'cron', '0 9 * * *', 'Asia/Shanghai', 'active', false
) as sd \gset
reset role;
insert into public.sync_runs (task_id, trigger_type, status)
values ((:'td'::jsonb ->> 'id')::uuid, 'cron', 'running');

set local role authenticated;
select public.upsert_sync_task(
  (:'td'::jsonb ->> 'id')::uuid, '批次2任务D', (:'src'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"d","target_field":"name"}]'::jsonb, 'skip', 'disabled'
) as td_dis \gset
reset role;
select is(
  (select status from public.sync_schedules where task_id = (:'td'::jsonb ->> 'id')::uuid),
  'disabled_pending_unschedule',
  'D：有运行中 run 时任务停用 → 调度待注销'
);
select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'td'::jsonb ->> 'id')),
  1::bigint,
  'D：待注销期间 job 保留'
);
select is(
  (select status from public.system_cron_registry where job_name = 'sync-task-' || (:'td'::jsonb ->> 'id')),
  'active',
  'D：待注销期间登记保持 active'
);

-- 模拟当次 run 完成 → 编辑保存同一调度触发瞬态收敛
update public.sync_runs
   set status = 'success', finished_at = now()
 where task_id = (:'td'::jsonb ->> 'id')::uuid and status = 'running';
set local role authenticated;
select public.upsert_sync_schedule(
  (:'td'::jsonb ->> 'id')::uuid, 'cron', '0 9 * * *', 'Asia/Shanghai', null, false
) as td_conv \gset
reset role;
select is((:'td_conv'::jsonb) ->> 'status', 'disabled', 'D：run 结束后编辑收敛 disabled');
select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'td'::jsonb ->> 'id')),
  0::bigint,
  'D：收敛后 job 注销'
);
select is(
  (select status from public.system_cron_registry where job_name = 'sync-task-' || (:'td'::jsonb ->> 'id')),
  'disabled',
  'D：收敛后登记 disabled'
);

-- ===========================================================================
-- 5. pending 瞬态收敛（8）
-- ===========================================================================
-- 5a. 直接 UPDATE 收敛（触发器兜底，覆盖执行函数内联 unschedule 路径）
set local role authenticated;
select public.upsert_sync_schedule(
  (:'th'::jsonb ->> 'id')::uuid, 'cron', '15 4 * * *', 'Asia/Shanghai', 'active', false
) as sh \gset
reset role;
update public.sync_schedules
   set status = 'disabled_pending_unschedule'
 where task_id = (:'th'::jsonb ->> 'id')::uuid;
select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'th'::jsonb ->> 'id')),
  1::bigint,
  'H：pending 态保留 job（等待条件满足）'
);
update public.sync_schedules
   set status = 'disabled'
 where task_id = (:'th'::jsonb ->> 'id')::uuid;
select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'th'::jsonb ->> 'id')),
  0::bigint,
  'H：状态迁移 disabled 触发器兜底注销 job'
);
select is(
  (select status from public.system_cron_registry where job_name = 'sync-task-' || (:'th'::jsonb ->> 'id')),
  'disabled',
  'H：触发器兜底登记 disabled'
);

-- 5b. 改 trigger_type：pending 态（有运行中 run）直接收敛 disabled
set local role authenticated;
select public.upsert_sync_schedule(
  (:'th'::jsonb ->> 'id')::uuid, 'cron', '15 4 * * *', 'Asia/Shanghai', 'active', false
) as sh2 \gset
reset role;
insert into public.sync_runs (task_id, trigger_type, status)
values ((:'th'::jsonb ->> 'id')::uuid, 'cron', 'running');
update public.sync_schedules
   set status = 'disabled_pending_unschedule'
 where task_id = (:'th'::jsonb ->> 'id')::uuid;

set local role authenticated;
select public.upsert_sync_schedule(
  (:'th'::jsonb ->> 'id')::uuid, 'manual', null, 'Asia/Shanghai', null, false
) as sh_manual \gset
reset role;
select is((:'sh_manual'::jsonb) ->> 'trigger_type', 'manual', 'H：改为 manual 成功');
select is((:'sh_manual'::jsonb) ->> 'status', 'disabled', 'H：pending 态改 trigger_type 直接收敛 disabled');
select is((:'sh_manual'::jsonb) ->> 'cron_expr', null::text, 'H：改 manual 清空 cron_expr');
select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'th'::jsonb ->> 'id')),
  0::bigint,
  'H：pending 态改 trigger_type 注销 job'
);
select is(
  (select status from public.system_cron_registry where job_name = 'sync-task-' || (:'th'::jsonb ->> 'id')),
  'disabled',
  'H：pending 态改 trigger_type 登记 disabled'
);

-- ===========================================================================
-- 6. webhook 限流边界（6）
-- ===========================================================================
set local role authenticated;
select public.upsert_sync_schedule(
  (:'tb'::jsonb ->> 'id')::uuid, 'webhook', null, 'Asia/Shanghai', 'active', false
) as swb \gset
reset role;

set local role anon;
select public.trigger_sync_webhook((:'swb'::jsonb) ->> 'webhook_token') as wh1 \gset
reset role;
select is(
  (select trigger_type from public.sync_runs where id = :'wh1'),
  'webhook',
  'B：token 有效触发创建 webhook run（限流窗口内）'
);

insert into public.sync_runs (task_id, trigger_type, status, stats)
select (:'tb'::jsonb ->> 'id')::uuid, 'webhook', 'success',
       '{"insert":0,"update":0,"conflict":0,"skip":0,"failed":0}'::jsonb
from generate_series(1, 59);
select is(
  (select count(*) from public.sync_runs
    where task_id = (:'tb'::jsonb ->> 'id')::uuid
      and trigger_type = 'webhook' and started_at > now() - interval '1 minute'),
  60::bigint,
  'B：限流窗口内已有 60 次受理'
);
set local role anon;
select throws_ok(
  format($q$ select public.trigger_sync_webhook(%L) $q$, (:'swb'::jsonb) ->> 'webhook_token'),
  '53400', null, 'B：第 61 次触发被限流（53400/429）'
);
reset role;

-- 不同 token 互不影响（锁/计数按 token 粒度）
set local role authenticated;
select public.upsert_sync_schedule(
  (:'tg'::jsonb ->> 'id')::uuid, 'webhook', null, 'Asia/Shanghai', 'active', false
) as swg \gset
reset role;
set local role anon;
select public.trigger_sync_webhook((:'swg'::jsonb) ->> 'webhook_token') as whg \gset
reset role;
select is(
  (select task_id from public.sync_runs where id = :'whg'),
  (:'tg'::jsonb ->> 'id')::uuid,
  'G：另一 token 不受 B 限流影响（锁/计数按 token 粒度）'
);

-- 非 cron 型任务停用：无 job 可保留，直接 disabled（不进入待注销）
insert into public.sync_runs (task_id, trigger_type, status)
values ((:'tg'::jsonb ->> 'id')::uuid, 'manual', 'running');
set local role authenticated;
select public.upsert_sync_task(
  (:'tg'::jsonb ->> 'id')::uuid, '批次2任务G', (:'src'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"d","target_field":"name"}]'::jsonb, 'skip', 'disabled'
) as tg_dis \gset
reset role;
select is(
  (select status from public.sync_schedules where task_id = (:'tg'::jsonb ->> 'id')::uuid),
  'disabled',
  'G：非 cron 型任务停用直接 disabled（不进入待注销）'
);
select is(
  (select count(*) from public.system_cron_registry where job_name = 'sync-task-' || (:'tg'::jsonb ->> 'id')),
  0::bigint,
  'G：webhook 型无 sync-task 登记行'
);

-- ===========================================================================
-- 7. 删除任务孤儿 job 清理（4）
-- ===========================================================================
set local role authenticated;
select public.upsert_sync_schedule(
  (:'tc'::jsonb ->> 'id')::uuid, 'cron', '30 6 * * *', 'Asia/Shanghai', 'active', false
) as sc \gset
reset role;
select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'tc'::jsonb ->> 'id')),
  1::bigint,
  'C：删除前 job 在册'
);

delete from public.sync_tasks where id = (:'tc'::jsonb ->> 'id')::uuid;
select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'tc'::jsonb ->> 'id')),
  0::bigint,
  'C：删除任务后 job 无残留（触发器注销）'
);
select is(
  (select status from public.system_cron_registry where job_name = 'sync-task-' || (:'tc'::jsonb ->> 'id')),
  'disabled',
  'C：删除任务后登记 disabled'
);
select is(
  (select count(*) from public.sync_schedules where task_id = (:'tc'::jsonb ->> 'id')::uuid),
  0::bigint,
  'C：删除任务级联清调度行'
);

-- ===========================================================================
-- 8. 日聚合与清理（28）
-- ===========================================================================
-- 夹具：跨上海业务日边界的执行明细（2026-01-01 23:30 SH / 2026-01-02 00:30 SH）
insert into public.sync_runs (id, task_id, trigger_type, status, stats, started_at, finished_at)
values
  ('bbbb0000-0000-4000-8000-000000000001', (:'te'::jsonb ->> 'id')::uuid,
   'manual', 'success', '{"insert":3,"update":1,"conflict":0,"skip":0,"failed":0}'::jsonb,
   '2026-01-01 15:30:00+00', '2026-01-01 15:35:00+00'),
  ('bbbb0000-0000-4000-8000-000000000002', (:'te'::jsonb ->> 'id')::uuid,
   'manual', 'failed', '{"insert":0,"update":0,"conflict":0,"skip":0,"failed":2}'::jsonb,
   '2026-01-01 16:30:00+00', '2026-01-01 16:31:00+00'),
  ('bbbb0000-0000-4000-8000-000000000003', (:'te'::jsonb ->> 'id')::uuid,
   'manual', 'partial', '{"insert":1,"update":2,"conflict":1,"skip":0,"failed":1}'::jsonb,
   '2026-01-02 01:00:00+00', '2026-01-02 01:01:00+00'),
  ('bbbb0000-0000-4000-8000-000000000004', (:'te'::jsonb ->> 'id')::uuid,
   'manual', 'running', '{"insert":0,"update":0,"conflict":0,"skip":0,"failed":5}'::jsonb,
   '2026-01-02 02:00:00+00', null);

select is(
  app.aggregate_sync_run_stats_daily('2026-01-01'),
  1,
  '聚合 2026-01-01（上海）返回 1 行'
);
select is(
  (select runs from public.sync_run_stats_daily
    where day = '2026-01-01' and task_id = (:'te'::jsonb ->> 'id')::uuid),
  1::bigint,
  '跨日边界：23:30 SH 明细归入前一日'
);
select is(
  (select success from public.sync_run_stats_daily
    where day = '2026-01-01' and task_id = (:'te'::jsonb ->> 'id')::uuid),
  1::bigint,
  'day1 success=1'
);
select is(
  (select rows_insert from public.sync_run_stats_daily
    where day = '2026-01-01' and task_id = (:'te'::jsonb ->> 'id')::uuid),
  3::bigint,
  'day1 rows_insert=3'
);
select is(
  (select rows_update from public.sync_run_stats_daily
    where day = '2026-01-01' and task_id = (:'te'::jsonb ->> 'id')::uuid),
  1::bigint,
  'day1 rows_update=1'
);
select is(
  app.aggregate_sync_run_stats_daily('2026-01-02'),
  1,
  '聚合 2026-01-02（上海）返回 1 行'
);
select is(
  (select runs from public.sync_run_stats_daily
    where day = '2026-01-02' and task_id = (:'te'::jsonb ->> 'id')::uuid),
  2::bigint,
  'day2 running 明细不计入（runs=2）'
);
select is(
  (select failed from public.sync_run_stats_daily
    where day = '2026-01-02' and task_id = (:'te'::jsonb ->> 'id')::uuid),
  1::bigint,
  'day2 failed=1（partial 不计入 failed）'
);
select is(
  (select rows_failed from public.sync_run_stats_daily
    where day = '2026-01-02' and task_id = (:'te'::jsonb ->> 'id')::uuid),
  3::bigint,
  'day2 rows_failed=3（failed 2 + partial 1；running 不计）'
);
select is(
  (select runs - success - failed from public.sync_run_stats_daily
    where day = '2026-01-02' and task_id = (:'te'::jsonb ->> 'id')::uuid),
  1::bigint,
  'day2 partial = runs - success - failed = 1'
);
select is(app.aggregate_sync_run_stats_daily('2026-01-02'), 1, '重复聚合幂等（返回行数不变）');
select is(
  (select runs from public.sync_run_stats_daily
    where day = '2026-01-02' and task_id = (:'te'::jsonb ->> 'id')::uuid),
  2::bigint,
  '重复聚合后计数不变'
);
select is(
  app.aggregate_sync_run_stats_daily(),
  (
    select count(*)::integer from (
      select 1
      from public.sync_runs r
      where r.started_at >= (
              ((now() at time zone 'Asia/Shanghai')::date - 6)::timestamp at time zone 'Asia/Shanghai'
            )
        and r.started_at < (
              (((now() at time zone 'Asia/Shanghai')::date + 1)::timestamp at time zone 'Asia/Shanghai')
            )
        and r.status <> 'running'
      group by (r.started_at at time zone 'Asia/Shanghai')::date, r.task_id
    ) x
  ),
  'NULL 参数补采最近 7 天（覆盖窗口内全部（日,任务）分组）'
);
select is(
  (select runs from public.sync_run_stats_daily
    where day = '2026-01-01' and task_id = (:'te'::jsonb ->> 'id')::uuid),
  1::bigint,
  '7 天补采不触碰历史日聚合'
);

-- 清理前聚合兜底：2026-02-01 未聚合的旧明细在 cleanup 时先聚合再删除
insert into public.sync_runs (id, task_id, trigger_type, status, stats, started_at, finished_at)
values
  ('bbbb0000-0000-4000-8000-000000000005', (:'te'::jsonb ->> 'id')::uuid,
   'manual', 'success', '{"insert":7,"update":0,"conflict":0,"skip":0,"failed":0}'::jsonb,
   '2026-02-01 10:00:00+00', '2026-02-01 10:01:00+00');

select is(app.cleanup_sync_runs(30), 4::bigint, 'cleanup 删除 4 条超期明细（跨两日 + 二月旧明细）');
select is(
  (select runs from public.sync_run_stats_daily
    where day = '2026-02-01' and task_id = (:'te'::jsonb ->> 'id')::uuid),
  1::bigint,
  'cleanup 先聚合待删旧日（2026-02-01 聚合补上）'
);
select is(
  (select rows_insert from public.sync_run_stats_daily
    where day = '2026-02-01' and task_id = (:'te'::jsonb ->> 'id')::uuid),
  7::bigint,
  'cleanup 兜底聚合数字正确'
);
select is(
  (select count(*) from public.sync_runs where id = 'bbbb0000-0000-4000-8000-000000000005'),
  0::bigint,
  '超期旧明细已删除'
);
select is(
  (select count(*) from public.sync_runs where id = 'bbbb0000-0000-4000-8000-000000000004'),
  1::bigint,
  'running 明细保留不清理'
);
select is(
  (select runs from public.sync_run_stats_daily
    where day = '2026-01-01' and task_id = (:'te'::jsonb ->> 'id')::uuid),
  1::bigint,
  '历史聚合在明细删除后长期保留'
);

-- pending 冲突保护 + 不冲小已有聚合
insert into public.sync_runs (id, task_id, trigger_type, status, stats, started_at, finished_at)
values
  ('bbbb0000-0000-4000-8000-000000000006', (:'te'::jsonb ->> 'id')::uuid,
   'manual', 'partial', '{"insert":2,"update":0,"conflict":1,"skip":0,"failed":0}'::jsonb,
   '2026-02-02 08:00:00+00', '2026-02-02 08:01:00+00');
insert into public.sync_conflicts (run_id, row_key, source_data, target_data)
values (
  'bbbb0000-0000-4000-8000-000000000006', '保护行',
  '{"name":"保护行"}'::jsonb, '{"name":"保护行"}'::jsonb
);

select is(app.cleanup_sync_runs(30), 0::bigint, '含 pending 冲突的超期 run 不被删除');
select is(
  (select runs from public.sync_run_stats_daily
    where day = '2026-02-02' and task_id = (:'te'::jsonb ->> 'id')::uuid),
  1::bigint,
  'pending 保护行所在日聚合已建立（等待裁决）'
);
select is(
  (select count(*) from public.sync_runs where id = 'bbbb0000-0000-4000-8000-000000000006'),
  1::bigint,
  'pending 冲突保护行保留'
);

update public.sync_conflicts set resolution = 'ignored', resolved_at = now()
 where run_id = 'bbbb0000-0000-4000-8000-000000000006';
select is(app.cleanup_sync_runs(30), 1::bigint, '裁决后保护行可被清理（删除 1 条）');
select is(
  (select runs from public.sync_run_stats_daily
    where day = '2026-02-02' and task_id = (:'te'::jsonb ->> 'id')::uuid),
  1::bigint,
  '保护行删除后历史聚合不冲小（仍为 1）'
);

-- 聚合表越权（engineer 0 行；anon 无 GRANT）
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select count(*) from public.sync_run_stats_daily),
  0::bigint,
  'engineer 直查聚合表 RLS 收窄为 0 行'
);
select throws_ok(
  $$ select app.aggregate_sync_run_stats_daily('2026-01-01') $$,
  '42501', null, 'engineer 调聚合函数被拒（无执行权）'
);
reset role;
set local role anon;
select throws_ok(
  $$ select * from public.sync_run_stats_daily $$,
  '42501', null, 'anon 直查聚合表被拒（无 GRANT）'
);
reset role;

-- ===========================================================================
-- 9. 凭据掩码修复 + 显式清空（10）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);

-- 8 位凭据：仅 ****（不泄露尾段）；9 位：尾 4 位
set local role authenticated;
select public.upsert_sync_source(
  null, '短凭据源', 'api', '{"base_url":"https://s1.example.com"}'::jsonb, 'short123', null
) as s_short \gset
select public.upsert_sync_source(
  null, '长凭据源', 'api', '{"base_url":"https://s2.example.com"}'::jsonb, 'abcdefghi', null
) as s_long \gset
reset role;
set local role authenticated;
select is(
  (select credentials_masked from public.get_sync_sources() where id = (:'s_short'::jsonb ->> 'id')::uuid),
  '****',
  '≤8 位凭据掩码仅 ****（不暴露尾段）'
);
select is(
  (select credentials_masked from public.get_sync_sources() where id = (:'s_long'::jsonb ->> 'id')::uuid),
  '****fghi',
  '9 位凭据掩码 **** + 尾 4 位'
);

-- 空白串 = 保留
select public.upsert_sync_source(
  (:'s_long'::jsonb ->> 'id')::uuid, '长凭据源', 'api',
  '{"base_url":"https://s2.example.com"}'::jsonb, '   ', null
) as s_ws \gset
reset role;
select is(
  (select app.decrypt_secret(credentials) from public.sync_sources where id = (:'s_long'::jsonb ->> 'id')::uuid),
  'abcdefghi',
  '纯空白串 = 保留原凭据（btrim 判空）'
);

-- 已验证源显式清空：降级 + 清空
set local role authenticated;
select public.test_sync_source((:'s_long'::jsonb ->> 'id')::uuid) as s_long_v \gset
select public.upsert_sync_source(
  (:'s_long'::jsonb ->> 'id')::uuid, '长凭据源', 'api',
  '{"base_url":"https://s2.example.com"}'::jsonb, null, null, true
) as s_long_clear \gset
reset role;
select is((:'s_long_v'::jsonb) ->> 'verify_status', 'verified', '前置：长凭据源已验证');
select is((:'s_long_clear'::jsonb) ->> 'credentials_set', 'false', '显式清空后 credentials_set=false');
select is((:'s_long_clear'::jsonb) ->> 'verify_status', 'unverified', '凭据清空同样触发已验证降级');
select is(
  (select credentials from public.sync_sources where id = (:'s_long'::jsonb ->> 'id')::uuid),
  null::bytea,
  '显式清空后 credentials 为 NULL'
);
select is(
  (select credentials_masked from public.get_sync_sources() where id = (:'s_long'::jsonb ->> 'id')::uuid),
  null::text,
  '清空后列表掩码为 NULL'
);
select is(
  (select last_verified_at from public.sync_sources where id = (:'s_long'::jsonb ->> 'id')::uuid),
  null::timestamptz,
  '清空降级同时清空 last_verified_at'
);

-- 旧 6 参调用兼容（p_clear_credentials 默认 false）
set local role authenticated;
select public.upsert_sync_source(
  (:'s_short'::jsonb ->> 'id')::uuid, '短凭据源', 'api',
  '{"base_url":"https://s1.example.com"}'::jsonb, null, null
) as s_compat \gset
reset role;
select is((:'s_compat'::jsonb) ->> 'credentials_set', 'true', '旧 6 参调用兼容且保留凭据');

select * from finish();
rollback;
