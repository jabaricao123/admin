-- 系统管理 · 飞书扫码登录数据面（工单 im/002）
-- 契约：docs/adr/003-im-login.md §3（会话签发不另立体系，callback 内 generateLink + verifyOtp）、
--       §4（state 防代扫；扫码成败落 audit_logins，新增 via=im 维度）、
--       docs/adr/004-im-login-credential-boundary.md（凭据不出库；交互式出站 extensions.http；
--       最小角色 im_backend + SECURITY DEFINER 链）、
--       docs/adr/002-audit-login-path.md（登录打点通道：匿名单写失败 / 已登录写成功）、
--       docs/modules/INDEX.md 规则 4（凭据解密仅后端）、规则 10（内部入口不 GRANT API 角色）、
--       ADR-001（全局禁 service_role）。
--
-- 组成：
--   1. audit_logins 扩展：via（password / im_feishu / im_wecom / im_dingtalk）+ im_userid
--      （IM 尝试身份线索；未绑定拒绝时 user_id/email 均为 NULL，靠 im_userid 留痕）；
--   2. app.audit_login 扩参（保持「唯一写入入口」）：+ p_via / p_im_userid；
--   3. public.record_im_login_attempt：IM 打点公开包装（anon 仅失败 + 身份由绑定推导；
--      已登录仅成功 + 校验 userid 与本人绑定一致；限流按 im_userid）；
--   4. 厂商逻辑下沉（im/002 修复）：凭据解密 / 授权 URL / code 换 token / userinfo /
--      绑定匹配全在 Postgres 内完成；Next.js 只调 im_start_auth / im_handle_callback。
--      原 im_get_provider_config（service_role 专属、secret 出库）删除（违反 INDEX 规则 10 /
--      ADR-001 全局禁令），改由专用最小角色 im_backend + SECURITY DEFINER 链式包装承接。
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
-- 4. 厂商逻辑下沉（im/002 修复）：凭据解密 / 授权 URL / code 换 token / userinfo /
--    绑定匹配全部在 Postgres 内完成；Next.js 只调 public.im_start_auth /
--    public.im_handle_callback。厂商 secret 不出 Postgres（INDEX 规则 10、ADR-001 全局禁令）。
--
--    出站运行时：extensions.http（pgsql-http，同步）——登录回调必须在单次 RPC 内拿到厂商
--    响应；ADR-001 的 pg_net + pg_cron 异步模型面向后台投递，不适用于交互式登录。
--    超时在函数内收紧（连接 3s / 总 8s），出站失败一律映射为 im_failed，不回显内部细节。
--
--    授权模型（角色即边界，Next.js 无 service_role 直读凭据路径）：
--      - app.* 实现函数零授权（public/anon/authenticated/service_role 全 revoke）；
--      - public.im_start_auth / public.im_handle_callback 为 SECURITY DEFINER 薄包装，
--        链式调用 app.* 实现（调用者无需 app schema 权限）；
--      - 两薄包装仅 GRANT 给专用最小角色 im_backend（nologin、非 BYPASSRLS、无表权限，
--        仅 EXECUTE 这两个函数）；Next.js 以 role=im_backend 的 JWT 经 PostgREST 调用
--        （im_backend GRANT authenticator 以支持 SET ROLE）。
-- ---------------------------------------------------------------------------

-- 4.1 旧版凭据读取口清理：本修订不再创建 public.im_get_provider_config
--     （service_role 专属、secret 出库）；若目标库曾手工应用旧版迁移则清理之。
do $do$
begin
  if exists (
    select 1
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'im_get_provider_config'
  ) then
    drop function public.im_get_provider_config(text);
  end if;
end
$do$;

-- 4.2 出站扩展：http（同步，仅登录链路使用；后台投递仍按 ADR-001 走 pg_net）
create extension if not exists http with schema extensions;

