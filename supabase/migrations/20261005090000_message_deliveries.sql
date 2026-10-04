-- 消息中心 · 发送记录 + 渠道分发（工单 message/007+008+009）
-- 契约：docs/modules/message/history.md：
--   * message_deliveries 按月分区（PARTITION BY RANGE (created_at)），唯一
--     (idempotency_key, created_at)（含分区键，跨分区生效）；
--   * 状态三分：success / failed / degraded（渠道停用自动降级标 degraded，不产生 failed 噪音）；
--   * 保留策略 90 天，清理任务在 system pg_cron 登记处注册；
--   * RLS：admin 全量；普通用户 SELECT 本人（自查收件问题）；
--   * 重发经 app.resend_delivery（admin；仅 failed）：更新原行 + attempts+1（幂等，不产生重复站内信）。
-- 渠道分发（docs/modules/message/inbox.md 依赖与契约 + docs/adr/001-job-runner.md）：
--   * send_notification 写 messages（站内信必达，delivery=success）后调
--     app.dispatch_message_channels：按 message_template_current 的 email/push/sms 当前
--     published 模板逐个渲染分发（best-effort，失败/降级不影响站内信）；
--   * system_services 未配置 / 未验证 / 无 relay_api_url → degraded（自动降级不报错）；
--     配置 relay_api_url 且 verified → pg_net 异步 POST（异步入队，response 记 request_id）；
--   * 真实 SMTP / 推送发送属 Edge Function 投递器（ADR-001 预留；届时 relay_api_url 指向投递器）。
-- 实现落 app schema（public 同名薄包装供 Data API）；管理 RPC 函数内显式 admin 校验；
-- 表对 API 角色仅 SELECT（RLS 再收口），写全经 SECURITY DEFINER RPC / 内部函数。
-- 依赖：20261003205454（messages + app.send_notification）、20261005020000（模板/渲染/current）、
--       20261004151000（system_services + encrypt/decrypt_secret）、20261005080000（register_cron_job）、
--       20261004235500（pg_net：create extension 已在此合入）。

-- ---------------------------------------------------------------------------
-- 1. message_deliveries：投递明细（按月分区）
-- ---------------------------------------------------------------------------
create table public.message_deliveries (
  id               bigint generated always as identity,
  message_id       bigint not null references public.messages (id) on delete cascade,
  recipient_id     uuid not null references public.profiles (id) on delete cascade,
  event_key        text not null,
  channel          text not null
                   constraint message_deliveries_channel_check
                   check (channel in ('inbox', 'email', 'push', 'sms')),
  status           text not null
                   constraint message_deliveries_status_check
                   check (status in ('success', 'failed', 'degraded')),
  error            text,
  response         text,
  rendered_subject text,
  rendered_body    text,
  idempotency_key  text not null,
  attempts         integer not null default 1
                   constraint message_deliveries_attempts_check
                   check (attempts >= 1),
  created_at       timestamptz not null default now(),
  -- 分区表主键必须包含分区键；id 由 identity 序列保证全局唯一
  constraint message_deliveries_pkey primary key (id, created_at),
  -- history.md 数据模型：唯一约束含分区键（跨分区生效），防同一消息同渠道重复投递
  constraint message_deliveries_idempotency_key_created_at_uq
    unique (idempotency_key, created_at)
) partition by range (created_at);

comment on table public.message_deliveries is
  '消息投递明细（按月分区）：每次业务触发的完整渠道矩阵（站内信/邮件/推送/短信）；'
  '写入唯一入口 app.dispatch_message_channels（send_notification 内调用），'
  '重发经 app.resend_delivery（更新原行，不新增重复通知）';
comment on column public.message_deliveries.message_id is '关联 messages.id（站内信主体，级联删除）';
comment on column public.message_deliveries.recipient_id is '收件人（profiles.id；RLS 自查依据）';
comment on column public.message_deliveries.event_key is '通知事件 key（与 messages.event_key 一致）';
comment on column public.message_deliveries.channel is '投递渠道：inbox 站内信 / email 邮件 / push 推送 / sms 短信';
comment on column public.message_deliveries.status is
  '投递状态：success 成功 / failed 失败（可重发）/ degraded 降级（渠道停用或未配置，非失败噪音）';
