-- 系统管理 · 钉钉扫码 + WebView 免登数据面（工单 im/005）
-- 契约：docs/adr/003-im-login.md §1（全局单选启用）/§4（state 防代扫、audit via=im）/
--       §7（钉钉第三批：在飞书 / 企业微信之上检验 IMProvider 抽象的第二次扩展）、
--       docs/adr/004-im-login-credential-boundary.md（凭据解密与 OAuth 出站全在 Postgres；
--       Next.js 只调两个公开薄包装；本迁移保持两包装签名不变、内部按 provider 分派）、
--       docs/modules/INDEX.md 规则 4（凭据统一加密 + 掩码）/ 规则 10（内部入口不 GRANT API
--       角色）、ADR-001（全局禁 service_role）。
--
-- 钉钉官方接口对应（企业内部应用，open.dingtalk.com）：
--   授权页        https://login.dingtalk.com/oauth2/auth?redirect_uri=…&response_type=code
--                 &client_id=AppKey&scope=openid&state=…&prompt=consent
--                 （端外扫码与端内 WebView 免登是同一端点：钉钉端内已持有登录态，用户只需
--                  确认授权，无需输入账号密码；官方 prompt 固定 consent，无端内静默 URL）
--   code 换 token https://api.dingtalk.com/v1.0/oauth2/userAccessToken
--                 body {"clientId","clientSecret","code","grantType":"authorization_code"}（JSON）
--                 返回 accessToken / refreshToken / expireIn（7200s）
--   用户身份      https://api.dingtalk.com/v1.0/contact/users/me
--                 Header x-acs-dingtalk-access-token=accessToken；
--                 返回 nick/avatarUrl/mobile/openId/unionId/email/stateCode
--
-- 绑定键选择（本迁移的关键设计，工单 im/005 验收项）：
--   本系统以 **unionId** 作为 profiles.dingtalk_userid（绑定键），不是 userid 也不是 openId：
--   1) 该接口（userAccessToken 身份）不返回 userid —— 新版钉钉 OAuth2 响应只有 unionId/openId；
--      取 userid 需额外用「企业内部应用 access_token」调通讯录接口
--      （topapi/v2/user/getuserinfo / topapi/user/getbyunionid），即多一层应用级凭据 +
--      通讯录应用权限；扫码 / 免登链路不持有该凭据，无法在一次交互内拿到 userid；
--   2) unionId 在组织（企业）内唯一且稳定，适合作为跨账号绑定键；
--   3) openId 仅在「当前应用」内唯一，更换应用即失效，不适合做绑定键。
--   若后续要切 userid 绑定，需新增应用凭据与通讯录权限，属独立工单。
--
-- token 缓存：无。钉钉 userAccessToken 为 code→token 直换（没有 client_credential 中间层），
--   code 单次有效、token 与用户/授权一次性绑定；缓存会引入用户级 token 存储与失效管理，
--   收益极低，故每次回调直接换（与 wecom 的 app 级 access_token 缓存场景不同）。
--
-- 组成：
--   1. app.im_dingtalk_parse_token_response / app.im_dingtalk_parse_identity_response：
--      响应解析（纯函数，pgTAP 覆盖；错误统一映射 im_failed，detail 不含 secret）；
--   2. app.im_dingtalk_build_authorize_url：授权 URL（PC 扫码 / WebView 免登同一端点；
--      state `m.` 前缀沿用 im/004 约定并在此接受）；
--   3. app.im_dingtalk_exchange_code：code → userAccessToken → unionId（两次 extensions.http）；
--   4. app.im_dingtalk_handle_callback：回调编排（换 token → 取 unionId → 预绑定匹配）；
--   5. public.im_start_auth / public.im_handle_callback 改由 provider 分派（签名不变）；
--   6. 授权面：新 app 实现函数零 API 角色授权；两薄包装 ACL 保持仅 im_backend。
--
-- 凭据键（app.im_provider_credentials('dingtalk') 解密的 jsonb）：
--   app_key（必填；钉钉后台「AppKey」，新称 Client ID）+ app_secret（换 token 用；
--   钉钉后台「AppSecret」，新称 Client Secret）——与 im/006 配置页 / 连接测试同键；
--   兼容别名 client_id / client_secret / app_id / secret（本迁移按上序取首个非空）。
--   注意：登录链路把 app_key 作为 OAuth clientId 传给 userAccessToken（钉钉定义
--   clientId=AppKey、clientSecret=AppSecret）。
--
-- 兼容：不改飞书 / 企业微信已实现 —— app.im_build_authorize_url / app.im_exchange_code /
--       app.im_fetch_userid / app.im_handle_callback / app.im_wecom_* 均原样保留，本迁移不触碰；
--       public 两包装仅追加 dingtalk 分支。

