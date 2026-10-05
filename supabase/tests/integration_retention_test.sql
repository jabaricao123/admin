-- pgTAP：integration 批次 4 —— 事件保留清理（90 天）+ 调用日志聚合时区/7 天补采
-- 运行：supabase db reset && supabase test db
-- 覆盖：cleanup_integration_events 函数属性/授权；终态事件（done/failed）超期删除且
--       webhook_deliveries 级联清理，pending/delivering 与保留期内事件不受影响；幂等；
--       pg_cron 每日任务 + system 登记处；聚合按 Asia/Shanghai 业务日分日（UTC 跨日样例）；
--       无参调用补采最近 7 天、窗口外不聚合、重复调用幂等。
-- 说明：夹具只在本事务内生效，finish 后 rollback；分区 DDL 随事务回滚。

begin;

select plan(27);

-- ===========================================================================
-- 1. 函数与 SECURITY 属性（3）
-- ===========================================================================
select has_function('app', 'cleanup_integration_events', array['integer'],
  'app.cleanup_integration_events(integer) 存在');
select ok(
  (select not p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'cleanup_integration_events'),
  'cleanup_integration_events 为 SECURITY INVOKER + search_path 空'
);
select has_function('app', 'aggregate_integration_call_stats_daily', array['date'],
  'aggregate_integration_call_stats_daily(date) 存在（签名不变）');

-- ===========================================================================
-- 2. 授权：维护函数不 GRANT API 角色（4）
-- ===========================================================================
select ok(
  not has_function_privilege('authenticated', 'app.cleanup_integration_events(integer)', 'EXECUTE'),
  'authenticated 无 cleanup_integration_events 执行权'
);
select ok(
  not has_function_privilege('anon', 'app.cleanup_integration_events(integer)', 'EXECUTE')
  and not has_function_privilege('service_role', 'app.cleanup_integration_events(integer)', 'EXECUTE'),
  'anon/service_role 无 cleanup_integration_events 执行权'
);
select ok(
  not has_function_privilege('authenticated', 'app.aggregate_integration_call_stats_daily(date)', 'EXECUTE'),
  'authenticated 无聚合执行权（仅 pg_cron 可达）'
);
select ok(
  not has_function_privilege('anon', 'app.aggregate_integration_call_stats_daily(date)', 'EXECUTE')
  and not has_function_privilege('service_role', 'app.aggregate_integration_call_stats_daily(date)', 'EXECUTE'),
  'anon/service_role 无聚合执行权（ADR-001）'
);

-- ===========================================================================
-- 3. 事件保留清理：终态超期删除 + 级联 + 在途/保留期保留 + 幂等（10）
-- ===========================================================================
insert into public.webhooks (name, url, secret_enc, events)
values ('保留清理端点', 'https://hooks.example.com/cleanup', app.encrypt_secret('s'),
        array['pgtap.cleanup'])
returning id as wcl \gset

insert into public.integration_events (event, payload, status, created_at)
values ('pgtap.cleanup.done_old', '{}'::jsonb, 'done', now() - interval '100 days')
returning id as e_done_old \gset
insert into public.integration_events (event, payload, status, created_at)
values ('pgtap.cleanup.failed_old', '{}'::jsonb, 'failed', now() - interval '91 days')
returning id as e_failed_old \gset
insert into public.integration_events (event, payload, status, created_at)
values ('pgtap.cleanup.done_new', '{}'::jsonb, 'done', now() - interval '89 days')
returning id as e_done_new \gset
insert into public.integration_events (event, payload, status, created_at)
values ('pgtap.cleanup.pending_old', '{}'::jsonb, 'pending', now() - interval '100 days')
returning id as e_pending_old \gset
insert into public.integration_events (event, payload, status, created_at)
values ('pgtap.cleanup.delivering_old', '{}'::jsonb, 'delivering', now() - interval '100 days')
returning id as e_delivering_old \gset

insert into public.webhook_deliveries
  (event_id, webhook_id, attempt_no, status, attempted_at, finished_at)
values
  (:'e_done_old', :'wcl', 0, 'done', now() - interval '100 days', now() - interval '100 days'),
  (:'e_failed_old', :'wcl', 0, 'failed', now() - interval '91 days', now() - interval '91 days'),
  (:'e_done_new', :'wcl', 0, 'done', now() - interval '89 days', now() - interval '89 days');

select app.cleanup_integration_events(90) as cleaned \gset

