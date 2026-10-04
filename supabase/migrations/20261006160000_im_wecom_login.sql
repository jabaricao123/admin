-- 系统管理 · 企业微信扫码 + 移动免登数据面（工单 im/004）
-- 契约：docs/adr/003-im-login.md §1（全局单选启用）/§4（state 防代扫、audit via=im）/
--       §7（企业微信第二批：在飞书抽象之上检验厂商差异）、
--       docs/adr/004-im-login-credential-boundary.md（凭据解密与 OAuth 出站全在 Postgres；
--       Next.js 只调两个公开薄包装；本迁移保持两包装签名不变、内部按 provider 分派）、
--       docs/modules/INDEX.md 规则 4（凭据统一加密 + 掩码）/ 规则 10（内部入口不 GRANT API
--       角色）、ADR-001（全局禁 service_role）。
--
-- 企业微信官方接口对应（企业自建应用）：
--   PC 扫码      https://open.work.weixin.qq.com/wwopen/sso/qrConnect?appid=CORPID&agentid=AGENTID…
--   App 内免登   https://open.weixin.qq.com/connect/oauth2/authorize?appid=CORPID…scope=snsapi_privateinfo
--                #wechat_redirect（「网页授权及 JS-SDK」需配置可信域名）
--   access_token https://qyapi.weixin.qq.com/cgi-bin/gettoken?corpid=&corpsecret=（expires_in 7200s）
--   code→userid  https://qyapi.weixin.qq.com/cgi-bin/auth/getuserinfo?access_token=&code=
--                （新版返回 userid；旧版 user/getuserinfo 返回 UserId，解析层两者兼容）
--
-- 两入口的客户端类型只有 Next.js 知道，而公开包装签名不可变：
-- start 路由把「IM 内嵌 WebView（UA 含 wxwork）」编码为 state 的 `m.` 前缀
-- （state 仍是一次性随机 + cookie 绑定，前缀只是授权端点模式标记），本文件据此选端点。
--
-- 组成：
--   1. app.im_wecom_token_cache：access_token 加密缓存（gettoken 有限频；键含 secret 指纹，
--      轮换 secret 即缓存失效）；
--   2. app.im_wecom_* 厂商适配：授权 URL / 响应解析（纯函数，pgTAP 覆盖）/ 缓存读写 /
--      gettoken / code 换 userid / 回调编排（换 token → 取 userid → 预绑定匹配）；
--   3. public.im_start_auth / public.im_handle_callback 改由 provider 分派（签名不变）；
--   4. 授权面：新 app 实现函数零 API 角色授权；两薄包装 ACL 保持仅 im_backend。
--
-- 兼容：不改飞书已实现 —— app.im_build_authorize_url / app.im_exchange_code /
--       app.im_fetch_userid / app.im_handle_callback 均原样保留，本迁移不触碰；
--       飞书分支行为与 im/002 完全一致。

-- ---------------------------------------------------------------------------
-- 1. app.im_wecom_token_cache：access_token 加密缓存（不暴露 API）
-- ---------------------------------------------------------------------------
create table app.im_wecom_token_cache (
  cache_key    text primary key,
  access_token bytea not null,
  expires_at   timestamptz not null,
  updated_at   timestamptz not null default now()
);

comment on table app.im_wecom_token_cache is
  '企业微信 access_token 缓存（gettoken 有限频，避免每登录一次换一次）：access_token 经 '
  'app.encrypt_secret 加密；cache_key = corp_id:sha256(secret)，轮换 secret 即失效；'
  'app schema 不经 PostgREST 暴露，无任何 API 角色表权限';
comment on column app.im_wecom_token_cache.cache_key is
  '缓存键：<corp_id>:<sha256(secret)>（app.im_wecom_cache_key 生成；不存 secret 明文）';
comment on column app.im_wecom_token_cache.access_token is
  'access_token 密文（app.encrypt_secret）；读取经 app.im_wecom_cached_token 在函数内解密';