-- ---------------------------------------------------------------------------
-- 1. app.im_dingtalk_parse_token_response：userAccessToken 响应解析（纯函数，pgTAP 覆盖）
-- ---------------------------------------------------------------------------
create function app.im_dingtalk_parse_token_response(p_http_status integer, p_content text)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_body    jsonb;
  v_detail  text;
  v_expires integer;
begin
  if p_http_status is distinct from 200 then
    -- 钉钉新版错误体：{code, message, requestid}；能解析则带上便于排查（无 secret）
    begin
      v_body := p_content::jsonb;
    exception when others then
      v_body := null;
    end;

    v_detail := format('钉钉获取用户 token HTTP %s', p_http_status);
    if v_body is not null and (v_body ? 'code' or v_body ? 'message') then
      v_detail := v_detail || format(
        '（code=%s）：%s',
        coalesce(v_body ->> 'code', '?'),
        coalesce(nullif(v_body ->> 'message', ''), '未知错误')
      );
    end if;

    return jsonb_build_object('ok', false, 'error', 'im_failed', 'detail', v_detail);
  end if;

  begin
    v_body := p_content::jsonb;
  exception when others then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed', 'detail', '钉钉获取用户 token 响应不是合法 JSON'
    );
  end;

  if nullif(btrim(coalesce(v_body ->> 'accessToken', '')), '') is null then
    if v_body ? 'code' or v_body ? 'message' then
      return jsonb_build_object(
        'ok', false, 'error', 'im_failed',
        'detail', format(
          '钉钉获取用户 token 失败（code=%s）：%s',
          coalesce(v_body ->> 'code', '?'),
          coalesce(nullif(v_body ->> 'message', ''), '未知错误')
        )
      );
    end if;
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed', 'detail', '钉钉获取用户 token 响应缺少 accessToken'
    );
  end if;

  begin
    v_expires := (v_body ->> 'expireIn')::integer;
  exception when others then
    v_expires := null;
  end;

  return jsonb_build_object(
    'ok', true,
    'access_token', btrim(v_body ->> 'accessToken'),
    'expires_in', v_expires
  );
end;
$$;

comment on function app.im_dingtalk_parse_token_response(integer, text) is
  '钉钉 userAccessToken 响应解析：HTTP 非 200（附 code/message，若有）/ 非法 JSON / 缺 '
  'accessToken 均返回 {ok:false,error:im_failed,detail}（detail 不含 secret）；成功返回 '
  '{ok:true,access_token,expires_in}；不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 2. app.im_dingtalk_parse_identity_response：联系人个人信息响应解析（纯函数，pgTAP 覆盖）
--    绑定键 = unionId（见文件头「绑定键选择」）；openId 仅应用内唯一，不采用
-- ---------------------------------------------------------------------------
create function app.im_dingtalk_parse_identity_response(p_http_status integer, p_content text)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_body     jsonb;
  v_detail   text;
  v_union_id text;
