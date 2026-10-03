-- 接口/集成中心 · Webhook 订阅与事件入队（工单 integration/004）
-- 契约：docs/modules/integration/webhooks.md（secret pgcrypto 加密可解密、HMAC 出站签名、
--       emit_event 首期发射点契约）、docs/adr/001-job-runner.md（投递器 005 消费队列表）、
--       docs/modules/INDEX.md 规则 2（审计摘要）、规则 4（凭据加密）、规则 10（emit_event
--       不 GRANT authenticated）。
-- 组成：
--   1. public.webhooks：订阅端点（url https、secret_enc bytea、events text[]、retry_policy jsonb、
--      headers_enc bytea——整串 jsonb 加密存 bytea）；
--   2. public.integration_events：事件队列表（005 投递器消费；本期只入队）；
--   3. app.create_webhook / app.update_webhook / app.disable_webhook：admin 管理 RPC；
--      secret 生成后一次性返回明文，落库经 app.encrypt_secret（system/001 共享 helper）；
--   4. app.emit_event：全模块事件入口（SECURITY DEFINER，不 GRANT authenticated，规则 10）；
--      各模块写路径经自身 SECURITY DEFINER RPC 或后端 wrapper 调用——本期只入队 + 返回匹配订阅数；
--   5. RLS：webhooks/integration_events 仅 admin SELECT；无表级写。
--
-- 依赖：app.current_role() / app.set_updated_at()（init_profiles）、app.audit_log()（audit/001）、
--       app.encrypt_secret / app.decrypt_secret（system/001）。

-- ---------------------------------------------------------------------------
-- 1. webhooks：Webhook 订阅端点
-- ---------------------------------------------------------------------------
create table public.webhooks (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  url          text not null,
  secret_enc   bytea not null,
  events       text[] not null,
  retry_policy jsonb not null default '{"max_attempts": 3, "backoff": "exponential"}'::jsonb,
  headers_enc  bytea,
  status       text not null default 'active'
               constraint webhooks_status_check
               check (status in ('active', 'disabled')),
  created_by   uuid,
  updated_by   uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint webhooks_name_check check (btrim(name) <> ''),
  constraint webhooks_url_https_check check (url ~ '^https://[^[:space:]]+$'),
  constraint webhooks_events_nonempty_check check (cardinality(events) >= 1),
  constraint webhooks_retry_policy_object_check check (jsonb_typeof(retry_policy) = 'object')
);

comment on table public.webhooks is
  'Webhook 订阅端点（admin 管理）；出站签名需可解密，secret 经 app.encrypt_secret 落库、'
  '仅创建响应一次性返回明文；投递器（005）解密后计算 HMAC 签名头';
comment on column public.webhooks.url is '目标地址（仅 https，check 约束兜底）';
comment on column public.webhooks.secret_enc is '每端点独立 secret 密文（''whsec_'' + 32 位十六进制；pgp_sym 随机盐）';
comment on column public.webhooks.events is '订阅事件名数组（如 approval.approved；active 且匹配才投递）';
comment on column public.webhooks.retry_policy is
  '重试策略 jsonb（默认 {"max_attempts":3,"backoff":"exponential"}；005 消费）';
comment on column public.webhooks.headers_enc is '自定义请求头密文（整个 jsonb 经 app.encrypt_secret 加密为 bytea；NULL=无自定义头）';
comment on column public.webhooks.status is '状态机：active 启用 / disabled 停用（停用端点不再收到事件）';

create trigger webhooks_set_updated_at
before update on public.webhooks
for each row
execute function app.set_updated_at();

alter table public.webhooks enable row level security;

-- ---------------------------------------------------------------------------
-- 2. integration_events：事件队列表（005 投递器消费；本期只入队）
-- ---------------------------------------------------------------------------
create table public.integration_events (
  id            bigint generated always as identity primary key,
  event         text not null,
  payload       jsonb not null default '{}'::jsonb,
  status        text not null default 'pending'
                constraint integration_events_status_check
                check (status in ('pending', 'delivering', 'done', 'failed')),
  attempts      integer not null default 0,
  next_retry_at timestamptz not null default now(),
  created_at    timestamptz not null default now()
);

comment on table public.integration_events is
  '事件队列（emit_event 唯一入队口；005 投递器按 status=pending + next_retry_at 轮询消费）';