-- 4.3 专用最小角色 im_backend：IM 登录后端身份（nologin；无表权限、无 BYPASSRLS）
do $do$
begin
  if not exists (
    select 1 from pg_catalog.pg_roles where rolname = 'im_backend'
  ) then
    create role im_backend nologin;
  end if;
end
$do$;

comment on role im_backend is
  'IM 登录后端最小角色（Next.js 服务端以 role=im_backend 的 JWT 调用）：nologin、'
  '非 superuser、非 bypassrls、无任何表权限；仅被 GRANT EXECUTE public.im_start_auth / '
  'public.im_handle_callback（厂商凭据解密与出站均在 SECURITY DEFINER 内完成，secret 不出库）；'
  '全局禁 service_role（ADR-001 / INDEX 规则 10）';

-- 4.4 app.urlencode：RFC3986 百分号编码（授权 URL 与表单体共用；纯函数）
create function app.urlencode(p_text text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_result text := '';
  v_char   text;
  v_bytes  bytea;
  i        integer;
  j        integer;
begin
  if p_text is null then
    return null;
  end if;

  for i in 1..char_length(p_text) loop
    v_char := substr(p_text, i, 1);
    if v_char ~ '^[A-Za-z0-9._~-]$' then
      v_result := v_result || v_char;
    else
      v_bytes := convert_to(v_char, 'UTF8');
      for j in 0..octet_length(v_bytes) - 1 loop
        v_result := v_result || '%' || upper(lpad(to_hex(get_byte(v_bytes, j)), 2, '0'));
      end loop;
    end if;
  end loop;

  return v_result;
end;
$$;

comment on function app.urlencode(text) is
  'RFC3986 百分号编码（保留 A-Za-z0-9-._~，其余按 UTF-8 字节 %XX）；'
  'SECURITY INVOKER + immutable + search_path 空；不 GRANT API 角色';

-- 4.5 app.im_provider_credentials：启用厂商的解密凭据（未启用 / 未配置返回 NULL，不抛错）
create function app.im_provider_credentials(p_provider text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
           when c.enabled and c.credentials is not null
           then app.decrypt_secret(c.credentials)::jsonb
         end
  from public.im_auth_configs c
  where c.provider = lower(btrim(coalesce(p_provider, '')))
$$;

comment on function app.im_provider_credentials(text) is
  'IM 厂商凭据解密读取（内部 helper，不 GRANT 任何角色）：仅 enabled=true 且 credentials '
  '非空时返回解密后的 jsonb，否则 NULL；secret 只存在于函数作用域';

-- 4.6 app.im_http_timeout：同步出站超时收紧（curlopt 会话级，幂等）
create function app.im_http_timeout()
returns void
language plpgsql
volatile
set search_path = ''
as $$
begin
  -- pg_net 用于后台投递且自带超时；pgsql-http 无默认超时，此处收紧防连接悬挂
  perform extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '3000');
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');
end;
$$;

comment on function app.im_http_timeout() is
  '交互式出站超时（连接 3s / 总 8s）；http_set_curlopt 会话级、幂等；不 GRANT API 角色';

-- 4.7 app.im_parse_exchange_response：v3 token 响应解析（纯函数，pgTAP 覆盖）
create function app.im_parse_exchange_response(p_http_status integer, p_content text)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_body jsonb;
begin
  if p_http_status is distinct from 200 then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed',
      'detail', format('飞书授权码换 token HTTP %s', p_http_status)
    );
  end if;

  begin
    v_body := p_content::jsonb;
  exception when others then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed', 'detail', '飞书授权码换 token 响应不是合法 JSON'
    );
  end;

  -- 成功响应 code=0（飞书 JSON 数字）；错误响应带 code + error_description / msg
  if coalesce(v_body ->> 'code', '') <> '0' then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed',
      'detail', format(
        '飞书授权码换 token 失败（code=%s）：%s',
        coalesce(v_body ->> 'code', '?'),
        coalesce(v_body ->> 'error_description', v_body ->> 'msg', '未知错误')
      )
    );
  end if;

  if coalesce(v_body ->> 'access_token', '') = '' then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed', 'detail', '飞书授权码换 token 响应缺少 access_token'
    );
  end if;

  return jsonb_build_object('ok', true, 'access_token', v_body ->> 'access_token');
