-- 接口/集成中心 · Webhook 投递级重试（integration 批次 4：事件级重试改投递级）
-- 契约：docs/modules/integration/webhooks.md（每端点独立 retry_policy；成功端点不重复投递）。
-- 问题：旧状态机按「事件最新一轮」判定——任一端点失败即整条事件退回 pending，重派时
--   对所有 active 订阅端点重建投递行，已 success 的端点被重复投递。
-- 修复：
--   * finalize：按端点汇总（has_done / failed_count / 自身 max_attempts）——
--     仍有未 done 且未耗尽的端点 → pending（退避取可重试端点的最小间隔）；
--     全部无 done 的端点都已耗尽 → failed（audit + 仅通知耗尽端点创建人）；
--     其余（全部端点 done / 失败端点已停用且无其他可重试） → done；
--   * process 派发：首轮投全部 active 匹配端点；重试轮只投「无 done 终态、已失败且未耗尽」的端点。
-- 防御合并（batch1 = 20261007091000）：max_attempts 安全解析（regex 预检 + 1..10 兜底 3）
--   与逐事件 exception 隔离在本迁移内联保留（v_done := v_attempt + 1 使毒数据在溢出处
--   触发隔离）；finalize/process 不再直接 ::integer 解析存量脏值。
--   integration_events.attempts 仍为事件级派发轮次（终态投递 attempt_no 对齐该值）。
-- 依赖：20261004235500（worker）、20261005122000（finalize + call_logs 写入）、
--       20261007091000（SSRF/重试防御）。

