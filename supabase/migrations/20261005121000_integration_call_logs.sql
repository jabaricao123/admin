-- 接口/集成中心 · 调用日志（工单 integration/007：技术排障明细 + 每日聚合）
-- 契约：docs/modules/integration/logs.md：
--   * 明细 integration_call_logs（按月分区）：kind（api/webhook）、key_id/webhook_id、
--     method/event、status_code、duration_ms、request_excerpt/response_excerpt（各截断 2048
--     字符）、error、created_at；明细保留 30 天；
--   * 聚合 integration_call_stats_daily（day/kind/ref/total/failed/avg_duration）长期保留；
--   * 清理与聚合任务在 system pg_cron 登记处注册（INDEX 规则 5）；
--   * 与 audit 分工：本表是排障明细，audit 只有调用量摘要（INDEX 规则 2）。
-- 分区策略：range(created_at) 按月；写入路径经 app.log_integration_call 动态确保当月分区
--   （app.ensure_integration_call_log_partition），迁移预建当月与下月；
--   清理先 drop 整体过期的月分区，再按行删除保留分区中超过 30 天的明细，
--   保证「30 天前明细不可查」的验收口径（最多一天清理延迟）。
-- 组成：
--   1. public.integration_call_logs：调用明细（分区表；admin 只读，写仅经函数）；
--   2. app.ensure_integration_call_log_partition：按月分区确保（幂等）；
--   3. app.log_integration_call：唯一写入入口（含截断与校验；webhook 收口与 API 资源 RPC 调用）；
--   4. public.integration_call_stats_daily：按天聚合（kind + ref 维度）长期保留；
--   5. app.aggregate_integration_call_stats_daily：每日重算（幂等）；
--   6. app.cleanup_integration_call_logs：30 天明细清理（drop + delete）；
--   7. pg_cron：aggregate-integration-call-stats（每日）、cleanup-integration-call-logs（每日）。
-- 依赖：integration/001（api_keys）、integration/004（webhooks）、system/011（register_cron_job）、
--       pg_cron（report/007 已建）。

-- ---------------------------------------------------------------------------
-- 1. integration_call_logs：调用明细（按月分区）
-- ---------------------------------------------------------------------------
create table public.integration_call_logs (
  id               bigint generated always as identity,
  kind             text not null,
  key_id           uuid references public.api_keys (id) on delete set null,
  webhook_id       uuid references public.webhooks (id) on delete set null,
  method_event     text not null,
  status_code      integer,
  duration_ms      integer,
  request_excerpt  text,
  response_excerpt text,
  error            text,
  created_at       timestamptz not null default now(),
  constraint integration_call_logs_pkey primary key (id, created_at),
  constraint integration_call_logs_kind_check
    check (kind in ('api', 'webhook')),
  constraint integration_call_logs_ref_check
    check ((kind = 'api' and webhook_id is null)
        or (kind = 'webhook' and key_id is null)),
  constraint integration_call_logs_method_event_check
    check (btrim(method_event) <> ''),
  constraint integration_call_logs_status_code_check
    check (status_code is null or status_code between 100 and 599),
  constraint integration_call_logs_duration_check
    check (duration_ms is null or duration_ms >= 0),
  constraint integration_call_logs_excerpt_check
    check ((request_excerpt is null or char_length(request_excerpt) <= 2048)
       and (response_excerpt is null or char_length(response_excerpt) <= 2048))
) partition by range (created_at);

comment on table public.integration_call_logs is
  'API/Webhook 技术调用明细（按月分区；排障用，不进 audit 明细）：'
  'kind=api 关联 key_id（method_event=资源 RPC 名），kind=webhook 关联 webhook_id'
  '（method_event=事件名）；excerpt 各截断 2048 字符；仅 admin 可见；明细保留 30 天';
comment on column public.integration_call_logs.key_id is
  'API 密钥 id（kind=api；密钥删除置 NULL 保留追溯）';
comment on column public.integration_call_logs.webhook_id is
  'Webhook 端点 id（kind=webhook；端点删除置 NULL 保留追溯）';
