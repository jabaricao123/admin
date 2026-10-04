-- pgTAP：im/005 —— 钉钉扫码 + WebView 免登数据面
-- 覆盖：
--   1) 结构与授权面：公开包装签名不变（im_start_auth / im_handle_callback）；
--      app.im_dingtalk_* 实现函数零 anon/authenticated/service_role/im_backend 执行权；
--      im_backend 仅两薄包装；涉及凭据 / 出站的函数 security definer + search_path=''；
--   2) 授权 URL：PC 扫码与端内 WebView 免登（state `m.` 前缀）同一端点精确匹配；
--      scope=openid + prompt=consent；secret 不出现在 URL；client_id 别名 app_key 兼容；
--      未启用 / 凭据缺失 / 参数非法错误映射；
--   3) 响应解析（纯函数）：userAccessToken 与 contact/users/me 的成功 / 厂商错误体 /
--      HTTP / JSON / 缺字段；绑定键取 unionId（openId 不采用）；unionId 格式校验；
--   4) 回调与绑定：code 参数校验、回调地址校验；未启用 → im_unavailable（不出站）；
--      预绑定匹配（命中 / 未绑定 / 停用）；薄包装分派；匿名拒绝留痕 via=im_dingtalk。
-- 说明：真实出站（extensions.http → 钉钉）不依赖外网，pgTAP 以纯函数解析层 + 参数校验层
--       覆盖；出站成功路径由本地 mock 全链路验证（docs/evidence/im-005/README.md）。
-- 运行：supabase db reset && supabase test db
begin;

select plan(50);

-- ===========================================================================
-- 1. 结构与授权面（11）
-- ===========================================================================
select has_function('app', 'im_dingtalk_parse_token_response', array['integer','text'], 'app.im_dingtalk_parse_token_response 存在');
select has_function('app', 'im_dingtalk_parse_identity_response', array['integer','text'], 'app.im_dingtalk_parse_identity_response 存在');
select has_function('app', 'im_dingtalk_build_authorize_url', array['text','text'], 'app.im_dingtalk_build_authorize_url 存在');
select has_function('app', 'im_dingtalk_exchange_code', array['text'], 'app.im_dingtalk_exchange_code 存在');
select has_function('app', 'im_dingtalk_handle_callback', array['text','text'], 'app.im_dingtalk_handle_callback 存在');

-- 公开包装签名不变（im/005 验收项）：仍是 (text,text,text) → text / jsonb
select has_function('public', 'im_start_auth', array['text','text','text'],
  'public.im_start_auth(text,text,text) 签名未变');
select has_function('public', 'im_handle_callback', array['text','text','text'],
  'public.im_handle_callback(text,text,text) 签名未变');

select ok(
  (select bool_and(p.prosecdef and p.proconfig @> array['search_path=""'])
     from pg_proc p
    where p.oid in (
      'app.im_dingtalk_build_authorize_url(text,text)'::regprocedure,
      'app.im_dingtalk_exchange_code(text)'::regprocedure,
      'app.im_dingtalk_handle_callback(text,text)'::regprocedure
    )),
  '钉钉厂商函数（涉及凭据/出站）security definer + search_path 固定为空'
);
select ok(
  not exists (
    select 1
      from pg_proc p
     where p.oid in (
       'app.im_dingtalk_parse_token_response(integer,text)'::regprocedure,
       'app.im_dingtalk_parse_identity_response(integer,text)'::regprocedure,
       'app.im_dingtalk_build_authorize_url(text,text)'::regprocedure,
       'app.im_dingtalk_exchange_code(text)'::regprocedure,
       'app.im_dingtalk_handle_callback(text,text)'::regprocedure
     )
       and (
         has_function_privilege('anon', p.oid, 'EXECUTE')
         or has_function_privilege('authenticated', p.oid, 'EXECUTE')
         or has_function_privilege('service_role', p.oid, 'EXECUTE')
         or has_function_privilege('im_backend', p.oid, 'EXECUTE')
       )
  ),
  '5 个 app.im_dingtalk_* 实现函数零 API 角色 / im_backend 执行权'
);
select ok(
  has_function_privilege('im_backend', 'public.im_start_auth(text,text,text)', 'EXECUTE')
    and has_function_privilege('im_backend', 'public.im_handle_callback(text,text,text)', 'EXECUTE'),
  'im_backend 可执行两个薄包装'
);
select ok(
  not has_function_privilege('service_role', 'public.im_start_auth(text,text,text)', 'EXECUTE')
    and not has_function_privilege('service_role', 'public.im_handle_callback(text,text,text)', 'EXECUTE')
    and not has_function_privilege('anon', 'public.im_start_auth(text,text,text)', 'EXECUTE'),
  'service_role / anon 零执行权（ADR-001 全局禁令）'
);

