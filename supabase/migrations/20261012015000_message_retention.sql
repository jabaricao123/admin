-- 消息中心 · 站内信保留策略（message 批次 2 修复项 1）
-- 背景：messages 自 message/001 起只增不减；收件箱查询按 (recipient_id, created_at)
--   索引走，超期旧信对用户已无检索价值，且长期累积扩大敏感读写面。
-- 策略：已读（read_at 非空）且超过保留期（默认 12 个月）的站内信清理；
--   * 未读不清理（read_at 是未读唯一事实源，用户长期未登录也不能丢）；
--   * starred 豁免（用户主动收藏，视同显式保留意图）。
-- 调度：cron.schedule 每日 03:40 UTC + app.register_cron_job 登记（INDEX 规则 5）。
-- 授权：security invoker + 撤销 API 角色（同 app.cleanup_message_deliveries 先例，
--   仅 pg_cron / owner 可达）。
-- 依赖：20261003205454（messages）、20261005080000（register_cron_job）。

-- ---------------------------------------------------------------------------
-- 1. app.cleanup_messages：已读超期站内信清理（pg_cron 每日调用）
-- ---------------------------------------------------------------------------
create function app.cleanup_messages(p_retention_months integer default 12)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_months  integer := coalesce(p_retention_months, 12);
  v_deleted integer;
begin
  if v_months < 1 then
    raise exception '保留月数必须 >= 1：%', v_months using errcode = '22023';
  end if;

  -- 已读 + 非星标 + 超期；未读与 starred 永不清理（用户事实源 / 显式保留）
  delete from public.messages m
   where m.read_at is not null
     and not m.starred
     and m.created_at < now() - make_interval(months => v_months);

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

comment on function app.cleanup_messages(integer) is
  '站内信保留清理（默认 12 个月）：已读（read_at 非空）且超期的 messages 删除；'
  '未读保留（未读唯一事实源）、starred 豁免（用户收藏）；返回删除条数；'
  'security invoker + 撤销 API 角色执行权，仅 pg_cron 可达';

revoke all on function app.cleanup_messages(integer)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. pg_cron 登记：每日 03:40 UTC 清理
-- ---------------------------------------------------------------------------
select app.register_cron_job(
  'message-cleanup-inbox', 'message', '40 3 * * *', 'Asia/Shanghai', '/message/inbox'
);

do $$
begin
  if to_regprocedure('cron.schedule(text,text,text)') is null then
    raise exception 'pg_cron 未安装，无法注册站内信清理任务' using errcode = '0A000';
  end if;

  perform cron.schedule(
    'message-cleanup-inbox',
    '40 3 * * *',
    $cron$select app.cleanup_messages()$cron$
  );
end $$;
