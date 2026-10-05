-- 接口/集成中心 · 批次 4 并入：事件保留清理 + 调用日志聚合时区/补采（工单 integration/fix-batch4）
-- 契约：docs/modules/integration/logs.md（聚合长期保留、清理任务在 system pg_cron 登记处注册，
--       INDEX 规则 5）、docs/modules/integration/webhooks.md（事件队列排障明细保留）、
--       docs/adr/001-job-runner.md（系统级清理任务为最小实现）。
-- 本迁移两组变更：
--   1. 事件保留清理 app.cleanup_integration_events：终态（done/failed）事件保留 90 天，
--      超期删除；webhook_deliveries 按 FK on delete cascade 级联清理（pending/delivering
--      不清理，避免删在途事件）。cron.schedule 每日 + register_cron_job 登记。
--   2. 聚合时区修复：app.aggregate_integration_call_stats_daily 按业务时区
--      Asia/Shanghai 的自然日分日（原按 UTC/会话时区，凌晨 0-8 点调用会把当天数据
--      记到错误日）；无参调用默认重算最近 7 天（含业务今日）补采，防漏跑缺数；
--      聚合任务 cron 改为无参调用（幂等，可安全重复执行）。
-- 依赖：integration/004/005（integration_events / webhook_deliveries）、
--       integration/007（integration_call_logs / stats_daily）、system/011（register_cron_job）。

-- ---------------------------------------------------------------------------
-- 1. app.cleanup_integration_events：90 天终态事件清理（级联 deliveries）
-- ---------------------------------------------------------------------------
create function app.cleanup_integration_events(p_retention_days integer default 90)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_days    integer := greatest(coalesce(p_retention_days, 90), 1);
  v_cutoff  timestamptz := now() - make_interval(days => v_days);
  v_deleted integer;
begin
  -- 仅终态（done/failed）：pending/delivering 为在途事件，不清理；
  -- webhook_deliveries（event_id FK on delete cascade）随事件级联删除。
  delete from public.integration_events
   where status in ('done', 'failed')
     and created_at < v_cutoff;

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

comment on function app.cleanup_integration_events(integer) is
  '集成事件保留清理：终态（done/failed）事件超过保留期（默认 90 天）删除，关联 '
  'webhook_deliveries 级联清理；pending/delivering 在途事件不受影响；返回删除事件数；'
  'security invoker + 撤销 API 角色执行权，仅 pg_cron 可达';

-- ---------------------------------------------------------------------------
-- 2. app.aggregate_integration_call_stats_daily：业务时区按日 + 最近 7 天补采
--    p_day = 业务日（Asia/Shanghai 自然日）；NULL（默认）＝重算最近 7 天（含业务今日）。
-- ---------------------------------------------------------------------------
create or replace function app.aggregate_integration_call_stats_daily(p_day date default null)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  c_zero  constant uuid := '00000000-0000-0000-0000-000000000000'::uuid;
  v_from  date;
  v_to    date;
  v_rows  integer;
begin
  if p_day is null then
    -- 业务时区今日（Asia/Shanghai）+ 往前 6 天：防漏跑/时区跨日缺数的幂等补采
    v_to := (now() at time zone 'Asia/Shanghai')::date;
    v_from := v_to - 6;
  else
    v_from := p_day;
    v_to := p_day;
  end if;

  delete from public.integration_call_stats_daily
   where day between v_from and v_to;

  insert into public.integration_call_stats_daily
    (day, kind, ref_id, ref_name, total, failed, avg_duration_ms)
  select
    (l.created_at at time zone 'Asia/Shanghai')::date,
    l.kind,
    coalesce(l.key_id, l.webhook_id, c_zero),
    case
      when l.kind = 'api' then k.name
      else w.name
    end,
    count(*),
    count(*) filter (where l.status_code is null or l.status_code >= 400),
    round(avg(l.duration_ms) filter (where l.duration_ms is not null), 1)
  from public.integration_call_logs l
  left join public.api_keys k
    on l.kind = 'api' and k.id = l.key_id
  left join public.webhooks w
    on l.kind = 'webhook' and w.id = l.webhook_id
  -- 分区裁剪友好：按业务日边界换算 timestamptz 区间
  where l.created_at >= (v_from::timestamp at time zone 'Asia/Shanghai')
    and l.created_at < ((v_to + 1)::timestamp at time zone 'Asia/Shanghai')
  group by 1, 2, 3, 4;

  get diagnostics v_rows = row_count;
  return v_rows;
end;
$$;

comment on function app.aggregate_integration_call_stats_daily(date) is
  '重算调用聚合：day 为 Asia/Shanghai 业务日（原 UTC 分日修复）；p_day 为 NULL（默认）时'
  '重算最近 7 天（含业务今日）补采，否则仅重算指定业务日；先删后插，幂等；'
  'failed=状态码≥400 或无响应；security invoker + 撤销 API 角色执行权，仅 pg_cron 可达';

-- ---------------------------------------------------------------------------
-- 3. 授权：维护函数不 GRANT API 角色（聚合 create or replace 保持原 ACL，显式再收口）
-- ---------------------------------------------------------------------------
revoke all on function app.cleanup_integration_events(integer)
  from public, anon, authenticated, service_role;
revoke all on function app.aggregate_integration_call_stats_daily(date)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. pg_cron + system 登记处
--    事件清理每日约 03:40 UTC（11:40 上海）；聚合任务改无参（业务日最近 7 天补采）。
-- ---------------------------------------------------------------------------
select cron.schedule(
  'cleanup-integration-events',
  '40 3 * * *',
  $cron$select app.cleanup_integration_events()$cron$
);

select app.register_cron_job(
  'cleanup-integration-events', 'integration', '40 3 * * *', 'Asia/Shanghai', '/integration/webhooks'
);

select cron.schedule(
  'aggregate-integration-call-stats',
  '10 0 * * *',
  $cron$select app.aggregate_integration_call_stats_daily()$cron$
);

select app.register_cron_job(
  'aggregate-integration-call-stats', 'integration', '10 0 * * *', 'Asia/Shanghai', '/integration/logs'
);