-- ---------------------------------------------------------------------------
-- 1. app.finalize_webhook_deliveries：收口 + 投递级重试状态机
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
  v_done     integer;
  v_retryable integer;
  v_exhausted integer;
  v_interval interval;
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

  -- 2) 事件状态机（投递级）：最新一轮无进行中投递的事件按端点汇总判定；
  --    逐事件包 exception：单条毒事件（如异常重试配置/毒数据）只把自己置 failed，
  --    不回滚整个收口事务，保证其他事件继续收口（防全管线停滞）。
  for v_event in
    select e.id, e.event, e.attempts
    from public.integration_events e
    where e.status = 'delivering'
      and not exists (
        select 1
        from public.webhook_deliveries d
        where d.event_id = e.id
          and d.status = 'delivering'
      )
    order by e.id
    for update skip locked
  loop
    begin
      -- 新派发轮次号；毒数据（attempt_no=integer 上限）在此溢出 → exception 隔离
      select max(d.attempt_no) into v_attempt
      from public.webhook_deliveries d
      where d.event_id = v_event.id;

      v_done := v_attempt + 1;

      -- 端点级汇总：has_done=已有成功终态（永不重投）；failed_count=失败次数；
      -- max_attempts 内联安全解析（regex 预检 + 1..10 兜底 3，与批次 1 语义一致）；
      -- backoff 取端点自身策略；停用端点不再重试。
      select
        count(*) filter (where not x.has_done and x.failed_count >= x.max_attempts)::integer,
        count(*) filter (where not x.has_done and x.failed_count < x.max_attempts
                           and x.is_active)::integer,
        min(case when not x.has_done and x.failed_count < x.max_attempts and x.is_active
                 then app.next_retry(x.failed_count::integer, x.backoff) end)
      into v_exhausted, v_retryable, v_interval
      from (
        select
          d.webhook_id,
          bool_or(d.status = 'done') as has_done,
          count(*) filter (where d.status = 'failed') as failed_count,
          case
            when coalesce(w.retry_policy ->> 'max_attempts', '') ~ '^\d+$'
            then case
                   when (w.retry_policy ->> 'max_attempts')::numeric between 1 and 10
                   then (w.retry_policy ->> 'max_attempts')::integer
                   else 3
                 end
            else 3
          end as max_attempts,
          coalesce(w.retry_policy ->> 'backoff', 'exponential') as backoff,
          coalesce(w.status = 'active', false) as is_active
        from public.webhook_deliveries d
        left join public.webhooks w on w.id = d.webhook_id
        where d.event_id = v_event.id
        group by d.webhook_id, w.retry_policy, w.status
      ) x;

      if v_retryable > 0 then
        -- 仍有未 done 且未耗尽的端点：事件退回 pending，按可重试端点最小退避重派
        update public.integration_events
           set status        = 'pending',
               attempts      = v_done,
               next_retry_at = now() + coalesce(v_interval, interval '1 minute')
         where id = v_event.id;
      elsif v_exhausted > 0 then
        -- 所有未 done 端点均已耗尽：事件终态 failed（audit + 仅通知耗尽端点创建人）
        update public.integration_events
           set status   = 'failed',
               attempts = v_done
         where id = v_event.id;

        perform app.audit_log(
          'integration', 'fail', 'webhook_event', v_event.id::text,
          jsonb_build_object(
            'event', v_event.event,
            'attempts', v_done,
            'endpoints_failed', v_exhausted
          )
        );

        for v_hook in
          with ep as (
            select
              d.webhook_id,
              bool_or(d.status = 'done') as has_done,
              count(*) filter (where d.status = 'failed') as failed_count,
              min(d.error) filter (where d.status = 'failed') as last_error
            from public.webhook_deliveries d
            where d.event_id = v_event.id
            group by d.webhook_id
          )
          select w.id, w.name, w.created_by, ep.failed_count, ep.last_error
          from ep
          join public.webhooks w on w.id = ep.webhook_id
          where not ep.has_done
            and ep.failed_count >= case
              when coalesce(w.retry_policy ->> 'max_attempts', '') ~ '^\d+$'
              then case
                     when (w.retry_policy ->> 'max_attempts')::numeric between 1 and 10
                     then (w.retry_policy ->> 'max_attempts')::integer
                     else 3
                   end
              else 3
            end
          order by w.id
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
                  v_hook.name, v_event.event, v_hook.failed_count,
                  coalesce(v_hook.last_error, '未知错误')
                ),
                'ref_type', 'webhook',
                'ref_id', v_hook.id::text,
                'source_module', 'integration'
              )
            );
          end if;
        end loop;
      else
        -- 全部端点 done（或仅剩已停用端点，不再投递）：事件终结
        update public.integration_events
           set status = 'done'
         where id = v_event.id;
      end if;

      v_count := v_count + 1;
    exception when others then
      -- 单事件故障隔离：标记该事件 failed 后继续处理后续事件（不回滚整个事务）
      begin
        update public.integration_events
           set status = 'failed'
         where id = v_event.id;
      exception when others then
        null; -- 连失败标记都失败时静默跳过，避免全管线停滞
      end;

      v_count := v_count + 1;
    end;
  end loop;

  return v_count;
end;
$$;

comment on function app.finalize_webhook_deliveries() is
  '投递收口：按 net._http_response 将 delivering 明细置 done（2xx）/failed（非 2xx/错误/超时>10min）；'
  '事件状态机为投递级重试：端点已有 done 终态即不再重投——仍有未 done 且未耗尽端点则 pending 退避，'
  '未 done 端点全部耗尽则 failed（audit + 仅通知耗尽端点创建人），其余 done；返回收口事件数。'
  '每条终态投递追加 integration_call_logs（kind=webhook，含响应摘要/耗时/错误）。'
  'max_attempts 安全解析（脏值兜底 3，不抛错）；逐事件 exception 隔离（毒事件置 failed 继续）。'
  'security invoker + 仅函数属主/pg_cron 可达（撤销 API 角色执行权），禁 service_role（ADR-001）';

-- ---------------------------------------------------------------------------
-- 2. app.process_webhook_events：派发阶段只重试未 done 且未耗尽的端点
-- ---------------------------------------------------------------------------
create or replace function app.process_webhook_events()
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  c_batch    constant integer := 5;
  v_event    record;
  v_webhook  record;
  v_body     jsonb;
  v_headers  jsonb;
  v_request  bigint;
  v_matched  integer;
  v_processed integer := 0;