-- ===========================================================================
-- 2. 授权 URL：PC 扫码 / WebView 免登（10）
-- ===========================================================================
-- 夹具：启用钉钉配置（含加密凭据；同一时刻至多一行 enabled）
update public.im_auth_configs set enabled = false where enabled;
insert into public.im_auth_configs (provider, enabled, credentials)
values (
  'dingtalk', true,
  app.encrypt_secret('{"app_key":"ding_test_client","app_secret":"dingtalk_test_secret"}')
)
on conflict (provider) do update
   set enabled = true, credentials = excluded.credentials;

select is(
  app.im_dingtalk_build_authorize_url(
    'https://admin.example.com/auth/callback/dingtalk',
    'teststate_0123456789abcdef'
  ),
  'https://login.dingtalk.com/oauth2/auth'
    || '?redirect_uri=https%3A%2F%2Fadmin.example.com%2Fauth%2Fcallback%2Fdingtalk'
    || '&response_type=code'
    || '&client_id=ding_test_client'
    || '&scope=openid'
    || '&state=teststate_0123456789abcdef'
    || '&prompt=consent',
  'PC 扫码授权 URL 精确匹配（oauth2/auth + prompt=consent）'
);
select is(
  app.im_dingtalk_build_authorize_url(
    'https://admin.example.com/auth/callback/dingtalk',
    'm.teststate_0123456789abcdef'
  ),
  'https://login.dingtalk.com/oauth2/auth'
    || '?redirect_uri=https%3A%2F%2Fadmin.example.com%2Fauth%2Fcallback%2Fdingtalk'
    || '&response_type=code'
    || '&client_id=ding_test_client'
    || '&scope=openid'
    || '&state=m.teststate_0123456789abcdef'
    || '&prompt=consent',
  'WebView 免登（state m. 前缀）与 PC 同一端点，前缀被接受'
);
select ok(
  position('dingtalk_test_secret' in app.im_dingtalk_build_authorize_url(
    'https://admin.example.com/auth/callback/dingtalk',
    'teststate_0123456789abcdef'
  )) = 0,
  '授权 URL 不含 secret（secret 不出库）'
);

-- 公开包装分派（im_backend 视角；pgTAP 断言函数位于 extensions schema，临时授权 USAGE）
grant usage on schema extensions to im_backend;
set local role im_backend;
select is(
  public.im_start_auth(
    'dingtalk',
    'https://admin.example.com/auth/callback/dingtalk',
    'teststate_0123456789abcdef'
  ),
  'https://login.dingtalk.com/oauth2/auth'
    || '?redirect_uri=https%3A%2F%2Fadmin.example.com%2Fauth%2Fcallback%2Fdingtalk'
    || '&response_type=code'
    || '&client_id=ding_test_client'
    || '&scope=openid'
    || '&state=teststate_0123456789abcdef'
    || '&prompt=consent',
  'im_backend 经薄包装取钉钉授权 URL（按 provider 分派）'
);
select ok(
  public.im_start_auth(
    'dingtalk',
    'https://admin.example.com/auth/callback/dingtalk',
    'm.teststate_0123456789abcdef'
  ) like '%state=m.teststate_0123456789abcdef%&prompt=consent',
  'im_backend 经薄包装传递 state m. 前缀（WebView 免登标记不丢）'
);
reset role;

-- 未启用 / 凭据缺失 / 别名 / 参数非法
update public.im_auth_configs set enabled = false where provider = 'dingtalk';
select throws_ok(
  $$ select app.im_dingtalk_build_authorize_url(
       'https://admin.example.com/auth/callback/dingtalk',
       'teststate_0123456789abcdef') $$,
  '42501', null, '停用钉钉后拒绝构造授权 URL'
);
update public.im_auth_configs
   set enabled = true,
       credentials = app.encrypt_secret('{"app_secret":"dingtalk_test_secret"}')
 where provider = 'dingtalk';
select throws_ok(
  $$ select app.im_dingtalk_build_authorize_url(
       'https://admin.example.com/auth/callback/dingtalk',
       'teststate_0123456789abcdef') $$,
  '42501', null, '缺少 app_key 拒绝构造授权 URL'
);
-- 新称 Client ID / Client Secret 别名兼容（im/006 配置页命名弹性）
update public.im_auth_configs
   set credentials = app.encrypt_secret('{"client_id":"ding_alias_key","client_secret":"ding_alias_secret"}')
 where provider = 'dingtalk';
select is(
  position('client_id=ding_alias_key' in app.im_dingtalk_build_authorize_url(
    'https://admin.example.com/auth/callback/dingtalk',
    'teststate_0123456789abcdef'
  )) > 0,
  true,
  '凭据别名 client_id / client_secret 兼容（新称 Client ID/Secret）'
);
update public.im_auth_configs
   set credentials = app.encrypt_secret('{"app_key":"ding_test_client","app_secret":"dingtalk_test_secret"}')
 where provider = 'dingtalk';
