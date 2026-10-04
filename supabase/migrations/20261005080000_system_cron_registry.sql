-- 系统管理 · pg_cron 平台登记处（工单 system/011：registry 表 + register/unregister RPC + 监控视图）
-- 契约：docs/modules/system/jobs.md：
--   * 全站 pg_cron job 统一登记（job_name 唯一），/system/jobs 只读监控，启停回各模块调度页；
--   * 健康视图 system_cron_jobs_v = 登记表 ⨝ cron.job ⨝ cron.job_run_details 聚合：
--     最近运行、24h 运行数/失败数/失败率、超期判定（> 2 个预期周期）；
--   * 孤儿 job（在 cron.job、不在登记表）在视图标记 is_orphan（页面标红）；
--   * 登记契约 register_cron_job：各模块迁移内调用或后端 wrapper，不 GRANT authenticated
--     （INDEX 规则 10）；注销经 unregister_cron_job（同样不 GRANT）。
-- INDEX 规则 5（调度统一登记）、规则 10（内部 RPC 不 GRANT API 角色）。
-- 说明：
--   * register_cron_job 只登记元数据，不代替 cron.schedule（调度/启停仍由各模块执行）；
--   * 超期判定按 cron_expr 粗判（* * * * *→1min、*/N→N min、0 *→1h、daily→24h、weekly→7d；
--     解析不了返回 NULL，不判超期），expected_interval_minutes 显式供页面展示；
--   * 静态三 job 迁移内回填：process-export-jobs（report/007）、process-webhook-events
--     （integration/003）、sync-cleanup-runs（sync/004，job 名以 cron.schedule 实际登记为准）；
--   * 动态 sync-task-<id> 登记与 sync 调度 RPC 联动待 sync 侧改造：
--     TODO(sync)：upsert_sync_schedule 启用/编辑时补 app.register_cron_job；
--     停用注销时补 app.unregister_cron_job（本工单不改已合入函数，晚绑定调用即可）。
-- 依赖：pg_cron（report/007 已 create extension）、app.current_role() / app.audit_log 同库既有。

-- ---------------------------------------------------------------------------
-- 1. system_cron_registry：pg_cron 平台登记表
-- ---------------------------------------------------------------------------
create table public.system_cron_registry (
  id           bigint generated always as identity primary key,
  job_name     text not null,
  module       text not null,
  cron_expr    text not null,
  timezone     text not null default 'Asia/Shanghai',
  owner_route  text not null,
  status       text not null default 'active',
  last_run_at  timestamptz,
  last_result  text,
  registered_by uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint system_cron_registry_job_name_key unique (job_name),
  constraint system_cron_registry_job_name_check check (btrim(job_name) <> ''),
  constraint system_cron_registry_module_check check (btrim(module) <> ''),
  constraint system_cron_registry_cron_check check (btrim(cron_expr) <> ''),
  constraint system_cron_registry_timezone_check check (btrim(timezone) <> ''),
  constraint system_cron_registry_owner_route_check check (owner_route ~ '^/'),
  constraint system_cron_registry_status_check check (status in ('active', 'disabled'))
);

comment on table public.system_cron_registry is
  'pg_cron 平台登记表：各模块经 app.register_cron_job 登记（幂等 upsert）；'
  '/system/jobs 只读监控的元数据源，不承载启停（启停在各模块调度页）';
comment on column public.system_cron_registry.job_name is 'pg_cron job 名（唯一，对应 cron.job.jobname）';
comment on column public.system_cron_registry.module is '来源模块（report/integration/sync/system 等）';
comment on column public.system_cron_registry.cron_expr is '登记时的 cron 表达式（实际调度以 cron.job 为准）';
comment on column public.system_cron_registry.timezone is '业务时区（pg_cron 内部统一 UTC，展示用）';
comment on column public.system_cron_registry.owner_route is '模块管理路由（页面「去管理」链接，以 / 开头）';
comment on column public.system_cron_registry.status is 'active 登记有效 / disabled 已注销（历史保留）';
comment on column public.system_cron_registry.last_run_at is
  '最近运行时间缓存（弱一致；视图优先取 cron.job_run_details 最新值）';
comment on column public.system_cron_registry.last_result is
  '最近运行结果缓存（弱一致；视图优先取 cron.job_run_details 最新状态）';
comment on column public.system_cron_registry.registered_by is '登记人 auth.uid()（迁移内回填为 NULL）';

create trigger system_cron_registry_set_updated_at
before update on public.system_cron_registry
for each row
execute function app.set_updated_at();

alter table public.system_cron_registry enable row level security;

