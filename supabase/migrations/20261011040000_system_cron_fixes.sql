-- 系统管理 · pg_cron 监控修正（system 批次 2 修复项 4）
-- 1. app.cron_expected_interval_minutes：周期粗判扩展「月内某日」形 'N M D * *' →
--    保守 31*24*60 分钟（dom 取值 1..31，避免低估导致误报超期）。
-- 2. system_cron_jobs_v：
--    * 超期兜底：从未有运行记录（job_run_details / last_run_at 均无）的 job，以
--      registry.created_at + 2 倍预期周期判定 overdue，不再恒为 false；
--    * 失败率口径：failures_24h 只计 status='failed'（不再把 running/starting 计入分子；
--      runs_24h 仍为 24h 全部运行数）。
-- 3. last_run_at / last_result 保留但明确标注为死列（视图优先取 cron.job_run_details；
--    保留列与 COALESCE 读取仅为兼容既有数据与测试，勿新增写入）。
-- 依赖：20261005080000（登记表 / 视图 / 解析 helper）。

-- ---------------------------------------------------------------------------
-- 1. 周期粗判：扩展月内某日（N M D * *）
-- ---------------------------------------------------------------------------
create or replace function app.cron_expected_interval_minutes(p_cron_expr text)
returns integer
language sql
immutable
set search_path = ''
as $$
  with parts as (
    select regexp_split_to_array(btrim(coalesce(p_cron_expr, '')), '\s+') as f
  )
  select case
    when array_length(f, 1) <> 5 then null
    -- 每分钟
    when f[1] = '*' and f[2] = '*' and f[3] = '*' and f[4] = '*' and f[5] = '*' then 1
    -- 每 N 分钟（*/N * * * *）
    when f[1] ~ '^\*/\d+$' and f[2] = '*' and f[3] = '*' and f[4] = '*' and f[5] = '*'
      then substring(f[1] from 3)::integer
    -- 每 N 小时（M */N * * *）
    when f[1] ~ '^\d+$' and f[2] ~ '^\*/\d+$' and f[3] = '*' and f[4] = '*' and f[5] = '*'
      then substring(f[2] from 3)::integer * 60
    -- 每小时
    when f[1] ~ '^\d+$' and f[2] = '*' and f[3] = '*' and f[4] = '*' and f[5] = '*' then 60
    -- 每天
    when f[1] ~ '^\d+$' and f[2] ~ '^\d+$' and f[3] = '*' and f[4] = '*' and f[5] = '*'
      then 1440
    -- 月内某日（N M D * *，如 0 3 1 * *）→ 保守按 31 天（dom 上限）
    when f[1] ~ '^\d+$' and f[2] ~ '^\d+$' and f[3] ~ '^[0-9,\-*/]+$' and f[4] = '*' and f[5] = '*'
      then 31 * 24 * 60
    -- 每周（周字段受限）
    when f[1] ~ '^\d+$' and f[2] ~ '^\d+$' and f[3] = '*' and f[4] = '*' and f[5] ~ '^[0-9,\-*/]+$'
      then 10080
    else null
  end
  from parts
$$;

comment on function app.cron_expected_interval_minutes(text) is
  'cron 预期周期粗判（分钟）：* * * * *→1、*/N→N、0 *→1h、daily→24h、月内某日（N M D * *）'
  '→31d（保守）、weekly→7d；仅支持五段常见形，解析不了返回 NULL（视图不判超期）；'
  '纯解析 helper，GRANT authenticated（视图内调用），anon/service_role 不授';

-- ---------------------------------------------------------------------------
-- 2. 死列标注（保留列定义，避免破坏既有视图/测试）
-- ---------------------------------------------------------------------------
comment on column public.system_cron_registry.last_run_at is
  '死列（deprecated，仅历史数据兼容）：视图优先取 cron.job_run_details 最新值，不再回写；勿新增写入';
comment on column public.system_cron_registry.last_result is
  '死列（deprecated，仅历史数据兼容）：视图优先取 cron.job_run_details 最新状态，不再回写；勿新增写入';