select throws_ok(
  $$ select app.im_dingtalk_build_authorize_url(
       'https://admin.example.com/auth/callback/dingtalk', 'bad') $$,
  '22023', null, 'state 格式非法被拒'
);
select throws_ok(
  $$ select app.im_dingtalk_build_authorize_url(
       'javascript:alert(1)', 'teststate_0123456789abcdef') $$,
  '22023', null, '回调地址非法被拒'
);
select throws_ok(
  $$ select public.im_start_auth(
       'saml', 'https://admin.example.com/auth/callback/dingtalk',
       'teststate_0123456789abcdef') $$,
  '22023', null, '未知厂商经薄包装被拒'
);

-- ===========================================================================
-- 3. 响应解析（纯函数）（15）
-- ===========================================================================
select is(
  app.im_dingtalk_parse_token_response(
    200, '{"accessToken":"tok_a","refreshToken":"ref_a","expireIn":7200,"corpId":"corp_x"}'),
  jsonb_build_object('ok', true, 'access_token', 'tok_a', 'expires_in', 7200),
  'userAccessToken 成功响应解析出 access_token / expires_in'
);
select is(
  app.im_dingtalk_parse_token_response(200, '{"accessToken":"tok_b"}'),
  jsonb_build_object('ok', true, 'access_token', 'tok_b', 'expires_in', null::integer),
  'userAccessToken 缺 expireIn 仍成功（无缓存，expires_in 仅透传）'
);
select ok(
  (app.im_dingtalk_parse_token_response(
     400, '{"code":"invalidParameter","message":"code参数不合法","requestid":"r1"}'
   ) ->> 'error') = 'im_failed'
    and position('invalidParameter' in app.im_dingtalk_parse_token_response(
      400, '{"code":"invalidParameter","message":"code参数不合法","requestid":"r1"}'
    ) ->> 'detail') > 0,
  'userAccessToken HTTP 400 厂商错误体映射 im_failed 且 detail 带 code'
);
select ok(
  (app.im_dingtalk_parse_token_response(502, 'not-json') ->> 'ok')::boolean = false
    and position('HTTP 502' in app.im_dingtalk_parse_token_response(502, 'not-json') ->> 'detail') > 0,
  'userAccessToken HTTP 非 200 且响应非 JSON 映射 im_failed'
);
select ok(
  (app.im_dingtalk_parse_token_response(200, 'not-json') ->> 'error') = 'im_failed',
  'userAccessToken 非法 JSON 映射 im_failed'
);
select ok(
  (app.im_dingtalk_parse_token_response(
     200, '{"code":"Forbidden.AccessDenied","message":"无权限"}'
   ) ->> 'error') = 'im_failed'
    and position('Forbidden.AccessDenied' in app.im_dingtalk_parse_token_response(
      200, '{"code":"Forbidden.AccessDenied","message":"无权限"}'
    ) ->> 'detail') > 0,
  'userAccessToken 200 带厂商错误体映射 im_failed 且 detail 带 code'
);
select ok(
  (app.im_dingtalk_parse_token_response(200, '{}') ->> 'error') = 'im_failed'
    and position('accessToken' in app.im_dingtalk_parse_token_response(200, '{}') ->> 'detail') > 0,
  'userAccessToken 缺 accessToken 映射 im_failed'
);

select is(
  app.im_dingtalk_parse_identity_response(
    200, '{"nick":"张三","openId":"open_1","unionId":"union_001","stateCode":"86"}'),
  jsonb_build_object('ok', true, 'userid', 'union_001'),
  'contact/users/me 成功解析：绑定键取 unionId'
);
select is(
  app.im_dingtalk_parse_identity_response(
    200, '{"openId":"open_1","unionId":"union_002"}') ->> 'userid',
  'union_002'::text,
  '同时返回 openId / unionId 时优先 unionId（openId 应用内唯一，不采用）'
);
select ok(
  (app.im_dingtalk_parse_identity_response(200, '{"openId":"open_only"}') ->> 'error') = 'im_failed'
    and position('unionId' in app.im_dingtalk_parse_identity_response(
      200, '{"openId":"open_only"}'
    ) ->> 'detail') > 0,
  '仅返回 openId（缺 unionId）映射 im_failed'
);
select ok(
  (app.im_dingtalk_parse_identity_response(200, '{"unionId":"corp/union"}') ->> 'error') = 'im_failed',
  '含 / 的 unionId 按格式非法拒绝（与 profiles CHECK 对齐）'
);
select ok(
  (app.im_dingtalk_parse_identity_response(
     404, '{"code":"invalidParameter.user.notFound","message":"找不到该用户"}'
   ) ->> 'ok')::boolean = false
    and position('HTTP 404' in app.im_dingtalk_parse_identity_response(
      404, '{"code":"invalidParameter.user.notFound","message":"找不到该用户"}'
    ) ->> 'detail') > 0,
  'contact/users/me HTTP 404 映射 im_failed'
);
select ok(
  (app.im_dingtalk_parse_identity_response(200, 'not-json') ->> 'error') = 'im_failed',
  'contact/users/me 非法 JSON 映射 im_failed'
);
select ok(
  (app.im_dingtalk_parse_identity_response(401, 'not-json') ->> 'ok')::boolean = false,
  'contact/users/me HTTP 401 映射 im_failed'
);
select ok(
  (app.im_dingtalk_parse_token_response(200, '{"accessToken":"tok_c"}') ->> 'expires_in') is null,
  'expires_in 为 SQL NULL（透传，不做缓存收敛）'
);
select is(
  app.im_dingtalk_parse_token_response(200, '{"accessToken":"  tok_trim  "}') ->> 'access_token',
  'tok_trim'::text,
  'accessToken 两端空白被裁剪'
);
select is(
  app.im_dingtalk_parse_identity_response(200, '{"unionId":"  union_trim  "}') ->> 'userid',
  'union_trim'::text,
  'unionId 两端空白被裁剪'
);