select is(:'cleaned'::integer, 2, '清理 2 条终态超期事件（done 100 天 + failed 91 天）');
select ok(
  not exists (select 1 from public.integration_events where id = :'e_done_old'),
  '100 天前 done 事件被删除'
);
select ok(
  not exists (select 1 from public.integration_events where id = :'e_failed_old'),
  '91 天前 failed 事件被删除'
);
select is(
  (select count(*) from public.webhook_deliveries where event_id = :'e_done_old'),
  0::bigint,
  '被删事件的投递明细级联清理（done）'
);
select is(
  (select count(*) from public.webhook_deliveries where event_id = :'e_failed_old'),
  0::bigint,
  '被删事件的投递明细级联清理（failed）'
);
select ok(
  exists (select 1 from public.integration_events where id = :'e_done_new'),
  '89 天前终态事件保留（未超 90 天）'
);
select ok(
  exists (select 1 from public.integration_events where id = :'e_pending_old'),
  'pending 在途事件不清理（即使超期）'
);
select ok(
  exists (select 1 from public.integration_events where id = :'e_delivering_old'),
  'delivering 在途事件不清理（即使超期）'
);
select ok(
  exists (select 1 from public.webhook_deliveries where event_id = :'e_done_new'),
  '保留期内事件的投递明细不受影响'
);
select is(app.cleanup_integration_events(90), 0, '再次清理幂等（无更多超期终态事件）');

-- ===========================================================================
-- 4. pg_cron + system 登记处（3）
-- ===========================================================================
select ok(
  exists (
    select 1 from cron.job
     where jobname = 'cleanup-integration-events'
       and schedule = '40 3 * * *'
       and command like '%cleanup_integration_events%'
  ),
  'pg_cron 已注册每日事件清理'
);
select ok(
  (select count(*) from public.system_cron_registry
    where job_name = 'cleanup-integration-events'
      and module = 'integration'
      and owner_route = '/integration/webhooks'
      and status = 'active') = 1,
  'system 登记处已登记事件清理 job'
);
select ok(
  exists (
    select 1 from cron.job
     where jobname = 'aggregate-integration-call-stats'
       and command like '%aggregate_integration_call_stats_daily()%'
  ),
  '聚合任务改为无参调用（最近 7 天补采）'
);

-- ===========================================================================
-- 5. 聚合时区：Asia/Shanghai 业务日分日 + 7 天补采（7）
-- ===========================================================================
-- UTC 2026-01-01 17:00 = 上海 2026-01-02 01:00：应按上海日 01-02 聚合
select app.ensure_integration_call_log_partition(date '2026-01-01') as tz_part \gset
insert into public.integration_call_logs (kind, method_event, created_at)
values ('api', 'tz.fixed', timestamptz '2026-01-01 17:00:00+00')
returning id as tz_log \gset

select app.aggregate_integration_call_stats_daily(date '2026-01-02') as agg_fixed \gset
select ok(:'agg_fixed'::integer >= 1, '指定业务日聚合返回分组数');
select is(
  (select total from public.integration_call_stats_daily
    where day = date '2026-01-02' and kind = 'api'
      and ref_id = '00000000-0000-0000-0000-000000000000'::uuid),
  1::bigint,
  'UTC 01-01 17:00 的日志计入上海业务日 01-02（时区修复）'
);

select app.aggregate_integration_call_stats_daily(date '2026-01-01');
select is(
  (select count(*) from public.integration_call_stats_daily where day = date '2026-01-01'),
  0::bigint,
  '按上海业务日 01-01 聚合不会把 17:00Z 日志误记到 01-01'
);

-- 最近 7 天补采：3 天前的日志（无参调用应覆盖）
select app.ensure_integration_call_log_partition((now() - interval '3 days')::date) as recent_part \gset
insert into public.integration_call_logs (kind, method_event, created_at)
values ('api', 'retention.recent', now() - interval '3 days');

select app.aggregate_integration_call_stats_daily() as agg_recent \gset
select ok(:'agg_recent'::integer >= 1, '无参调用补采最近 7 天');
select is(
  (select total from public.integration_call_stats_daily
    where day = (now() at time zone 'Asia/Shanghai')::date - 3
      and kind = 'api'
      and ref_id = '00000000-0000-0000-0000-000000000000'::uuid),
  1::bigint,
  '3 天前日志被无参补采聚合（业务日正确）'
);

-- 10 天前的日志在补采窗口外：重复调用不会引入
select app.ensure_integration_call_log_partition((now() - interval '10 days')::date) as old_part \gset
insert into public.integration_call_logs (kind, method_event, created_at)
values ('api', 'retention.old', now() - interval '10 days');

select app.aggregate_integration_call_stats_daily() as agg_again \gset
select is(:'agg_again'::integer, :'agg_recent'::integer, '无参调用幂等（窗口内分组数稳定）');
select ok(
  not exists (
    select 1 from public.integration_call_stats_daily
     where day = (now() at time zone 'Asia/Shanghai')::date - 10
  ),
  '窗口外（10 天前）日志不被无参补采聚合'
);

select * from finish();
rollback;