-- ---------------------------------------------------------------------------
-- 2. register_cron_job / unregister_cron_job：登记契约（内部 RPC，规则 10）
-- ---------------------------------------------------------------------------
create function app.register_cron_job(
  p_job_name    text,
  p_module      text,
  p_cron        text,
  p_tz          text,
  p_owner_route text
)
returns public.system_cron_registry
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job_name text := btrim(coalesce(p_job_name, ''));
  v_module   text := btrim(coalesce(p_module, ''));
  v_cron     text := btrim(coalesce(p_cron, ''));
  v_tz       text := coalesce(nullif(btrim(coalesce(p_tz, '')), ''), 'Asia/Shanghai');
  v_route    text := btrim(coalesce(p_owner_route, ''));
  v_parts    text[];
  v_row      public.system_cron_registry;
begin
  if v_job_name = '' then
    raise exception 'job 名不能为空' using errcode = '22023';
  end if;
  if v_module = '' then
    raise exception '模块标识不能为空' using errcode = '22023';
  end if;
  if v_cron = '' then
    raise exception 'cron 表达式不能为空' using errcode = '22023';
  end if;

  v_parts := regexp_split_to_array(v_cron, '\s+');
  if array_length(v_parts, 1) <> 5 then
    raise exception 'cron 表达式需为五段（分 时 日 月 周）：%', v_cron using errcode = '22023';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_timezone_names t where t.name = v_tz
  ) then
    raise exception '未知时区：%', v_tz using errcode = '22023';
  end if;

  if v_route = '' or v_route !~ '^/' then
    raise exception 'owner_route 需为模块路由（以 / 开头）' using errcode = '22023';
  end if;

  insert into public.system_cron_registry
    (job_name, module, cron_expr, timezone, owner_route, status, registered_by)
  values
    (v_job_name, v_module, v_cron, v_tz, v_route, 'active', (select auth.uid()))
  on conflict (job_name) do update
    set module        = excluded.module,
        cron_expr     = excluded.cron_expr,
        timezone      = excluded.timezone,
        owner_route   = excluded.owner_route,
        -- 重新登记视为恢复有效；注销仅置 disabled
        status        = 'active',
        -- 保留首个登记人（迁移回填为 NULL 时由首次调用者补位）
        registered_by = coalesce(public.system_cron_registry.registered_by, excluded.registered_by)
  returning * into v_row;

  return v_row;
end;
$$;

comment on function app.register_cron_job(text, text, text, text, text) is
  '登记/更新 pg_cron job 元数据（幂等 upsert，重登记恢复 active）；'
  '模块迁移内调用或后端 SECURITY DEFINER wrapper 调用；不 GRANT authenticated（INDEX 规则 10）';

