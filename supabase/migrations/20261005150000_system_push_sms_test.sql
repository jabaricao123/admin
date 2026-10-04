-- 系统管理 · 消息推送 / 短信服务配置（工单 system/004 + system/005 后端）
-- 契约：docs/modules/system/services-push.md（双渠道 webhook + secret 掩码 + 各渠道测试）；
--       docs/modules/system/services-sms.md（provider/access_key_id/secret/sign_name + 通道开关 +
--       启用后测试短信）；docs/modules/INDEX.md 规则 4（凭据 pgcrypto 加密 + 界面掩码）、
--       规则 10（内部 RPC 不 GRANT authenticated）。
--
-- 组成：
--   1. app.get_push_status / public.get_push_status：推送配置脱敏读取（admin）——
--      push 为双渠道（wecom 企业微信 / dingtalk 钉钉），config 存每渠道 webhook_url + enabled，
--      credentials 存加密的每渠道 secret JSON（{"wecom":"...","dingtalk":"..."}），
--      本 RPC 在函数内解密并仅返回「**** + 尾 4 位」掩码，不下发明文/密文；
--   2. app.upsert_push_channel / public.upsert_push_channel：单渠道保存（admin）——
--      读取现有密文 → 合并本渠道 config 与 secret → 复用 app.upsert_service_config 加密落库
--      （验证状态机与审计沿用 system/001/002 契约）；p_secret IS NULL = 不修改（保留原值），
--      空串 = 清除该渠道 secret；启用渠道前 webhook_url 必填（防置灰渠道误开）；
--   3. app.test_push_config / public.test_push_config：推送渠道「测试推送」（admin）——
--      本期不做真实出站（webhook 投递待通道接入），校验渠道配置完整性并经
--      app.mark_service_verified 回写：完整 → verified，缺失 → failed；
--   4. app.test_sms_config / public.test_sms_config：短信「测试发送」（admin）——
--      通道未启用时报 22023（状态不变，页面按钮同步禁用）；启用后校验
--      phone/provider/access_key_id/sign_name/secret 完整性 → verified / failed；
--      p_phone 仅记录于审计备注，不落凭据明文。
--
-- 说明：message/009 渠道分发（app.attempt_channel_delivery）对 push/sms 的降级判定
--   依赖 verify_status=verified + config.relay_api_url；本期尚未配置 relay_api_url，
--   分发自动降级为站内信（best-effort），不影响本页配置与测试语义。
--
-- 依赖：system/001（20261004151000_system_services.sql）、system/002（20261004161000，upsert 保留语义）。

