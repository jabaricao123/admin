-- pgTAP：system/011 —— system_cron_registry + register/unregister + system_cron_jobs_v + 执行历史 RPC
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构（表/列/约束/RLS）；静态 job 回填；register 幂等 upsert 与参数校验；
--       unregister 幂等置 disabled；视图字段（周期粗判/超期判定/24h 聚合/孤儿标记）；
--       get_cron_run_history（admin 校验/过滤/limit 收敛）；GRANT 面（register 系不 GRANT、
--       表 admin 只读、视图 admin 门禁、engineer/anon 越权拒绝）。
-- 说明：夹具（登记行 + cron.job + job_run_details）只在本事务内生效，finish 后 rollback。

begin;

select plan(90);

-- ===========================================================================
-- 1. 结构：表 / 列 / 约束 / RLS（14）
-- ===========================================================================
select has_table('public', 'system_cron_registry', 'system_cron_registry 表存在');
select col_is_pk('public', 'system_cron_registry', 'id', 'id 为主键');
select col_type_is('public', 'system_cron_registry', 'job_name', 'text', 'job_name 为 text');
select col_type_is('public', 'system_cron_registry', 'cron_expr', 'text', 'cron_expr 为 text');
select col_type_is('public', 'system_cron_registry', 'timezone', 'text', 'timezone 为 text');
select col_type_is('public', 'system_cron_registry', 'status', 'text', 'status 为 text');
select col_type_is('public', 'system_cron_registry', 'last_run_at', 'timestamp with time zone', 'last_run_at 为 timestamptz');
select col_has_default('public', 'system_cron_registry', 'timezone', 'timezone 有默认值');
select col_has_default('public', 'system_cron_registry', 'status', 'status 有默认值');
select col_has_default('public', 'system_cron_registry', 'created_at', 'created_at 有默认值');
select col_not_null('public', 'system_cron_registry', 'module', 'module 非空');
select col_not_null('public', 'system_cron_registry', 'owner_route', 'owner_route 非空');
select col_has_check('public', 'system_cron_registry', 'status', 'status 有取值 check 约束');
select is(
  (select relrowsecurity from pg_class where oid = 'public.system_cron_registry'::regclass),
  true,
  'system_cron_registry 已启用 RLS'
);

-- ===========================================================================
-- 2. 静态 job 回填（7）
-- ===========================================================================
select is(
  (select count(*) from public.system_cron_registry
    where job_name in ('process-export-jobs', 'process-webhook-events', 'sync-cleanup-runs')),
  3::bigint,
  '静态三 job 已回填（process-export-jobs / process-webhook-events / sync-cleanup-runs）'
);
select is(
  (select module from public.system_cron_registry where job_name = 'process-export-jobs'),
  'report',
  'process-export-jobs 来源模块 report'
);
select is(
  (select owner_route from public.system_cron_registry where job_name = 'process-export-jobs'),
  '/report/exports',
  'process-export-jobs owner_route=/report/exports'
);
select is(
  (select module from public.system_cron_registry where job_name = 'process-webhook-events'),
  'integration',
  'process-webhook-events 来源模块 integration'
);
select is(
  (select owner_route from public.system_cron_registry where job_name = 'process-webhook-events'),
  '/integration/webhooks',
  'process-webhook-events owner_route=/integration/webhooks'
);
select is(
  (select cron_expr from public.system_cron_registry where job_name = 'sync-cleanup-runs'),
  '30 3 * * *',
  'sync-cleanup-runs cron 表达式回填正确'
);
select is(
  (select count(*) from public.system_cron_registry where timezone <> 'Asia/Shanghai'),
  0::bigint,
  '回填 job 时区均为 Asia/Shanghai'
);