end;
$$;

comment on function app.im_parse_exchange_response(integer, text) is
  '飞书 v3 token 响应解析：HTTP 非 200 / 非法 JSON / code<>0 / 缺 access_token 均返回 '
  '{ok:false,error,detail}（detail 仅含 code 与厂商描述，不含 secret）；不 GRANT API 角色';

-- 4.8 app.im_parse_identity_response：userinfo 响应解析（纯函数，pgTAP 覆盖）
create function app.im_parse_identity_response(p_http_status integer, p_content text)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_body   jsonb;
  v_userid text;
begin
  if p_http_status is distinct from 200 then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed',
      'detail', format('飞书获取用户信息 HTTP %s', p_http_status)
    );
  end if;

  begin
    v_body := p_content::jsonb;
  exception when others then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed', 'detail', '飞书获取用户信息响应不是合法 JSON'
    );
  end;

  if coalesce(v_body ->> 'code', '') <> '0' then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed',
      'detail', format(
        '飞书获取用户信息失败（code=%s）：%s',
        coalesce(v_body ->> 'code', '?'),
        coalesce(v_body ->> 'msg', '未知错误')
      )
    );
  end if;

  v_userid := nullif(btrim(v_body #>> '{data,user_id}'), '');
  if v_userid is null then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed',
      'detail', '未取得 user_id（检查应用权限 contact:user.employee_id:readonly）'
    );
  end if;
  -- 与 profiles.<provider>_userid 的 CHECK 对齐，避免带入不可入库字符
  if v_userid !~ '^[A-Za-z0-9_-]+$' then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed', 'detail', '飞书 user_id 格式非法'
    );
  end if;

  return jsonb_build_object('ok', true, 'userid', v_userid);
end;
$$;

comment on function app.im_parse_identity_response(integer, text) is
  '飞书 userinfo 响应解析：HTTP 非 200 / 非法 JSON / code<>0 / 缺 user_id / user_id 格式非法 '
  '均返回 {ok:false,error,detail}；成功返回 {ok:true,userid}；不 GRANT API 角色';

-- 4.9 app.im_resolve_binding：IM userid → profiles 预绑定（user_id / email / status）
create function app.im_resolve_binding(p_provider text, p_im_userid text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
           'user_id', p.id,
           'email', lower(u.email),
           'status', p.status
         )
  from public.profiles p
  left join auth.users u on u.id = p.id
  where lower(btrim(coalesce(p_provider, ''))) in ('wecom', 'feishu', 'dingtalk')
    and p_im_userid is not null
    and case lower(btrim(p_provider))
          when 'wecom' then p.wecom_userid
          when 'feishu' then p.feishu_userid
          else p.dingtalk_userid
        end = p_im_userid
  limit 1
$$;

comment on function app.im_resolve_binding(text, text) is
  'IM userid 预绑定解析（ADR-003 §1 只认 profiles.<provider>_userid）：命中返回 '
  '{user_id,email,status}，未绑定返回 NULL；不 GRANT API 角色';

-- 4.10 app.im_build_authorize_url：启用厂商与解密凭据 → 授权 URL（secret 不出库）
create function app.im_build_authorize_url(
  p_provider     text,
  p_redirect_uri text,
  p_state        text
)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_provider    text := lower(btrim(coalesce(p_provider, '')));
  v_credentials jsonb;
  v_app_id      text;
