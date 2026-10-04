-- 系统管理 · 飞书扫码登录数据面（工单 im/002）
-- 契约：docs/adr/003-im-login.md §3（会话签发不另立体系，callback 内 generateLink + verifyOtp）、
--       §4（state 防代扫；扫码成败落 audit_logins，新增 via=im 维度）、
--       docs/adr/002-audit-login-path.md（登录打点通道：匿名单写失败 / 已登录写成功）、
--       docs/modules/INDEX.md 规则 4（凭据解密仅后端）、规则 10（内部入口不 GRANT API 角色）。
--
-- 组成：
--   1. audit_logins 扩展：via（password / im_feishu / im_wecom / im_dingtalk）+ im_userid
--      （IM 尝试身份线索；未绑定拒绝时 user_id/email 均为 NULL，靠 im_userid 留痕）；
--   2. app.audit_login 扩参（保持「唯一写入入口」）：+ p_via / p_im_userid；
--   3. public.record_im_login_attempt：IM 打点公开包装（anon 仅失败 + 身份由绑定推导；
--      已登录仅成功 + 校验 userid 与本人绑定一致；限流按 im_userid）；
--   4. public.im_get_provider_config：后端凭据读取口（内部 app.decrypt_secret；
--      仅 service_role 可执行，secret 不出后端进程；前端不接触）。
--
-- 兼容：app.audit_login 原 6 参签名被替换为 8 参（后两参带默认值），
--       public.record_login_attempt 行为不变（显式传 'password'）。

-- ---------------------------------------------------------------------------
-- 1. audit_logins 扩展：via + im_userid
-- ---------------------------------------------------------------------------
alter table public.audit_logins
  add column via text not null default 'password',
  add column im_userid text;

comment on column public.audit_logins.via is
  '登录方式：password（表单）/ im_feishu / im_wecom / im_dingtalk（ADR-003 §4 via=im 维度）';
comment on column public.audit_logins.im_userid is
  'IM 尝试的厂商 userid（扫码成功/未绑定拒绝均可追溯；密码登录为 NULL）';

-- 身份约束扩展：IM 行允许仅靠 im_userid 留痕（未绑定拒绝场景 user_id/email 为 NULL）
alter table public.audit_logins
  drop constraint audit_logins_identity_check,
  add constraint audit_logins_identity_check
    check (
      user_id is not null
      or email is not null
      or im_userid is not null
      or via <> 'password'
    ),
  add constraint audit_logins_via_check
    check (via in ('password', 'im_feishu', 'im_wecom', 'im_dingtalk'));

-- ---------------------------------------------------------------------------
-- 2. app.audit_login：唯一写入入口扩参（via / im_userid；不 GRANT API 角色）
--    原 6 参签名由 8 参（默认值）替代；password 路径行为不变。
-- ---------------------------------------------------------------------------
drop function app.audit_login(uuid, text, boolean, text, inet, text);

