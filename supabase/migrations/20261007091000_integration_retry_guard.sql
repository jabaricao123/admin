-- 接口/集成中心 · 批次 1 安全修复：retry_policy 防御 + SSRF 内网校验
-- 背景：create/update_webhook 对 retry_policy 只校验「对象」，非法 max_attempts（非整数）
--       会被原样落库；finalize_webhook_deliveries 直接 ::integer 解析，一条毒配置让整个投递
--       收口事务（process_webhook_events 每分钟）持续失败 —— 全管线停滞。
--       同时 URL 校验只有 ^https:// 正则，允许 127.0.0.1 / 169.254.169.254 等内网地址
--       （SSRF：云元数据、内网服务可达）。
-- 本迁移组成：
--   1. app.is_forbidden_webhook_host：SSRF 主机判定纯函数（IP literal 私网/环回/link-local
--      与 localhost/*.localhost/*.local/*.internal；IPv4 短写与 ::ffff: 映射同样覆盖）；
--   2. app.validate_webhook_fields（create/update 共用）：URL ≤500 字符、host 非空、
--      禁 userinfo、SSRF 黑名单；retry_policy 的 max_attempts 必须 1..10 整数、
--      backoff 必须 linear/exponential；自定义 header 名/值禁 CR/LF 控制字符；
--   3. app.finalize_webhook_deliveries：max_attempts 安全解析（regex 预检 + 非法兜底 3，
--      不再抛错）；事件状态机逐事件包 exception 块（when others → 该事件置 failed 并继续，
--      不回滚整个收口事务）。
-- 残留风险披露：域名型 SSRF 依赖 DNS 解析结果，本版只做字面校验（解析后二次校验/出站代理
--       属 v2；DNS rebinding 仍可能绕过字面黑名单，已由「出站由 pg_net 发起、无内网凭据」
--       与最小面缓和）。
-- 依赖：integration/004（webhooks / validate_webhook_fields）、integration/005 与 007
--       （finalize_webhook_deliveries 最新版在 20261005122000）、system/001（app.decrypt_secret）。

-- ---------------------------------------------------------------------------
-- 1. app.is_forbidden_webhook_host：SSRF 主机黑名单判定（纯函数）
--    输入为 URL 中的 host（不含端口；IPv6 已去方括号）；命中返回 true。
-- ---------------------------------------------------------------------------
create function app.is_forbidden_webhook_host(p_host text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_host text := lower(btrim(coalesce(p_host, '')));
  v_ip   inet;
  v_addr text;
begin
  if v_host = '' then
    return true; -- 空主机不可用
  end if;

  -- 本机/内网保留域名后缀
  if v_host in ('localhost', 'localhost.localdomain', 'local', 'internal')
     or v_host like '%.localhost'
     or v_host like '%.local'
     or v_host like '%.internal' then
    return true;
  end if;

  -- IP literal：仅当字符集为十六进制/点/冒号时尝试解析（兼容 127.1 等短写；
  -- 解析失败如 'beef' 视为普通域名）
  if v_host ~ '^[0-9a-f:.]+$' then
    begin
      v_ip := v_host::inet;
    exception when others then
      v_ip := null;
    end;
  end if;

  if v_ip is null then
    return false; -- 域名（字面检查通过；DNS 解析后校验属 v2）
  end if;

  -- IPv4-mapped IPv6（::ffff:a.b.c.d）归一化后按 IPv4 段判定
  v_addr := host(v_ip);
  if v_addr like '::ffff:%' then
    begin
      v_ip := substring(v_addr from 8)::inet; -- '::ffff:' 共 7 字符
    exception when others then
      return true; -- 形似映射地址但解析失败：宁拒勿放
    end;
  end if;

  -- 私网/环回/link-local/未指定/ULA（覆盖任务清单并含常见旁路）
  return v_ip <<= inet '0.0.0.0/8'
      or v_ip <<= inet '127.0.0.0/8'
      or v_ip <<= inet '10.0.0.0/8'
      or v_ip <<= inet '172.16.0.0/12'
      or v_ip <<= inet '192.168.0.0/16'
      or v_ip <<= inet '169.254.0.0/16'
      or v_ip <<= inet '::/128'
      or v_ip <<= inet '::1/128'
      or v_ip <<= inet 'fc00::/7'
      or v_ip <<= inet 'fe80::/10';
end;
$$;

comment on function app.is_forbidden_webhook_host(text) is
  'SSRF 主机判定：localhost/*.localhost/*.local/*.internal、IPv4 私网/环回/link-local/未指定、'
  'IPv6 ::/::1/ULA(fc00::/7)/链路本地(fe80::/10)，含 127.1 短写与 ::ffff: 映射归一；'
  '仅字面校验（DNS rebinding 属 v2）；纯函数，不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 2. app.validate_webhook_fields：URL（SSRF）+ retry_policy + headers 校验强化
-- ---------------------------------------------------------------------------
create or replace function app.validate_webhook_fields(
  p_name         text,
  p_url          text,
  p_events       text[],
  p_retry_policy jsonb,
  p_headers      jsonb
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_authority text;
  v_host      text;
  v_max_num   numeric;
begin
  if p_name is null or btrim(p_name) = '' then
    raise exception 'Webhook 名称不能为空' using errcode = '22023';
  end if;

  -- URL：非空、≤500 字符、https、host 非空、禁 userinfo、禁内网/本机地址
  if p_url is null or btrim(p_url) = '' then
    raise exception 'Webhook URL 不能为空' using errcode = '22023';
  end if;

  if char_length(p_url) > 500 then
    raise exception 'Webhook URL 长度不能超过 500 字符' using errcode = '22023';
  end if;

  if p_url !~ '^https://[^[:space:]]+$' then
    raise exception 'Webhook URL 必须为 https:// 开头且不含空白字符' using errcode = '22023';
  end if;

  v_authority := substring(p_url from '^https://([^/?#]+)');

  if v_authority is null or v_authority = '' then
    raise exception 'Webhook URL 缺少主机名' using errcode = '22023';
  end if;

  if position('@' in v_authority) > 0 then
    raise exception 'Webhook URL 不允许包含 userinfo（user@host）' using errcode = '22023';
  end if;

  -- 主机解析：IPv6 必须方括号；其余 host[:port] 且端口为数字
  if v_authority ~ '^\[[^\]]+\](:[0-9]{1,5})?$' then
    v_host := substring(v_authority from '^\[([^\]]+)\]');
  elsif v_authority ~ '^[^:]+(:[0-9]{1,5})?$' then
    v_host := split_part(v_authority, ':', 1);
  else
    raise exception 'Webhook URL 主机格式非法（IPv6 需方括号，端口需为数字）' using errcode = '22023';
  end if;

  if v_host is null or btrim(v_host) = '' then
    raise exception 'Webhook URL 主机名不能为空' using errcode = '22023';
  end if;

  if app.is_forbidden_webhook_host(v_host) then
    raise exception 'Webhook URL 指向内网/本机地址，已拒绝（SSRF 防护）：%', v_host
      using errcode = '22023';
  end if;

  if p_events is null or cardinality(p_events) < 1 then
    raise exception '至少订阅一个事件' using errcode = '22023';
  end if;

  if exists (
    select 1
    from unnest(p_events) as e
    where e is null or btrim(e) = ''
  ) then
    raise exception '事件名不能为空' using errcode = '22023';
  end if;

  -- 重试策略：max_attempts 存在时必须为 1..10 整数；backoff 存在时必须 linear/exponential
  if p_retry_policy is not null then
    if jsonb_typeof(p_retry_policy) <> 'object' then
      raise exception '重试策略必须为 jsonb 对象' using errcode = '22023';
    end if;

    if p_retry_policy ? 'max_attempts' then
      if jsonb_typeof(p_retry_policy -> 'max_attempts') <> 'number'
         or (p_retry_policy ->> 'max_attempts') !~ '^\d+$' then
        raise exception '重试策略 max_attempts 必须为 1..10 的整数' using errcode = '22023';
      end if;

      v_max_num := (p_retry_policy ->> 'max_attempts')::numeric;

      if v_max_num < 1 or v_max_num > 10 then
        raise exception '重试策略 max_attempts 必须为 1..10 的整数' using errcode = '22023';
      end if;
    end if;

    if p_retry_policy ? 'backoff'
       and coalesce(p_retry_policy ->> 'backoff', '') not in ('linear', 'exponential') then
      raise exception '重试策略 backoff 必须为 linear 或 exponential' using errcode = '22023';
    end if;
  end if;

  if p_headers is not null then
    if jsonb_typeof(p_headers) <> 'object' then
      raise exception '自定义 header 必须为 jsonb 对象' using errcode = '22023';
    end if;

    if exists (
      select 1
      from jsonb_each(p_headers) as h(key, value)
      where jsonb_typeof(h.value) <> 'string'
    ) then
      raise exception '自定义 header 的值必须为字符串' using errcode = '22023';
    end if;

    -- header 名/值不得含 CR/LF（出站请求头注入防护）；名不得为空
    if exists (
      select 1
      from jsonb_each(p_headers) as h(key, value)
      where position(chr(13) in h.key) > 0
         or position(chr(10) in h.key) > 0
         or position(chr(13) in (h.value #>> '{}')) > 0
         or position(chr(10) in (h.value #>> '{}')) > 0
    ) then
      raise exception '自定义 header 名/值不能包含控制字符（CR/LF）' using errcode = '22023';
    end if;

    if exists (
      select 1
      from jsonb_each(p_headers) as h(key, value)
      where btrim(h.key) = ''
    ) then
      raise exception '自定义 header 名不能为空' using errcode = '22023';
    end if;
  end if;
end;
$$;

comment on function app.validate_webhook_fields(text, text, text[], jsonb, jsonb) is
  'Webhook 入参校验（create/update 共用）：名称/URL（≤500、https、host 非空、禁 userinfo、'
  '禁内网与本机地址=SSRF 防护）/事件非空/retry_policy（max_attempts 1..10 整数、'
  'backoff linear|exponential）/header（字符串值、名非空、名值禁 CR/LF 控制字符）';

-- ---------------------------------------------------------------------------
-- 3. app.finalize_webhook_deliveries：安全解析 + 单事件故障隔离
--    （保留 integration/007 起每条终态投递写 integration_call_logs 的行为）
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
  --    逐事件包 exception：单条毒事件（如异常重试配置/数据）只把自己置 failed，
  --    不回滚整个收口事务，保证其他事件继续收口（防全管线停滞）。
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
    begin
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
        -- backoff 全为 linear 才走线性，否则指数（默认）。
        -- max_attempts 安全解析：regex 预检（^\d+$）+ 嵌套 CASE 保证先校验后转型；
        -- 缺失/非整数/越界（1..10 之外）一律兜底默认 3，非法存量值不再抛错。
        select
          max(
            case
              when coalesce(w.retry_policy ->> 'max_attempts', '') ~ '^\d+$'
              then case
                     when (w.retry_policy ->> 'max_attempts')::numeric between 1 and 10
                     then (w.retry_policy ->> 'max_attempts')::integer
                     else 3
                   end
              else 3
            end
          ),
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
  '事件最新一轮全部终态后 done/退避重试/终态 failed（audit + 通知失败端点创建人）；返回收口事件数。'
  'integration/007 起：每条终态投递追加 integration_call_logs（kind=webhook）；'
  'max_attempts 非法存量值 regex 预检兜底 3（不抛错）；逐事件 exception 隔离（毒事件置 failed 继续）。'
  'security invoker + 仅函数属主/pg_cron 可达（撤销 API 角色执行权），禁 service_role（ADR-001）';

-- ---------------------------------------------------------------------------
-- 4. 授权：新增 SSRF helper 不 GRANT API 角色（validate 内调用，函数属主可见）
-- ---------------------------------------------------------------------------
revoke all on function app.is_forbidden_webhook_host(text)
  from public, anon, authenticated, service_role;
