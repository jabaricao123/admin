-- 接口/集成中心 · API key 近 30 天用量统计 RPC（integration 批次 4）
-- 契约：docs/modules/integration/api-keys.md（列表：近 30 天调用量，来自调用日志聚合）。
-- 数据源与口径：
--   * integration_call_logs（明细保留 30 天；当日未聚合也可读）为第一优先；
--   * integration_call_stats_daily（长期聚合）补齐明细已清理的日期；
--   * 天级去重（同一天明细优先）；failed = 状态码 ≥400 或无响应（null）；
--   * avg_duration_ms 为按天 total 加权的均值。
-- 权限：admin 校验在实现内；public 薄包装 GRANT authenticated（页面接入属批次 3）。
-- 依赖：20261005121000（integration_call_logs / stats_daily）、app.current_role。

create function app.get_api_key_usage(p_key_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_key    public.api_keys;
  v_days   jsonb;
  v_total  bigint;
  v_failed bigint;
  v_avg    numeric;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_key_id is null then
    raise exception '密钥 ID 不能为空' using errcode = '22023';
  end if;

  select * into v_key
  from public.api_keys
  where id = p_key_id;

  if not found then
    raise exception '密钥不存在：%', p_key_id using errcode = 'P0002';
  end if;

  with daily as (
    select
      l.created_at::date as day,
      count(*) as total,
      count(*) filter (where l.status_code is null or l.status_code >= 400) as failed,
      round(avg(l.duration_ms) filter (where l.duration_ms is not null), 1) as avg_duration_ms,
      1 as src
    from public.integration_call_logs l
    where l.kind = 'api'
      and l.key_id = p_key_id
      and l.created_at >= current_date - interval '29 days'
    group by 1
    union all
    select s.day, s.total, s.failed, s.avg_duration_ms, 2
    from public.integration_call_stats_daily s
    where s.kind = 'api'
      and s.ref_id = p_key_id
      and s.day >= current_date - 29
  ),
  dedup as (
    select distinct on (day) day, total, failed, avg_duration_ms
    from daily
    order by day, src
  )
  select
    coalesce(
      jsonb_agg(jsonb_build_object(
        'day', day,
        'total', total,
        'failed', failed,
        'avg_duration_ms', avg_duration_ms
      ) order by day),
      '[]'::jsonb
    ),
    coalesce(sum(total), 0),
    coalesce(sum(failed), 0),
    case
      when sum(total) filter (where avg_duration_ms is not null) > 0 then
        round(
          sum(avg_duration_ms * total) filter (where avg_duration_ms is not null)
            / sum(total) filter (where avg_duration_ms is not null),
          1
        )
      else null
    end
  into v_days, v_total, v_failed, v_avg
  from dedup;

  return jsonb_build_object(
    'key_id', v_key.id,
    'name', v_key.name,
    'key_prefix', v_key.key_prefix,
    'status', v_key.status,
    'since', current_date - 29,
    'days', v_days,
    'total', v_total,
    'failed', v_failed,
    'success', v_total - v_failed,
    'avg_duration_ms', v_avg
  );
end;
$$;

comment on function app.get_api_key_usage(uuid) is
  'API key 近 30 天用量（admin）：按天聚合 integration_call_logs（明细优先）+ '
  'integration_call_stats_daily（长期补齐）；返回 {key_id,name,key_prefix,status,since,days,'
  'total,failed,success,avg_duration_ms}；密钥不存在抛 P0002';

create function public.get_api_key_usage(p_key_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.get_api_key_usage(p_key_id)
$$;

comment on function public.get_api_key_usage(uuid) is
  'get_api_key_usage Data API 薄包装（admin 校验在 app 实现内）';

revoke all on function app.get_api_key_usage(uuid)
  from public, anon, authenticated, service_role;

revoke all on function public.get_api_key_usage(uuid)
  from public, anon, service_role;
grant execute on function public.get_api_key_usage(uuid) to authenticated;
