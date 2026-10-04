-- 接口/集成中心 · 调用日志写入点改造（工单 integration/007 配套）
-- 契约：docs/modules/integration/logs.md（写入：API 调用与 webhook 投递异步写日志，不阻塞主流程）、
--       docs/modules/INDEX.md 规则 2（技术明细归 integration，摘要进 audit）。
-- 本迁移只 create or replace 两个既有函数，加入 app.log_integration_call 调用：
--   1. app.finalize_webhook_deliveries（integration/005）：投递收口为终态时追加
--      kind='webhook' 调用日志（status/duration/error/响应内容；请求摘要由事件信封重建）；
--   2. app.api_departments（integration/002）：token+scope 守卫通过后记录 kind='api'
--      调用日志（status=200/耗时/请求scope/响应摘要），日志失败不影响资源返回路径。
-- 说明：失败调用（守卫拒绝）在异常事务中回滚，无法同事务留痕；网关/中间件层留痕留 v2。
-- 依赖：integration/007 迁移（app.log_integration_call 已建）。

-- ---------------------------------------------------------------------------
-- 1. app.finalize_webhook_deliveries：原状态机不变，终态追加 call_logs
-- ---------------------------------------------------------------------------
create or replace function app.finalize_webhook_deliveries()
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  c_stale    constant interval := interval '10 minutes';
  v_delivery record;
  v_event    record;
  v_hook     record;
  v_attempt  integer;
  v_max      integer;
  v_backoff  text;
  v_done     integer;
  v_count    integer := 0;
  -- 调用日志收口变量（每次投递终态后写一行）
  v_logged      boolean;
  v_log_status  integer;
  v_log_duration integer;
  v_log_error   text;