begin
  if v_provider not in ('wecom', 'feishu', 'dingtalk') then
    raise exception '未知 IM 厂商：%', coalesce(p_provider, '(null)') using errcode = '22023';
  end if;
  if v_provider <> 'feishu' then
    raise exception '厂商 % 授权页尚未接入（im/002 仅飞书）', v_provider using errcode = '22023';
  end if;
  if p_redirect_uri is null or p_redirect_uri !~ '^https?://[^[:space:]]+$' then
    raise exception '回调地址非法' using errcode = '22023';
  end if;
  -- state 由 Next.js 生成（base64url + 毫秒时间戳，含点号）
  if p_state is null or p_state !~ '^[A-Za-z0-9._-]{16,128}$' then
    raise exception 'state 非法' using errcode = '22023';
  end if;

  v_credentials := app.im_provider_credentials(v_provider);
  if v_credentials is null then
    raise exception 'IM 厂商未启用或凭据缺失：%', v_provider using errcode = '42501';
  end if;

  v_app_id := nullif(btrim(v_credentials ->> 'app_id'), '');
  if v_app_id is null then
    raise exception 'IM 厂商凭据缺少 app_id（请在配置中重新保存）' using errcode = '42501';
  end if;

  -- 飞书现行 OAuth 2.0 授权页（与 im/002 原 Next.js 实现逐参数对齐）
  return 'https://accounts.feishu.cn/open-apis/authen/v1/authorize'
    || '?client_id=' || app.urlencode(v_app_id)
    || '&response_type=code'
    || '&redirect_uri=' || app.urlencode(p_redirect_uri)
    || '&scope=' || app.urlencode('contact:user.employee_id:readonly')
    || '&state=' || app.urlencode(p_state);
end;
$$;

comment on function app.im_build_authorize_url(text, text, text) is
  '授权 URL 构造（内部实现，不 GRANT 任何角色）：解密启用的厂商凭据，返回飞书授权页 URL；'
  '未启用 / 凭据缺失抛 42501，参数非法抛 22023；app_id 出现在 URL（公开标识），secret 不出函数作用域';

-- 4.11 app.im_exchange_code：授权码换 user_access_token（extensions.http 同步出站）
create function app.im_exchange_code(
  p_provider     text,
  p_code         text,
  p_redirect_uri text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_provider    text := lower(btrim(coalesce(p_provider, '')));
  v_credentials jsonb;
  v_app_id      text;
  v_app_secret  text;
  v_response    extensions.http_response;
begin
  if v_provider <> 'feishu' then
    raise exception '厂商 % 回调尚未接入（im/002 仅飞书）', v_provider using errcode = '22023';
  end if;
  if p_code is null or btrim(p_code) = '' or length(p_code) > 512 then
    raise exception '授权码非法' using errcode = '22023';
  end if;
  if p_redirect_uri is null or p_redirect_uri !~ '^https?://[^[:space:]]+$' then
    raise exception '回调地址非法' using errcode = '22023';
  end if;

  v_credentials := app.im_provider_credentials(v_provider);
  if v_credentials is null then
    return jsonb_build_object('ok', false, 'error', 'im_unavailable');
  end if;
  v_app_id := nullif(btrim(v_credentials ->> 'app_id'), '');
  v_app_secret := nullif(btrim(v_credentials ->> 'app_secret'), '');
  if v_app_id is null or v_app_secret is null then
    return jsonb_build_object('ok', false, 'error', 'im_unavailable');
  end if;

  perform app.im_http_timeout();
  begin
    v_response := extensions.http_post(
      'https://accounts.feishu.cn/oauth/v3/token',
      'grant_type=authorization_code'
        || '&client_id=' || app.urlencode(v_app_id)
        || '&client_secret=' || app.urlencode(v_app_secret)
        || '&code=' || app.urlencode(p_code)
        || '&redirect_uri=' || app.urlencode(p_redirect_uri),
      'application/x-www-form-urlencoded'
    );
  exception when others then
    -- 连接 / 超时 / DNS 等出站异常：不区分细节（探测面），交回调编排映射 im_failed
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed', 'detail', '飞书授权码换 token 出站请求失败'
    );
  end;

  return app.im_parse_exchange_response(v_response.status, v_response.content);
end;
$$;

