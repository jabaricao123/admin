-- 消息中心 M0 补齐（工单 message/003 的 RPC 部分）：已读回退 mark_notification_unread
-- 契约：message/inbox.md 验收「已读回退（标未读）可用」；
--       INDEX 规则 10（内部 RPC 不 GRANT authenticated，Data API 走 public 薄包装）。
-- 说明：
--   * app.mark_notification_unread 是唯一实现，属主校验 auth.uid() = recipient_id；
--   * public.mark_notification_unread 是 Data API 薄包装（config.toml schemas 仅 public/graphql_public）；
--   * 错误约定与 mark_notification_read 对齐：不存在/无权一律 42501「消息不存在或无权操作」；
--   * 幂等：对未读行重复调用不报错，read_at 保持 null。

-- ---------------------------------------------------------------------------
-- 1. app.mark_notification_unread：已读回退唯一实现
-- ---------------------------------------------------------------------------
create function app.mark_notification_unread(p_id bigint)
returns public.messages
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.messages;
begin
  update public.messages
     set read_at = null
   where id = p_id
     and recipient_id = (select auth.uid())
  returning * into v_row;

  if v_row.id is null then
    raise exception '消息不存在或无权操作' using errcode = '42501';
  end if;

  return v_row;
end;
$$;

comment on function app.mark_notification_unread(bigint) is
  '本人单条消息回退未读（read_at 置 null，幂等）；越权/不存在报 42501；公开调用走 public 薄包装';

-- 不 GRANT API 角色（INDEX 规则 10）：仅函数属主与 public 薄包装可调
revoke all on function app.mark_notification_unread(bigint) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. public 薄包装（GRANT authenticated）
-- ---------------------------------------------------------------------------
create function public.mark_notification_unread(p_id bigint)
returns public.messages
language sql
security definer
set search_path = ''
as $$
  select app.mark_notification_unread(p_id)
$$;

comment on function public.mark_notification_unread(bigint) is
  '标记本人单条消息未读（已读回退）；security definer 内部经 app 实现校验 recipient = auth.uid()';

revoke all on function public.mark_notification_unread(bigint) from public, anon;
grant execute on function public.mark_notification_unread(bigint) to authenticated;