-- ===========================================================================
-- 3. 函数存在性 + SECURITY DEFINER + search_path（8）
-- ===========================================================================
select has_function(
  'app', 'register_cron_job', array['text', 'text', 'text', 'text', 'text'],
  'app.register_cron_job(text,text,text,text,text) 存在'
);
select has_function(
  'app', 'unregister_cron_job', array['text'],
  'app.unregister_cron_job(text) 存在'
);
select has_function(
  'app', 'cron_expected_interval_minutes', array['text'],
  'app.cron_expected_interval_minutes(text) 存在'
);
select has_function(
  'app', 'get_cron_run_history', array['text', 'integer'],
  'app.get_cron_run_history(text,integer) 存在'
);
select has_function(
  'public', 'get_cron_run_history', array['text', 'integer'],
  'public.get_cron_run_history(text,integer) 薄包装存在'
);
select has_view('public', 'system_cron_jobs_v', 'system_cron_jobs_v 视图存在');
select ok(
  (select count(*) = 3
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname in ('register_cron_job', 'unregister_cron_job', 'cron_expected_interval_minutes')
      and p.proconfig @> array['search_path=""']
      and (p.proname = 'cron_expected_interval_minutes' or p.prosecdef)),
  '登记契约 3 函数 search_path 固定为空（register/unregister 为 SECURITY DEFINER）'
);
select ok(
  (select count(*) = 2
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where p.proname = 'get_cron_run_history'
      and n.nspname in ('app', 'public')
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  'get_cron_run_history 两侧均 security definer + search_path 固定为空'
);

-- ===========================================================================
-- 4. GRANT 面：登记系不 GRANT；表 admin 只读；视图仅 authenticated（9）
-- ===========================================================================
select ok(
  not has_function_privilege(
    'authenticated', 'app.register_cron_job(text,text,text,text,text)', 'EXECUTE'),
  'authenticated 无 app.register_cron_job 执行权（规则 10）'
);
select ok(
  not has_function_privilege('authenticated', 'app.unregister_cron_job(text)', 'EXECUTE'),
  'authenticated 无 app.unregister_cron_job 执行权（规则 10）'
);
select ok(
  has_function_privilege('authenticated', 'app.cron_expected_interval_minutes(text)', 'EXECUTE'),
  'authenticated 可执行纯解析 helper（system_cron_jobs_v 视图内调用）'
);
select ok(
  not has_function_privilege('anon', 'public.get_cron_run_history(text,integer)', 'EXECUTE'),
  'anon 无 public.get_cron_run_history 执行权'
);
select ok(
  has_function_privilege('authenticated', 'public.get_cron_run_history(text,integer)', 'EXECUTE'),
  'authenticated 可执行 public.get_cron_run_history（函数内 admin 校验）'
);
select ok(
  has_table_privilege('authenticated', 'public.system_cron_registry', 'SELECT'),
  'authenticated 对 system_cron_registry 有 SELECT'
);
select ok(
  not has_table_privilege('authenticated', 'public.system_cron_registry', 'INSERT'),
  'authenticated 对 system_cron_registry 无 INSERT（写仅函数）'
);
select ok(
  has_table_privilege('authenticated', 'public.system_cron_jobs_v', 'SELECT'),
  'authenticated 对 system_cron_jobs_v 有 SELECT'
);
select ok(
  not has_table_privilege('anon', 'public.system_cron_jobs_v', 'SELECT'),
  'anon 对 system_cron_jobs_v 无 SELECT'
);

-- ===========================================================================
-- 5. register 幂等 + 参数校验 + unregister（18）
-- ===========================================================================
select lives_ok(
  $$ select app.register_cron_job(
       'pgtap-cron-job', 'pgtap', '0 * * * *', 'Asia/Shanghai', '/pgtap'
     ) $$,
  'register 新 job 成功'
);
select is(
  (select count(*) from public.system_cron_registry where job_name = 'pgtap-cron-job'),
  1::bigint,
  'register 新增一行'
);
select is(
  (select module from public.system_cron_registry where job_name = 'pgtap-cron-job'),
  'pgtap',
  'register 返回 module 正确'
);
select lives_ok(
  $$ select app.register_cron_job(
       'pgtap-cron-job', 'pgtap2', '30 * * * *', 'Asia/Shanghai', '/pgtap/other'
     ) $$,
  'register 同名重复登记成功（idempotent upsert）'
);
select is(
  (select count(*) from public.system_cron_registry where job_name = 'pgtap-cron-job'),
  1::bigint,
  '重复登记不产生重复行'
);
select is(
  (select cron_expr from public.system_cron_registry where job_name = 'pgtap-cron-job'),
  '30 * * * *',
  '重复登记更新 cron 表达式'
);
select is(
  (select owner_route from public.system_cron_registry where job_name = 'pgtap-cron-job'),
  '/pgtap/other',
  '重复登记更新 owner_route'
);
select is(
  (select app.unregister_cron_job('pgtap-cron-job')),
  true,
  'unregister 已登记 job 返回 true'
);
select is(
  (select status from public.system_cron_registry where job_name = 'pgtap-cron-job'),
  'disabled',
  'unregister 置 disabled（历史保留）'
);
select is(
  (select app.unregister_cron_job('no-such-job')),
  false,
  'unregister 未登记 job 幂等返回 false'
);
select lives_ok(
  $$ select app.register_cron_job(
       'pgtap-cron-job', 'pgtap', '30 * * * *', 'Asia/Shanghai', '/pgtap/other'
     ) $$,
  '重新登记已注销 job 成功'
);
select is(
  (select status from public.system_cron_registry where job_name = 'pgtap-cron-job'),
  'active',
  '重新登记恢复 active'
);
select throws_ok(
  $$ insert into public.system_cron_registry (job_name, module, cron_expr, owner_route)
     values ('process-export-jobs', 'dup', '* * * * *', '/dup') $$,
  '23505', null,
  'job_name 唯一约束拒绝重复登记行'
);

select throws_ok(
  $$ select app.register_cron_job('', 'pgtap', '* * * * *', 'Asia/Shanghai', '/x') $$,
  '22023', null,
  '空 job 名被拒'
);
select throws_ok(
  $$ select app.register_cron_job('x', '  ', '* * * * *', 'Asia/Shanghai', '/x') $$,
  '22023', null,
  '空模块被拒'
);
select throws_ok(
  $$ select app.register_cron_job('x', 'pgtap', '0 * * *', 'Asia/Shanghai', '/x') $$,
  '22023', null,
  '四段 cron 被拒'
);
select throws_ok(
  $$ select app.register_cron_job('x', 'pgtap', '* * * * *', 'Nowhere/Zone', '/x') $$,
  '22023', null,
  '未知时区被拒'
);
select throws_ok(
  $$ select app.register_cron_job('x', 'pgtap', '* * * * *', 'Asia/Shanghai', 'x') $$,
  '22023', null,
  'owner_route 非 / 开头被拒'
);

-- ===========================================================================
-- 6. 视图：周期粗判 / 超期判定 / 24h 聚合 / 孤儿（23）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$ select * from public.system_cron_jobs_v $$,
  'admin 可读 system_cron_jobs_v'
);
select is(
  (select expected_interval_minutes from public.system_cron_jobs_v where job_name = 'process-export-jobs'),
  1,
  '每分钟 job 预期周期=1min'
);
select is(
  (select expected_interval_minutes from public.system_cron_jobs_v where job_name = 'process-webhook-events'),
  1,
  'webhook 轮询 job 预期周期=1min'
);
select is(
  (select expected_interval_minutes from public.system_cron_jobs_v where job_name = 'sync-cleanup-runs'),
  1440,
  '每日 job 预期周期=24h'
);
select is(
  (select expected_interval_minutes from public.system_cron_jobs_v where job_name = 'pgtap-cron-job'),
  60,
  '整点 cron（30 * * * *）预期周期=1h'
);
select is(
  (select is_scheduled from public.system_cron_jobs_v where job_name = 'pgtap-cron-job'),
  false,
  '登记但未 cron.schedule 的 job is_scheduled=false'
);
select is(
  (select status from public.system_cron_jobs_v where job_name = 'pgtap-cron-job'),
  'unscheduled',
  '登记但未调度的 job 状态提示 unscheduled'
);
select is(
  (select overdue from public.system_cron_jobs_v where job_name = 'sync-cleanup-runs'),
  false,
  '从未运行且无 last_run 的 job 不判超期'
);

