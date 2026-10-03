-- 消息中心 M0 底座（工单 message/001+002）：messages 表 + send_notification + 公开 RPC + RLS
-- 契约：INDEX 规则 2（审计摘要统一入口，audit/001 软依赖）、3（通知发送单通道）、10（内部 RPC 不 GRANT authenticated）。
-- 说明：
--   * message/005 前无 message_templates 表，文案渲染为 vars fallback（title/body 取 p_vars，缺省用 event_key/空串）；
--   * 公开 RPC 放 public schema：app schema 不在 Data API 暴露面（config.toml schemas 仅 public/graphql_public），
--     客户端 supabase-js rpc() 只能调用 public schema 函数（与 admin_update_profile 先例一致）；
--   * 渠道分发（邮件/推送/短信）与 message_deliveries 不在本期（message/007+009）。

-- ---------------------------------------------------------------------------
-- 1. messages 表（收件箱，写入唯一入口 app.send_notification）
-- ---------------------------------------------------------------------------
create table public.messages (
  id            bigint generated always as identity primary key,
  recipient_id  uuid not null references public.profiles (id) on delete cascade,
  event_key     text not null,
  title         text not null,
  body          text not null,
  source_module text,
  ref_type      text,
  ref_id        text,
  read_at       timestamptz,
  starred       boolean not null default false,
  created_at    timestamptz not null default now()
);

comment on table public.messages is '站内信收件箱；写入唯一入口 app.send_notification，用户操作经公开 RPC';
comment on column public.messages.event_key is '事件 key（约定 module.event，如 approval.approved）；fallback 文案与 source_module 推断依据';
comment on column public.messages.read_at is '首次已读时间；null=未读（未读唯一事实源）';
comment on column public.messages.starred is '星标态，经 toggle_notification_star RPC 切换';

create index messages_recipient_created_idx
  on public.messages (recipient_id, created_at desc);

create index messages_recipient_unread_idx
  on public.messages (recipient_id, read_at)
  where read_at is null;

-- ---------------------------------------------------------------------------
-- 2. 表级权限与 RLS（敏感表二分：无任何角色表级写，写仅经 SECURITY DEFINER RPC）
-- ---------------------------------------------------------------------------
revoke all on public.messages from anon, authenticated, service_role;
grant select on public.messages to authenticated;

-- identity 序列不暴露给 API 角色（与 audit/001 一致）
revoke all on sequence public.messages_id_seq from public, anon, authenticated, service_role;

alter table public.messages enable row level security;

-- 本人只读自己的行；写权限不授予任何 API 角色（RPC 内再做属主校验）
create policy messages_select_own
on public.messages
for select
to authenticated
using ((select auth.uid()) = recipient_id);

-- ---------------------------------------------------------------------------
-- 3. 内部写入 RPC：send_notification（全模块通知单通道，INDEX 规则 3）
-- ---------------------------------------------------------------------------
create function app.send_notification(
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
begin
  if p_recipient is null then
    raise exception '收件人不能为空' using errcode = '22023';
  end if;
  if p_event_key is null or btrim(p_event_key) = '' then
    raise exception 'event_key 不能为空' using errcode = '22023';
  end if;

  -- message/005 前无模板表：fallback 取 vars 直传文案；vars 骨架与模板变量对齐
  v_title := coalesce(nullif(v_vars ->> 'title', ''), p_event_key);
  v_body  := coalesce(v_vars ->> 'body', '');
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

  -- 审计摘要：audit/001 并行开发中，用 to_regprocedure 软依赖（未合入则跳过，合入后自动生效）。
  -- 落点兼容 app/public 两种可能，audit/001 合入后由后续工单收敛为单一路径。
  if to_regprocedure('app.audit_log(text,text,text,text,jsonb)') is not null then
    perform app.audit_log(
      'message',
      'send_notification',
      'message',
      v_id::text,
      jsonb_build_object('recipient_id', p_recipient, 'event_key', p_event_key)
    );
  elsif to_regprocedure('public.audit_log(text,text,text,text,jsonb)') is not null then
    perform public.audit_log(
      'message',
      'send_notification',
      'message',
      v_id::text,
      jsonb_build_object('recipient_id', p_recipient, 'event_key', p_event_key)
    );
  end if;

  return v_id;
end;
$$;

comment on function app.send_notification(uuid, text, jsonb) is
  '通知发送唯一入口（INDEX 规则 3）；本期 fallback 渲染，message/005 起查模板。不 GRANT API 角色，仅 SECURITY DEFINER wrapper 调用';

-- 不 GRANT authenticated/anon（INDEX 规则 10）；revoke PUBLIC 后仅函数属主（postgres）可执行，
-- 即各模块的 SECURITY DEFINER wrapper（同属主）天然可调；专用后端角色落地后再在此显式 GRANT。
revoke all on function app.send_notification(uuid, text, jsonb)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. 公开 RPC（收件箱 / sidebar / dashboard 消费；GRANT authenticated）
-- ---------------------------------------------------------------------------
create function public.recent_notifications(p_limit int default 20)
returns setof public.messages
language sql
stable
security definer
set search_path = ''
as $$
  select m.*
  from public.messages m
  where m.recipient_id = (select auth.uid())
  order by m.created_at desc, m.id desc
  limit least(greatest(coalesce(p_limit, 20), 1), 200)
$$;

comment on function public.recent_notifications(int) is
  '本人最近通知（默认 20，上限 200）；security definer 内部强制 recipient=auth.uid()';

create function public.mark_all_read()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  update public.messages
     set read_at = now()
   where recipient_id = (select auth.uid())
     and read_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

comment on function public.mark_all_read() is '批量标记本人未读为已读，返回影响行数';

create function public.unread_count()
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)
  from public.messages m
  where m.recipient_id = (select auth.uid())
    and m.read_at is null
$$;

comment on function public.unread_count() is '本人未读数（sidebar 徽标 / dashboard 同源）';

create function public.mark_notification_read(p_id bigint)
returns public.messages
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.messages;
begin
  update public.messages
     set read_at = coalesce(read_at, now())
   where id = p_id
     and recipient_id = (select auth.uid())
  returning * into v_row;

  if v_row.id is null then
    raise exception '消息不存在或无权操作' using errcode = '42501';
  end if;

  return v_row;
end;
$$;

comment on function public.mark_notification_read(bigint) is '标记本人单条消息已读（幂等，不覆盖首次已读时间）；越权/不存在报 42501';

create function public.toggle_notification_star(p_id bigint)
returns public.messages
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.messages;
begin
  update public.messages
     set starred = not starred
   where id = p_id
     and recipient_id = (select auth.uid())
  returning * into v_row;

  if v_row.id is null then
    raise exception '消息不存在或无权操作' using errcode = '42501';
  end if;

  return v_row;
end;
$$;

comment on function public.toggle_notification_star(bigint) is '切换本人单条消息星标；越权/不存在报 42501';

revoke all on function public.recent_notifications(int) from public, anon;
revoke all on function public.mark_all_read() from public, anon;
revoke all on function public.unread_count() from public, anon;
revoke all on function public.mark_notification_read(bigint) from public, anon;
revoke all on function public.toggle_notification_star(bigint) from public, anon;

grant execute on function public.recent_notifications(int) to authenticated;
grant execute on function public.mark_all_read() to authenticated;
grant execute on function public.unread_count() to authenticated;
grant execute on function public.mark_notification_read(bigint) to authenticated;
grant execute on function public.toggle_notification_star(bigint) to authenticated;
