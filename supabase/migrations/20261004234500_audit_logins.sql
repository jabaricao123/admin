-- audit/003+005：登录日志 audit_logins + 写入路径（ADR-002：服务端打点主路径）
-- 契约：INDEX 规则 2（audit 统一入口）、规则 10（app.audit_login 不 GRANT API 角色；
--       公开包装 public.record_login_attempt 内做身份/限流校验）
-- append-only：API 角色无表级 INSERT/UPDATE/DELETE，写入仅经 SECURITY DEFINER 函数。
-- Auth hook 预留：未来 Custom Access Token / Password Verification hook 接入时，
-- 仅需以 supabase_auth_admin 调用 app.audit_login，无需改表。

-- ---------------------------------------------------------------------------
-- 1. audit_logins：登录行为日志（成功/失败、原因、IP、UA）
-- ---------------------------------------------------------------------------
create table public.audit_logins (
  id          bigint generated always as identity primary key,
  user_id     uuid,
  email       text,
  success     boolean not null,
  fail_reason text,
  ip          inet,
  ua          text,
  created_at  timestamptz not null default now(),
  constraint audit_logins_identity_check
    check (user_id is not null or email is not null)
);

comment on table public.audit_logins is
  '登录日志（append-only）：成功/失败尝试、失败原因、IP/UA；'
  '唯一写入入口 app.audit_login，匿名登录前失败经 public.record_login_attempt 包装';
comment on column public.audit_logins.user_id is
  '用户 id（弱关联 auth.users，不设外键以保留追溯；邮箱未匹配时为 NULL）';
comment on column public.audit_logins.email is
  '尝试登录的邮箱（小写归一；已登录会话以会话邮箱为准）';
comment on column public.audit_logins.fail_reason is
  '失败原因归类（invalid_credentials/user_banned/other）；成功为 NULL';

create index audit_logins_user_created_idx
  on public.audit_logins (user_id, created_at);
create index audit_logins_created_idx
  on public.audit_logins (created_at);

-- ---------------------------------------------------------------------------
-- 2. app.audit_login：唯一写入入口（6 参；不 GRANT API 角色，INDEX 规则 10）
-- ---------------------------------------------------------------------------
create function app.audit_login(
  p_user_id     uuid,
  p_email       text,
  p_success     boolean,
  p_fail_reason text,
  p_ip          inet,
  p_ua          text
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  if p_success is null then
    raise exception 'success 不能为空' using errcode = '22023';
  end if;

  insert into public.audit_logins
    (user_id, email, success, fail_reason, ip, ua)
  values
    (p_user_id,
     nullif(lower(btrim(p_email)), ''),
     p_success,
     case when p_success then null else nullif(btrim(p_fail_reason), '') end,
     p_ip,
     p_ua)
  returning id into v_id;

  return v_id;
end;
$$;

comment on function app.audit_login(uuid, text, boolean, text, inet, text) is
  '登录日志唯一写入入口（6 参）：收口身份/结果/原因/IP/UA，成功后清空 fail_reason；'
  '不 GRANT API 角色（INDEX 规则 10）；Auth hook 接入时以 supabase_auth_admin 调用';

-- ---------------------------------------------------------------------------
-- 3. public.record_login_attempt：登录打点公开包装（anon 失败 / authenticated 成功）
--    - 匿名（登录前）：仅允许失败留痕；user_id 由 p_email 解析，调用方无法指定身份；
--    - 已登录：邮箱以会话为准，防止代写他人邮箱；
--    - 防刷：同邮箱 1 分钟 ≤10 条，超限静默丢弃（返回 NULL）；
--    - IP/UA：从 PostgREST 注入的 request.headers 采集，采集不到记 NULL。
-- ---------------------------------------------------------------------------
create function public.record_login_attempt(
  p_email       text,
  p_success     boolean,
  p_fail_reason text default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_max_per_minute constant integer := 10;
  v_email          text := lower(btrim(coalesce(p_email, '')));
  v_uid            uuid := (select auth.uid());
  v_session_email  text;
  v_user_id        uuid;
  v_recent         integer;
  v_headers        jsonb;
  v_ip             inet;
  v_ua             text;
begin
  if v_email = '' and v_uid is null then
    raise exception '邮箱不能为空' using errcode = '22023';
  end if;

  if p_success is null then
    raise exception 'success 不能为空' using errcode = '22023';
  end if;

  if v_uid is not null then
    -- 已登录：以会话身份归档；邮箱以会话邮箱为准（不接受代写他人邮箱）
    select lower(u.email) into v_session_email
    from auth.users u
    where u.id = v_uid;

    v_user_id := v_uid;
    v_email := coalesce(v_session_email, v_email);
  else
    -- 登录前匿名：仅失败可写；按邮箱解析用户，身份由数据库推导
    if p_success then
      raise exception '未登录状态不可记录成功登录' using errcode = '42501';
    end if;

    select u.id into v_user_id
    from auth.users u
    where lower(u.email) = v_email
    limit 1;
  end if;

  if v_email = '' then
    raise exception '邮箱不能为空' using errcode = '22023';
  end if;

  -- 防刷：同邮箱 1 分钟 ≤10 条；超限静默丢弃，不报错以免成为探测信号
  select count(*)::integer into v_recent
  from public.audit_logins
  where email = v_email
    and created_at > now() - interval '1 minute';

  if v_recent >= c_max_per_minute then
    return null;
  end if;

  begin
    v_headers := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then
    v_headers := null;
  end;

  if v_headers is not null then
    v_ua := v_headers ->> 'user-agent';
    begin
      -- X-Forwarded-For 可能是多段「客户端, 代理...」，取第一段
      v_ip := nullif(trim(both from split_part(v_headers ->> 'x-forwarded-for', ',', 1)), '')::inet;
    exception when others then
      v_ip := null;
    end;
  end if;

  return app.audit_login(v_user_id, v_email, p_success, p_fail_reason, v_ip, v_ua);
end;
$$;

comment on function public.record_login_attempt(text, boolean, text) is
  '登录打点公开包装（anon/authenticated）：匿名仅可记失败且身份按邮箱解析；'
  '已登录邮箱以会话为准；同邮箱 1 分钟 ≤10 条防刷；IP/UA 取 request.headers；'
  '写经 app.audit_login（ADR-002 服务端打点主路径）';

-- ---------------------------------------------------------------------------
-- 4. 授权：append-only（API 角色只读，RLS 再收口；写仅经函数）
-- ---------------------------------------------------------------------------
revoke all on public.audit_logins from public, anon, authenticated, service_role;
grant select on public.audit_logins to authenticated, service_role;

revoke all on sequence public.audit_logins_id_seq
  from public, anon, authenticated, service_role;

revoke all on function app.audit_login(uuid, text, boolean, text, inet, text)
  from public, anon, authenticated;
revoke all on function public.record_login_attempt(text, boolean, text)
  from public, anon, authenticated;
grant execute on function public.record_login_attempt(text, boolean, text)
  to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. RLS：admin SELECT 全量；本人 SELECT user_id = auth.uid()（登录日志自查）
-- ---------------------------------------------------------------------------
alter table public.audit_logins enable row level security;

create policy audit_logins_select_admin
on public.audit_logins
for select
to authenticated
using (app.current_role() = 'admin');

create policy audit_logins_select_self
on public.audit_logins
for select
to authenticated
using ((select auth.uid()) = user_id);
