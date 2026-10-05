-- 消息中心 · 发送限流（message 批次 2 修复项 2）
-- 背景：send_notification 是站内信唯一入口，任何模块循环/重试风暴都可能对同一收件人
--   瞬间灌入大量通知（业务放大路径：审批催办、公告批量、同步失败重试）。
-- 规则：
--   * 同一 recipient + 同一 event_key：1 分钟 ≤ 5 条（第 6 条拒绝）；
--   * 同一 recipient 全事件：1 小时 ≤ 50 条（第 51 条拒绝）；
--   * 超限抛 53400（PostgREST 映射 429 Too Many Requests），不写 messages。
-- 实现：
--   * app.check_notification_rate 独立函数：事务级 advisory lock（recipient 级命名空间）
--     串行化「计数 + 本轮写入」窗口（同事务重入放行，批量同 recipient 计数仍精确；
--     并发冲突立即 429，不阻塞排队——参照 sync/003 webhook 限流先例）；
--   * app.send_notification 基于批次 1 已落版本（20261012010000：dispatch 异常隔离）
--     追加限流调用（写库前，超限不产生任何行）。
-- 说明：计数依据 messages 行（写入唯一入口），窗口滑动；被拒请求不计数。
-- 依赖：20261012010000（send_notification 当前版）。

-- ---------------------------------------------------------------------------
-- 1. app.check_notification_rate：限流检查（超限 53400 / 429）
-- ---------------------------------------------------------------------------
create function app.check_notification_rate(
  p_recipient uuid,
  p_event_key text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event_recent integer;
  v_total_recent integer;
begin
  if p_recipient is null then
    raise exception '收件人不能为空' using errcode = '22023';
  end if;
  if p_event_key is null or btrim(p_event_key) = '' then
    raise exception 'event_key 不能为空' using errcode = '22023';
  end if;

  -- 原子化：同一 recipient 的「计数 + 本轮写入」串行化（事务级 advisory lock，
  -- 提交/回滚即释放）。同事务重入直接放行（批量同 recipient 多条计数仍精确）；
  -- 并发同 recipient 触发立即 429（53400）由调用方退避重试，不做阻塞排队。
  if not pg_try_advisory_xact_lock(hashtextextended('message-rate:' || p_recipient::text, 0)) then
    raise exception '通知发送并发过高，请稍后重试' using errcode = '53400';
  end if;

  -- 同 recipient + 同事件：1 分钟 ≤ 5 条（第 6 条拒绝）
  select count(*) into v_event_recent
  from public.messages m
  where m.recipient_id = p_recipient
    and m.event_key = p_event_key
    and m.created_at > now() - interval '1 minute';

  if v_event_recent >= 5 then
    raise exception '同一事件通知超过速率限制（5 条/分钟），请稍后重试'
      using errcode = '53400';
  end if;

  -- 同 recipient 全事件：1 小时 ≤ 50 条（第 51 条拒绝）
  select count(*) into v_total_recent
  from public.messages m
  where m.recipient_id = p_recipient
    and m.created_at > now() - interval '1 hour';

  if v_total_recent >= 50 then
    raise exception '通知发送超过速率限制（50 条/小时），请稍后重试'
      using errcode = '53400';
  end if;
end;
$$;

comment on function app.check_notification_rate(uuid, text) is
  '通知发送限流（send_notification 内调用）：同 recipient+event 1 分钟 ≤5 条、'
  '同 recipient 1 小时 ≤50 条；超限抛 53400（429）；recipient 级事务 advisory lock '
  '串行化计数窗口（并发冲突立即 429）；被拒请求不计数；不 GRANT API 角色';

revoke all on function app.check_notification_rate(uuid, text)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. app.send_notification：写库前追加限流检查（基于批次 1 已落版本）
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

  -- 限流（批次 2 修复项 2）：超限 53400（429）直接拒绝，不写 messages；
  -- advisory lock 覆盖「计数 + 本事务后续写入」窗口（同事务重入放行）。
  perform app.check_notification_rate(p_recipient, p_event_key);

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
  '通知发送唯一入口（INDEX 规则 3）：先经 app.check_notification_rate 限流（同事件 5 条/分钟、'
  '同 recipient 50 条/小时，超限 53400/429 不写库）；按 (event_key,''inbox'') 当前 published 模板渲染，'
  '缺变量保留占位符；无模板走 vars fallback；写 messages 后经 app.dispatch_message_channels '
  '分发 email/push/sms（渠道缺失自动降级，站内信必达）。'
  'dispatch 结构型异常整体隔离：降级写 audit（message/dispatch_degraded）+ warning，不影响 messages 落库。'
  '不 GRANT API 角色，仅 SECURITY DEFINER wrapper 调用';