comment on column public.message_deliveries.error is
  '错误 / 降级原因摘要（降级记录注明自动降级依据，如「邮件服务未配置」）';
comment on column public.message_deliveries.response is
  '渠道响应摘要（如 pg_net request id / 已入队标记；异步投递的现实约束，失败详情见 error）';
comment on column public.message_deliveries.rendered_subject is '渲染后标题快照（排查「为什么没收到」的原文依据）';
comment on column public.message_deliveries.rendered_body is '渲染后正文快照';
comment on column public.message_deliveries.idempotency_key is
  '幂等键 = message_id || '':'' || channel（跨分区唯一约束的组成列；重发更新原行不改键）';
comment on column public.message_deliveries.attempts is '投递尝试次数（首次 =1；admin 重发 +1）';
comment on column public.message_deliveries.created_at is '投递时间（分区键，按月 range 分区）';

create index message_deliveries_recipient_created_idx
  on public.message_deliveries (recipient_id, created_at desc);

-- 初始分区：当月 + 下月（迁移落库时点 2026-10 / 2026-11）；
-- 迁移尾部的 ensure 调用兜底后续月份（如 db reset 在更晚月份执行）。
create table public.message_deliveries_202610 partition of public.message_deliveries
  for values from ('2026-10-01') to ('2026-11-01');
create table public.message_deliveries_202611 partition of public.message_deliveries
  for values from ('2026-11-01') to ('2026-12-01');

comment on table public.message_deliveries_202610 is 'message_deliveries 2026-10 月分区';
comment on table public.message_deliveries_202611 is 'message_deliveries 2026-11 月分区';

-- 分区直查防护：分区不继承父表 RLS 策略，且默认权限会给 service_role 表权限；
-- 显式撤权 + 启用 RLS（无策略 = 拒绝），防止绕过父表策略直读分区。
-- 后续由 app.ensure_message_partition 创建的分区在同一函数内做同样处理。
revoke all on public.message_deliveries_202610
  from public, anon, authenticated, service_role;
revoke all on public.message_deliveries_202611
  from public, anon, authenticated, service_role;
alter table public.message_deliveries_202610 enable row level security;
alter table public.message_deliveries_202611 enable row level security;

-- 三张表（含分区）不暴露写权限；identity 序列不暴露给 API 角色（与 messages 一致）
revoke all on public.message_deliveries from public, anon, authenticated, service_role;
revoke all on sequence public.message_deliveries_id_seq
  from public, anon, authenticated, service_role;
grant select on public.message_deliveries to authenticated;

alter table public.message_deliveries enable row level security;

-- admin 全量（排查全员投递）；普通用户 SELECT 本人（自查收件问题）
create policy message_deliveries_select_admin
on public.message_deliveries
for select
to authenticated
using ((select app.current_role()) = 'admin');

create policy message_deliveries_select_own
on public.message_deliveries
for select
to authenticated
using ((select auth.uid()) = recipient_id);