begin
  -- 1) 投递明细收口：pg_net 响应 → done/failed；长期无响应 → 超时失败
  for v_delivery in
    select d.id, d.event_id, d.webhook_id, d.attempt_no, d.attempted_at,
           e.event,
           e.payload,
           r.status_code, r.error_msg, r.timed_out, r.created, r.content
    from public.webhook_deliveries d
    join public.integration_events e on e.id = d.event_id
    left join net._http_response r on r.id = d.request_id
    where d.status = 'delivering'
    order by d.id
    for update of d skip locked
  loop
    v_logged := false;
    v_log_status := null;
    v_log_duration := null;
    v_log_error := null;

    if v_delivery.created is not null then
      if v_delivery.status_code between 200 and 299 then
        update public.webhook_deliveries
           set status      = 'done',
               http_status = v_delivery.status_code,
               duration_ms = greatest(
                 0,
                 floor(extract(epoch from (v_delivery.created - v_delivery.attempted_at)) * 1000)::integer
               ),
               error       = null,
               finished_at = v_delivery.created
         where id = v_delivery.id;

        v_log_status := v_delivery.status_code;
        v_log_duration := greatest(
          0,
          floor(extract(epoch from (v_delivery.created - v_delivery.attempted_at)) * 1000)::integer
        );
        v_logged := true;
      else
        update public.webhook_deliveries
           set status      = 'failed',
               http_status = v_delivery.status_code,
               duration_ms = greatest(
                 0,
                 floor(extract(epoch from (v_delivery.created - v_delivery.attempted_at)) * 1000)::integer
               ),
               error       = coalesce(
                 v_delivery.error_msg,
                 case
                   when v_delivery.timed_out then '请求超时（pg_net）'
                   when v_delivery.status_code is not null then 'HTTP ' || v_delivery.status_code
                   else '投递失败（pg_net 无错误详情）'
                 end
               ),
               finished_at = v_delivery.created
         where id = v_delivery.id;

        v_log_status := v_delivery.status_code;
        v_log_duration := greatest(
          0,
          floor(extract(epoch from (v_delivery.created - v_delivery.attempted_at)) * 1000)::integer
        );
        v_log_error := coalesce(
          v_delivery.error_msg,
          case
            when v_delivery.timed_out then '请求超时（pg_net）'
            when v_delivery.status_code is not null then 'HTTP ' || v_delivery.status_code
            else '投递失败（pg_net 无错误详情）'
          end
        );
        v_logged := true;
      end if;
    elsif v_delivery.attempted_at <= now() - c_stale then
      update public.webhook_deliveries
         set status      = 'failed',
             error       = '投递超时（pg_net 10 分钟内无响应）',
             finished_at = now()
       where id = v_delivery.id;

      v_log_error := '投递超时（pg_net 10 分钟内无响应）';
      v_logged := true;
    end if;

    -- 终态投递追加技术调用日志（kind='webhook'；排障明细，不影响状态机）
    if v_logged then
      perform app.log_integration_call(
        'webhook',
        null,
        v_delivery.webhook_id,
        v_delivery.event,
        v_log_status,
        v_log_duration,
        jsonb_build_object(
          'event', v_delivery.event,
          'data', v_delivery.payload
        )::text,
        v_delivery.content,
        v_log_error
      );
    end if;
  end loop;

  -- 2) 事件状态机：最新一轮投递全部终态 → done / 退避重试 / 终态 failed
  for v_event in
    select e.id, e.event
    from public.integration_events e
    where e.status = 'delivering'
      and not exists (
        select 1
        from public.webhook_deliveries d
        where d.event_id = e.id
          and d.attempt_no = (
            select max(d2.attempt_no)
            from public.webhook_deliveries d2
            where d2.event_id = e.id
          )
          and d.status = 'delivering'
      )
    order by e.id
    for update skip locked
  loop
    select max(d.attempt_no) into v_attempt
    from public.webhook_deliveries d
    where d.event_id = v_event.id;

    if not exists (
      select 1
      from public.webhook_deliveries d
      where d.event_id = v_event.id
        and d.attempt_no = v_attempt
        and d.status = 'failed'
    ) then
      update public.integration_events
         set status = 'done'
       where id = v_event.id;
    else
      -- 本轮失败端点的策略：max_attempts 取最大（任一端点未耗尽即重试整条事件）；
      -- backoff 全为 linear 才走线性，否则指数（默认）
      select
        max(greatest(coalesce(nullif(w.retry_policy ->> 'max_attempts', '')::integer, 3), 1)),
        case
          when bool_and(coalesce(w.retry_policy ->> 'backoff', 'exponential') = 'linear')
          then 'linear'
          else 'exponential'
        end
        into v_max, v_backoff
      from public.webhook_deliveries d
      join public.webhooks w on w.id = d.webhook_id
      where d.event_id = v_event.id
        and d.attempt_no = v_attempt
        and d.status = 'failed';

      v_done := v_attempt + 1;

      if v_done >= v_max then
        -- 终态失败：先置 failed，再写审计摘要并通知各失败端点创建人
        update public.integration_events
           set status   = 'failed',
               attempts = v_done
         where id = v_event.id;

        perform app.audit_log(
          'integration', 'fail', 'webhook_event', v_event.id::text,
          jsonb_build_object(
            'event', v_event.event,
            'attempts', v_done,
            'max_attempts', v_max,
            'endpoints_failed', (
              select count(*)
              from public.webhook_deliveries d
              where d.event_id = v_event.id
                and d.attempt_no = v_attempt
                and d.status = 'failed'
            )
          )
        );

        for v_hook in
          select w.id, w.name, w.created_by, min(d.error) as error
          from public.webhook_deliveries d
          join public.webhooks w on w.id = d.webhook_id
          where d.event_id = v_event.id
            and d.attempt_no = v_attempt
            and d.status = 'failed'
          group by w.id, w.name, w.created_by
        loop
          if v_hook.created_by is not null
             and exists (select 1 from public.profiles p where p.id = v_hook.created_by) then
            perform app.send_notification(
              v_hook.created_by,
              'webhook.delivery_failed',
              jsonb_build_object(
                'title', 'Webhook 投递失败',
                'body', format(
                  '端点「%s」投递事件 %s 失败 %s 次：%s',
                  v_hook.name, v_event.event, v_done, coalesce(v_hook.error, '未知错误')
                ),
                'ref_type', 'webhook',
                'ref_id', v_hook.id::text,
                'source_module', 'integration'
              )
            );
          end if;
        end loop;
      else
        update public.integration_events
           set status        = 'pending',
               attempts      = v_done,
               next_retry_at = now() + app.next_retry(v_done, v_backoff)
         where id = v_event.id;
      end if;
    end if;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