comment on column public.integration_call_logs.method_event is
  'api=资源 RPC 名（如 api_departments）；webhook=事件名（如 approval.approved）';
comment on column public.integration_call_logs.status_code is
  'HTTP/RPC 结果状态码（100..599）；webhook 超时/无响应为 NULL（error 记原因）';
comment on column public.integration_call_logs.duration_ms is '耗时毫秒（未知为 NULL）';
comment on column public.integration_call_logs.request_excerpt is
  '请求摘要（脱敏后的参数/信封，截断 2048 字符）';
comment on column public.integration_call_logs.response_excerpt is
  '响应摘要（截断 2048 字符）';
comment on column public.integration_call_logs.error is '失败原因（成功为 NULL）';

create index integration_call_logs_created_idx
  on public.integration_call_logs (created_at desc, id desc);
create index integration_call_logs_kind_created_idx
  on public.integration_call_logs (kind, created_at desc);
create index integration_call_logs_webhook_idx
  on public.integration_call_logs (webhook_id, created_at desc);
create index integration_call_logs_key_idx
  on public.integration_call_logs (key_id, created_at desc);

alter table public.integration_call_logs enable row level security;

create policy integration_call_logs_select_admin
on public.integration_call_logs
for select
to authenticated
using ((select app.current_role()) = 'admin');

-- ---------------------------------------------------------------------------
-- 2. app.ensure_integration_call_log_partition：按月分区确保（幂等）
--    分区名 integration_call_logs_YYYY_MM；并发安全经 duplicate_table 兜底。
-- ---------------------------------------------------------------------------
create function app.ensure_integration_call_log_partition(p_month date default current_date)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_month date := date_trunc('month', coalesce(p_month, current_date))::date;
  v_name  text := 'integration_call_logs_' || to_char(v_month, 'YYYY_MM');
begin
  if to_regclass(format('public.%I', v_name)) is not null then
    return v_name;
  end if;

  begin
    execute format(
      'create table public.%I partition of public.integration_call_logs for values from (%L) to (%L)',
      v_name, v_month, (v_month + interval '1 month')::date
    );
  exception when duplicate_table then
    null; -- 并发下另一会话已建：幂等
  end;

  return v_name;
end;
$$;

comment on function app.ensure_integration_call_log_partition(date) is
  '确保集成调用日志的月分区存在（integration_call_logs_YYYY_MM，幂等）；'
  '写入路径 log_integration_call 自动调用；不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 3. app.log_integration_call：唯一写入入口（webhook 收口 / API 资源 RPC）