begin
  if p_http_status is distinct from 200 then
    begin
      v_body := p_content::jsonb;
    exception when others then
      v_body := null;
    end;

    v_detail := format('钉钉获取用户身份 HTTP %s', p_http_status);
    if v_body is not null and (v_body ? 'code' or v_body ? 'message') then
      v_detail := v_detail || format(
        '（code=%s）：%s',
        coalesce(v_body ->> 'code', '?'),
        coalesce(nullif(v_body ->> 'message', ''), '未知错误')
      );
    end if;

    return jsonb_build_object('ok', false, 'error', 'im_failed', 'detail', v_detail);
  end if;

  begin
    v_body := p_content::jsonb;
  exception when others then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed', 'detail', '钉钉获取用户身份响应不是合法 JSON'
    );
  end;

  -- 本系统绑定键 = unionId（企业内唯一且稳定）；openId 应用内唯一，不作为绑定依据
  v_union_id := nullif(btrim(coalesce(v_body ->> 'unionId', '')), '');
  if v_union_id is null then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed',
      'detail', '未取得 unionId（需在钉钉开发者后台申请个人权限「通讯录个人信息读权限」'
                ' Contact.User.Read；本系统以 unionId 作为绑定键）'
    );
  end if;
  -- 与 profiles.dingtalk_userid 的 CHECK 对齐，避免带入不可入库字符
  if v_union_id !~ '^[A-Za-z0-9_-]+$' then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed', 'detail', '钉钉 unionId 格式非法'
    );
  end if;

  return jsonb_build_object('ok', true, 'userid', v_union_id);
end;
$$;

comment on function app.im_dingtalk_parse_identity_response(integer, text) is
  '钉钉 contact/users/me 响应解析：HTTP 非 200（附 code/message，若有）/ 非法 JSON / 缺 '
  'unionId / unionId 格式非法均返回 {ok:false,error:im_failed,detail}；成功返回 '
  '{ok:true,userid}（userid 即 unionId，见文件头绑定键选择）；openId 不采用；'
  '不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 3. app.im_dingtalk_build_authorize_url：授权 URL（PC 扫码 / WebView 免登，secret 不出库）