comment on function app.finalize_webhook_deliveries() is
  '投递收口：按 net._http_response 将 delivering 明细置 done（2xx）/failed（非 2xx/错误/超时>10min）；'
  '事件最新一轮全部终态后 done/退避重试/终态 failed（audit + 通知失败端点创建人）；返回收口事件数。'
  'integration/007 起：每条终态投递追加 integration_call_logs（kind=webhook，含响应摘要/耗时/错误）。'
  'security invoker + 仅函数属主/pg_cron 可达（撤销 API 角色执行权），禁 service_role（ADR-001）';

-- ---------------------------------------------------------------------------
-- 2. app.api_departments：守卫不变，成功路径记录 kind='api' 调用日志
-- ---------------------------------------------------------------------------
create or replace function app.api_departments(p_token text)
returns setof public.departments_v
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_claims    jsonb;
  v_prev_role text := pg_catalog.current_setting('role');
  v_key_id    uuid;
  v_started   timestamptz := clock_timestamp();
  v_rows      jsonb;
  v_duration  integer;
begin
  -- 守卫：验 token（无效直接 401 语义）
  v_claims := app.verify_api_token(p_token);

  if v_claims is null then
    raise exception 'API token 无效或已过期' using errcode = '42501';
  end if;

  -- 范围守卫：本资源要求 org:read（scopes 为签发时 API key 上声明的白名单）
  if not coalesce((v_claims -> 'scopes') ? 'org:read', false) then
    raise exception 'API token 缺少所需范围：org:read' using errcode = '42501';
  end if;

  v_key_id := nullif(v_claims ->> 'key_id', '')::uuid;

  begin
    -- 资源查询身份：api_client_role（不绕过 RLS；无写策略=拒绝）
    set local role api_client_role;

    -- 结果聚合为 jsonb：既用于返回，也作为调用日志的响应摘要
    select jsonb_agg(to_jsonb(dv) order by dv.depth, dv.sort_order, dv.name)
      into v_rows
    from public.departments_v dv;

    -- 查询完成：还原入口身份，避免影响同一事务中的后续语句
    if v_prev_role is null or v_prev_role = 'none' then
      reset role;
    else
      execute format('set local role %I', v_prev_role);
    end if;
  exception when others then
    if v_prev_role is null or v_prev_role = 'none' then
      reset role;
    else
      execute format('set local role %I', v_prev_role);
    end if;
    raise;
  end;

  v_duration := greatest(
    0,
    floor(extract(epoch from (clock_timestamp() - v_started)) * 1000)::integer
  );

  -- 调用日志（kind='api'）：状态码语义 200；响应摘要截断由 log 函数收口
  perform app.log_integration_call(
    'api',
    v_key_id,
    null,
    'api_departments',
    200,
    v_duration,
    jsonb_build_object('scope', 'org:read')::text,
    coalesce(v_rows, '[]'::jsonb)::text,
    null
  );

  return query
  select *
  from jsonb_populate_recordset(null::public.departments_v, coalesce(v_rows, '[]'::jsonb));
end;
$$;

comment on function app.api_departments(text) is
  '开放 API 资源 RPC 模板（演示端到端闭环）：验 token + scopes 含 org:read → '
  'set local role api_client_role → 返回 departments_v（RLS 按该角色策略过滤）；'
  'integration/007 起：成功调用追加 integration_call_logs（kind=api，method_event=api_departments，'
  '响应摘要截断存储）；失败调用在异常事务内回滚无法留痕（网关层留痕留 v2）。'
  'SECURITY INVOKER（PG17 禁 definer 内 SET ROLE），查询前无业务数据访问；'
  '后续资源 RPC 按此模板扩展（scopes 按模块只读/读写拆分）';
