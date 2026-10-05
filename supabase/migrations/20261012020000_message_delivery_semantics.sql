-- 消息中心 · 出站投递语义修正 + 重发明细留痕（message 批次 2 修复项 3 + 批次 4 并入项 1）
-- 契约：docs/modules/message/history.md（投递状态与重发）。
-- 背景：
--   1. app.attempt_channel_delivery 对 pg_net 异步 POST 入队成功即记 status='success'，
--      但 pg_net 只是「请求已入队」，真实发送结果（SMTP/推送器回执）尚未知，把入队
--      当成功会让 /message/history 误导「已送达」。本迁移引入 status='queued'：
--        * queued = pg_net 入队成功，真实结果待 Edge Function 投递器回写（ADR-001）；
--        * inbox 站内信仍为 success（写 messages 即送达，同步必达）；
--        * degraded / failed 语义不变；
--        * 历史 email/push/sms 的 success 行保留不动（迁移前「入队成功」的历史口径，
--          不回溯改标，避免审计口径二次变更）。
--   2. app.resend_delivery 原先只允许 status='failed'；补充「queued 超过 10 分钟视为
--      卡死」可重发（投递器未回写、请求丢失时人工兜底），未超时拒绝（避免重复入队）。
--   3. 批次 4 并入：message_delivery_attempts 明细表（append-only）——每次重发写入
--      attempt_no/status/response/error，补齐「中间失败详情」的可追溯性（重发更新原行
--      会覆盖上一次结果，单靠 message_deliveries 行看不到历史尝试链）。
-- 依赖：20261005090000（message_deliveries / resend_delivery）、
--       20261011020000（attempt_channel_delivery 最新版：get_service_config 白名单读取）、
--       20261004235500（pg_net）。

-- ---------------------------------------------------------------------------
-- 1. status check 约束扩展：queued（异步出站已入队）
-- ---------------------------------------------------------------------------
alter table public.message_deliveries
  drop constraint message_deliveries_status_check;

alter table public.message_deliveries
  add constraint message_deliveries_status_check
  check (status in ('success', 'failed', 'degraded', 'queued'));

comment on column public.message_deliveries.status is
  '投递状态：success 成功（inbox 写库即送达）/ queued 已入队（pg_net 异步投递，'
  '真实结果待投递器回写）/ failed 失败（可重发）/ degraded 降级（渠道停用或未配置，非失败噪音）；'
  '历史 email/push/sms 的 success 行为迁移前「入队成功」口径，保留不动';

-- ---------------------------------------------------------------------------
-- 2. app.attempt_channel_delivery：pg_net 入队成功记 queued（不再记 success）
-- ---------------------------------------------------------------------------
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

  -- 入队成功 ≠ 送达成功：pg_net 只保证请求已入队，真实结果（SMTP/推送器回执）
  -- 由 Edge Function 投递器异步回写 delivery 行（ADR-001）；此处如实记 queued。
  return jsonb_build_object(
    'status', 'queued',
    'error', null,
    'response', format('pg_net request #%s（已入队异步投递，真实结果待投递器回写）', v_request)
  );
end;
$$;

comment on function app.attempt_channel_delivery(text, uuid, text, text) is
  '单渠道投递尝试（内部 helper）：配置/凭据统一经 app.get_service_config 白名单读取口；'
  '邮箱渠道经 relay_api_url pg_net 异步 POST；服务未配置 / 未验证 / 无 relay_api_url → degraded'
  '（自动降级不报错）；凭据解密失败 → degraded 并标注可读原因；pg_net 入队成功 → queued'
  '（真实结果待投递器回写，不再记 success）；pg_net 入队异常 → failed（可重发）；'
  '返回 {status, error, response}；不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 3. message_delivery_attempts：重发尝试明细（append-only）
-- ---------------------------------------------------------------------------
create table public.message_delivery_attempts (
  id           bigint generated always as identity primary key,
  -- 弱引用 message_deliveries.id：分区表保留期到期整分区 DROP，硬 FK 会阻碍分区 DDL；
  -- 明细随 delivery 同保留期清理（见 app.cleanup_message_deliveries）。
  delivery_id  bigint not null,
  attempt_no   integer not null
               constraint message_delivery_attempts_attempt_no_check check (attempt_no >= 1),
  status       text not null
               constraint message_delivery_attempts_status_check
               check (status in ('success', 'failed', 'degraded', 'queued')),
  response     text,
  error        text,
  attempted_at timestamptz not null default now()
);