-- ---------------------------------------------------------------------------
create function app.im_dingtalk_build_authorize_url(
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
  v_client_id   text;
begin
  if p_redirect_uri is null or p_redirect_uri !~ '^https?://[^[:space:]]+$' then
    raise exception '回调地址非法' using errcode = '22023';
  end if;
  -- state 由 Next.js 生成（base64url + 毫秒时间戳，可带 `m.` 免登前缀；沿用 im/004 约定）
  if p_state is null or p_state !~ '^[A-Za-z0-9._-]{16,128}$' then
    raise exception 'state 非法' using errcode = '22023';
  end if;

  v_credentials := app.im_provider_credentials('dingtalk');
  if v_credentials is null then
    raise exception 'IM 厂商未启用或凭据缺失：dingtalk' using errcode = '42501';
  end if;

  -- 规范键 app_key（钉钉 AppKey / 新称 Client ID）；兼容别名，按序取首个非空
  v_client_id := coalesce(
    nullif(btrim(v_credentials ->> 'app_key'), ''),
    nullif(btrim(v_credentials ->> 'client_id'), ''),
    nullif(btrim(v_credentials ->> 'app_id'), '')
  );
  if v_client_id is null then
    raise exception 'IM 厂商凭据缺少 app_key（钉钉 AppKey）' using errcode = '42501';
  end if;

  -- 端外扫码与端内 WebView 免登共用本端点：端内钉钉已登录，授权页仅需确认（免账号密码）。
  -- state 的 `m.` 前缀由 start 路由按 UA 注入（沿用 im/004 约定），端内 / 端外 URL 一致，
  -- 前缀在此被接受并留作模式标记（官方 prompt 固定 consent，无端内静默 URL）。
  return 'https://login.dingtalk.com/oauth2/auth'
    || '?redirect_uri=' || app.urlencode(p_redirect_uri)
    || '&response_type=code'
    || '&client_id=' || app.urlencode(v_client_id)
    || '&scope=' || app.urlencode('openid')
    || '&state=' || app.urlencode(p_state)
    || '&prompt=consent';
end;
$$;

comment on function app.im_dingtalk_build_authorize_url(text, text) is
  '钉钉授权 URL 构造（内部实现，不 GRANT 任何角色）：解密启用的厂商凭据；client_id / '
  'scope=openid / prompt=consent（PC 扫码与端内 WebView 免登同一端点，state `m.` 前缀被接受）；'
  'client_id 出现在 URL（公开标识），secret 不出函数作用域；未启用 / 凭据缺失抛 42501，'
  '参数非法抛 22023';

-- ---------------------------------------------------------------------------
-- 4. app.im_dingtalk_exchange_code：code → userAccessToken → unionId（无缓存，见文件头）
-- ---------------------------------------------------------------------------
create function app.im_dingtalk_exchange_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_credentials jsonb;
  v_client_id   text;
  v_secret      text;
  v_token_body  text;
  v_response    extensions.http_response;
  v_parsed      jsonb;
  v_access_token text;
begin
  if p_code is null or btrim(p_code) = '' or length(p_code) > 512 then
    raise exception '授权码非法' using errcode = '22023';
  end if;

  v_credentials := app.im_provider_credentials('dingtalk');
  if v_credentials is null then
    return jsonb_build_object('ok', false, 'error', 'im_unavailable');
  end if;
  v_client_id := coalesce(
    nullif(btrim(v_credentials ->> 'app_key'), ''),
    nullif(btrim(v_credentials ->> 'client_id'), ''),
    nullif(btrim(v_credentials ->> 'app_id'), '')
  );
  v_secret := coalesce(
    nullif(btrim(v_credentials ->> 'app_secret'), ''),
    nullif(btrim(v_credentials ->> 'client_secret'), ''),
    nullif(btrim(v_credentials ->> 'secret'), '')
  );
  if v_client_id is null or v_secret is null then
    return jsonb_build_object('ok', false, 'error', 'im_unavailable');
  end if;

  -- 第一步：code 换 userAccessToken（JSON body；官方接口无 redirect_uri 参数）
  v_token_body := jsonb_build_object(
    'clientId', v_client_id,
    'clientSecret', v_secret,
    'code', p_code,
    'grantType', 'authorization_code'
  )::text;

  perform app.im_http_timeout();
  begin
    v_response := extensions.http_post(
      'https://api.dingtalk.com/v1.0/oauth2/userAccessToken',
      v_token_body,
      'application/json'
    );
  exception when others then
    -- 连接 / 超时 / DNS 等出站异常：不区分细节（探测面），统一映射
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed', 'detail', '钉钉用户 token 出站请求失败'
    );
  end;

  v_parsed := app.im_dingtalk_parse_token_response(v_response.status, v_response.content);
  if not coalesce((v_parsed ->> 'ok')::boolean, false) then
    return v_parsed;
  end if;
  v_access_token := v_parsed ->> 'access_token';

  -- 第二步：userAccessToken 换身份（unionId；unionId 参数传 me 即当前授权人）
  perform app.im_http_timeout();
  begin
    v_response := extensions.http(
      (
        'GET',
        'https://api.dingtalk.com/v1.0/contact/users/me',
        array[extensions.http_header('x-acs-dingtalk-access-token', v_access_token)],
        null::text,
        null::text
      )::extensions.http_request
    );
  exception when others then
    return jsonb_build_object(
      'ok', false, 'error', 'im_failed', 'detail', '钉钉获取用户身份出站请求失败'
    );
  end;

  return app.im_dingtalk_parse_identity_response(v_response.status, v_response.content);
end;
$$;

comment on function app.im_dingtalk_exchange_code(text) is
  '钉钉 code → unionId（extensions.http 同步两步：userAccessToken JSON POST → contact/users/me '
  'Bearer GET）：未启用 / 凭据缺失返回 {ok:false,im_unavailable}；出站异常与厂商错误经解析'
  '函数统一为 {ok:false,error,detail}；token / secret 只在本函数作用域；无 token 缓存'
  '（code 单次直换，见文件头）；不 GRANT 任何角色';