reset role;

select lives_ok(
  $$ select cron.schedule('pgtap-cron-job', '30 * * * *', 'select 1') $$,
  '夹具：注册同名 pg_cron job'
);
update public.system_cron_registry
   set last_run_at = now() - interval '3 hours'
 where job_name = 'pgtap-cron-job';

set local role authenticated;

select is(
  (select is_scheduled from public.system_cron_jobs_v where job_name = 'pgtap-cron-job'),
  true,
  '同名 pg_cron job 存在则 is_scheduled=true'
);
select is(
  (select status from public.system_cron_jobs_v where job_name = 'pgtap-cron-job'),
  'active',
  '在调度的登记 job 状态 active'
);
select is(
  (select overdue from public.system_cron_jobs_v where job_name = 'pgtap-cron-job'),
  true,
  'last_run 3h 前 / 周期 1h → overdue=true（超 2 周期）'
);

reset role;

update public.system_cron_registry
   set last_run_at = now() - interval '90 minutes'
 where job_name = 'pgtap-cron-job';

set local role authenticated;

select is(
  (select overdue from public.system_cron_jobs_v where job_name = 'pgtap-cron-job'),
  false,
  'last_run 1.5h 前 / 周期 1h → 未超 2 周期不判超期'
);

reset role;

-- 夹具：插入两条运行明细（1 成功 + 1 失败，均在 24h 内；显式 runid 规避序列权限）
insert into cron.job_run_details
  (runid, jobid, database, username, command, status, return_message, start_time, end_time)
select
  900000001, j.jobid, 'postgres', 'postgres', 'select 1', 'succeeded', 'ok',
  now() - interval '10 minutes',
  now() - interval '10 minutes' + interval '1.5 seconds'
from cron.job j
where j.jobname = 'pgtap-cron-job';

