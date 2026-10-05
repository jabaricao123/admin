-- pgTAP：system 批次 2 修复项 4 —— cron 修正三件套（system_cron_fixes）
-- 覆盖：周期粗判扩展「月内某日」'N M D * *' → 44640 分钟（31d 保守）；
--       从未运行 job 以 registry.created_at + 2 周期兜底判 overdue；
--       失败率分子只计 status='failed'（running 不再计入）；
--       last_run_at / last_result 死列注释；daily 解析回归不变。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(16);

-- ---------------------------------------------------------------------------
-- 1. 周期粗判 helper（4，superuser 直调）
-- ---------------------------------------------------------------------------
select is(
  app.cron_expected_interval_minutes('0 3 1 * *'),
  31 * 24 * 60,
  '月内某日（0 3 1 * *）：预期周期=31 天（保守）'
);
select is(
  app.cron_expected_interval_minutes('0 0 15 * *'),
  31 * 24 * 60,
  '月内某日（0 0 15 * *）：预期周期=31 天'
);
select is(
  app.cron_expected_interval_minutes('30 3 * * *'),
  1440,
  '每日解析回归不变（1440 分钟）'
);
select is(
  app.cron_expected_interval_minutes('0 3'),
  null::integer,
  '非五段表达式返回 NULL（不误判）'
);

-- ---------------------------------------------------------------------------
-- 夹具：登记两个月度 job（一个 created 3 周期前 / 一个新登记并调度）
-- ---------------------------------------------------------------------------
select app.register_cron_job(
  'pgtap-monthly-overdue', 'pgtap', '0 3 1 * *', 'Asia/Shanghai', '/pgtap'
);
select app.register_cron_job(
  'pgtap-monthly-fresh', 'pgtap', '0 3 1 * *', 'Asia/Shanghai', '/pgtap'
);

update public.system_cron_registry
   set created_at = now() - interval '93 days'   -- 3 × 31 天
 where job_name = 'pgtap-monthly-overdue';

select cron.schedule('pgtap-monthly-overdue', '0 3 1 * *', 'select 1');
select cron.schedule('pgtap-monthly-fresh', '0 3 1 * *', 'select 1');

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

-- ---------------------------------------------------------------------------
-- 2. 视图：月度周期展示 + never-run 兜底 overdue（4）
-- ---------------------------------------------------------------------------
select is(
  (select expected_interval_minutes from public.system_cron_jobs_v
    where job_name = 'pgtap-monthly-overdue'),
  31 * 24 * 60,
  '视图：月度 job expected_interval_minutes 非空且为 44640'
);
select is(
  (select overdue from public.system_cron_jobs_v where job_name = 'pgtap-monthly-overdue'),
  true,
  '从未运行 + created 3 周期前 → overdue=true'
);
select is(
  (select last_run_at from public.system_cron_jobs_v where job_name = 'pgtap-monthly-overdue'),
  null::timestamptz,
  '从未运行 job last_run_at 为空（overdue 由 created_at 兜底判定）'
);
select is(
  (select overdue from public.system_cron_jobs_v where job_name = 'pgtap-monthly-fresh'),
  false,
  '从未运行 + 刚登记 → 未超 2 周期，overdue=false'
);

reset role;

-- ---------------------------------------------------------------------------
-- 3. 失败率口径：running 不计入分子（4）
-- ---------------------------------------------------------------------------
insert into cron.job_run_details
  (runid, jobid, database, username, command, status, return_message, start_time, end_time)
select
  900000101, j.jobid, 'postgres', 'postgres', 'select 1', 'running', 'still running',
  now() - interval '3 minutes', null
from cron.job j
where j.jobname = 'pgtap-monthly-fresh';

insert into cron.job_run_details
  (runid, jobid, database, username, command, status, return_message, start_time, end_time)
select
  900000102, j.jobid, 'postgres', 'postgres', 'select 1', 'failed', 'boom',
  now() - interval '2 minutes',
  now() - interval '2 minutes' + interval '1 second'
from cron.job j
where j.jobname = 'pgtap-monthly-fresh';

set local role authenticated;

select is(
  (select runs_24h from public.system_cron_jobs_v where job_name = 'pgtap-monthly-fresh'),
  2,
  '24h 运行数=2（running + failed）'
);
select is(
  (select failures_24h from public.system_cron_jobs_v where job_name = 'pgtap-monthly-fresh'),
  1,
  '24h 失败数=1（running 计入运行数但不计入失败数）'
);
select is(
  (select failure_rate_24h from public.system_cron_jobs_v where job_name = 'pgtap-monthly-fresh'),
  0.5::numeric,
  '失败率=1/2=0.5（旧口径会把 running 计成失败 → 1.0）'
);

reset role;

insert into cron.job_run_details
  (runid, jobid, database, username, command, status, return_message, start_time, end_time)
select
  900000103, j.jobid, 'postgres', 'postgres', 'select 1', 'succeeded', 'ok',
  now() - interval '1 minute',
  now() - interval '1 minute' + interval '0.5 seconds'
from cron.job j
where j.jobname = 'pgtap-monthly-fresh';

set local role authenticated;

select is(
  (select failures_24h from public.system_cron_jobs_v where job_name = 'pgtap-monthly-fresh'),
  1,
  '追加 succeeded 后失败数仍为 1（只计显式 failed）'
);

reset role;

-- ---------------------------------------------------------------------------
-- 4. 死列注释 + 月度 job 在 registry（4）
-- ---------------------------------------------------------------------------
select ok(
  col_description(
    'public.system_cron_registry'::regclass,
    (select attnum from pg_attribute
      where attrelid = 'public.system_cron_registry'::regclass and attname = 'last_run_at')
  ) like '%死列%',
  'last_run_at 列注释明确标注死列（保留列定义兼容既有视图/测试）'
);
select ok(
  col_description(
    'public.system_cron_registry'::regclass,
    (select attnum from pg_attribute
      where attrelid = 'public.system_cron_registry'::regclass and attname = 'last_result')
  ) like '%死列%',
  'last_result 列注释明确标注死列'
);
select is(
  (select count(*) from public.system_cron_registry
    where job_name like 'pgtap-monthly-%' and status = 'active'),
  2::bigint,
  '月度 job 登记为 active（视图 overdue 判定前提）'
);
select is(
  (select module from public.system_cron_registry where job_name = 'pgtap-monthly-overdue'),
  'pgtap',
  '登记来源模块可查（监控视图 module 列）'
);

select * from finish();
rollback;