-- ---------------------------------------------------------------------------
-- 5. app.im_dingtalk_handle_callback：回调编排（code→unionId → 预绑定匹配）
-- ---------------------------------------------------------------------------
create function app.im_dingtalk_handle_callback(
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

  v_identity := app.im_dingtalk_exchange_code(p_code);
  if not coalesce((v_identity ->> 'ok')::boolean, false) then
    v_error := coalesce(v_identity ->> 'error', 'im_failed');
    return jsonb_build_object(
      'ok', false, 'error', v_error, 'detail', v_identity ->> 'detail'
    );
  end if;
  v_userid := v_identity ->> 'userid';

  v_binding := app.im_resolve_binding('dingtalk', v_userid);
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

comment on function app.im_dingtalk_handle_callback(text, text) is
  '钉钉回调编排（内部实现，不 GRANT 任何角色）：code 换 unionId（secret 不出库）→ '
  'profiles.dingtalk_userid 预绑定匹配；返回 {ok:true,user_id,im_userid} 或 '
  '{ok:false,error:im_unavailable|im_failed|im_not_bound|im_banned[,im_userid/detail]}；'
  '参数非法抛 22023；不签发 session（仍由 Next.js 经 Supabase Auth admin API 签发，ADR-003 §3）';

-- ---------------------------------------------------------------------------
-- 6. 公开薄包装：签名不变，内部按 provider 分派（飞书 / 企业微信原实现不动）
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
    return app.im_dingtalk_build_authorize_url(p_redirect_uri, p_state);
  else
    raise exception '未知 IM 厂商：%', coalesce(p_provider, '(null)') using errcode = '22023';
  end if;
end;
$$;

comment on function public.im_start_auth(text, text, text) is
  'IM 授权起点 Data API 薄包装（签名不变，内部按 provider 分派）：飞书 → '
  'app.im_build_authorize_url、企业微信 → app.im_wecom_build_authorize_url、钉钉 → '
  'app.im_dingtalk_build_authorize_url（state `m.` 前缀 = IM 端内免登）；返回厂商授权页 URL，'
  'secret 不出库；仅 GRANT im_backend（Next.js 服务端）';

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
    return app.im_dingtalk_handle_callback(p_code, p_redirect_uri);
  else
    raise exception '未知 IM 厂商：%', coalesce(p_provider, '(null)') using errcode = '22023';
  end if;
end;
$$;

comment on function public.im_handle_callback(text, text, text) is
  'IM 授权回调 Data API 薄包装（签名不变，内部按 provider 分派）：飞书 → '
  'app.im_handle_callback、企业微信 → app.im_wecom_handle_callback、钉钉 → '
  'app.im_dingtalk_handle_callback；换 token / 取 userid / 绑定匹配全在 Postgres 内，'
  'secret 不出库；返回 {ok,...} 或错误码；仅 GRANT im_backend';

-- ---------------------------------------------------------------------------
-- 7. 授权：新 app 实现函数零 API 角色；两薄包装 ACL 维持仅 im_backend
-- ---------------------------------------------------------------------------
revoke all on function app.im_dingtalk_parse_token_response(integer, text) from public, anon, authenticated, service_role;
revoke all on function app.im_dingtalk_parse_identity_response(integer, text) from public, anon, authenticated, service_role;
revoke all on function app.im_dingtalk_build_authorize_url(text, text) from public, anon, authenticated, service_role;
revoke all on function app.im_dingtalk_exchange_code(text) from public, anon, authenticated, service_role;
revoke all on function app.im_dingtalk_handle_callback(text, text) from public, anon, authenticated, service_role;

-- CREATE OR REPLACE 保留原 ACL；此处显式重放，保证任何应用顺序下都收口
revoke all on function public.im_start_auth(text, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.im_start_auth(text, text, text)
  to im_backend;

revoke all on function public.im_handle_callback(text, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.im_handle_callback(text, text, text)
  to im_backend;