-- ===========================================================================
-- 4. 回调与绑定（14）
-- ===========================================================================
update public.profiles
   set dingtalk_userid = 'ding_union_eng_001'
 where id = '22222222-2222-2222-2222-222222220001';
select is(
  app.im_resolve_binding('dingtalk', 'ding_union_eng_001'),
  jsonb_build_object(
    'user_id', '22222222-2222-2222-2222-222222220001'::uuid,
    'email', 'engineer@example.com',
    'status', 'active'
  ),
  '已绑定 dingtalk unionId 解析出 user_id / email / status'
);
select is(
  app.im_resolve_binding('dingtalk', 'ding_union_ghost_001'),
  null::jsonb,
  '未绑定 dingtalk unionId 返回 NULL'
);
update public.profiles set status = 'inactive'
 where id = '22222222-2222-2222-2222-222222220001';
select is(
  app.im_resolve_binding('dingtalk', 'ding_union_eng_001') ->> 'status',
  'inactive'::text,
  '停用账号绑定解析出 status=inactive（由编排层映射 im_banned）'
);
update public.profiles set status = 'active'
 where id = '22222222-2222-2222-2222-222222220001';

select throws_ok(
  $$ select app.im_dingtalk_exchange_code('') $$,
  '22023', null, '空授权码被拒（出站前校验）'
);
select throws_ok(
  $$ select app.im_dingtalk_handle_callback(
       '', 'https://admin.example.com/auth/callback/dingtalk') $$,
  '22023', null, '空授权码经回调编排被拒（出站前校验）'
);
select throws_ok(
  $$ select app.im_dingtalk_handle_callback('code', 'notaurl') $$,
  '22023', null, '回调地址非法被拒'
);

-- 未启用厂商：回调返回 im_unavailable，且不触发出站
update public.im_auth_configs set enabled = false where provider = 'dingtalk';
select is(
  app.im_dingtalk_handle_callback('anything', 'https://admin.example.com/auth/callback/dingtalk'),
  jsonb_build_object('ok', false, 'error', 'im_unavailable', 'detail', null),
  '未启用钉钉回调返回 im_unavailable（不出站）'
);
set local role im_backend;
select is(
  public.im_handle_callback(
    'dingtalk', 'anything', 'https://admin.example.com/auth/callback/dingtalk') ->> 'error',
  'im_unavailable'::text,
  'im_backend 经薄包装回调未启用钉钉 → im_unavailable'
);
reset role;

-- 匿名未绑定拒绝留痕 via=im_dingtalk
select set_config('request.jwt.claims', '{}', true);
set local role anon;
select lives_ok(
  $$ select public.record_im_login_attempt('dingtalk', 'ding_union_ghost_001', false, 'im_not_bound') $$,
  '匿名可记录钉钉未绑定拒绝（im_not_bound）'
);
reset role;
select results_eq(
  $$ select via, im_userid, success from public.audit_logins
      where im_userid = 'ding_union_ghost_001' order by id desc limit 1 $$,
  $$ values ('im_dingtalk'::text, 'ding_union_ghost_001'::text, false) $$,
  '钉钉拒绝行 via=im_dingtalk / im_userid 留痕'
);
select results_eq(
  $$ select via, im_userid, success, fail_reason from public.audit_logins
      where im_userid = 'ding_union_ghost_001' order by id desc limit 1 $$,
  $$ values ('im_dingtalk'::text, 'ding_union_ghost_001'::text, false, 'im_not_bound'::text) $$,
  '钉钉拒绝行 fail_reason=im_not_bound'
);

select * from finish();
rollback;