create function app.unregister_cron_job(p_job_name text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job_name text := btrim(coalesce(p_job_name, ''));
  v_row      public.system_cron_registry;
begin
  if v_job_name = '' then
    raise exception 'job 名不能为空' using errcode = '22023';
  end if;

  update public.system_cron_registry
     set status = 'disabled'
   where job_name = v_job_name
  returning * into v_row;

  -- 不存在时幂等返回 false（模块注销流程不因登记缺失而失败）
  return found;
end;
$$;

comment on function app.unregister_cron_job(text) is
  '注销登记（置 disabled，历史保留；不存在幂等返回 false）；不 GRANT API 角色（INDEX 规则 10）';

-- ---------------------------------------------------------------------------
-- 3. 静态 job 回填（迁移内登记；动态 sync-task-* 见文件头 TODO(sync)）
-- ---------------------------------------------------------------------------
select app.register_cron_job(
  'process-export-jobs', 'report', '* * * * *', 'Asia/Shanghai', '/report/exports'
);
select app.register_cron_job(
  'process-webhook-events', 'integration', '* * * * *', 'Asia/Shanghai', '/integration/webhooks'
);
select app.register_cron_job(
  'sync-cleanup-runs', 'sync', '30 3 * * *', 'Asia/Shanghai', '/sync/schedules'
);

-- ---------------------------------------------------------------------------
-- 4. cron 预期周期粗判（视图 overdue 判定用；解析不了返回 NULL）
-- ---------------------------------------------------------------------------
create function app.cron_expected_interval_minutes(p_cron_expr text)
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
    when f[1] ~ '^\d+$' and f[2] ~ '^\d+$' and f[3] = '*' and f[4] = '*' and f[5] = '*' then 1440
    -- 每周（周字段受限）
    when f[1] ~ '^\d+$' and f[2] ~ '^\d+$' and f[3] = '*' and f[4] = '*' and f[5] ~ '^[0-9,\-*/]+$'
      then 10080
    else null
  end
  from parts
$$;

comment on function app.cron_expected_interval_minutes(text) is
  'cron 预期周期粗判（分钟）：* * * * *→1、*/N→N、0 *→1h、daily→24h、weekly→7d；'
  '仅支持五段常见形，解析不了返回 NULL（视图不判超期）；纯解析 helper，'
  'GRANT authenticated（视图内调用），anon/service_role 不授';

-- ---------------------------------------------------------------------------
-- 5. system_cron_jobs_v：登记表 ⨝ cron.job ⨝ cron.job_run_details 聚合（admin 只读）
-- ---------------------------------------------------------------------------
create view public.system_cron_jobs_v as
with runs as (
  select
    d.jobid,
    max(d.start_time) as last_start_at,
    count(*) filter (
      where d.start_time > now() - interval '24 hours'
    ) as runs_24h,
    count(*) filter (
      where d.start_time > now() - interval '24 hours'
        and d.status is distinct from 'succeeded'
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
  coalesce(
    b.registry_id is not null
    and b.registry_status = 'active'
    and b.jobid is not null
    and coalesce(l.start_time, b.registry_last_run_at) is not null
    and now() > coalesce(l.start_time, b.registry_last_run_at)
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
  '失败率=24h 失败数/运行数（0..1）；overdue=最近运行早于 2 倍预期周期；'
  'is_orphan=在 cron.job 但未登记（页面标红）';

-- ---------------------------------------------------------------------------
-- 6. get_cron_run_history：执行历史（admin；跨 cron 系统表）
-- ---------------------------------------------------------------------------
create function app.get_cron_run_history(
  p_job_name text default null,
  p_limit    integer default 50
)
returns table (
  job_name       text,
  runid          bigint,
  job_pid        integer,
  status         text,
  start_time     timestamptz,
  end_time       timestamptz,
  duration_ms    integer,
  return_message text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  return query
  select
    j.jobname,
    d.runid,
    d.job_pid,
    d.status,
    d.start_time,
    d.end_time,
    case
      when d.end_time is not null
        then (extract(epoch from d.end_time - d.start_time) * 1000)::integer
    end as duration_ms,
    d.return_message
  from cron.job_run_details d
  join cron.job j on j.jobid = d.jobid
  where p_job_name is null
     or btrim(p_job_name) = ''
     or j.jobname = btrim(p_job_name)
  order by d.start_time desc nulls last, d.runid desc
  limit v_limit;
end;
$$;

comment on function app.get_cron_run_history(text, integer) is
  'pg_cron 执行历史（admin；job 名可空=全部，limit 收敛 1..200，默认 50）；'
  'SECURITY DEFINER 读 cron 系统表，函数内显式 admin 校验';

-- ---------------------------------------------------------------------------
-- 7. public 薄包装（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.get_cron_run_history(
  p_job_name text default null,
  p_limit    integer default 50
)
returns table (
  job_name       text,
  runid          bigint,
  job_pid        integer,
  status         text,
  start_time     timestamptz,
  end_time       timestamptz,
  duration_ms    integer,
  return_message text
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.get_cron_run_history(p_job_name, p_limit)
$$;

comment on function public.get_cron_run_history(text, integer) is
  'get_cron_run_history Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 8. 授权与 RLS：表/视图 admin 只读；register/unregister 不 GRANT 任何 API 角色
-- ---------------------------------------------------------------------------
revoke all on public.system_cron_registry from public, anon, authenticated, service_role;
grant select on public.system_cron_registry to authenticated;

create policy system_cron_registry_select_admin
on public.system_cron_registry
for select
to authenticated
using ((select app.current_role()) = 'admin');

revoke all on public.system_cron_jobs_v from public, anon, authenticated, service_role;
-- 视图内嵌 admin 角色门禁：仅 admin 请求（JWT）可见行；service_role 无 JWT 语义故不开放
grant select on public.system_cron_jobs_v to authenticated;

revoke all on function app.register_cron_job(text, text, text, text, text)
  from public, anon, authenticated, service_role;
revoke all on function app.unregister_cron_job(text)
  from public, anon, authenticated, service_role;

-- 纯解析 helper（不触表）：视图内调用需 authenticated 执行权（同 app.current_role 先例）
revoke all on function app.cron_expected_interval_minutes(text)
  from public, anon, service_role;
grant execute on function app.cron_expected_interval_minutes(text) to authenticated;

revoke all on function app.get_cron_run_history(text, integer) from public, anon;
grant execute on function app.get_cron_run_history(text, integer) to authenticated;

revoke all on function public.get_cron_run_history(text, integer) from public, anon;
grant execute on function public.get_cron_run_history(text, integer) to authenticated;