--    截断与校验在此收口；调用方负责脱敏（secret/token 不落 excerpt）。
-- ---------------------------------------------------------------------------
create function app.log_integration_call(
  p_kind             text,
  p_key_id           uuid,
  p_webhook_id       uuid,
  p_method_event     text,
  p_status_code      integer default null,
  p_duration_ms      integer default null,
  p_request_excerpt  text default null,
  p_response_excerpt text default null,
  p_error            text default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind text := lower(btrim(coalesce(p_kind, '')));
  v_id   bigint;
begin
  if v_kind not in ('api', 'webhook') then
    raise exception '调用类型不合法（api/webhook）：%', coalesce(p_kind, '(null)')
      using errcode = '22023';
  end if;

  if p_method_event is null or btrim(p_method_event) = '' then
    raise exception '方法/事件不能为空' using errcode = '22023';
  end if;

  if p_status_code is not null and p_status_code not between 100 and 599 then
    raise exception '状态码不合法（100..599）：%', p_status_code using errcode = '22023';
  end if;

  if p_duration_ms is not null and p_duration_ms < 0 then
    raise exception '耗时不能为负' using errcode = '22023';
  end if;

  -- 分区与 created_at 默认值同取会话时区的当前日期（与分区边界字面量解释一致）
  perform app.ensure_integration_call_log_partition(current_date);

  insert into public.integration_call_logs
    (kind, key_id, webhook_id, method_event, status_code, duration_ms,
     request_excerpt, response_excerpt, error)
  values
    (v_kind,
     case when v_kind = 'api' then p_key_id else null end,
     case when v_kind = 'webhook' then p_webhook_id else null end,
     btrim(p_method_event),
     p_status_code,
     p_duration_ms,
     left(p_request_excerpt, 2048),
     left(p_response_excerpt, 2048),
     p_error)
  returning id into v_id;

  return v_id;
end;
$$;

comment on function app.log_integration_call(text, uuid, uuid, text, integer, integer, text, text, text) is
  '集成调用日志唯一写入入口：校验 kind/状态码/耗时，excerpt 截断 2048 字符，'
  '自动确保当月分区后插入；GRANT anon（api_departments 以调用者身份执行，内部需记录）；'
  'authenticated 不经此入口（webhook 收口为 pg_cron 的 postgres 直接调用）';

-- ---------------------------------------------------------------------------
-- 4. integration_call_stats_daily：按天聚合（长期保留）
--    ref_id 为 key_id（api）或 webhook_id（webhook）；无引用时归零 UUID；
--    ref_name 为聚合时点名称快照（密钥/端点删除后仍可读）。
-- ---------------------------------------------------------------------------
create table public.integration_call_stats_daily (
  day             date not null,
  kind            text not null,
  ref_id          uuid not null default '00000000-0000-0000-0000-000000000000'::uuid,
  ref_name        text,
  total           bigint not null default 0,
  failed          bigint not null default 0,
  avg_duration_ms numeric(12, 1),
  updated_at      timestamptz not null default now(),
  constraint integration_call_stats_daily_pkey primary key (day, kind, ref_id),
  constraint integration_call_stats_daily_kind_check check (kind in ('api', 'webhook')),
  constraint integration_call_stats_daily_total_check check (total >= 0),
  constraint integration_call_stats_daily_failed_check
    check (failed >= 0 and failed <= total),
  constraint integration_call_stats_daily_duration_check
    check (avg_duration_ms is null or avg_duration_ms >= 0)
);

comment on table public.integration_call_stats_daily is
  '集成调用按天聚合（长期保留，30 天明细清理后仍可看趋势）：'
  'failed = 状态码 ≥400 或无响应（status_code is null）；'
  'avg_duration_ms = 有耗时样本的均值（无样本为 NULL）';
comment on column public.integration_call_stats_daily.ref_id is
  'api=key_id / webhook=webhook_id；均无引用时为全零 UUID（未知引用）';
comment on column public.integration_call_stats_daily.ref_name is
  '聚合时点名称快照（api_keys.name / webhooks.name；未解析为 NULL）';

create index integration_call_stats_daily_kind_day_idx
  on public.integration_call_stats_daily (kind, day desc);

alter table public.integration_call_stats_daily enable row level security;

create policy integration_call_stats_daily_select_admin
on public.integration_call_stats_daily
for select
to authenticated
using ((select app.current_role()) = 'admin');

-- ---------------------------------------------------------------------------
-- 5. app.aggregate_integration_call_stats_daily：按天重算（幂等）
-- ---------------------------------------------------------------------------
create function app.aggregate_integration_call_stats_daily(p_day date default current_date)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  c_zero constant uuid := '00000000-0000-0000-0000-000000000000'::uuid;
  v_day  date := coalesce(p_day, current_date);
  v_rows integer;
begin
  delete from public.integration_call_stats_daily
   where day = v_day;

  insert into public.integration_call_stats_daily
    (day, kind, ref_id, ref_name, total, failed, avg_duration_ms)
  select
    v_day,
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
  where l.created_at >= v_day
    and l.created_at < v_day + 1
  group by 1, 2, 3, 4;

  get diagnostics v_rows = row_count;
  return v_rows;
end;
$$;

comment on function app.aggregate_integration_call_stats_daily(date) is
  '重算指定日期（默认当天）的调用聚合：先删当天旧行再按 kind+ref 聚合插入；'
  'failed=状态码≥400 或无响应；幂等；security invoker + 撤销 API 角色执行权，仅 pg_cron 可达';

-- ---------------------------------------------------------------------------
-- 6. app.cleanup_integration_call_logs：30 天明细清理（drop 过期分区 + 行级删除）
-- ---------------------------------------------------------------------------
create function app.cleanup_integration_call_logs(p_retention_days integer default 30)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_days    integer := greatest(coalesce(p_retention_days, 30), 1);
  v_cutoff  timestamptz := now() - make_interval(days => v_days);
  v_part    record;
  v_deleted integer;
begin
  -- 1) 整月分区已整体过期 → drop（比重行删高效）；分区名后缀 YYYY_MM 由 ensure 保证
  for v_part in
    select c.relname
    from pg_catalog.pg_class c
    join pg_catalog.pg_inherits i on i.inhrelid = c.oid
    where i.inhparent = 'public.integration_call_logs'::regclass
      and c.relname ~ '^integration_call_logs_[0-9]{4}_[0-9]{2}$'
  loop
    if to_date(substring(v_part.relname from '([0-9]{4}_[0-9]{2})$'), 'YYYY_MM')
         + interval '1 month' <= v_cutoff then
      execute format('drop table public.%I', v_part.relname);
    end if;
  end loop;

  -- 2) 保留分区内按行清理（保证 30 天前明细不可查；最多一天清理延迟）
  delete from public.integration_call_logs
   where created_at < v_cutoff;

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