comment on table public.message_delivery_attempts is
  '重发尝试明细（append-only）：app.resend_delivery 每次重发写一行，保留被原行覆盖的'
  '中间失败详情；delivery_id 弱引用 message_deliveries.id（无硬 FK，分区回收不牵连），'
  '明细与投递同保留期清理；写入唯一入口 app.resend_delivery';
comment on column public.message_delivery_attempts.delivery_id is
  '关联 message_deliveries.id（弱引用：分区 drop 后可能残留孤儿行直到同保留期清理）';
comment on column public.message_delivery_attempts.attempt_no is
  '尝试序号（与 message_deliveries.attempts 对齐：首投=1，第 N 次重发=N+1）';
comment on column public.message_delivery_attempts.status is
  '本次尝试结果：queued 入队 / success / failed / degraded（同 delivery 状态枚举）';
comment on column public.message_delivery_attempts.attempted_at is '尝试时间（保留期清理依据）';

create index message_delivery_attempts_delivery_idx
  on public.message_delivery_attempts (delivery_id, attempted_at desc);

create index message_delivery_attempts_attempted_at_idx
  on public.message_delivery_attempts (attempted_at);

revoke all on public.message_delivery_attempts from public, anon, authenticated, service_role;
grant select on public.message_delivery_attempts to authenticated;
revoke all on sequence public.message_delivery_attempts_id_seq
  from public, anon, authenticated, service_role;

alter table public.message_delivery_attempts enable row level security;

-- admin 全量（排查重发链）；本人经 delivery 关联只读自己的尝试明细
create policy message_delivery_attempts_select_admin
on public.message_delivery_attempts
for select
to authenticated
using ((select app.current_role()) = 'admin');

create policy message_delivery_attempts_select_own
on public.message_delivery_attempts
for select
to authenticated
using (
  exists (
    select 1
    from public.message_deliveries d
    where d.id = delivery_id
      and d.recipient_id = (select auth.uid())
  )
);

-- ---------------------------------------------------------------------------
-- 4. app.resend_delivery：failed + queued 超时可重发；写尝试明细
-- ---------------------------------------------------------------------------
create or replace function app.resend_delivery(p_delivery_id bigint)
returns public.message_deliveries
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- queued 卡死判定：投递器应在分钟级回写；超过 10 分钟视为请求丢失，可人工重发
  c_queue_stuck constant interval := interval '10 minutes';
  v_row         public.message_deliveries;
  v_result      jsonb;
  v_attempt_no  integer;
  v_status      text;
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

  if v_row.status = 'queued' then
    if v_row.created_at > now() - c_queue_stuck then
      raise exception '投递已入队（queued）未满 10 分钟，等待投递器回执后再重发（入队时间：%）',
        v_row.created_at using errcode = '22023';
    end if;
  elsif v_row.status <> 'failed' then
    raise exception '仅失败或排队超时记录可重发（当前状态：%）', v_row.status
      using errcode = '22023';
  end if;

  -- 重发沿用原渲染快照（vars 未持久化；快照即用户实际应收到的内容）
  v_result := app.attempt_channel_delivery(
    v_row.channel, v_row.recipient_id, v_row.rendered_subject, v_row.rendered_body
  );
  v_status     := coalesce(v_result ->> 'status', 'failed');
  v_attempt_no := v_row.attempts + 1;

  update public.message_deliveries
     set status   = v_status,
         error    = v_result ->> 'error',
         response = v_result ->> 'response',
         attempts = v_attempt_no
   where id = v_row.id
  returning * into v_row;

  -- append-only 明细：原行只保留最后一次结果，本次尝试留痕（批次 4：中间失败详情可追溯）
  insert into public.message_delivery_attempts
    (delivery_id, attempt_no, status, response, error)
  values
    (v_row.id, v_attempt_no, v_status, v_result ->> 'response', v_result ->> 'error');

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
  '失败投递重发（admin）：status=failed 或 queued 超过 10 分钟（视为卡死）可重发；'
  'queued 未超时拒绝（避免重复入队）；重发调用 attempt_channel_delivery——入队成功记 queued；'
  '更新原行（status/error/response 重算，attempts+1）并写 message_delivery_attempts 明细'
  '（append-only）；幂等键与 created_at 不变；写审计摘要';

comment on function public.resend_delivery(bigint) is
  'resend_delivery Data API 薄包装（admin 校验在 app 实现内；failed / queued 超时均可重发）';

-- ---------------------------------------------------------------------------
-- 5. 授权：明细表写仅经函数；attempt_channel_delivery 不 GRANT（保持原状，显式再收口）
-- ---------------------------------------------------------------------------
revoke all on function app.attempt_channel_delivery(text, uuid, text, text)
  from public, anon, authenticated, service_role;