comment on column public.integration_events.event is '事件名（如 approval.submitted）';
comment on column public.integration_events.payload is '事件负载（jsonb 对象；不含模块内部表引用）';
comment on column public.integration_events.status is '投递状态机：pending/delivering/done/failed（005 维护）';
comment on column public.integration_events.attempts is '已尝试投递次数（005 维护；重试按 retry_policy）';
comment on column public.integration_events.next_retry_at is '下次可投递时间（默认 now()，005 退避时后移）';

create index integration_events_dispatch_idx
  on public.integration_events (status, next_retry_at);

alter table public.integration_events enable row level security;

-- ---------------------------------------------------------------------------
-- 3. 内部 helper：字段校验 + header 值掩码（不 GRANT API 角色）
-- ---------------------------------------------------------------------------
create function app.validate_webhook_fields(
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
begin
  if p_name is null or btrim(p_name) = '' then
    raise exception 'Webhook 名称不能为空' using errcode = '22023';
  end if;

  if p_url is null or p_url !~ '^https://[^[:space:]]+$' then
    raise exception 'Webhook URL 必须为 https:// 开头且不含空白字符' using errcode = '22023';
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

  if p_retry_policy is not null and jsonb_typeof(p_retry_policy) <> 'object' then
    raise exception '重试策略必须为 jsonb 对象' using errcode = '22023';
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
  end if;
end;
$$;

comment on function app.validate_webhook_fields(text, text, text[], jsonb, jsonb) is
  'Webhook 入参校验（名称/URL https/事件非空/策略对象/header 字符串值）；create/update 共用';

create function app.mask_jsonb_values(p jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    jsonb_object_agg(
      e.key,
      case
        when jsonb_typeof(e.value) = 'string' and length(e.value #>> '{}') > 4
        then to_jsonb(('****' || right(e.value #>> '{}', 4))::text)
        else to_jsonb('****'::text)
      end
    ),
    '{}'::jsonb
  )
  from jsonb_each(coalesce(p, '{}'::jsonb)) as e(key, value)
$$;

comment on function app.mask_jsonb_values(jsonb) is
  'jsonb 值掩码（''****'' + 明文尾 4 位；短值全掩）；headers 展示脱敏，不下发明文';

-- ---------------------------------------------------------------------------
-- 4. app.create_webhook：admin 新建（secret 一次性返回明文）
--    返回 jsonb：id/name/url/events/retry_policy/status/headers_masked/created_at + secret（仅此一次）。
-- ---------------------------------------------------------------------------
create function app.create_webhook(
  p_name         text,
  p_url          text,
  p_events       text[],
  p_retry_policy jsonb default null,
  p_headers      jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_secret  text;
  v_retry   jsonb := coalesce(p_retry_policy, '{"max_attempts": 3, "backoff": "exponential"}'::jsonb);
  v_row     public.webhooks;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  perform app.validate_webhook_fields(p_name, p_url, p_events, p_retry_policy, p_headers);

  -- 每端点独立 secret：'whsec_' + 32 位十六进制；明文仅本次响应，落库加密
  v_secret := 'whsec_' || replace(gen_random_uuid()::text, '-', '');

  insert into public.webhooks
    (name, url, secret_enc, events, retry_policy, headers_enc, created_by, updated_by)
  values
    (btrim(p_name),
     p_url,
     app.encrypt_secret(v_secret),
     p_events,
     v_retry,
     case when p_headers is null then null else app.encrypt_secret(p_headers::text) end,
     (select auth.uid()),
     (select auth.uid()))
  returning * into v_row;

  perform app.audit_log(
    'integration', 'create', 'webhook', v_row.id::text,
    jsonb_build_object(
      'name', v_row.name,
      'url', v_row.url,
      'events', to_jsonb(v_row.events),
      'retry_policy', v_row.retry_policy,
      'headers_set', p_headers is not null,
      'secret_set', true
    )
  );

  return jsonb_build_object(
    'id', v_row.id,
    'name', v_row.name,
    'url', v_row.url,
    'events', to_jsonb(v_row.events),
    'retry_policy', v_row.retry_policy,
    'status', v_row.status,
    'secret', v_secret, -- 明文仅此一次；表中仅有 secret_enc
    'headers_masked',
      case
        when v_row.headers_enc is null then null
        else app.mask_jsonb_values(app.decrypt_secret(v_row.headers_enc)::jsonb)
      end,
    'created_at', v_row.created_at
  );
end;
$$;

comment on function app.create_webhook(text, text, text[], jsonb, jsonb) is
  'Webhook 新建 RPC（admin）：生成 ''whsec_'' + 32 位十六进制 secret，'
  '经 app.encrypt_secret 落库并一次性返回明文；headers 整串加密为 headers_enc；'
  '审计只记配置项与 secret_set，不落 secret 明文';

-- ---------------------------------------------------------------------------
-- 5. app.update_webhook：admin 编辑（p_retry_policy/p_headers 为 NULL 表示保持原值）
-- ---------------------------------------------------------------------------
create function app.update_webhook(
  p_id           uuid,
  p_name         text,
  p_url          text,
  p_events       text[],
  p_retry_policy jsonb default null,
  p_headers      jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev public.webhooks;
  v_row  public.webhooks;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_prev
  from public.webhooks
  where id = p_id
  for update;

  if not found then
    raise exception 'Webhook 不存在：%', coalesce(p_id::text, '(null)') using errcode = 'P0002';
  end if;

  perform app.validate_webhook_fields(
    p_name,
    p_url,
    p_events,
    coalesce(p_retry_policy, v_prev.retry_policy),
    p_headers
  );

  update public.webhooks
     set name         = btrim(p_name),
         url          = p_url,
         events       = p_events,
         retry_policy = coalesce(p_retry_policy, v_prev.retry_policy),
         headers_enc  = case
                          when p_headers is null then v_prev.headers_enc
                          else app.encrypt_secret(p_headers::text)
                        end,
         updated_by   = (select auth.uid())
   where id = p_id
  returning * into v_row;

  perform app.audit_log(
    'integration', 'update', 'webhook', v_row.id::text,
    jsonb_build_object(
      'name', v_row.name,
      'url', v_row.url,
      'url_changed', v_row.url is distinct from v_prev.url,
      'events', to_jsonb(v_row.events),
      'events_changed', v_row.events is distinct from v_prev.events,
      'retry_policy_changed', v_row.retry_policy is distinct from v_prev.retry_policy,
      'headers_changed', v_row.headers_enc is distinct from v_prev.headers_enc
    )
  );

  return jsonb_build_object(
    'id', v_row.id,
    'name', v_row.name,
    'url', v_row.url,
    'events', to_jsonb(v_row.events),
    'retry_policy', v_row.retry_policy,
    'status', v_row.status,
    'headers_masked',
      case
        when v_row.headers_enc is null then null
        else app.mask_jsonb_values(app.decrypt_secret(v_row.headers_enc)::jsonb)
      end,
    'updated_at', v_row.updated_at
  );
end;
$$;

comment on function app.update_webhook(uuid, text, text, text[], jsonb, jsonb) is
  'Webhook 编辑 RPC（admin）：name/url/events 必填；retry_policy/headers 为 NULL 时保持原值；'
  'headers 重加密落库；摘要记变更标记，不落 header 明文';

-- ---------------------------------------------------------------------------
-- 6. app.disable_webhook：admin 停用（停用端点不再收到事件）
-- ---------------------------------------------------------------------------
create function app.disable_webhook(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev public.webhooks;
  v_row  public.webhooks;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_prev
  from public.webhooks
  where id = p_id
  for update;

  if not found then
    raise exception 'Webhook 不存在：%', coalesce(p_id::text, '(null)') using errcode = 'P0002';
  end if;

  update public.webhooks
     set status     = 'disabled',
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  perform app.audit_log(
    'integration', 'disable', 'webhook', v_row.id::text,
    jsonb_build_object(
      'name', v_row.name,
      'status_before', v_prev.status,
      'status_after', v_row.status
    )
  );

  return jsonb_build_object(
    'id', v_row.id,
    'name', v_row.name,
    'status', v_row.status,
    'updated_at', v_row.updated_at
  );
end;
$$;

comment on function app.disable_webhook(uuid) is
  'Webhook 停用 RPC（admin）：status=disabled；emit_event 匹配仅统计 active 端点（停用不再收到事件）';

-- ---------------------------------------------------------------------------
-- 7. app.emit_event：全模块事件入口（规则 10，不 GRANT authenticated）
--    本期只入队 public.integration_events 并返回匹配的 active 订阅数；投递由 005 消费队列。
-- ---------------------------------------------------------------------------
create function app.emit_event(
  p_event   text,
  p_payload jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event   text := btrim(coalesce(p_event, ''));
  v_matched integer;
begin
  if v_event = '' then
    raise exception '事件名不能为空' using errcode = '22023';
  end if;

  if p_payload is not null and jsonb_typeof(p_payload) <> 'object' then
    raise exception 'payload 必须为 jsonb 对象' using errcode = '22023';
  end if;

  insert into public.integration_events (event, payload)
  values (v_event, coalesce(p_payload, '{}'::jsonb));

  select count(*) into v_matched
  from public.webhooks w
  where w.status = 'active'
    and v_event = any(w.events);

  return v_matched;
end;
$$;

comment on function app.emit_event(text, jsonb) is
  '事件发射入口（全模块，INDEX 规则 10）：插入 integration_events 队列并返回匹配的 active 订阅数；'
  '不 GRANT authenticated，各模块经自身 SECURITY DEFINER RPC 或后端 wrapper 调用；'
  '投递/重试/HMAC 签名由 005 投递器消费队列实现（ADR-001）';

-- ---------------------------------------------------------------------------
-- 8. public 薄包装（PostgREST 仅暴露 public schema；admin 校验在 app 实现内）
-- ---------------------------------------------------------------------------
create function public.create_webhook(
  p_name         text,
  p_url          text,
  p_events       text[],
  p_retry_policy jsonb default null,
  p_headers      jsonb default null
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.create_webhook(p_name, p_url, p_events, p_retry_policy, p_headers)
$$;

create function public.update_webhook(
  p_id           uuid,
  p_name         text,
  p_url          text,
  p_events       text[],
  p_retry_policy jsonb default null,
  p_headers      jsonb default null
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.update_webhook(p_id, p_name, p_url, p_events, p_retry_policy, p_headers)
$$;

create function public.disable_webhook(p_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.disable_webhook(p_id)
$$;

comment on function public.create_webhook(text, text, text[], jsonb, jsonb) is
  'create_webhook Data API 薄包装（admin 校验在 app 实现内；返回一次性 secret）';
comment on function public.update_webhook(uuid, text, text, text[], jsonb, jsonb) is
  'update_webhook Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.disable_webhook(uuid) is
  'disable_webhook Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 9. 授权：敏感表无表级写；管理 RPC 仅 authenticated（函数内 admin 校验）；
--    内部 helper / emit_event 不 GRANT API 角色（规则 4、10）
-- ---------------------------------------------------------------------------
revoke all on public.webhooks from public, anon, authenticated, service_role;
revoke all on public.integration_events from public, anon, authenticated, service_role;
grant select on public.webhooks to authenticated;
grant select on public.integration_events to authenticated;

revoke all on sequence public.integration_events_id_seq
  from public, anon, authenticated, service_role;

revoke all on function app.validate_webhook_fields(text, text, text[], jsonb, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function app.mask_jsonb_values(jsonb)
  from public, anon, authenticated, service_role;
revoke all on function app.emit_event(text, jsonb)
  from public, anon, authenticated, service_role;

revoke all on function app.create_webhook(text, text, text[], jsonb, jsonb) from public, anon;
grant execute on function app.create_webhook(text, text, text[], jsonb, jsonb) to authenticated;

revoke all on function app.update_webhook(uuid, text, text, text[], jsonb, jsonb) from public, anon;
grant execute on function app.update_webhook(uuid, text, text, text[], jsonb, jsonb) to authenticated;

revoke all on function app.disable_webhook(uuid) from public, anon;
grant execute on function app.disable_webhook(uuid) to authenticated;

revoke all on function public.create_webhook(text, text, text[], jsonb, jsonb) from public, anon;
grant execute on function public.create_webhook(text, text, text[], jsonb, jsonb) to authenticated;

revoke all on function public.update_webhook(uuid, text, text, text[], jsonb, jsonb) from public, anon;
grant execute on function public.update_webhook(uuid, text, text, text[], jsonb, jsonb) to authenticated;

revoke all on function public.disable_webhook(uuid) from public, anon;
grant execute on function public.disable_webhook(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 10. RLS：仅 admin SELECT；无 INSERT/UPDATE/DELETE 策略（写仅经 RPC，无策略=拒绝）
-- ---------------------------------------------------------------------------
create policy webhooks_select_admin
on public.webhooks
for select
to authenticated
using ((select app.current_role()) = 'admin');

create policy integration_events_select_admin
on public.integration_events
for select
to authenticated
using ((select app.current_role()) = 'admin');