begin
  -- 阶段 1：先收口已到响应/超时的投递，推进事件重试状态机
  perform app.finalize_webhook_deliveries();

  -- 阶段 2：派发到期的 pending 事件（每轮最多 5 条；skip locked 防多实例重复消费）
  for v_event in
    select e.id, e.event, e.payload, e.attempts, e.created_at
    from public.integration_events e
    where e.status = 'pending'
      and e.next_retry_at <= now()
    order by e.next_retry_at, e.id
    for update skip locked
    limit c_batch
  loop
    v_matched := 0;

    -- 投递级重试：首轮（attempts=0）投全部 active 匹配端点；
    -- 重试轮只投「无 done 终态、已失败且未耗尽自身 max_attempts」的端点（success 端点不重复投递）。
    for v_webhook in
      select w.id, w.url, w.secret_enc, w.headers_enc
      from public.webhooks w
      where w.status = 'active'
        and v_event.event = any(w.events)
        and not exists (
          select 1
          from public.webhook_deliveries d
          where d.event_id = v_event.id
            and d.webhook_id = w.id
            and d.status = 'done'
        )
        and (
          v_event.attempts = 0
          or exists (
            select 1
            from public.webhook_deliveries d
            where d.event_id = v_event.id
              and d.webhook_id = w.id
              and d.status = 'failed'
          )
        )
        and (
          select count(*)
          from public.webhook_deliveries d
          where d.event_id = v_event.id
            and d.webhook_id = w.id
            and d.status = 'failed'
        ) < case
              when coalesce(w.retry_policy ->> 'max_attempts', '') ~ '^\d+$'
              then case
                     when (w.retry_policy ->> 'max_attempts')::numeric between 1 and 10
                     then (w.retry_policy ->> 'max_attempts')::integer
                     else 3
                   end
              else 3
            end
      order by w.id
    loop
      -- 事件信封：id/event/created_at/data；签名与发送字节一致（jsonb 规范化文本）
      v_body := jsonb_build_object(
        'id', v_event.id,
        'event', v_event.event,
        'created_at', v_event.created_at,
        'data', v_event.payload
      );

      v_headers := app.webhook_request_headers(
        app.decrypt_secret(v_webhook.secret_enc),
        v_body,
        v_event.event,
        v_webhook.headers_enc
      );

      v_request := net.http_post(
        url := v_webhook.url,
        body := v_body,
        headers := v_headers,
        timeout_milliseconds := 10000
      );

      insert into public.webhook_deliveries
        (event_id, webhook_id, attempt_no, request_id, status, attempted_at)
      values
        (v_event.id, v_webhook.id, v_event.attempts, v_request, 'delivering', now());

      v_matched := v_matched + 1;
    end loop;

    if v_matched = 0 then
      -- 无待投端点（无 active 订阅，或失败端点均已 done/耗尽/停用）：事件终结，避免永久 pending
      update public.integration_events
         set status = 'done'
       where id = v_event.id;
    else
      update public.integration_events
         set status = 'delivering'
       where id = v_event.id;
    end if;

    v_processed := v_processed + 1;
  end loop;

  return v_processed;
end;
$$;

comment on function app.process_webhook_events() is
  'Webhook 投递器（pg_cron 每分钟）：先收口上一轮响应/超时（finalize），再派发 pending 到期事件'
  '（skip locked 限 5 条/轮）：首轮匹配全部 active 订阅，重试轮仅未 done 且未耗尽的端点'
  '（success 端点不重复投递；max_attempts 安全解析，脏值兜底 3）→ 逐端点 pg_net.http_post'
  '（签名头）→ 写 webhook_deliveries（delivering，attempt_no=事件 attempts）→ 事件 delivering；'
  '无待投端点直接 done；返回本轮派发事件数。security invoker + 撤销 API 角色执行权'
  '（仅 pg_cron 的 postgres 可达），禁 service_role';