insert into cron.job_run_details
  (runid, jobid, database, username, command, status, return_message, start_time, end_time)
select
  900000002, j.jobid, 'postgres', 'postgres', 'select 1', 'failed', 'boom',
  now() - interval '2 minutes',
  now() - interval '2 minutes' + interval '2.5 seconds'
from cron.job j
where j.jobname = 'pgtap-cron-job';

set local role authenticated;

select is(
  (select runs_24h from public.system_cron_jobs_v where job_name = 'pgtap-cron-job'),
  2,
  '24h 运行数聚合=2'
);
select is(
  (select failures_24h from public.system_cron_jobs_v where job_name = 'pgtap-cron-job'),
  1,
  '24h 失败数聚合=1'
);
select is(
  (select failure_rate_24h from public.system_cron_jobs_v where job_name = 'pgtap-cron-job'),
  0.5::numeric,
  '24h 失败率=0.5（失败数/运行数）'
);
select is(
  (select last_result from public.system_cron_jobs_v where job_name = 'pgtap-cron-job'),
  'failed',
  'last_result 取最近一次运行状态'
);
select is(
  (select overdue from public.system_cron_jobs_v where job_name = 'pgtap-cron-job'),
  false,
  '有近期运行明细时 overdue 以运行明细为准（false）'
);

reset role;

select lives_ok(
  $$ select cron.schedule('pgtap-orphan-job', '0 0 1 1 *', 'select 1') $$,
  '夹具：注册未登记的孤儿 pg_cron job'
);

set local role authenticated;

select is(
  (select is_orphan from public.system_cron_jobs_v where job_name = 'pgtap-orphan-job'),
  true,
  '孤儿 job（在 cron.job、未登记）is_orphan=true'
);
select is(
  (select module from public.system_cron_jobs_v where job_name = 'pgtap-orphan-job'),
  null::text,
  '孤儿 job 无来源模块'
);
select is(
  (select status from public.system_cron_jobs_v where job_name = 'pgtap-orphan-job'),
  'orphan',
  '孤儿 job 状态标记 orphan'
);

reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;

select is(
  (select count(*) from public.system_cron_jobs_v),
  0::bigint,
  'engineer 读 system_cron_jobs_v 被 admin 门禁过滤（0 行）'
);

reset role;

-- ===========================================================================
-- 7. get_cron_run_history：过滤 / limit / 越权（8）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select is(
  (select count(*) from public.get_cron_run_history('pgtap-cron-job', 50)),
  2::bigint,
  'admin 查 pgtap-cron-job 执行历史 2 条'
);
select is(
  (select status from public.get_cron_run_history('pgtap-cron-job', 50) limit 1),
  'failed',
  '执行历史按开始时间倒序（最近失败在前）'
);
select is(
  (select duration_ms from public.get_cron_run_history('pgtap-cron-job', 50) limit 1),
  2500,
  '执行历史计算耗时（end_time-start_time, ms）'
);
select is(
  (select count(*) from public.get_cron_run_history('sync-cleanup-runs', 50)),
  0::bigint,
  '按 job 名过滤（sync-cleanup-runs 无执行明细）'
);
select is(
  (select count(*) from public.get_cron_run_history(null, 1)),
  1::bigint,
  'p_limit 生效（1 条）'
);
select ok(
  (select count(*) from public.get_cron_run_history(null, 1000)) >= 2,
  'p_limit=1000（收敛上限内）返回全部 job 历史（>=2 条）'
);

reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$ select * from public.get_cron_run_history('pgtap-cron-job', 50) $$,
  '42501', null,
  'engineer 查执行历史被 admin 校验拒绝'
);

reset role;

set local role anon;

select throws_ok(
  $$ select * from public.get_cron_run_history('pgtap-cron-job', 50) $$,
  '42501', null,
  'anon 调 get_cron_run_history 被拒（无 GRANT）'
);

reset role;

-- ===========================================================================
-- 8. 表级直读策略：admin 可见、engineer 0 行、写入拒绝（3）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select ok(
  (select count(*) from public.system_cron_registry) >= 3,
  'admin 表级直读 system_cron_registry 可见登记行'
);

reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;

select is(
  (select count(*) from public.system_cron_registry),
  0::bigint,
  'engineer 表级直读 system_cron_registry 被 RLS 过滤（0 行）'
);
select throws_ok(
  $$ insert into public.system_cron_registry (job_name, module, cron_expr, owner_route)
     values ('engineer-hack', 'hack', '* * * * *', '/hack') $$,
  '42501', null,
  'engineer 直写 system_cron_registry 被拒（无表级写权限）'
);

reset role;

select * from finish();
rollback;