create function app.audit_login(
  p_user_id     uuid,
  p_email       text,
  p_success     boolean,
  p_fail_reason text,
  p_ip          inet,
  p_ua          text,
  p_via         text default 'password',
  p_im_userid   text default null
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
    (user_id, email, success, fail_reason, ip, ua, via, im_userid)
  values
    (p_user_id,
     nullif(lower(btrim(p_email)), ''),
     p_success,
     case when p_success then null else nullif(btrim(p_fail_reason), '') end,
     p_ip,
     p_ua,
     coalesce(nullif(btrim(p_via), ''), 'password'),
     nullif(btrim(p_im_userid), ''))
  returning id into v_id;

  return v_id;
end;
$$;

comment on function app.audit_login(uuid, text, boolean, text, inet, text, text, text) is
  '登录日志唯一写入入口（8 参）：收口身份/结果/原因/IP/UA/方式/IM userid，成功后清空 fail_reason；'
  '不 GRANT API 角色（INDEX 规则 10）；密码经 record_login_attempt、IM 经 record_im_login_attempt 调用';

revoke all on function app.audit_login(uuid, text, boolean, text, inet, text, text, text)
  from public, anon, authenticated, service_role;

-- password 通道显式传 via（行为与旧版一致）
create or replace function public.record_login_attempt(
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

  return app.audit_login(
    v_user_id, v_email, p_success, p_fail_reason, v_ip, v_ua, 'password', null
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. public.record_im_login_attempt：IM 打点公开包装（anon 失败 / 已登录成功）
--    - 匿名（回调路由未签发会话，如未绑定被拒）：仅失败可写；
--      user_id/email 由 profiles.<provider>_userid 绑定推导，未绑定时保持 NULL，
--      仍以 im_userid 留痕（fail_reason=im_not_bound）；
--    - 已登录（verifyOtp 成功后）：仅成功可写，且 userid 必须与本人绑定一致；
--    - 防刷：同 (厂商, im_userid) 1 分钟 ≤10 条，超限静默丢弃（返回 NULL）；
--    - IP/UA：从 PostgREST 注入的 request.headers 采集（回调路由转发浏览器头）。
-- ---------------------------------------------------------------------------
create function public.record_im_login_attempt(
  p_provider    text,
  p_im_userid   text,
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
  v_provider       text := lower(btrim(coalesce(p_provider, '')));
  v_userid         text := nullif(btrim(p_im_userid), '');
  v_uid            uuid := (select auth.uid());
  v_col            text;
  v_user_id        uuid;
  v_email          text;
  v_via            text;
  v_recent         integer;
  v_headers        jsonb;
  v_ip             inet;
  v_ua             text;
begin
  if v_provider not in ('wecom', 'feishu', 'dingtalk') then
    raise exception '未知 IM 厂商：%', coalesce(p_provider, '(null)') using errcode = '22023';
  end if;

  if v_userid is null or v_userid !~ '^[A-Za-z0-9_-]+$' then
    raise exception 'IM userid 格式不正确：%', coalesce(p_im_userid, '(null)') using errcode = '22023';
  end if;

  if p_success is null then
    raise exception 'success 不能为空' using errcode = '22023';
  end if;

  -- 依据厂商选择绑定列（三列均在 im/001 建立；case 避免动态 SQL）
  if v_uid is not null then
    -- 已登录：仅成功可写，且 userid 必须与本人绑定一致（防代写他人 IM 登录）
    if not p_success then
      raise exception '已登录状态不重复记录 IM 登录失败' using errcode = '42501';
    end if;

    select p.id, lower(u.email)
      into v_user_id, v_email
    from public.profiles p
    left join auth.users u on u.id = p.id
    where p.id = v_uid
      and case v_provider
            when 'wecom' then p.wecom_userid
            when 'feishu' then p.feishu_userid
            else p.dingtalk_userid
          end = v_userid;

    if not found then
      raise exception 'IM userid 与当前账号绑定不一致' using errcode = '42501';
    end if;
  else
    -- 登录前匿名：仅失败可写；身份按绑定推导（未绑定则保持 NULL）
    if p_success then
      raise exception '未登录状态不可记录成功登录' using errcode = '42501';
    end if;

    select p.id, lower(u.email)
      into v_user_id, v_email
    from public.profiles p
    left join auth.users u on u.id = p.id
    where case v_provider
            when 'wecom' then p.wecom_userid
            when 'feishu' then p.feishu_userid
            else p.dingtalk_userid
          end = v_userid;
  end if;

  v_via := 'im_' || v_provider;

  -- 防刷：同厂商同 userid 1 分钟 ≤10 条；超限静默丢弃，不报错以免成为探测信号
  select count(*)::integer into v_recent
  from public.audit_logins
  where im_userid = v_userid
    and via = v_via
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
      v_ip := nullif(trim(both from split_part(v_headers ->> 'x-forwarded-for', ',', 1)), '')::inet;
    exception when others then
      v_ip := null;
    end;
  end if;

  return app.audit_login(
    v_user_id, v_email, p_success, p_fail_reason, v_ip, v_ua, v_via, v_userid
  );
end;
$$;

comment on function public.record_im_login_attempt(text, text, boolean, text) is
  'IM 登录打点公开包装（anon/authenticated）：匿名仅可记失败且身份按绑定推导；'
  '已登录仅可记成功且校验 userid 与本人绑定一致；同厂商同 userid 1 分钟 ≤10 条防刷；'
  'IP/UA 取 request.headers（回调路由转发）；写经 app.audit_login（ADR-002 通道）';

-- ---------------------------------------------------------------------------
-- 4. public.im_get_provider_config：后端凭据读取口（含解密）
--    仅 service_role（Next.js 服务端路由）可执行：appid/secret 出库后只存在于后端进程；
--    登录页与浏览器不接触本函数（授权 URL 由 /auth/im/[provider]/start 服务端构造）。
-- ---------------------------------------------------------------------------
create function public.im_get_provider_config(p_provider text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
           when c.provider is null then null
           else jsonb_build_object(
             'provider', c.provider,
             'enabled', c.enabled,
             'credentials',
             case
               when c.credentials is null then null
               else app.decrypt_secret(c.credentials)::jsonb
             end
           )
         end
  from public.im_auth_configs c
  where c.provider = lower(btrim(p_provider))
$$;

comment on function public.im_get_provider_config(text) is
  'IM 厂商配置后端读取口（含 app.decrypt_secret 解密）：仅 service_role；'
  '未配置的厂商返回 NULL；credentials 为解密后的 jsonb 对象（secret 不出后端进程）';

-- ---------------------------------------------------------------------------
-- 5. 授权：新 RPC 面收口
-- ---------------------------------------------------------------------------
revoke all on function public.record_im_login_attempt(text, text, boolean, text)
  from public, anon, authenticated, service_role;
grant execute on function public.record_im_login_attempt(text, text, boolean, text)
  to anon, authenticated;

revoke all on function public.im_get_provider_config(text)
  from public, anon, authenticated, service_role;
grant execute on function public.im_get_provider_config(text)
  to service_role;