comment on column app.im_wecom_token_cache.expires_at is
  'token 过期时间（now() + expires_in）；读取侧预留 5 分钟余量，见 app.im_wecom_cached_token';
comment on column app.im_wecom_token_cache.updated_at is '最近一次写入时间';

alter table app.im_wecom_token_cache enable row level security;
revoke all on app.im_wecom_token_cache from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. app.im_wecom_cache_key：缓存键 = corp_id:sha256(secret)（纯函数）
-- ---------------------------------------------------------------------------
create function app.im_wecom_cache_key(p_corp_id text, p_secret text)
returns text
language sql
immutable
set search_path = ''
as $$
  select btrim(coalesce(p_corp_id, '')) || ':' ||
         encode(extensions.digest(btrim(coalesce(p_secret, '')), 'sha256'), 'hex')
$$;

comment on function app.im_wecom_cache_key(text, text) is
  '企业微信 access_token 缓存键：corp_id + secret 的 sha256 指纹；secret 轮换后键变化，'
  '缓存自然失效（密钥不落明文）；不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 3. app.im_wecom_parse_token_response：gettoken 响应解析（纯函数，pgTAP 覆盖）
-- ---------------------------------------------------------------------------
create function app.im_wecom_parse_token_response(p_http_status integer, p_content text)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_body    jsonb;
  v_expires integer;
begin
  if p_http_status is distinct from 200 then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed',
      'detail', format('企业微信获取 access_token HTTP %s', p_http_status)
    );
  end if;

  begin
    v_body := p_content::jsonb;
  exception when others then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed',
      'detail', '企业微信获取 access_token 响应不是合法 JSON'
    );
  end;

  if coalesce(v_body ->> 'errcode', '') <> '0' then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed',
      'detail', format(
        '企业微信获取 access_token 失败（errcode=%s）：%s',
        coalesce(v_body ->> 'errcode', '?'),
        coalesce(nullif(v_body ->> 'errmsg', ''), '未知错误')
      )
    );
  end if;

  if nullif(btrim(coalesce(v_body ->> 'access_token', '')), '') is null then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed',
      'detail', '企业微信获取 access_token 响应缺少 access_token'
    );
  end if;

  begin
    v_expires := (v_body ->> 'expires_in')::integer;
  exception when others then
    v_expires := null;
  end;

  return jsonb_build_object(
    'ok', true,
    'access_token', btrim(v_body ->> 'access_token'),
    'expires_in', v_expires
  );
end;
$$;

comment on function app.im_wecom_parse_token_response(integer, text) is
  '企业微信 gettoken 响应解析：HTTP 非 200 / 非法 JSON / errcode<>0 / 缺 access_token 均返回 '
  '{ok:false,error,detail}（detail 仅含 errcode 与 errmsg，不含 secret）；成功返回 '
  '{ok:true,access_token,expires_in}；不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 4. app.im_wecom_parse_identity_response：code 换 userid 响应解析（纯函数，pgTAP 覆盖）
-- ---------------------------------------------------------------------------
create function app.im_wecom_parse_identity_response(p_http_status integer, p_content text)
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
      'detail', format('企业微信获取用户身份 HTTP %s', p_http_status)
    );
  end if;

  begin
    v_body := p_content::jsonb;
  exception when others then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed',
      'detail', '企业微信获取用户身份响应不是合法 JSON'
    );
  end;

  if coalesce(v_body ->> 'errcode', '') <> '0' then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed',
      'detail', format(
        '企业微信获取用户身份失败（errcode=%s）：%s',
        coalesce(v_body ->> 'errcode', '?'),
        coalesce(nullif(v_body ->> 'errmsg', ''), '未知错误')
      )
    );
  end if;

  -- 新版 auth/getuserinfo → userid；旧版 user/getuserinfo → UserId（兼容两者）
  v_userid := nullif(btrim(coalesce(v_body ->> 'userid', v_body ->> 'UserId')), '');
  if v_userid is null then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed',
      'detail', '未取得 userid（非企业成员，或成员不在应用可见范围）'
    );
  end if;
  -- 与 profiles.wecom_userid 的 CHECK 对齐，避免带入不可入库字符
  -- （互联企业返回的 CorpId/userid 含 '/'，本系统不支持，按格式非法拒绝）
  if v_userid !~ '^[A-Za-z0-9_-]+$' then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed', 'detail', '企业微信 userid 格式非法'
    );
  end if;

  return jsonb_build_object('ok', true, 'userid', v_userid);