comment on function app.im_exchange_code(text, text, text) is
  '授权码换 user_access_token（v3 表单接口，extensions.http 同步 POST）：'
  '未启用 / 凭据缺失返回 {ok:false,im_unavailable}；出站异常与厂商错误经 '
  'app.im_parse_exchange_response 统一为 {ok:false,error,detail}；secret 只在本函数作用域；'
  '不 GRANT 任何角色';

-- 4.12 app.im_fetch_userid：user_access_token 换厂商 userid（Bearer GET）
create function app.im_fetch_userid(p_provider text, p_access_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_provider text := lower(btrim(coalesce(p_provider, '')));
  v_response extensions.http_response;
begin
  if v_provider <> 'feishu' then
    raise exception '厂商 % 回调尚未接入（im/002 仅飞书）', v_provider using errcode = '22023';
  end if;
  if p_access_token is null or btrim(p_access_token) = '' or length(p_access_token) > 4096 then
    raise exception 'access_token 非法' using errcode = '22023';
  end if;

  perform app.im_http_timeout();
  begin
    v_response := extensions.http(
      (
        'GET',
        'https://open.feishu.cn/open-apis/authen/v1/user_info',
        array[extensions.http_header('Authorization', 'Bearer ' || p_access_token)],
        null::text,
        null::text
      )::extensions.http_request
    );
  exception when others then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed', 'detail', '飞书获取用户信息出站请求失败'
    );
  end;

  return app.im_parse_identity_response(v_response.status, v_response.content);
end;
$$;

comment on function app.im_fetch_userid(text, text) is
  'user_access_token 换厂商 userid（user_info Bearer GET）：出站异常 / 厂商错误经 '
  'app.im_parse_identity_response 统一为 {ok:false,error,detail}；不 GRANT 任何角色';