-- ---------------------------------------------------------------------------
-- 1. app.get_push_status：推送双渠道脱敏读取（admin）
-- ---------------------------------------------------------------------------
create function app.get_push_status()
returns table (
  channel       text,
  webhook_url   text,
  enabled       boolean,
  secret_masked text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row     public.system_services;
  v_secrets jsonb := '{}'::jsonb;
  v_channel text;
  v_items   text[] := array['wecom', 'dingtalk'];
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.system_services s
  where s.service = 'push';

  if found and v_row.credentials is not null then
    -- 凭据为每渠道 secret 的加密 JSON；解析失败按「未配置」处理（不因脏数据阻断页面）
    begin
      v_secrets := coalesce(
        nullif(app.decrypt_secret(v_row.credentials), '')::jsonb,
        '{}'::jsonb
      );
    exception when others then
      v_secrets := '{}'::jsonb;
    end;
  end if;

  foreach v_channel in array v_items loop
    channel       := v_channel;
    webhook_url   := nullif(btrim(v_row.config -> v_channel ->> 'webhook_url'), '');
    enabled       := coalesce(
                       (v_row.config -> v_channel -> 'enabled') = 'true'::jsonb,
                       false
                     );
    secret_masked := case
                       when v_secrets ->> v_channel is null
                            or btrim(v_secrets ->> v_channel) = ''
                       then null
                       else '****' || right(v_secrets ->> v_channel, 4)
                     end;
    return next;
  end loop;
end;
$$;

comment on function app.get_push_status() is
  '推送配置脱敏读取 RPC（admin）：返回 wecom/dingtalk 双渠道 webhook_url、enabled 与 '
  'secret 掩码（**** + 明文尾 4 位）；密文在函数内解密、明文不出函数；行不存在时返回两行空配置';

-- ---------------------------------------------------------------------------
-- 2. app.upsert_push_channel：单渠道保存（admin；合并写入，不互相覆盖）
-- ---------------------------------------------------------------------------
create function app.upsert_push_channel(
  p_channel     text,
  p_webhook_url text,
  p_secret      text,
  p_enabled     boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_channel text := lower(btrim(p_channel));
  v_url     text := nullif(btrim(p_webhook_url), '');
  v_enabled boolean := coalesce(p_enabled, false);
  v_prev    public.system_services;
  v_config  jsonb;
  v_secrets jsonb := '{}'::jsonb;
  v_creds   text;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if v_channel is null or v_channel not in ('wecom', 'dingtalk') then
    raise exception '未知推送渠道：%', coalesce(p_channel, '(null)') using errcode = '22023';
  end if;

  if v_enabled and v_url is null then
    raise exception '启用推送渠道前请先填写 Webhook URL' using errcode = '22023';
  end if;

  select * into v_prev
  from public.system_services s
  where s.service = 'push'
  for update;

  -- 现有渠道配置与凭据合并（保留另一渠道的既有值）
  v_config := coalesce(v_prev.config, '{}'::jsonb)
              || jsonb_build_object(
                   v_channel,
                   jsonb_build_object('webhook_url', v_url, 'enabled', v_enabled)
                 );

  if v_prev.credentials is not null then
    begin
      v_secrets := coalesce(
        nullif(app.decrypt_secret(v_prev.credentials), '')::jsonb,
        '{}'::jsonb
      );
    exception when others then
      v_secrets := '{}'::jsonb;
    end;
  end if;

  -- p_secret IS NULL = 不修改（保留原值）；'' = 清除；非空 = 设置新值
  if p_secret is not null then
    v_secrets := jsonb_set(v_secrets, array[v_channel], to_jsonb(btrim(p_secret)));
  end if;

  -- 从未有凭据且仍为空 → null（与 system/001 新建语义一致）；否则持久化合并后的 JSON
  v_creds := case
               when v_secrets = '{}'::jsonb and v_prev.credentials is null then null
               else v_secrets::text
             end;

  return app.upsert_service_config('push', v_config, v_creds)
         || jsonb_build_object('channel', v_channel);
end;
$$;

comment on function app.upsert_push_channel(text, text, text, boolean) is
  '推送单渠道保存 RPC（admin）：webhook_url/enabled 合并进 config，secret 合并进加密凭据 JSON；'
  'p_secret 为 NULL 表示不修改、空串表示清除、非空表示设置；'
  '启用渠道前 webhook_url 必填；复用 upsert_service_config（加密、验证状态机、审计）';

-- ---------------------------------------------------------------------------
-- 3. app.test_push_config：推送渠道测试（admin；本期为配置完整性校验）
-- ---------------------------------------------------------------------------
create function app.test_push_config(p_channel text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_channel   text := lower(btrim(p_channel));
  v_row       public.system_services;
  v_webhook   text;
  v_enabled   boolean;
  v_ok        boolean;
  v_message   text;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if v_channel is null or v_channel not in ('wecom', 'dingtalk') then
    raise exception '未知推送渠道：%', coalesce(p_channel, '(null)') using errcode = '22023';
  end if;

  select * into v_row
  from public.system_services s
  where s.service = 'push';

  if not found then
    raise exception '推送配置不存在，请先保存配置' using errcode = 'P0002';
  end if;

  v_webhook := nullif(btrim(v_row.config -> v_channel ->> 'webhook_url'), '');
  v_enabled := coalesce((v_row.config -> v_channel -> 'enabled') = 'true'::jsonb, false);

  if v_webhook is null then
    v_ok      := false;
    v_message := '配置不完整：Webhook URL 为必填';
  elsif v_webhook !~* '^https?://' then
    v_ok      := false;
    v_message := 'Webhook URL 需以 http:// 或 https:// 开头';
  elsif not v_enabled then
    v_ok      := false;
    v_message := '渠道未启用：请先打开渠道开关再测试';
  else
    v_ok      := true;
    v_message := '配置校验通过（真实推送待 Webhook 通道接入后启用）';
  end if;

  return app.mark_service_verified(
           'push',
           v_ok,
           format('测试推送渠道：%s；%s', v_channel, v_message)
         )
         || jsonb_build_object('ok', v_ok, 'message', v_message, 'channel', v_channel);
end;
$$;

comment on function app.test_push_config(text) is
  '推送渠道测试 RPC（admin）：校验 Webhook URL 完整性与渠道启用状态并经 app.mark_service_verified 回写；'
  '本期不做真实出站（Webhook 投递待通道接入），返回 {ok, message, channel, verify_status, verified_at}';

-- ---------------------------------------------------------------------------
-- 4. app.test_sms_config：短信测试（admin；通道未启用报 22023 且不改状态）
-- ---------------------------------------------------------------------------
create function app.test_sms_config(p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_phone    text := btrim(p_phone);
  v_row      public.system_services;
  v_enabled  boolean;
  v_provider text;
  v_key_id   text;
  v_sign     text;
  v_ok       boolean;
  v_message  text;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if v_phone is null or v_phone = '' then
    raise exception '测试手机号不能为空' using errcode = '22023';
  end if;

  if v_phone !~ '^\+?[0-9]{5,20}$' then
    raise exception '测试手机号格式不正确' using errcode = '22023';
  end if;

  select * into v_row
  from public.system_services s
  where s.service = 'sms';

  if not found then
    raise exception '短信配置不存在，请先保存配置' using errcode = 'P0002';
  end if;

  v_enabled := coalesce((v_row.config -> 'enabled') = 'true'::jsonb, false);
  if not v_enabled then
    -- 通道停用为业务前置而非配置错误：报错但不改变验证状态（services-sms.md 功能需求 3/4）
    raise exception '短信通道未启用，请先开启通道后再测试' using errcode = '22023';
  end if;

  v_provider := nullif(btrim(v_row.config ->> 'provider'), '');
  v_key_id   := nullif(btrim(v_row.config ->> 'access_key_id'), '');
  v_sign     := nullif(btrim(v_row.config ->> 'sign_name'), '');

  if v_provider is null or v_key_id is null or v_sign is null
     or v_row.credentials is null then
    v_ok      := false;
    v_message := '配置不完整：provider / access_key_id / sign_name / AccessKey Secret 均为必填';
  elsif v_provider not in ('aliyun', 'tencent') then
    v_ok      := false;
    v_message := format('未知短信服务商：%s（支持 aliyun / tencent）', v_provider);
  else
    v_ok      := true;
    v_message := '配置校验通过（真实短信发送待商业化启用后接入）';
  end if;

  return app.mark_service_verified(
           'sms',
           v_ok,
           format('测试手机号：%s；%s', v_phone, v_message)
         )
         || jsonb_build_object('ok', v_ok, 'message', v_message);
end;
$$;

comment on function app.test_sms_config(text) is
  '短信测试 RPC（admin）：通道未启用 → 22023（状态不变）；启用后校验 provider/access_key_id/'
  'sign_name/凭据完整性并经 app.mark_service_verified 回写；p_phone 仅记录于审计备注；'
  '返回 {ok, message, verify_status, verified_at}';

-- ---------------------------------------------------------------------------
-- 5. public 薄包装（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.get_push_status()
returns table (
  channel       text,
  webhook_url   text,
  enabled       boolean,
  secret_masked text
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.get_push_status()
$$;

create function public.upsert_push_channel(
  p_channel     text,
  p_webhook_url text,
  p_secret      text,
  p_enabled     boolean
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.upsert_push_channel(p_channel, p_webhook_url, p_secret, p_enabled)
$$;

create function public.test_push_config(p_channel text)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.test_push_config(p_channel)
$$;

create function public.test_sms_config(p_phone text)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.test_sms_config(p_phone)
$$;

comment on function public.get_push_status() is
  'get_push_status Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.upsert_push_channel(text, text, text, boolean) is
  'upsert_push_channel Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.test_push_config(text) is
  'test_push_config Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.test_sms_config(text) is
  'test_sms_config Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 6. 授权：管理/测试 RPC 仅 authenticated（函数内 admin 校验）；anon/service_role 无路径
-- ---------------------------------------------------------------------------
revoke all on function app.get_push_status() from public, anon, service_role;
revoke all on function app.upsert_push_channel(text, text, text, boolean) from public, anon, service_role;
revoke all on function app.test_push_config(text) from public, anon, service_role;
revoke all on function app.test_sms_config(text) from public, anon, service_role;

revoke all on function public.get_push_status() from public, anon, service_role;
revoke all on function public.upsert_push_channel(text, text, text, boolean) from public, anon, service_role;
revoke all on function public.test_push_config(text) from public, anon, service_role;
revoke all on function public.test_sms_config(text) from public, anon, service_role;

grant execute on function app.get_push_status() to authenticated;
grant execute on function app.upsert_push_channel(text, text, text, boolean) to authenticated;
grant execute on function app.test_push_config(text) to authenticated;
grant execute on function app.test_sms_config(text) to authenticated;

grant execute on function public.get_push_status() to authenticated;
grant execute on function public.upsert_push_channel(text, text, text, boolean) to authenticated;
grant execute on function public.test_push_config(text) to authenticated;
grant execute on function public.test_sms_config(text) to authenticated;
