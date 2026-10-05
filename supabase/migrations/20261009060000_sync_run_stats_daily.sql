-- 第三方数据同步 · 批次 4 并入 1：执行记录日聚合长期保留（sync_run_stats_daily）
-- 契约：docs/modules/sync/runs.md「保留策略：明细 30 天（pending 冲突记录不受清理影响，
--       裁决后随明细保留）；聚合长期保留（同 integration/logs 惯例）」。此前只有明细清理，
--       30 天前的趋势不可查。
-- 方案：
--   1. public.sync_run_stats_daily：按（业务日 Asia/Shanghai 自然日，任务）聚合
--      runs/success/failed/rows_insert/rows_update/rows_failed；PK(day, task_id)。
--   2. app.aggregate_sync_run_stats_daily(date)：重算指定业务日（先删后插，幂等）；
--      p_day 为 NULL（默认）时重算最近 7 天（含业务今日）补采，防漏跑/时区跨日缺数
--      （与 integration 聚合同口径）；running 明细不计入（未终态）；
--   3. app.cleanup_sync_runs 改为「先聚合再删」：
--      a) 先重算最近 7 天（含昨日）补采；
--      b) 本次将删除且该（日,任务）尚无聚合的旧日兜底聚合——已有聚合的日子不回算，
--         避免 pending 冲突保护行残留时重算把历史数字冲小；随后按原语义删除 30 天明细；
--   4. cron「sync-aggregate-run-stats」每日 03:00（cleanup 03:30 之前）重算 + 登记处登记。
-- 授权：聚合表 admin 只读（RLS）；聚合/清理函数 security invoker + 撤销 API 角色（仅 pg_cron 可达）。
-- pgTAP：sync_batch2_test.sql（跨界日、计数、幂等、cleanup 先聚合后删、pending 保护、cron 登记）。
-- 依赖：20261005030000（sync_runs / cleanup 现状）、20261005080000（register_cron_job）。

-- ---------------------------------------------------------------------------
-- 1. sync_run_stats_daily：按（业务日，任务）聚合（长期保留）
-- ---------------------------------------------------------------------------
create table public.sync_run_stats_daily (
  day          date not null,
  task_id      uuid not null references public.sync_tasks (id) on delete cascade,
  runs         bigint not null default 0,
  success      bigint not null default 0,
  failed       bigint not null default 0,
  rows_insert  bigint not null default 0,
  rows_update  bigint not null default 0,
  rows_failed  bigint not null default 0,
  updated_at   timestamptz not null default now(),
  constraint sync_run_stats_daily_pkey primary key (day, task_id),
  constraint sync_run_stats_daily_runs_check
    check (runs >= 0 and success >= 0 and failed >= 0 and success + failed <= runs),
  constraint sync_run_stats_daily_rows_check
    check (rows_insert >= 0 and rows_update >= 0 and rows_failed >= 0)
);

comment on table public.sync_run_stats_daily is
  '同步执行按天聚合（长期保留，30 天明细清理后仍可看趋势）：按上海业务日 + 任务维度；'
  '重算幂等（先删后插）；running 明细不计入（未终态）';
comment on column public.sync_run_stats_daily.day is
  '业务日：Asia/Shanghai 自然日（明细 started_at 换算；与 integration 聚合同时区口径）';
comment on column public.sync_run_stats_daily.runs is
  '当日终态执行次数（success + partial + failed）；partial = runs - success - failed';
comment on column public.sync_run_stats_daily.success is '当日 success 次数';
comment on column public.sync_run_stats_daily.failed is '当日 failed 次数';
comment on column public.sync_run_stats_daily.rows_insert is '当日明细 stats.insert 合计';
comment on column public.sync_run_stats_daily.rows_update is '当日明细 stats.update 合计';
comment on column public.sync_run_stats_daily.rows_failed is '当日明细 stats.failed 合计';

create index sync_run_stats_daily_day_idx on public.sync_run_stats_daily (day desc);

alter table public.sync_run_stats_daily enable row level security;

-- ---------------------------------------------------------------------------
-- 2. app.aggregate_sync_run_stats_daily：重算业务日（NULL = 最近 7 天补采）
-- ---------------------------------------------------------------------------
create function app.aggregate_sync_run_stats_daily(p_day date default null)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_from date;
  v_to   date;
  v_rows integer;
