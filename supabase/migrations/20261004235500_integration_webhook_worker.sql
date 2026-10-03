-- 接口/集成中心 · Webhook 投递器（工单 integration/005）
-- 契约：docs/modules/integration/webhooks.md（每端点独立 secret 解密后 HMAC-SHA256 签名、
--       重试策略 max_attempts/backoff、测试投递 ping、投递明细）、
--       docs/adr/001-job-runner.md（pg_cron 轮询队列表 → pg_net 出站 POST → 写执行记录；
--       禁 service_role）、docs/modules/INDEX.md 规则 2（终态失败审计摘要）、
--       规则 3（send_notification 通知）、规则 5（pg_cron 登记，system/011 登记表上线前直连
--       cron.schedule）。
--
-- 运行时：pg_net 异步 HTTP——net.http_post 只入队，由 pg_net 后台 worker 实际出站，响应落在
-- net._http_response（request_id 关联）。因此投递分两相（同一次 pg_cron 轮询内完成）：
--   * 收口（app.finalize_webhook_deliveries）：有响应 → 2xx 记 done，其余记 failed；
--     >10 分钟无响应记 failed（投递超时，防队列永久占用）；事件最新一轮投递全部终态后：
--     全 done → 事件 done；否则按失败端点 retry_policy 退避（attempts+1；指数 2^n 分钟，
--     n=已尝试次数，上限 60）或达 max_attempts 终态 failed（audit + send_notification
--     给失败端点创建人，事件 key 'webhook.delivery_failed'）。
--   * 派发（app.process_webhook_events）：pending 且 next_retry_at<=now() 的事件（skip locked
--     限 5）匹配 active 端点（event = any(events)）→ 逐端点 http_post（body 信封 +
--     x-webhook-signature + x-webhook-event）→ 写 webhook_deliveries（delivering + request_id）
--     → 事件 delivering；无订阅端点的事件直接 done（避免永久 pending）。
--
-- 测试投递（app.test_webhook + app.webhook_test_result）：pg_net 的入队行对后台 worker 仅在
-- 事务提交后可见，函数内同步等待必然拿不到自己的响应（教训：实测 6s 后仍 pending）。因此测试
-- 投递落地为两段式：test_webhook 直发 ping（不经 integration_events 队列）并立即返回
-- request_id；结果经 webhook_test_result(request_id) 查询（同一事务内可读注入/已到的响应）。
--
-- HMAC 验证（接收端说明）：签名 = hex(HMAC-SHA256(secret, raw_body)，与发送字节一致——
-- body 为 jsonb 规范化文本）；请求头 x-webhook-signature、事件名 x-webhook-event。
-- Node 示例：crypto.createHmac('sha256', secret).update(rawBody).digest('hex')；
-- Python：hmac.new(secret.encode(), raw_body, hashlib.sha256).hexdigest()（比较需防时序攻击）。
--
-- 本地限制：真实出站无法 pgTAP 覆盖（无 http mock）。测试覆盖：签名/退避/请求头组装、
-- 队列选取与派发（真实 http_post 只入队）、响应收口与事件状态机（向 net._http_response
-- 注入响应行模拟）、test_webhook 越权与结果查询、cron 注册；公网端到端需真实 echo 端点
-- （实现时已用 postman-echo 实测：签名头/自定义头回显一致、事件与明细 2xx → done）。
--
-- 组成：
--   1. public.webhook_deliveries：投递明细（每次端点尝试一行）；
--   2. app.webhook_signature / app.next_retry / app.webhook_request_headers：可测纯函数；
--   3. app.process_webhook_events：pg_cron 每分钟入口（收口 + 派发）；
--   4. app.finalize_webhook_deliveries：响应收口与重试状态机；
--   5. app.test_webhook（admin）：测试投递 ping（直发端点、不经队列；返回 request_id）+
--      app.webhook_test_result（admin）：按 request_id 返回 HTTP 结果；
--   6. pg_cron：process-webhook-events 每分钟。
--
-- 依赖：integration/004（webhooks / integration_events / emit_event）、system/001
--       （app.decrypt_secret）、message/001（app.send_notification）、audit/001（app.audit_log）、
--       extensions.pg_net / extensions.pgcrypto。

-- ---------------------------------------------------------------------------
-- 1. pg_net 扩展（异步出站 HTTP；net schema 由扩展脚本创建）
-- ---------------------------------------------------------------------------
create extension if not exists pg_net with schema extensions;

-- ---------------------------------------------------------------------------
-- 2. webhook_deliveries：投递明细（每次端点尝试一行；收口后写结果）
-- ---------------------------------------------------------------------------
create table public.webhook_deliveries (
  id           bigint generated always as identity primary key,
  event_id     bigint not null references public.integration_events (id) on delete cascade,
  webhook_id   uuid not null references public.webhooks (id) on delete cascade,
  attempt_no   integer not null default 0,
  request_id   bigint,
  status       text not null default 'delivering'
               constraint webhook_deliveries_status_check
               check (status in ('delivering', 'done', 'failed')),
  http_status  integer,
  duration_ms  integer,
  error        text,
  attempted_at timestamptz not null default now(),
  finished_at  timestamptz,
  constraint webhook_deliveries_attempt_no_check check (attempt_no >= 0),
  constraint webhook_deliveries_duration_check check (duration_ms is null or duration_ms >= 0)
);

comment on table public.webhook_deliveries is
  'Webhook 投递明细（每次端点尝试一行）：派发写 delivering + request_id，收口写 done/failed + '
  'http_status/duration_ms/error；排障明细，不进 audit（摘要在事件终态时写）';
comment on column public.webhook_deliveries.event_id is '所属事件（integration_events；级联删除）';
comment on column public.webhook_deliveries.webhook_id is '目标端点（webhooks；级联删除）';
comment on column public.webhook_deliveries.attempt_no is
  '第几次派发（0 起；与 integration_events.attempts 对应，用于区分事件的重试轮次）';
comment on column public.webhook_deliveries.request_id is
  'pg_net 请求 id（net.http_post 返回；收口时按此关联 net._http_response）';
comment on column public.webhook_deliveries.status is
  '投递状态机：delivering 已入队待响应 / done 2xx / failed 非 2xx、超时或网络错误';
comment on column public.webhook_deliveries.duration_ms is '投递耗时（响应到达 - 入队时刻；未收口为 NULL）';
comment on column public.webhook_deliveries.error is '失败原因（HTTP 状态/网络错误/超时；成功为 NULL）';
comment on column public.webhook_deliveries.attempted_at is '本次尝试入队时间（超时判定基准）';
comment on column public.webhook_deliveries.finished_at is '收口时间（响应到达时间或超时标记时间）';

create index webhook_deliveries_pending_idx
  on public.webhook_deliveries (id)
  where status = 'delivering';
create index webhook_deliveries_event_idx
  on public.webhook_deliveries (event_id);
create index webhook_deliveries_webhook_time_idx
  on public.webhook_deliveries (webhook_id, attempted_at desc);

alter table public.webhook_deliveries enable row level security;

-- ---------------------------------------------------------------------------
-- 3. app.webhook_signature：HMAC-SHA256 hex（签名 = 对发送 body 的 jsonb 规范化文本）
--    纯函数（immutable），投递与测试投递共用；不 GRANT API 角色。
-- ---------------------------------------------------------------------------
create function app.webhook_signature(p_secret text, p_payload jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(extensions.hmac(p_payload::text, p_secret, 'sha256'), 'hex')
$$;

comment on function app.webhook_signature(text, jsonb) is
  'Webhook HMAC-SHA256 签名（hex）；对 p_payload::text（jsonb 规范化文本，与 pg_net 发送字节一致）'
  '用端点独立 secret 计算；接收端对 raw body 做同样计算即可验签；不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 4. app.next_retry：退避计算（纯函数，pgTAP 直接覆盖）
--    单参：指数退避 2^n 分钟（n=已尝试次数），上限 60 分钟；
--    双参：按 retry_policy.backoff（'linear' 线性 / 其余按指数）。
-- ---------------------------------------------------------------------------
create function app.next_retry(p_attempts integer)
returns interval
language sql
immutable
set search_path = ''
as $$
  select make_interval(
           mins => least(power(2, least(greatest(coalesce(p_attempts, 0), 0), 30)), 60)::integer
         )
$$;

comment on function app.next_retry(integer) is
  '指数退避间隔：2^n 分钟（n=已尝试次数，上限 60 分钟）；纯函数，不 GRANT API 角色';

create function app.next_retry(p_attempts integer, p_backoff text)
returns interval
language sql
immutable
set search_path = ''
as $$
  select case
           when p_backoff = 'linear'
           then make_interval(mins => least(greatest(coalesce(p_attempts, 1), 1), 60))
           else app.next_retry(p_attempts)
         end
$$;

comment on function app.next_retry(integer, text) is
  '按 retry_policy.backoff 计算退避：linear = n 分钟；其余（exponential/NULL）走指数 2^n 分钟；'
  '不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 5. app.webhook_request_headers：自定义头（解密，剔除保留头）+ 保留头（Content-Type/
--    签名/事件）。保留头在合并中最后写入，保证自定义头无法伪造/覆盖。
-- ---------------------------------------------------------------------------
create function app.webhook_request_headers(
  p_secret      text,
  p_body        jsonb,
  p_event       text,
  p_headers_enc bytea
)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_custom jsonb := '{}'::jsonb;
begin
  if p_headers_enc is not null then
    v_custom := app.decrypt_secret(p_headers_enc)::jsonb;

    -- 剔除与投递器保留头冲突的自定义键（大小写不敏感）
    select coalesce(jsonb_object_agg(h.key, h.value), '{}'::jsonb)
      into v_custom
    from jsonb_each(v_custom) as h(key, value)
    where lower(h.key) not in ('content-type', 'x-webhook-signature', 'x-webhook-event');
  end if;

  return v_custom || jsonb_build_object(
    'Content-Type', 'application/json',
    'x-webhook-signature', app.webhook_signature(p_secret, p_body),
    'x-webhook-event', p_event
  );
end;
$$;

comment on function app.webhook_request_headers(text, jsonb, text, bytea) is
  '投递请求头组装：自定义头（headers_enc 解密，剔除 Content-Type/签名/事件等保留键）+ '
  'Content-Type=application/json + x-webhook-signature + x-webhook-event；不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 6. app.finalize_webhook_deliveries：响应收口 + 事件重试状态机
--    （推荐只经 app.process_webhook_events 间接执行；单独可调便于 pgTAP 与运维排障）
-- ---------------------------------------------------------------------------
create function app.finalize_webhook_deliveries()
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
begin
  -- 1) 投递明细收口：pg_net 响应 → done/failed；长期无响应 → 超时失败
  for v_delivery in
    select d.id, d.event_id, d.attempt_no, d.attempted_at,
           r.status_code, r.error_msg, r.timed_out, r.created
    from public.webhook_deliveries d
    left join net._http_response r on r.id = d.request_id
    where d.status = 'delivering'
    order by d.id
    for update of d skip locked
  loop
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
      end if;
    elsif v_delivery.attempted_at <= now() - c_stale then
      update public.webhook_deliveries
         set status      = 'failed',
             error       = '投递超时（pg_net 10 分钟内无响应）',
             finished_at = now()
       where id = v_delivery.id;
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
  'security invoker + 仅函数属主/pg_cron 可达（撤销 API 角色执行权），禁 service_role（ADR-001）';

-- ---------------------------------------------------------------------------
-- 7. app.process_webhook_events：pg_cron 每分钟入口（收口 + 派发）
--    SECURITY INVOKER + REVOKE API 角色（同 report/007 worker 模式）；执行身份 = pg_cron
--    的 postgres（系统级任务，不注入属主身份——投递器只读订阅配置，无 RLS 行级语义）。
-- ---------------------------------------------------------------------------
create function app.process_webhook_events()
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

    for v_webhook in
      select w.id, w.url, w.secret_enc, w.headers_enc
      from public.webhooks w
      where w.status = 'active'
        and v_event.event = any(w.events)
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
      -- 无 active 订阅端点：事件无需投递，直接终结（避免永久 pending 占用队列）
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
  '（skip locked 限 5 条/轮）：匹配 active 订阅 → 逐端点 pg_net.http_post（签名头）→ 写 '
  'webhook_deliveries（delivering）→ 事件 delivering；无订阅端点直接 done；返回本轮派发事件数。'
  'security invoker + 撤销 API 角色执行权（仅 pg_cron 的 postgres 可达），禁 service_role';

-- ---------------------------------------------------------------------------
-- 8. app.test_webhook / app.webhook_test_result：admin 测试投递（ping 直发，不经队列）
--    pg_net 异步：入队行提交后 worker 才可见，函数内同步等待拿不到响应；故两段式：
--    test_webhook 发送并返回 request_id（queued），结果经 webhook_test_result 查询。
-- ---------------------------------------------------------------------------
create function app.test_webhook(p_webhook_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row     public.webhooks;
  v_body    jsonb;
  v_headers jsonb;
  v_request bigint;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_webhook_id is null then
    raise exception 'Webhook ID 不能为空' using errcode = '22023';
  end if;

  select * into v_row
  from public.webhooks
  where id = p_webhook_id;

  if not found then
    raise exception 'Webhook 不存在：%', p_webhook_id using errcode = 'P0002';
  end if;

  -- ping 信封与真实投递同构（event=ping；不进 integration_events / webhook_deliveries）
  v_body := jsonb_build_object(
    'id', null,
    'event', 'ping',
    'created_at', now(),
    'data', jsonb_build_object('webhook_id', v_row.id, 'test', true)
  );

  v_headers := app.webhook_request_headers(
    app.decrypt_secret(v_row.secret_enc),
    v_body,
    'ping',
    v_row.headers_enc
  );

  v_request := net.http_post(
    url := v_row.url,
    body := v_body,
    headers := v_headers,
    timeout_milliseconds := 10000
  );

  perform app.audit_log(
    'integration', 'test', 'webhook', v_row.id::text,
    jsonb_build_object('url', v_row.url, 'request_id', v_request, 'queued', true)
  );

  return jsonb_build_object(
    'webhook_id', v_row.id,
    'url', v_row.url,
    'event', 'ping',
    'request_id', v_request,
    'queued', true,
    'sent_at', now()
  );
end;
$$;

comment on function app.test_webhook(uuid) is
  '测试投递 RPC（admin）：向端点直发 ping（同签名头，不经 integration_events 队列），'
  '返回 {webhook_id,url,event,request_id,queued,sent_at}；结果是异步的——'
  'pg_net 入队行提交后 worker 才出站，请在数秒后调用 app.webhook_test_result(request_id) '
  '获取 HTTP 结果；写审计摘要（test/webhook）';

create function app.webhook_test_result(p_request_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_resp net._http_response;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_request_id is null then
    raise exception 'request_id 不能为空' using errcode = '22023';
  end if;

  select * into v_resp
  from net._http_response r
  where r.id = p_request_id
  order by r.created desc
  limit 1;

  if not found then
    return jsonb_build_object(
      'request_id', p_request_id,
      'responded', false,
      'pending', true
    );
  end if;

  return jsonb_build_object(
    'request_id', p_request_id,
    'responded', true,
    'pending', false,
    'ok', coalesce(v_resp.status_code between 200 and 299, false),
    'http_status', v_resp.status_code,
    'timed_out', coalesce(v_resp.timed_out, false),
    'error', v_resp.error_msg,
    'content', left(v_resp.content, 2000) -- 排障展示；截断防大响应
  );
end;
$$;

comment on function app.webhook_test_result(bigint) is
  '测试投递结果查询（admin）：按 pg_net request_id 读 net._http_response；'
  '未响应返回 {responded:false,pending:true}，已响应返回 ok/http_status/timed_out/error/content'
  '（content 截断 2000 字符）；与 test_webhook 配套（异步出站的现实约束）';

-- ---------------------------------------------------------------------------
-- 9. public 薄包装（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.test_webhook(p_webhook_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.test_webhook(p_webhook_id)
$$;

create function public.webhook_test_result(p_request_id bigint)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.webhook_test_result(p_request_id)
$$;

comment on function public.test_webhook(uuid) is
  'test_webhook Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.webhook_test_result(bigint) is
  'webhook_test_result Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 10. 授权：投递明细仅 admin 可见；worker/纯函数不 GRANT API 角色；测试投递仅 authenticated
-- ---------------------------------------------------------------------------
revoke all on public.webhook_deliveries from public, anon, authenticated, service_role;
grant select on public.webhook_deliveries to authenticated;

revoke all on sequence public.webhook_deliveries_id_seq
  from public, anon, authenticated, service_role;

revoke all on function app.webhook_signature(text, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function app.next_retry(integer)
  from public, anon, authenticated, service_role;
revoke all on function app.next_retry(integer, text)
  from public, anon, authenticated, service_role;
revoke all on function app.webhook_request_headers(text, jsonb, text, bytea)
  from public, anon, authenticated, service_role;
revoke all on function app.finalize_webhook_deliveries()
  from public, anon, authenticated, service_role;
revoke all on function app.process_webhook_events()
  from public, anon, authenticated, service_role;

revoke all on function app.test_webhook(uuid) from public, anon;
grant execute on function app.test_webhook(uuid) to authenticated;

revoke all on function app.webhook_test_result(bigint) from public, anon;
grant execute on function app.webhook_test_result(bigint) to authenticated;

revoke all on function public.test_webhook(uuid) from public, anon;
grant execute on function public.test_webhook(uuid) to authenticated;

revoke all on function public.webhook_test_result(bigint) from public, anon;
grant execute on function public.webhook_test_result(bigint) to authenticated;

-- ---------------------------------------------------------------------------
-- 11. RLS：webhook_deliveries 仅 admin SELECT；无写策略（写仅经 worker/RPC）
-- ---------------------------------------------------------------------------
create policy webhook_deliveries_select_admin
on public.webhook_deliveries
for select
to authenticated
using ((select app.current_role()) = 'admin');

-- ---------------------------------------------------------------------------
-- 12. pg_cron：每分钟轮询（TODO(system/011)：登记表上线后补登记，规则 5）
-- ---------------------------------------------------------------------------
select cron.schedule(
  'process-webhook-events',
  '* * * * *',
  $cron$select app.process_webhook_events()$cron$
);