-- ---------------------------------------------------------------------------
-- 3. system_cron_jobs_v：超期兜底 + 失败率口径（列结构不变）
-- ---------------------------------------------------------------------------
create or replace view public.system_cron_jobs_v as
with runs as (
  select
    d.jobid,
    max(d.start_time) as last_start_at,
    count(*) filter (
      where d.start_time > now() - interval '24 hours'
    ) as runs_24h,
    -- 失败率分子只计显式 failed（running/starting 不计入，dead 状态由 cron 自身标记为 failed）
    count(*) filter (
      where d.start_time > now() - interval '24 hours'
        and d.status = 'failed'
    ) as failures_24h
  from cron.job_run_details d
  group by d.jobid
),
latest as (
  select distinct on (d.jobid)
    d.jobid, d.status, d.return_message, d.start_time, d.end_time
  from cron.job_run_details d
  order by d.jobid, d.start_time desc, d.runid desc
),
base as (
  select
    coalesce(r.job_name, j.jobname) as job_name,
    r.id as registry_id,
    r.module,
    r.cron_expr,
    r.timezone,
    r.owner_route,
    r.status as registry_status,
    r.last_run_at as registry_last_run_at,
    r.last_result as registry_last_result,
    r.registered_by,
    r.created_at,
    r.updated_at,
    j.jobid,
    j.schedule as schedule_expr,
    j.active as schedule_active
  from public.system_cron_registry r
  full join cron.job j on j.jobname = r.job_name
)
select
  b.job_name,
  b.registry_id,
  b.module,
  coalesce(b.cron_expr, b.schedule_expr) as cron_expr,
  coalesce(b.timezone, 'Asia/Shanghai') as timezone,
  b.owner_route,
  case
    when b.registry_id is null then 'orphan'
    when b.registry_status = 'disabled' then 'disabled'
    when b.jobid is null then 'unscheduled'
    when b.schedule_active is false then 'paused'
    else 'active'
  end as status,
  coalesce(l.start_time, b.registry_last_run_at) as last_run_at,
  coalesce(l.status, b.registry_last_result) as last_result,
  coalesce(agg.runs_24h, 0)::integer as runs_24h,
  coalesce(agg.failures_24h, 0)::integer as failures_24h,
  coalesce(round(agg.failures_24h::numeric / nullif(agg.runs_24h, 0), 4), 0) as failure_rate_24h,
  app.cron_expected_interval_minutes(
    coalesce(b.cron_expr, b.schedule_expr)
  ) as expected_interval_minutes,
  -- 超期判定：从未运行的 job 以 created_at（登记时间）为兜底基准；
  -- 解析不了周期（expected NULL）不判超期
  coalesce(
    b.registry_id is not null
    and b.registry_status = 'active'
    and b.jobid is not null
    and app.cron_expected_interval_minutes(
          coalesce(b.cron_expr, b.schedule_expr)
        ) is not null
    and now() > coalesce(l.start_time, b.registry_last_run_at, b.created_at)
      + make_interval(mins => 2 * app.cron_expected_interval_minutes(
          coalesce(b.cron_expr, b.schedule_expr)
        )),
    false
  ) as overdue,
  (b.jobid is not null) as is_scheduled,
  (b.registry_id is null) as is_orphan,
  b.registered_by,
  b.created_at,
  b.updated_at
from base b
left join runs agg on agg.jobid = b.jobid
left join latest l on l.jobid = b.jobid
-- 视图以属主身份读 cron 系统表；以角色门禁收口 admin（保持 RLS 语义）；
-- job_name 为空的 pg_cron 匿名 job 不展示（无法登记/关联执行历史）
where (select app.current_role()) = 'admin'
  and b.job_name is not null;

comment on view public.system_cron_jobs_v is
  'pg_cron 平台登记健康视图（admin 只读，视图内嵌角色门禁）：registry full join cron.job；'
  '失败率=24h 显式 failed 数/24h 运行数（running/starting 不计入分子；0..1）；'
  'overdue=最近运行（或从未运行时为 created_at）早于 2 倍预期周期；月内某日形按 31 天保守估计；'
  'is_orphan=在 cron.job 但未登记（页面标红）';
