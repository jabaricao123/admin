-- 系统管理 · 全站公告（工单 system/013：表 + 状态机 RPC；system/014 页面消费）
-- 契约：docs/modules/system/announcements.md：
--   * 状态机 draft → published → offline/archived（到期自动归档）；
--   * 发布写 audit 摘要；投递委托 message app.send_notification（INDEX 规则 3），
--     全员事件 announcement.published（message/004 已注册）；通知为可选开关（横幅为主）；
--   * 范围 all / role:<code>；普通用户仅可见 published 且在时段内 + 范围内（工作台横幅消费
--     published_announcements_v，dashboard/004 接入）。
-- INDEX 规则 2（审计摘要）、3（通知发送单通道）、5（到期归档 pg_cron job 登记处登记）、
--   10（内部 RPC archive_expired_announcements 不 GRANT）。
-- 说明：
--   * 富文本 v1 存 markdown 子集文本（清洗在录入侧，页面以纯文本/受限渲染展示）；
--   * 全员投递 v1：p_notify=true 时逐 active profile 调 send_notification（不按 audience 过滤，
--     同工单口径）；TODO(message/007+)：单批 ≤500 分批 + 按受众投递（量级小前不引入分片表）；
--   * 编辑仅限 draft；published 只能下线（重新发布请新建），offline/archived 为终态。
-- 依赖：20261005060000（register_cron_job）、20261005020000（send_notification 模板）、
--       app.audit_log（audit/001）、app.current_role（init_profiles）。

-- ---------------------------------------------------------------------------
-- 1. system_announcements：公告表（状态机字段 + 生效时段 + 范围/置顶）
-- ---------------------------------------------------------------------------
create table public.system_announcements (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  content      text not null,
  starts_at    timestamptz,
  ends_at      timestamptz,
  audience     text not null default 'all',
  pinned       boolean not null default false,
  status       text not null default 'draft',
  published_by uuid,
  published_at timestamptz,
  created_by   uuid,
  updated_by   uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint system_announcements_title_check check (btrim(title) <> ''),
  constraint system_announcements_content_check check (btrim(content) <> ''),
  constraint system_announcements_audience_check
    check (audience = 'all' or audience ~ '^role:[a-z_]+$'),
  constraint system_announcements_status_check
    check (status in ('draft', 'published', 'offline', 'archived')),
  constraint system_announcements_period_check
    check (starts_at is null or ends_at is null or ends_at > starts_at)
);

comment on table public.system_announcements is
  '全站公告（draft→published→offline/archived）：横幅为主展示（published_announcements_v），'
  '站内信通知为可选；写仅经 admin RPC，普通用户不可直写';
comment on column public.system_announcements.content is '正文（markdown 子集文本，录入侧清洗）';
comment on column public.system_announcements.starts_at is '生效开始（发布前必填；草稿可空）';
comment on column public.system_announcements.ends_at is '生效结束（发布前必填且晚于开始；到期自动归档）';
comment on column public.system_announcements.audience is '可见范围：all / role:<user_role 枚举码>';
comment on column public.system_announcements.pinned is '置顶（横幅排序优先）';
comment on column public.system_announcements.status is 'draft 草稿 / published 已发布 / offline 已下线 / archived 已归档（终态）';
comment on column public.system_announcements.published_by is '发布人（弱关联 auth.users）';
comment on column public.system_announcements.published_at is '发布时间';
comment on column public.system_announcements.created_by is '创建人（弱关联 auth.users）';
comment on column public.system_announcements.updated_by is '最近修改人（弱关联 auth.users）';

create index system_announcements_status_window_idx
  on public.system_announcements (status, starts_at, ends_at);

create trigger system_announcements_set_updated_at
before update on public.system_announcements
for each row
execute function app.set_updated_at();

alter table public.system_announcements enable row level security;

-- ---------------------------------------------------------------------------
-- 2. 内部 helper：范围校验（all / role:<枚举码>，供 upsert 与发布复用）
-- ---------------------------------------------------------------------------
create function app.validate_announcement_audience(p_audience text)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_audience text := coalesce(nullif(btrim(coalesce(p_audience, '')), ''), 'all');
begin
  if v_audience = 'all' then
    return v_audience;
  end if;

  if v_audience !~ '^role:[a-z_]+$' then
    raise exception '公告范围不合法（仅支持 all / role:<角色码>）：%', v_audience
      using errcode = '22023';
  end if;

  if not exists (
    select 1
    from unnest(enum_range(null::public.user_role)) as e(code)
    where 'role:' || e.code::text = v_audience
  ) then
    raise exception '公告范围角色不存在：%', v_audience using errcode = '22023';
  end if;

  return v_audience;
end;
$$;