end;
$$;

comment on function app.im_wecom_parse_identity_response(integer, text) is
  '企业微信 code→userid 响应解析：HTTP 非 200 / 非法 JSON / errcode<>0 / 缺 userid / '
  'userid 格式非法均返回 {ok:false,error,detail}；userid 与 UserId 两键均兼容；'
  '成功返回 {ok:true,userid}；不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 5. app.im_wecom_cached_token / store_token / access_token：缓存读写与 gettoken
-- ---------------------------------------------------------------------------
-- 读缓存：命中且剩余有效期 > 5 分钟才返回（避免拿到临界过期 token）
create function app.im_wecom_cached_token(p_corp_id text, p_secret text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_cipher bytea;
begin
  select t.access_token into v_cipher
  from app.im_wecom_token_cache t
  where t.cache_key = app.im_wecom_cache_key(p_corp_id, p_secret)
    and t.expires_at > now() + interval '5 minutes';

  return app.decrypt_secret(v_cipher);
end;
$$;

comment on function app.im_wecom_cached_token(text, text) is
  '企业微信 access_token 缓存读取（内部 helper）：按 corp_id+secret 指纹命中且剩余有效期 '
  '>5 分钟时返回明文 token，否则 NULL；不 GRANT API 角色';

-- 写缓存：加密存储 + 过期时间（expires_in 防御性收敛到 60s..7200s）
create function app.im_wecom_store_token(
  p_corp_id      text,
  p_secret       text,
  p_access_token text,
  p_expires_in   integer
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ttl integer;
begin
  if nullif(btrim(coalesce(p_access_token, '')), '') is null then
    raise exception 'access_token 不能为空' using errcode = '22023';
  end if;

  v_ttl := least(greatest(coalesce(p_expires_in, 7200), 60), 7200);

  insert into app.im_wecom_token_cache (cache_key, access_token, expires_at, updated_at)
  values (
    app.im_wecom_cache_key(p_corp_id, p_secret),
    app.encrypt_secret(p_access_token),
    now() + make_interval(secs => v_ttl),
    now()
  )
  on conflict (cache_key) do update
     set access_token = excluded.access_token,
         expires_at   = excluded.expires_at,
         updated_at   = now();
end;
$$;

comment on function app.im_wecom_store_token(text, text, text, integer) is
  '企业微信 access_token 缓存写入（内部 helper）：app.encrypt_secret 加密后 upsert；'
  'expires_in 收敛到 60s..7200s（缺省 7200）；不 GRANT API 角色';

-- 取 access_token：缓存优先，未命中 / 过期则 GET gettoken 并回填
create function app.im_wecom_access_token(p_corp_id text, p_secret text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token    text;
  v_response extensions.http_response;
  v_parsed   jsonb;
begin
  if nullif(btrim(coalesce(p_corp_id, '')), '') is null
     or nullif(btrim(coalesce(p_secret, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'im_unavailable');
  end if;

  v_token := app.im_wecom_cached_token(p_corp_id, p_secret);
  if v_token is not null then
    return jsonb_build_object('ok', true, 'access_token', v_token, 'cached', true);
  end if;

  perform app.im_http_timeout();
  begin
    v_response := extensions.http_get(
      'https://qyapi.weixin.qq.com/cgi-bin/gettoken'
        || '?corpid=' || app.urlencode(p_corp_id)
        || '&corpsecret=' || app.urlencode(p_secret)
    );
  exception when others then
    -- 连接 / 超时 / DNS 等出站异常：不区分细节（探测面），统一映射
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed',
      'detail', '企业微信获取 access_token 出站请求失败'
    );
  end;

  v_parsed := app.im_wecom_parse_token_response(v_response.status, v_response.content);
  if not coalesce((v_parsed ->> 'ok')::boolean, false) then
    return v_parsed;
  end if;

  perform app.im_wecom_store_token(
    p_corp_id,
    p_secret,
    v_parsed ->> 'access_token',
    (v_parsed ->> 'expires_in')::integer
  );

  return jsonb_build_object(
    'ok', true,
    'access_token', v_parsed ->> 'access_token',
    'cached', false
  );
end;
$$;

comment on function app.im_wecom_access_token(text, text) is
  '企业微信 access_token 获取（内部 helper）：缓存优先（cached=true），未命中经 '
  'extensions.http 同步 GET gettoken 并加密回填；出站异常与厂商错误统一 '
  '{ok:false,error:im_failed,detail}；secret 只在本函数作用域；不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 6. app.im_wecom_build_authorize_url：授权 URL（PC 扫码 / App 内免登，secret 不出库）
-- ---------------------------------------------------------------------------
create function app.im_wecom_build_authorize_url(
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
  v_credentials jsonb;
  v_corp_id     text;
  v_agent_id    text;
  v_mobile      boolean := coalesce(p_state, '') like 'm.%';
begin
  if p_redirect_uri is null or p_redirect_uri !~ '^https?://[^[:space:]]+$' then
    raise exception '回调地址非法' using errcode = '22023';
  end if;
  -- state 由 Next.js 生成（base64url + 毫秒时间戳，可带 `m.` 免登前缀）
  if p_state is null or p_state !~ '^[A-Za-z0-9._-]{16,128}$' then
    raise exception 'state 非法' using errcode = '22023';
  end if;

  v_credentials := app.im_provider_credentials('wecom');
  if v_credentials is null then
    raise exception 'IM 厂商未启用或凭据缺失：wecom' using errcode = '42501';
  end if;

  v_corp_id := nullif(btrim(v_credentials ->> 'corp_id'), '');
  v_agent_id := nullif(btrim(v_credentials ->> 'agent_id'), '');
  if v_corp_id is null or v_agent_id is null then
    raise exception 'IM 厂商凭据缺少 corp_id / agent_id（请在配置中重新保存）' using errcode = '42501';
  end if;

  if v_mobile then
    -- 企业微信 App 内免登：开放平台网页授权（snsapi_privateinfo 需 agentid 且配置可信域名）
    return 'https://open.weixin.qq.com/connect/oauth2/authorize'
      || '?appid=' || app.urlencode(v_corp_id)
      || '&redirect_uri=' || app.urlencode(p_redirect_uri)
      || '&response_type=code'
      || '&scope=' || app.urlencode('snsapi_privateinfo')
      || '&agentid=' || app.urlencode(v_agent_id)
      || '&state=' || app.urlencode(p_state)
      || '#wechat_redirect';
  end if;

  -- PC 扫码：企业微信托管二维码页（appid=corpid；redirect_uri 需在网页应用可信域名内）
  return 'https://open.work.weixin.qq.com/wwopen/sso/qrConnect'
    || '?appid=' || app.urlencode(v_corp_id)
    || '&agentid=' || app.urlencode(v_agent_id)
    || '&redirect_uri=' || app.urlencode(p_redirect_uri)
    || '&state=' || app.urlencode(p_state);
end;
$$;

comment on function app.im_wecom_build_authorize_url(text, text) is
  '企业微信授权 URL 构造（内部实现，不 GRANT 任何角色）：解密启用的厂商凭据；state 以 '
  '`m.` 前缀标记 App 内免登（oauth2/authorize + snsapi_privateinfo），否则 PC 扫码 '
  '（wwopen/sso/qrConnect）；corp_id / agent_id 出现在 URL（公开标识），secret 不出函数作用域；'
  '未启用 / 凭据缺失抛 42501，参数非法抛 22023';

-- ---------------------------------------------------------------------------
-- 7. app.im_wecom_exchange_code：code → userid（gettoken 缓存 + auth/getuserinfo）
-- ---------------------------------------------------------------------------
create function app.im_wecom_exchange_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_credentials jsonb;
  v_corp_id     text;
  v_secret      text;
  v_token       jsonb;
  v_response    extensions.http_response;
begin
  if p_code is null or btrim(p_code) = '' or length(p_code) > 512 then
    raise exception '授权码非法' using errcode = '22023';
  end if;

  v_credentials := app.im_provider_credentials('wecom');
  if v_credentials is null then
    return jsonb_build_object('ok', false, 'error', 'im_unavailable');
  end if;
  v_corp_id := nullif(btrim(v_credentials ->> 'corp_id'), '');
  v_secret := nullif(btrim(v_credentials ->> 'secret'), '');
  if v_corp_id is null or v_secret is null then
    return jsonb_build_object('ok', false, 'error', 'im_unavailable');
  end if;

  -- 先拿 access_token（缓存优先），再用 code 换 userid
  v_token := app.im_wecom_access_token(v_corp_id, v_secret);
  if not coalesce((v_token ->> 'ok')::boolean, false) then
    return jsonb_build_object(
      'ok', false,
      'error', coalesce(v_token ->> 'error', 'im_failed'),
      'detail', v_token ->> 'detail'
    );
  end if;

  perform app.im_http_timeout();
  begin
    v_response := extensions.http_get(
      'https://qyapi.weixin.qq.com/cgi-bin/auth/getuserinfo'
        || '?access_token=' || app.urlencode(v_token ->> 'access_token')
        || '&code=' || app.urlencode(p_code)
    );
  exception when others then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed',
      'detail', '企业微信授权码换用户身份出站请求失败'
    );
  end;

  return app.im_wecom_parse_identity_response(v_response.status, v_response.content);
end;
$$;

comment on function app.im_wecom_exchange_code(text) is
  '企业微信 code → userid（gettoken 缓存 + auth/getuserinfo，extensions.http 同步）：'
  '未启用 / 凭据缺失返回 {ok:false,im_unavailable}；出站异常与厂商错误经解析函数统一为 '
  '{ok:false,error,detail}；access_token 与 secret 只在本函数作用域；不 GRANT 任何角色';

-- ---------------------------------------------------------------------------
-- 8. app.im_wecom_handle_callback：回调编排（code→userid → 预绑定匹配）
-- ---------------------------------------------------------------------------
create function app.im_wecom_handle_callback(
  p_code         text,
  p_redirect_uri text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_identity jsonb;
  v_binding  jsonb;
  v_userid   text;
  v_error    text;
begin
  if p_redirect_uri is null or p_redirect_uri !~ '^https?://[^[:space:]]+$' then
    raise exception '回调地址非法' using errcode = '22023';
  end if;

  v_identity := app.im_wecom_exchange_code(p_code);
  if not coalesce((v_identity ->> 'ok')::boolean, false) then
    v_error := coalesce(v_identity ->> 'error', 'im_failed');
    return jsonb_build_object(
      'ok', false, 'error', v_error, 'detail', v_identity ->> 'detail'
    );
  end if;
  v_userid := v_identity ->> 'userid';

  v_binding := app.im_resolve_binding('wecom', v_userid);
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

comment on function app.im_wecom_handle_callback(text, text) is
  '企业微信回调编排（内部实现，不 GRANT 任何角色）：code 换 userid（内含 gettoken 缓存；'
  'secret 不出库）→ profiles.wecom_userid 预绑定匹配；返回 {ok:true,user_id,im_userid} 或 '
  '{ok:false,error:im_unavailable|im_failed|im_not_bound|im_banned[,im_userid/detail]}；'
  '参数非法抛 22023；不签发 session（仍由 Next.js 经 Supabase Auth admin API 签发，ADR-003 §3）';

-- ---------------------------------------------------------------------------
-- 9. 公开薄包装：签名不变，内部按 provider 分派（飞书 → im/002 原实现）
-- ---------------------------------------------------------------------------
create or replace function public.im_start_auth(
  p_provider     text,
  p_redirect_uri text,
  p_state        text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_provider text := lower(btrim(coalesce(p_provider, '')));
begin
  if v_provider = 'feishu' then
    return app.im_build_authorize_url(p_provider, p_redirect_uri, p_state);
  elsif v_provider = 'wecom' then
    return app.im_wecom_build_authorize_url(p_redirect_uri, p_state);
  elsif v_provider = 'dingtalk' then
    raise exception '厂商 % 授权页尚未接入（im/004 已接入飞书 / 企业微信）', v_provider
      using errcode = '22023';
  else
    raise exception '未知 IM 厂商：%', coalesce(p_provider, '(null)') using errcode = '22023';
  end if;
end;
$$;

comment on function public.im_start_auth(text, text, text) is
  'IM 授权起点 Data API 薄包装（签名不变，内部按 provider 分派）：飞书 → '
  'app.im_build_authorize_url、企业微信 → app.im_wecom_build_authorize_url（state `m.` 前缀'
  ' = App 内免登）；返回厂商授权页 URL，secret 不出库；仅 GRANT im_backend（Next.js 服务端）';

create or replace function public.im_handle_callback(
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
  v_provider text := lower(btrim(coalesce(p_provider, '')));
begin
  if v_provider = 'feishu' then
    return app.im_handle_callback(p_provider, p_code, p_redirect_uri);
  elsif v_provider = 'wecom' then
    return app.im_wecom_handle_callback(p_code, p_redirect_uri);
  elsif v_provider = 'dingtalk' then
    raise exception '厂商 % 回调尚未接入（im/004 已接入飞书 / 企业微信）', v_provider
      using errcode = '22023';
  else
    raise exception '未知 IM 厂商：%', coalesce(p_provider, '(null)') using errcode = '22023';
  end if;
end;
$$;

comment on function public.im_handle_callback(text, text, text) is
  'IM 授权回调 Data API 薄包装（签名不变，内部按 provider 分派）：飞书 → '
  'app.im_handle_callback、企业微信 → app.im_wecom_handle_callback；换 token / 取 userid / '
  '绑定匹配全在 Postgres 内，secret 不出库；返回 {ok,...} 或错误码；仅 GRANT im_backend';

-- ---------------------------------------------------------------------------
-- 10. 授权：新 app 实现函数零 API 角色；两薄包装 ACL 维持仅 im_backend
-- ---------------------------------------------------------------------------
revoke all on function app.im_wecom_cache_key(text, text) from public, anon, authenticated, service_role;
revoke all on function app.im_wecom_parse_token_response(integer, text) from public, anon, authenticated, service_role;
revoke all on function app.im_wecom_parse_identity_response(integer, text) from public, anon, authenticated, service_role;
revoke all on function app.im_wecom_cached_token(text, text) from public, anon, authenticated, service_role;
revoke all on function app.im_wecom_store_token(text, text, text, integer) from public, anon, authenticated, service_role;
revoke all on function app.im_wecom_access_token(text, text) from public, anon, authenticated, service_role;
revoke all on function app.im_wecom_build_authorize_url(text, text) from public, anon, authenticated, service_role;
revoke all on function app.im_wecom_exchange_code(text) from public, anon, authenticated, service_role;
revoke all on function app.im_wecom_handle_callback(text, text) from public, anon, authenticated, service_role;

-- CREATE OR REPLACE 保留原 ACL；此处显式重放，保证任何应用顺序下都收口
revoke all on function public.im_start_auth(text, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.im_start_auth(text, text, text)
  to im_backend;

revoke all on function public.im_handle_callback(text, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.im_handle_callback(text, text, text)
  to im_backend;