-- ---------------------------------------------------------------------------
-- 2. app.ensure_message_partition：按月分区维护（幂等；月 cron 调用）
-- ---------------------------------------------------------------------------
create function app.ensure_message_partition(p_month date default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_start date := date_trunc('month', coalesce(p_month, current_date))::date;
  v_end   date := (v_start + interval '1 month')::date;
  v_name  text := 'message_deliveries_' || to_char(v_start, 'YYYYMM');
begin
  if to_regclass('public.' || v_name) is null then
    execute format(
      'create table public.%I partition of public.message_deliveries '
      'for values from (%L::timestamptz) to (%L::timestamptz)',
      v_name, v_start, v_end
    );

    -- 与迁移初始分区一致：分区直查不继承父表 RLS 策略，显式撤权 + 启用 RLS
    execute format(
      'revoke all on public.%I from public, anon, authenticated, service_role',
      v_name
    );
    execute format('alter table public.%I enable row level security', v_name);
  end if;

  return v_name;
end;
$$;

comment on function app.ensure_message_partition(date) is
  '确保 message_deliveries 指定月份（默认当月）的分区存在（幂等）；'
  '月 cron 每月 25 日预建下月分区；不 GRANT API 角色（仅 cron / 迁移 / 内部调用）';

-- ---------------------------------------------------------------------------
-- 3. app.cleanup_message_deliveries：90 天保留清理（pg_cron 每日调用）
-- ---------------------------------------------------------------------------
create function app.cleanup_message_deliveries(p_retention_days integer default 90)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_deleted integer;
begin
  if p_retention_days is null or p_retention_days < 1 then
    raise exception '保留天数必须 >= 1：%', coalesce(p_retention_days::text, '(null)')
      using errcode = '22023';
  end if;

  -- 明细 90 天（history.md 保留策略）；按 created_at 分区剪枝，逐分区删除
  delete from public.message_deliveries d
   where d.created_at < now() - make_interval(days => p_retention_days);

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

comment on function app.cleanup_message_deliveries(integer) is
  '投递明细清理（默认 90 天；history.md 保留策略）：删除超期 deliveries，返回删除条数；'
  '仅 pg_cron / owner 可达（撤销 API 角色，同 sync/004 先例）';

-- ---------------------------------------------------------------------------
-- 4. app.attempt_channel_delivery：单渠道投递尝试（降级 / pg_net 出站）
--    返回 {status, error, response}；渠道配置缺失不报错（INDEX 降级语义）。
-- ---------------------------------------------------------------------------
create function app.attempt_channel_delivery(
  p_channel   text,
  p_recipient uuid,
  p_subject   text,
  p_body      text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_service text;
  v_label   text;
  v_row     public.system_services;
  v_to      text;
  v_relay   text;
  v_token   text;
  v_headers jsonb;
  v_payload jsonb;
  v_request bigint;
begin
  if p_channel not in ('email', 'push', 'sms') then
    return jsonb_build_object(
      'status', 'failed',
      'error', '不支持的渠道：' || coalesce(p_channel, '(null)'),
      'response', null
    );
  end if;

  v_service := case p_channel when 'email' then 'mail' when 'push' then 'push' else 'sms' end;
  v_label   := case p_channel when 'email' then '邮件' when 'push' then '推送' else '短信' end;

  select s.* into v_row
  from public.system_services s
  where s.service = v_service;

  -- 未配置：自动降级为站内信（不报错、不重试、不产生 failed 噪音）
  if not found then
    return jsonb_build_object(
      'status', 'degraded',
      'error', format('%s服务未配置，自动降级为站内信', v_label),
      'response', null
    );
  end if;

  -- 未验证（草稿 / 最近验证失败）：同样自动降级
  if v_row.verify_status <> 'verified' then
    return jsonb_build_object(
      'status', 'degraded',
      'error', format('%s服务未验证（%s），自动降级为站内信', v_label, v_row.verify_status),
      'response', null
    );
  end if;

  v_relay := nullif(btrim(coalesce(v_row.config ->> 'relay_api_url', '')), '');

  -- 已验证但未配置中继 API：真实发送待 Edge Function 投递器（ADR-001 预留），降级不报错
  if v_relay is null then
    return jsonb_build_object(
      'status', 'degraded',
      'error', format('%s投递通道待 Edge Function 投递器（配置 relay_api_url 后启用），自动降级为站内信', v_label),
      'response', null
    );
  end if;

  if p_channel = 'email' then
    select u.email into v_to
    from auth.users u
    where u.id = p_recipient;

    if v_to is null or btrim(v_to) = '' then
      return jsonb_build_object(
        'status', 'failed',
        'error', '收件人邮箱缺失，无法投递邮件',
        'response', null
      );
    end if;
  else
    -- 推送/短信目标地址（用户联系方式）随 system/004-005 建模；当前无地址按失败记录
    return jsonb_build_object(
      'status', 'failed',
      'error', format('%s目标地址未建模（system/004-005 落地后启用），无法投递', v_label),
      'response', null
    );
  end if;

  -- relay 凭据（可选）：credentials 明文以 Bearer 头附带；未配置则仅 Content-Type
  v_token := app.decrypt_secret(v_row.credentials);
  v_headers := jsonb_build_object('Content-Type', 'application/json');
  if v_token is not null and btrim(v_token) <> '' then
    v_headers := v_headers || jsonb_build_object('Authorization', 'Bearer ' || v_token);
  end if;

  v_payload := jsonb_build_object(
    'channel', p_channel,
    'to', v_to,
    'subject', p_subject,
    'body', p_body
  );

  begin
    v_request := net.http_post(
      url := v_relay,
      body := v_payload,
      headers := v_headers,
      timeout_milliseconds := 10000
    );
  exception when others then
    return jsonb_build_object(
      'status', 'failed',
      'error', format('%s投递请求失败：%s', v_label, sqlerrm),
      'response', null
    );
  end;

  return jsonb_build_object(
    'status', 'success',
    'error', null,
    'response', format('pg_net request #%s（已入队异步投递）', v_request)
  );
end;
$$;

comment on function app.attempt_channel_delivery(text, uuid, text, text) is
  '单渠道投递尝试（内部 helper）：邮箱渠道经 relay_api_url pg_net 异步 POST；'
  '服务未配置 / 未验证 / 无 relay_api_url → degraded（自动降级不报错）；'
  'pg_net 入队异常 → failed（可重发）；返回 {status, error, response}；不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 5. app.dispatch_message_channels：消息渠道分发（send_notification 调用）
--    站内信必达 success；email/push/sms 按当前 published 模板逐个尝试（best-effort）。
-- ---------------------------------------------------------------------------
create function app.dispatch_message_channels(
  p_message_id bigint,
  p_vars       jsonb default '{}'::jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_msg     public.messages;
  v_vars    jsonb := coalesce(p_vars, '{}'::jsonb);
  v_channel record;
  v_subject text;
  v_body    text;
  v_result  jsonb;
  v_count   integer := 0;
begin
  if p_message_id is null then
    raise exception 'message_id 不能为空' using errcode = '22023';
  end if;

  select * into v_msg
  from public.messages m
  where m.id = p_message_id;

  if not found then
    raise exception '消息不存在：%', p_message_id using errcode = 'P0002';
  end if;

  -- 1) 站内信：必达渠道（messages 行即站内信），成功快照 = 渲染后标题/正文
  insert into public.message_deliveries (
    message_id, recipient_id, event_key, channel, status,
    rendered_subject, rendered_body, idempotency_key
  )
  values (
    v_msg.id, v_msg.recipient_id, v_msg.event_key, 'inbox', 'success',
    v_msg.title, v_msg.body, v_msg.id::text || ':inbox'
  )
  on conflict (idempotency_key, created_at) do nothing;

  -- 2) 外部渠道：按 (event_key, channel) 当前 published 模板分发；
  --    未配置模板的渠道不产生记录（无内容可发），模板渠道失败/降级不影响站内信
  for v_channel in
    select c.channel, t.subject_tpl, t.body_tpl
    from public.message_template_current c
    join public.message_templates t
      on t.id = c.template_id
     and t.status = 'published'
    where c.event_key = v_msg.event_key
      and c.channel in ('email', 'push', 'sms')
    order by c.channel
  loop
    v_subject := app.render_message_template(v_channel.subject_tpl, v_vars);
    v_body    := app.render_message_template(v_channel.body_tpl, v_vars);

    v_result := app.attempt_channel_delivery(
      v_channel.channel, v_msg.recipient_id, v_subject, v_body
    );

    insert into public.message_deliveries (
      message_id, recipient_id, event_key, channel, status, error, response,
      rendered_subject, rendered_body, idempotency_key, attempts
    )
    values (
      v_msg.id, v_msg.recipient_id, v_msg.event_key, v_channel.channel,
      v_result ->> 'status', v_result ->> 'error', v_result ->> 'response',
      v_subject, v_body, v_msg.id::text || ':' || v_channel.channel, 1
    )
    on conflict (idempotency_key, created_at) do nothing;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

comment on function app.dispatch_message_channels(bigint, jsonb) is
  '消息渠道分发唯一入口（send_notification 内调用）：写站内信 delivery（success 快照）+ '
  '按 message_template_current 当前 published 模板分发 email/push/sms（best-effort，降级不报错）；'
  '幂等键 = message_id || '':'' || channel；返回外部渠道尝试数；不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 6. app.resend_delivery / public.resend_delivery：失败重发（admin）
--    重发更新原行（attempts+1），幂等键不变，不新增重复站内信；
--    degraded 记录不可重发（渠道本就不可用，恢复配置后由新通知自然分发）。
-- ---------------------------------------------------------------------------
create function app.resend_delivery(p_delivery_id bigint)
returns public.message_deliveries
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row    public.message_deliveries;
  v_result jsonb;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_delivery_id is null then
    raise exception 'delivery id 不能为空' using errcode = '22023';
  end if;

  select * into v_row
  from public.message_deliveries d
  where d.id = p_delivery_id
  for update;

  if not found then
    raise exception '投递记录不存在' using errcode = 'P0002';
  end if;

  if v_row.status <> 'failed' then
    raise exception '仅失败记录可重发（当前状态：%）', v_row.status using errcode = '22023';
  end if;

  -- 重发沿用原渲染快照（vars 未持久化；快照即用户实际应收到的内容）
  v_result := app.attempt_channel_delivery(
    v_row.channel, v_row.recipient_id, v_row.rendered_subject, v_row.rendered_body
  );

  update public.message_deliveries
     set status   = v_result ->> 'status',
         error    = v_result ->> 'error',
         response = v_result ->> 'response',
         attempts = v_row.attempts + 1
   where id = v_row.id
  returning * into v_row;

  perform app.audit_log(
    'message', 'resend', 'message_delivery', v_row.id::text,
    jsonb_build_object(
      'message_id', v_row.message_id,
      'channel', v_row.channel,
      'attempts', v_row.attempts,
      'status', v_row.status
    )
  );

  return v_row;
end;
$$;

comment on function app.resend_delivery(bigint) is
  '失败投递重发（admin）：仅 status=failed 可重发；更新原行（status/error/response 重算，'
  'attempts+1），幂等键与 created_at 不变（分区唯一约束下不产生重复投递）；写审计摘要';

-- public 薄包装（PostgREST 仅暴露 public schema）
create function public.resend_delivery(p_delivery_id bigint)
returns public.message_deliveries
language sql
security definer
set search_path = ''
as $$
  select app.resend_delivery(p_delivery_id)
$$;

comment on function public.resend_delivery(bigint) is
  'resend_delivery Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 7. send_notification 升级（保持签名，create or replace）：写 messages 后触发渠道分发
-- ---------------------------------------------------------------------------
create or replace function app.send_notification(
  p_recipient uuid,
  p_event_key text,
  p_vars      jsonb
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_vars          jsonb := coalesce(p_vars, '{}'::jsonb);
  v_id            bigint;
  v_title         text;
  v_body          text;
  v_source_module text;
  v_subject_tpl   text;
  v_body_tpl      text;
begin
  if p_recipient is null then
    raise exception '收件人不能为空' using errcode = '22023';
  end if;
  if p_event_key is null or btrim(p_event_key) = '' then
    raise exception 'event_key 不能为空' using errcode = '22023';
  end if;

  -- message/005：按 (event_key,'inbox') 当前 published 模板渲染；
  -- 无模板（或指针指向非 published）走原 fallback（vars 直传文案）
  select t.subject_tpl, t.body_tpl
    into v_subject_tpl, v_body_tpl
    from public.message_template_current c
    join public.message_templates t
      on t.id = c.template_id
   where c.event_key = p_event_key
     and c.channel = 'inbox'
     and t.status = 'published';

  if v_subject_tpl is not null then
    v_title := app.render_message_template(v_subject_tpl, v_vars);
    v_body  := app.render_message_template(v_body_tpl, v_vars);
  else
    v_title := coalesce(nullif(v_vars ->> 'title', ''), p_event_key);
    v_body  := coalesce(v_vars ->> 'body', '');
  end if;

  v_source_module := coalesce(
    nullif(v_vars ->> 'source_module', ''),
    nullif(split_part(p_event_key, '.', 1), p_event_key)
  );

  insert into public.messages (
    recipient_id, event_key, title, body, source_module, ref_type, ref_id
  )
  values (
    p_recipient,
    p_event_key,
    v_title,
    v_body,
    v_source_module,
    nullif(v_vars ->> 'ref_type', ''),
    nullif(v_vars ->> 'ref_id', '')
  )
  returning id into v_id;

  -- message/009：渠道分发（站内信必达 + email/push/sms 模板渠道 best-effort，
  -- 渠道未配置/停用自动降级为 degraded，不报错、不影响站内信）
  perform app.dispatch_message_channels(v_id, v_vars);

  perform app.audit_log(
    'message',
    'send_notification',
    'message',
    v_id::text,
    jsonb_build_object('recipient_id', p_recipient, 'event_key', p_event_key)
  );

  return v_id;
end;
$$;

comment on function app.send_notification(uuid, text, jsonb) is
  '通知发送唯一入口（INDEX 规则 3）：按 (event_key,''inbox'') 当前 published 模板渲染，'
  '缺变量保留占位符；无模板走 vars fallback；写 messages 后经 app.dispatch_message_channels '
  '分发 email/push/sms（渠道缺失自动降级，站内信必达）。不 GRANT API 角色，仅 SECURITY DEFINER wrapper 调用';

-- ---------------------------------------------------------------------------
-- 8. 授权：表仅 SELECT（RLS 收口）；内部函数不 GRANT；重发 RPC 仅 authenticated
-- ---------------------------------------------------------------------------
revoke all on function app.ensure_message_partition(date)
  from public, anon, authenticated, service_role;
revoke all on function app.cleanup_message_deliveries(integer)
  from public, anon, authenticated, service_role;
revoke all on function app.attempt_channel_delivery(text, uuid, text, text)
  from public, anon, authenticated, service_role;
revoke all on function app.dispatch_message_channels(bigint, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function app.resend_delivery(bigint)
  from public, anon, authenticated, service_role;

revoke all on function public.resend_delivery(bigint) from public, anon, service_role;
grant execute on function public.resend_delivery(bigint) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. pg_cron 登记（INDEX 规则 5：调度统一登记）：分区维护 + 90 天清理
-- ---------------------------------------------------------------------------
select app.register_cron_job(
  'message-ensure-partitions', 'message', '0 1 25 * *', 'Asia/Shanghai', '/message/history'
);
select app.register_cron_job(
  'message-cleanup-deliveries', 'message', '20 3 * * *', 'Asia/Shanghai', '/message/history'
);

-- 兜底：确保当月 + 下月分区存在（幂等；迁移落库月份与硬编码分区不一致时仍可用）
select app.ensure_message_partition();
select app.ensure_message_partition((date_trunc('month', current_date) + interval '1 month')::date);

do $$
begin
  if to_regprocedure('cron.schedule(text,text,text)') is null then
    raise exception 'pg_cron 未安装，无法注册消息中心定时任务' using errcode = '0A000';
  end if;

  -- 每月 25 日预建下月分区（当前月由上次调用/迁移兜底保证）
  perform cron.schedule(
    'message-ensure-partitions',
    '0 1 25 * *',
    $cron$select app.ensure_message_partition((date_trunc('month', current_date) + interval '1 month')::date)$cron$
  );

  -- 每日 03:20 清理 90 天前投递明细
  perform cron.schedule(
    'message-cleanup-deliveries',
    '20 3 * * *',
    $cron$select app.cleanup_message_deliveries()$cron$
  );
end $$;