comment on function app.validate_announcement_audience(text) is
  '公告范围校验与归一（空=all；role:<code> 必须是 user_role 枚举码）；内部 helper，不 GRANT';

-- ---------------------------------------------------------------------------
-- 3. 状态机 RPC（admin）：upsert_announcement / publish_announcement / offline_announcement
-- ---------------------------------------------------------------------------
create function app.upsert_announcement(
  p_title    text,
  p_content  text,
  p_starts_at timestamptz,
  p_ends_at   timestamptz,
  p_audience  text,
  p_pinned    boolean,
  p_id        uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_title    text := btrim(coalesce(p_title, ''));
  v_content  text := btrim(coalesce(p_content, ''));
  v_audience text;
  v_pinned   boolean := coalesce(p_pinned, false);
  v_prev     public.system_announcements;
  v_row      public.system_announcements;
  v_created  boolean := p_id is null;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if v_title = '' then
    raise exception '公告标题不能为空' using errcode = '22023';
  end if;
  if v_content = '' then
    raise exception '公告正文不能为空' using errcode = '22023';
  end if;

  v_audience := app.validate_announcement_audience(p_audience);

  if p_starts_at is not null and p_ends_at is not null and p_ends_at <= p_starts_at then
    raise exception '生效时段不合法：结束时间必须晚于开始时间' using errcode = '22023';
  end if;

  if p_id is null then
    insert into public.system_announcements
      (title, content, starts_at, ends_at, audience, pinned, status, created_by, updated_by)
    values
      (v_title, v_content, p_starts_at, p_ends_at, v_audience, v_pinned, 'draft',
       (select auth.uid()), (select auth.uid()))
    returning * into v_row;
  else
    select * into v_prev
    from public.system_announcements
    where id = p_id
    for update;

    if not found then
      raise exception '公告不存在' using errcode = 'P0002';
    end if;
    if v_prev.status <> 'draft' then
      raise exception '仅草稿状态的公告可编辑（当前状态：%）', v_prev.status
        using errcode = '22023';
    end if;

    update public.system_announcements
       set title       = v_title,
           content     = v_content,
           starts_at   = p_starts_at,
           ends_at     = p_ends_at,
           audience    = v_audience,
           pinned      = v_pinned,
           updated_by  = (select auth.uid())
     where id = p_id
    returning * into v_row;
  end if;

  perform app.audit_log(
    'system', 'upsert', 'announcement', v_row.id::text,
    jsonb_build_object(
      'created', v_created,
      'status', v_row.status,
      'audience', v_row.audience,
      'pinned', v_row.pinned,
      'starts_at', v_row.starts_at,
      'ends_at', v_row.ends_at
    )
  );

  return jsonb_build_object(
    'id', v_row.id,
    'title', v_row.title,
    'status', v_row.status,
    'audience', v_row.audience,
    'pinned', v_row.pinned,
    'starts_at', v_row.starts_at,
    'ends_at', v_row.ends_at,
    'updated_at', v_row.updated_at
  );
end;
$$;

comment on function app.upsert_announcement(text, text, timestamptz, timestamptz, text, boolean, uuid) is
  '公告新建/编辑 RPC（admin）：仅草稿可编辑；范围归一校验；写审计；不直接投递';

create function app.publish_announcement(
  p_id     uuid,
  p_notify boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row        public.system_announcements;
  v_publisher  text;
  v_recipient  uuid;
  v_notified   integer := 0;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.system_announcements
  where id = p_id
  for update;

  if not found then
    raise exception '公告不存在' using errcode = 'P0002';
  end if;
  if v_row.status <> 'draft' then
    raise exception '仅草稿状态的公告可发布（当前状态：%）', v_row.status
      using errcode = '22023';
  end if;
  if btrim(v_row.title) = '' or btrim(v_row.content) = '' then
    raise exception '公告标题与正文不能为空' using errcode = '22023';
  end if;
  if v_row.starts_at is null or v_row.ends_at is null then
    raise exception '发布前请先填写生效时段（开始与结束时间）' using errcode = '22023';
  end if;
  if v_row.ends_at <= v_row.starts_at then
    raise exception '生效时段不合法：结束时间必须晚于开始时间' using errcode = '22023';
  end if;

  update public.system_announcements
     set status       = 'published',
         published_by = (select auth.uid()),
         published_at = now(),
         updated_by   = (select auth.uid())
   where id = p_id
  returning * into v_row;

  -- 站内信通知：可选（横幅为主）；v1 逐 active 用户发送（不按 audience 过滤，
  -- 同工单口径），量级小可接受；TODO：单批 ≤500 分批 + 按受众投递（message/007+）。
  if coalesce(p_notify, false) then
    select coalesce(nullif(p.full_name, ''), p.email, '系统管理员')
      into v_publisher
      from public.profiles p
     where p.id = (select auth.uid());

    for v_recipient in
      select p.id from public.profiles p where p.status = 'active'
    loop
      perform app.send_notification(
        v_recipient,
        'announcement.published',
        jsonb_build_object(
          'title', v_row.title,
          'publisher', coalesce(v_publisher, '系统管理员'),
          'body', v_row.content,
          'source_module', 'system',
          'ref_type', 'announcement',
          'ref_id', v_row.id::text
        )
      );
      v_notified := v_notified + 1;
    end loop;
  end if;

  perform app.audit_log(
    'system', 'publish', 'announcement', v_row.id::text,
    jsonb_build_object(
      'title', v_row.title,
      'audience', v_row.audience,
      'pinned', v_row.pinned,
      'starts_at', v_row.starts_at,
      'ends_at', v_row.ends_at,
      'notify', coalesce(p_notify, false),
      'notified', v_notified
    )
  );

  return jsonb_build_object(
    'id', v_row.id,
    'status', v_row.status,
    'published_at', v_row.published_at,
    'notified', v_notified
  );
end;
$$;

comment on function app.publish_announcement(uuid, boolean) is
  '公告发布 RPC（admin）：draft→published（校验时段）；p_notify=true 时逐 active 用户调'
  'app.send_notification（announcement.published，INDEX 规则 3）；写审计摘要';

create function app.offline_announcement(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.system_announcements;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.system_announcements
  where id = p_id
  for update;

  if not found then
    raise exception '公告不存在' using errcode = 'P0002';
  end if;
  if v_row.status <> 'published' then
    raise exception '仅已发布状态的公告可下线（当前状态：%）', v_row.status
      using errcode = '22023';
  end if;

  update public.system_announcements
     set status     = 'offline',
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  perform app.audit_log(
    'system', 'offline', 'announcement', v_row.id::text,
    jsonb_build_object('title', v_row.title, 'status', v_row.status)
  );

  return jsonb_build_object(
    'id', v_row.id,
    'status', v_row.status,
    'updated_at', v_row.updated_at
  );
end;
$$;

comment on function app.offline_announcement(uuid) is
  '公告下线 RPC（admin）：published→offline；非 published（如 draft）直接下线被拒（状态机）；写审计';

-- ---------------------------------------------------------------------------
-- 4. 到期自动归档（pg_cron 每日；内部 RPC 不 GRANT）
-- ---------------------------------------------------------------------------
create function app.archive_expired_announcements()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  update public.system_announcements
     set status = 'archived'
   where status = 'published'
     and ends_at is not null
     and ends_at < now();

  get diagnostics v_count = row_count;

  if v_count > 0 then
    perform app.audit_log(
      'system', 'archive', 'announcement', null,
      jsonb_build_object('count', v_count, 'reason', 'ended')
    );
  end if;

  return v_count;
end;
$$;

comment on function app.archive_expired_announcements() is
  '到期公告自动归档（published 且 ends_at<now() → archived；返回条数，批量写一条审计）；'
  '仅 pg_cron 执行，不 GRANT API 角色（INDEX 规则 10）';

-- ---------------------------------------------------------------------------
-- 5. 列表 RPC（admin）：get_announcements（含发布人姓名）
-- ---------------------------------------------------------------------------
create function app.get_announcements()
returns table (
  id             uuid,
  title          text,
  content        text,
  starts_at      timestamptz,
  ends_at        timestamptz,
  audience       text,
  pinned         boolean,
  status         text,
  publisher_name text,
  published_at   timestamptz,
  creator_name   text,
  updated_at     timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  return query
  select
    a.id,
    a.title,
    a.content,
    a.starts_at,
    a.ends_at,
    a.audience,
    a.pinned,
    a.status,
    coalesce(nullif(pub.full_name, ''), pub.email) as publisher_name,
    a.published_at,
    coalesce(nullif(cre.full_name, ''), cre.email) as creator_name,
    a.updated_at
  from public.system_announcements a
  left join public.profiles pub on pub.id = a.published_by
  left join public.profiles cre on cre.id = a.created_by
  order by a.pinned desc, a.created_at desc;
end;
$$;

comment on function app.get_announcements() is
  '公告全量列表 RPC（admin）：含各状态；join profiles 带发布人/创建人姓名；置顶优先、新建在前';

-- ---------------------------------------------------------------------------
-- 6. published_announcements_v：登录可读（时段内 + 范围匹配；dashboard 横幅消费）
-- ---------------------------------------------------------------------------
create view public.published_announcements_v
with (security_invoker = true)
as
select
  a.id,
  a.title,
  a.content,
  a.starts_at,
  a.ends_at,
  a.audience,
  a.pinned,
  a.published_at,
  a.updated_at
from public.system_announcements a
where a.status = 'published'
  and a.starts_at is not null
  and a.ends_at is not null
  and a.starts_at <= now()
  and a.ends_at > now()
  and (
    a.audience = 'all'
    or a.audience = 'role:' || (select app.current_role())::text
  )
order by a.pinned desc, a.published_at desc nulls last;

comment on view public.published_announcements_v is
  '生效中公告公开视图（security_invoker 随底层 RLS）：仅 published 且时段内 + 范围匹配；'
  'dashboard 横幅与普通用户消费，隐藏草稿/下线/归档';

-- ---------------------------------------------------------------------------
-- 7. public 薄包装（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.upsert_announcement(
  p_title    text,
  p_content  text,
  p_starts_at timestamptz,
  p_ends_at   timestamptz,
  p_audience  text,
  p_pinned    boolean,
  p_id        uuid default null
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.upsert_announcement(
    p_title, p_content, p_starts_at, p_ends_at, p_audience, p_pinned, p_id
  )
$$;

create function public.publish_announcement(
  p_id     uuid,
  p_notify boolean default false
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.publish_announcement(p_id, p_notify)
$$;

create function public.offline_announcement(p_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.offline_announcement(p_id)
$$;

create function public.get_announcements()
returns table (
  id             uuid,
  title          text,
  content        text,
  starts_at      timestamptz,
  ends_at        timestamptz,
  audience       text,
  pinned         boolean,
  status         text,
  publisher_name text,
  published_at   timestamptz,
  creator_name   text,
  updated_at     timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.get_announcements()
$$;

comment on function public.upsert_announcement(text, text, timestamptz, timestamptz, text, boolean, uuid) is
  'upsert_announcement Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.publish_announcement(uuid, boolean) is
  'publish_announcement Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.offline_announcement(uuid) is
  'offline_announcement Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.get_announcements() is
  'get_announcements Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 8. pg_cron：每日到期归档（规则 5：登记到平台登记处）
-- ---------------------------------------------------------------------------
select cron.schedule(
  'archive-expired-announcements',
  '15 4 * * *',
  $cron$select app.archive_expired_announcements()$cron$
);

select app.register_cron_job(
  'archive-expired-announcements', 'system', '15 4 * * *', 'Asia/Shanghai', '/system/announcements'
);

-- ---------------------------------------------------------------------------
-- 9. 授权与 RLS：表 admin 直读 + 普通用户范围只读；写仅 RPC；视图登录可读
-- ---------------------------------------------------------------------------
revoke all on public.system_announcements from public, anon, authenticated, service_role;
grant select on public.system_announcements to authenticated;

create policy system_announcements_select_admin
on public.system_announcements
for select
to authenticated
using ((select app.current_role()) = 'admin');

-- 普通用户：published + 时段内 + 范围匹配（与视图条件一致，供直读兜底）
create policy system_announcements_select_audience
on public.system_announcements
for select
to authenticated
using (
  (select app.current_role()) is not null
  and status = 'published'
  and starts_at is not null
  and ends_at is not null
  and starts_at <= now()
  and ends_at > now()
  and (
    audience = 'all'
    or audience = 'role:' || (select app.current_role())::text
  )
);

revoke all on public.published_announcements_v from public, anon, authenticated, service_role;
grant select on public.published_announcements_v to authenticated, service_role;

revoke all on function app.validate_announcement_audience(text)
  from public, anon, authenticated, service_role;
revoke all on function app.archive_expired_announcements()
  from public, anon, authenticated, service_role;

revoke all on function app.upsert_announcement(text, text, timestamptz, timestamptz, text, boolean, uuid)
  from public, anon;
grant execute on function app.upsert_announcement(text, text, timestamptz, timestamptz, text, boolean, uuid)
  to authenticated;

revoke all on function app.publish_announcement(uuid, boolean) from public, anon;
grant execute on function app.publish_announcement(uuid, boolean) to authenticated;

revoke all on function app.offline_announcement(uuid) from public, anon;
grant execute on function app.offline_announcement(uuid) to authenticated;

revoke all on function app.get_announcements() from public, anon;
grant execute on function app.get_announcements() to authenticated;

revoke all on function public.upsert_announcement(text, text, timestamptz, timestamptz, text, boolean, uuid)
  from public, anon;
grant execute on function public.upsert_announcement(text, text, timestamptz, timestamptz, text, boolean, uuid)
  to authenticated;

revoke all on function public.publish_announcement(uuid, boolean) from public, anon;
grant execute on function public.publish_announcement(uuid, boolean) to authenticated;

revoke all on function public.offline_announcement(uuid) from public, anon;
grant execute on function public.offline_announcement(uuid) to authenticated;

revoke all on function public.get_announcements() from public, anon;
grant execute on function public.get_announcements() to authenticated;