-- 4.13 app.im_handle_callback：回调编排（换 token → 取 userid → 预绑定匹配）
create function app.im_handle_callback(
  p_provider     text,
  p_code         text,
  p_redirect_uri text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_provider    text := lower(btrim(coalesce(p_provider, '')));
  v_exchange    jsonb;
  v_identity    jsonb;
  v_binding     jsonb;
  v_userid      text;
  v_error       text;
begin
  if v_provider not in ('wecom', 'feishu', 'dingtalk') then
    raise exception '未知 IM 厂商：%', coalesce(p_provider, '(null)') using errcode = '22023';
  end if;
  if v_provider <> 'feishu' then
    raise exception '厂商 % 回调尚未接入（im/002 仅飞书）', v_provider using errcode = '22023';
  end if;
  if p_code is null or btrim(p_code) = '' or length(p_code) > 512 then
    raise exception '授权码非法' using errcode = '22023';
  end if;
  if p_redirect_uri is null or p_redirect_uri !~ '^https?://[^[:space:]]+$' then
    raise exception '回调地址非法' using errcode = '22023';
  end if;

  v_exchange := app.im_exchange_code(v_provider, p_code, p_redirect_uri);
  if not coalesce((v_exchange ->> 'ok')::boolean, false) then
    v_error := coalesce(v_exchange ->> 'error', 'im_failed');
    return jsonb_build_object('ok', false, 'error', v_error, 'detail', v_exchange ->> 'detail');
  end if;

  v_identity := app.im_fetch_userid(v_provider, v_exchange ->> 'access_token');
  if not coalesce((v_identity ->> 'ok')::boolean, false) then
    v_error := coalesce(v_identity ->> 'error', 'im_failed');
    return jsonb_build_object('ok', false, 'error', v_error, 'detail', v_identity ->> 'detail');
  end if;
  v_userid := v_identity ->> 'userid';

  v_binding := app.im_resolve_binding(v_provider, v_userid);
  if v_binding is null then
    return jsonb_build_object('ok', false, 'error', 'im_not_bound', 'im_userid', v_userid);
  end if;
  if coalesce(v_binding ->> 'status', '') <> 'active' then
    return jsonb_build_object('ok', false, 'error', 'im_banned', 'im_userid', v_userid);
  end if;

  return jsonb_build_object(
    'ok', true,
    'user_id', v_binding ->> 'user_id',
    'im_userid', v_userid
  );
end;
$$;

comment on function app.im_handle_callback(text, text, text) is
  'IM 回调编排（内部实现，不 GRANT 任何角色）：换 token → 取 userid（secret 不出库）→ '
  'profiles 预绑定匹配；返回 {ok:true,user_id,im_userid} 或 '
  '{ok:false,error:im_unavailable|im_failed|im_not_bound|im_banned[,im_userid/detail]}；'
  '参数非法抛 22023；不签发 session（仍由 Next.js 经 Supabase Auth admin API 签发，ADR-003 §3）';

-- ---------------------------------------------------------------------------
-- 5. 公开薄包装 + 授权：仅 im_backend 可执行（API 角色零路径）
-- ---------------------------------------------------------------------------
create function public.im_start_auth(
  p_provider     text,
  p_redirect_uri text,
  p_state        text
)
returns text
language sql
security definer
set search_path = ''
as $$
  select app.im_build_authorize_url(p_provider, p_redirect_uri, p_state)
$$;

comment on function public.im_start_auth(text, text, text) is
  'IM 授权起点 Data API 薄包装（实现与凭据解密在 app.im_build_authorize_url）：'
  '返回厂商授权页 URL，secret 不出库；仅 GRANT im_backend（Next.js 服务端）';

create function public.im_handle_callback(
  p_provider     text,
  p_code         text,
  p_redirect_uri text
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.im_handle_callback(p_provider, p_code, p_redirect_uri)
$$;

comment on function public.im_handle_callback(text, text, text) is
  'IM 授权回调 Data API 薄包装（编排在 app.im_handle_callback）：换 token / 取 userid / '
  '绑定匹配全在 Postgres 内，secret 不出库；返回 {ok,...} 或错误码；仅 GRANT im_backend';

revoke all on function public.record_im_login_attempt(text, text, boolean, text)
  from public, anon, authenticated, service_role;
grant execute on function public.record_im_login_attempt(text, text, boolean, text)
  to anon, authenticated;

revoke all on function public.im_start_auth(text, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.im_start_auth(text, text, text)
  to im_backend;

revoke all on function public.im_handle_callback(text, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.im_handle_callback(text, text, text)
  to im_backend;

-- 实现函数零授权（仅经 SECURITY DEFINER 包装链式调用；PostgREST 只暴露 public schema）
revoke all on function app.urlencode(text) from public, anon, authenticated, service_role;
revoke all on function app.im_provider_credentials(text) from public, anon, authenticated, service_role;
revoke all on function app.im_http_timeout() from public, anon, authenticated, service_role;
revoke all on function app.im_parse_exchange_response(integer, text) from public, anon, authenticated, service_role;
revoke all on function app.im_parse_identity_response(integer, text) from public, anon, authenticated, service_role;
revoke all on function app.im_resolve_binding(text, text) from public, anon, authenticated, service_role;
revoke all on function app.im_build_authorize_url(text, text, text) from public, anon, authenticated, service_role;
revoke all on function app.im_exchange_code(text, text, text) from public, anon, authenticated, service_role;
revoke all on function app.im_fetch_userid(text, text) from public, anon, authenticated, service_role;
revoke all on function app.im_handle_callback(text, text, text) from public, anon, authenticated, service_role;

grant usage on schema public to im_backend;

-- PostgREST 会话用户为 authenticator；SET ROLE im_backend 需要成员资格（显式 SET，
-- 与 rolINHERIT 无关）。裸 Postgres 环境无 authenticator 时跳过。
do $do$
begin
  if exists (
    select 1 from pg_catalog.pg_roles where rolname = 'authenticator'
  ) then
    grant im_backend to authenticator;
  end if;
end
$do$;