begin
  if p_day is null then
    -- 业务时区今日（Asia/Shanghai）+ 往前 6 天：防漏跑/时区跨日缺数的幂等补采
    v_to := (now() at time zone 'Asia/Shanghai')::date;
    v_from := v_to - 6;
  else
    v_from := p_day;
    v_to := p_day;
  end if;

  delete from public.sync_run_stats_daily
   where day between v_from and v_to;

  insert into public.sync_run_stats_daily
    (day, task_id, runs, success, failed, rows_insert, rows_update, rows_failed)
  select
    (r.started_at at time zone 'Asia/Shanghai')::date,
    r.task_id,
    count(*),
    count(*) filter (where r.status = 'success'),
    count(*) filter (where r.status = 'failed'),
    coalesce(sum(coalesce((r.stats ->> 'insert')::bigint, 0)), 0),
    coalesce(sum(coalesce((r.stats ->> 'update')::bigint, 0)), 0),
    coalesce(sum(coalesce((r.stats ->> 'failed')::bigint, 0)), 0)
  from public.sync_runs r
  -- 分区/索引友好：按业务日边界换算 timestamptz 区间
  where r.started_at >= (v_from::timestamp at time zone 'Asia/Shanghai')
    and r.started_at < ((v_to + 1)::timestamp at time zone 'Asia/Shanghai')
    and r.status <> 'running'
  group by 1, 2;

  get diagnostics v_rows = row_count;
  return v_rows;
end;
$$;

comment on function app.aggregate_sync_run_stats_daily(date) is
  '重算同步执行日聚合：day 为 Asia/Shanghai 业务日；p_day 为 NULL（默认）时重算最近 7 天'
  '（含业务今日）补采，否则仅重算指定业务日；先删后插幂等；running 明细不计入；'
  'security invoker + 撤销 API 角色执行权，仅 pg_cron 可达';

-- ---------------------------------------------------------------------------
-- 3. app.cleanup_sync_runs：先聚合再删 30 天明细（原参数校验/保护语义不变）
-- ---------------------------------------------------------------------------
create or replace function app.cleanup_sync_runs(p_retention_days integer default 30)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_cutoff  timestamptz;
  v_day     date;
  v_deleted bigint;
begin
  if p_retention_days is null or p_retention_days < 1 then
    raise exception '保留天数必须 >= 1：%', coalesce(p_retention_days::text, '(null)')
      using errcode = '22023';
  end if;

  v_cutoff := now() - make_interval(days => p_retention_days);

  -- 先聚合后删除（runs.md：聚合长期保留）：
  --   1) 最近 7 天（含昨日）补采重算（幂等，覆盖当日凌晨/漏跑缺口）；
  --   2) 本次将删除且该（日,任务）尚无聚合的旧日兜底聚合——已有聚合的日子不回算，
  --      避免 pending 冲突保护行残留时重算把此前已删明细的历史数字冲小。
  perform app.aggregate_sync_run_stats_daily();

  for v_day in
    select distinct (r.started_at at time zone 'Asia/Shanghai')::date
    from public.sync_runs r
    where r.status <> 'running'
      and r.started_at < v_cutoff
      and not exists (
        select 1
        from public.sync_run_stats_daily s
        where s.day = (r.started_at at time zone 'Asia/Shanghai')::date
          and s.task_id = r.task_id
      )
  loop
    perform app.aggregate_sync_run_stats_daily(v_day);
  end loop;

  delete from public.sync_runs r
   where r.status <> 'running'
     and r.started_at < v_cutoff
     and not exists (
       select 1 from public.sync_conflicts c
       where c.run_id = r.id and c.resolution = 'pending'
     );

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

comment on function app.cleanup_sync_runs(integer) is
  '执行明细清理（默认 30 天；runs.md）：先聚合（最近 7 天补采 + 待删旧日无聚合兜底）再删除'
  '超期且不含 pending 冲突的 run（conflicts 级联）；running 保护；'
  '仅 pg_cron/owner 可达（撤销 API 角色），返回删除条数';

-- ---------------------------------------------------------------------------
-- 4. 授权与 RLS：聚合表 admin 只读；聚合函数无 API 直调
-- ---------------------------------------------------------------------------
revoke all on public.sync_run_stats_daily from public, anon, authenticated, service_role;
grant select on public.sync_run_stats_daily to authenticated;

create policy sync_run_stats_daily_select_admin
on public.sync_run_stats_daily
for select
to authenticated
using ((select app.current_role()) = 'admin');

revoke all on function app.aggregate_sync_run_stats_daily(date)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. pg_cron + 登记处：每日 03:00 重算（cleanup 03:30 之前）
-- ---------------------------------------------------------------------------
select cron.schedule(
  'sync-aggregate-run-stats',
  '0 3 * * *',
  $cron$select app.aggregate_sync_run_stats_daily()$cron$
);

select app.register_cron_job(
  'sync-aggregate-run-stats', 'sync', '0 3 * * *', 'Asia/Shanghai', '/sync/runs'
);