comment on function app.cleanup_integration_call_logs(integer) is
  '集成调用明细 30 天清理：先 drop 整体过期的月分区，再删除保留分区中超过保留期的行；'
  '返回删除行数（不含 drop 分区内行）；security invoker + 撤销 API 角色执行权，仅 pg_cron 可达';

-- ---------------------------------------------------------------------------
-- 7. 授权：明细/聚合 admin 只读；写与维护函数不 GRANT（log 入口给 anon 供资源 RPC 记录）
-- ---------------------------------------------------------------------------
revoke all on public.integration_call_logs from public, anon, authenticated, service_role;
grant select on public.integration_call_logs to authenticated, service_role;

revoke all on public.integration_call_stats_daily from public, anon, authenticated, service_role;
grant select on public.integration_call_stats_daily to authenticated, service_role;

-- identity 序列不暴露给 API 角色（写入仅经函数）
revoke all on sequence public.integration_call_logs_id_seq
  from public, anon, authenticated, service_role;

revoke all on function app.ensure_integration_call_log_partition(date)
  from public, anon, authenticated, service_role;

revoke all on function app.log_integration_call(text, uuid, uuid, text, integer, integer, text, text, text)
  from public, authenticated, service_role;
-- anon：api_departments 以调用者身份执行（SECURITY INVOKER），token 校验通过后需记录调用
grant execute on function app.log_integration_call(text, uuid, uuid, text, integer, integer, text, text, text)
  to anon;

revoke all on function app.aggregate_integration_call_stats_daily(date)
  from public, anon, authenticated, service_role;

revoke all on function app.cleanup_integration_call_logs(integer)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8. 预建分区 + pg_cron（聚合约 00:10、清理约 03:20 UTC；同步登记 system 登记处）
-- ---------------------------------------------------------------------------
select app.ensure_integration_call_log_partition(current_date);
select app.ensure_integration_call_log_partition(
  (date_trunc('month', current_date) + interval '1 month')::date
);

select cron.schedule(
  'aggregate-integration-call-stats',
  '10 0 * * *',
  $cron$select app.aggregate_integration_call_stats_daily(current_date - 1)$cron$
);

select cron.schedule(
  'cleanup-integration-call-logs',
  '20 3 * * *',
  $cron$select app.cleanup_integration_call_logs()$cron$
);

select app.register_cron_job(
  'aggregate-integration-call-stats', 'integration', '10 0 * * *', 'Asia/Shanghai', '/integration/logs'
);
select app.register_cron_job(
  'cleanup-integration-call-logs', 'integration', '20 3 * * *', 'Asia/Shanghai', '/integration/logs'
);
