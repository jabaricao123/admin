-- 消息中心 · 批次 1 修复（deliveries 幂等语义 + send_notification 分发异常隔离）
-- 1. app.dispatch_message_channels：写 deliveries 的 created_at 由 now() 改为 messages.created_at
--    确定值——(idempotency_key, created_at) 唯一约束对同 message 同渠道重放真正生效
--    （旧实现 created_at=now() 每次不同，重复插入绕开唯一约束）；
--    重发 app.resend_delivery 保持原行更新语义（不新增行、幂等键与 created_at 不变）。
-- 2. app.send_notification：dispatch 调用包 begin/exception——结构型异常（如分区缺失）不再拖垮站内信：
--    messages 落库后捕获异常 → 降级写 audit（message/dispatch_degraded）+ warning；
--    audit 自身失败也静默（保证「站内信必达」覆盖结构型异常）。
-- 依赖：20261005090000（当前版 send_notification / dispatch_message_channels）。

-- ---------------------------------------------------------------------------
-- 1. app.dispatch_message_channels：created_at 取 messages.created_at 确定值（真幂等）
-- ---------------------------------------------------------------------------
create or replace function app.dispatch_message_channels(
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

  -- 1) 站内信：必达渠道（messages 行即站内信），成功快照 = 渲染后标题/正文。
  --    created_at 取 messages.created_at 确定值（非 now()）：同 message 同渠道重放时
  --    (idempotency_key, created_at) 唯一约束必然命中 → do nothing，真正幂等。
  insert into public.message_deliveries (
    message_id, recipient_id, event_key, channel, status,
    rendered_subject, rendered_body, idempotency_key, created_at
  )
  values (
    v_msg.id, v_msg.recipient_id, v_msg.event_key, 'inbox', 'success',
    v_msg.title, v_msg.body, v_msg.id::text || ':inbox', v_msg.created_at
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
      rendered_subject, rendered_body, idempotency_key, attempts, created_at
    )
    values (
      v_msg.id, v_msg.recipient_id, v_msg.event_key, v_channel.channel,
      v_result ->> 'status', v_result ->> 'error', v_result ->> 'response',
      v_subject, v_body, v_msg.id::text || ':' || v_channel.channel, 1, v_msg.created_at
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
  '幂等键 = message_id || '':'' || channel，created_at = messages.created_at 确定值（重放必冲突不重复插入）；'
  '返回外部渠道尝试数；不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 2. app.send_notification：dispatch 异常隔离（降级 audit + warning，messages 必达）
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
  -- 渠道未配置/停用自动降级为 degraded，不报错、不影响站内信）。
  -- 批次 1 修复：dispatch 整体包异常隔离——结构型异常（deliveries 分区缺失、模板/分发内部错误等）
  -- 只降级为 audit 留痕（message/dispatch_degraded）+ warning，绝不让已落库的站内信回滚；
  -- 留痕自身失败也静默（保证「站内信必达」覆盖异常链路）。
  begin
    perform app.dispatch_message_channels(v_id, v_vars);
  exception when others then
    begin
      perform app.audit_log(
        'message',
        'dispatch_degraded',
        'message',
        v_id::text,
        jsonb_build_object(
          'recipient_id', p_recipient,
          'event_key', p_event_key,
          'sqlstate', sqlstate,
          'error', sqlerrm
        )
      );
    exception when others then
      null; -- 留痕失败也不拖垮站内信
    end;
    raise warning '消息 % 渠道分发降级（站内信已落库）：%', v_id, sqlerrm;
  end;

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
  '分发 email/push/sms（渠道缺失自动降级，站内信必达）。'
  'dispatch 结构型异常整体隔离：降级写 audit（message/dispatch_degraded）+ warning，不影响 messages 落库。'
  '不 GRANT API 角色，仅 SECURITY DEFINER wrapper 调用';
