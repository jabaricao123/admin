-- 消息中心 · 渠道分发改走 get_service_config（system 批次 2 修复项 2）
-- 背景：app.attempt_channel_delivery（message/009，20261005090000 版）直读 public.system_services
--   并自行调 app.decrypt_secret；与 system/001 规则 10「凭据读取只经白名单读取口」不符，
--   且解密失败无统一可读错误。
-- 本迁移：create or replace app.attempt_channel_delivery——配置与凭据统一经
--   app.get_service_config(v_service) 取回（config + credentials 明文 + verify_status），
--   函数体不再直读 system_services、不再直接解密；降级/失败语义保持不变：
--   * 服务未配置 / 未验证 / 无 relay_api_url → degraded（自动降级为站内信，不报错）；
--   * 凭据解密失败（get_service_config raise）→ degraded 并在 error 标注可读原因
--     （渠道不可用，非投递失败；留痕可见，不静默）；
--   * pg_net 入队异常 / 收件人邮箱缺失 → failed（可重发）。
-- 依赖：system/001 + 20261011010000（get_service_config 返回 verify_status 与可读解密错误）、
--       message/007+008（message_deliveries）、20261004235500（pg_net）。

create or replace function app.attempt_channel_delivery(
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
  v_cfg     jsonb;
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

  -- 白名单读取口（INDEX 规则 10）：一次取回 config + credentials 明文 + verify_status；
  -- 本函数不再直读服务配置表、不再直接解密（密钥轮换容错口径归口 get_service_config）。
  begin
    v_cfg := app.get_service_config(v_service);
  exception when others then
    return jsonb_build_object(
      'status', 'degraded',
      'error', format('%s配置读取失败：%s，自动降级为站内信', v_label, sqlerrm),
      'response', null
    );
  end;

  -- 未配置：自动降级为站内信（不报错、不重试、不产生 failed 噪音）
  if v_cfg is null then
    return jsonb_build_object(
      'status', 'degraded',
      'error', format('%s服务未配置，自动降级为站内信', v_label),
      'response', null
    );
  end if;

  -- 未验证（草稿 / 最近验证失败）：同样自动降级
  if v_cfg ->> 'verify_status' <> 'verified' then
    return jsonb_build_object(
      'status', 'degraded',
      'error', format(
        '%s服务未验证（%s），自动降级为站内信',
        v_label,
        coalesce(v_cfg ->> 'verify_status', 'unverified')
      ),
      'response', null
    );
  end if;

  v_relay := nullif(btrim(coalesce(v_cfg ->> 'relay_api_url', '')), '');

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

  -- relay 凭据（可选）：明文以 Bearer 头附带；未配置则仅 Content-Type
  v_token := v_cfg ->> 'credentials';
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
  '单渠道投递尝试（内部 helper）：配置/凭据统一经 app.get_service_config 白名单读取口；'
  '邮箱渠道经 relay_api_url pg_net 异步 POST；服务未配置 / 未验证 / 无 relay_api_url → degraded'
  '（自动降级不报错）；凭据解密失败 → degraded 并标注可读原因；pg_net 入队异常 → failed（可重发）；'
  '返回 {status, error, response}；不 GRANT API 角色'
