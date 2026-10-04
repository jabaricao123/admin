-- pgTAP：im/004 —— 企业微信扫码 + App 内免登数据面
-- 覆盖：
--   1) 结构与授权面：公开包装签名不变（im_start_auth / im_handle_callback）；
--      app.im_wecom_* 实现函数零 anon/authenticated/service_role 执行权；
--      im_backend 仅两薄包装；token 缓存表无表权限 + RLS；
--   2) 授权 URL：PC 扫码（qrConnect）/ App 内免登（oauth2/authorize + state `m.` 前缀）
--      精确匹配；secret 不出现在 URL；未启用 / 凭据缺失 / 参数非法错误映射；
--   3) 响应解析（纯函数）：gettoken 与 auth/getuserinfo 的成功 / errcode / HTTP / JSON / 缺字段；
--      userid 与旧版 UserId 双键兼容；
--   4) token 缓存：加密落库、corp_id+secret 指纹、5 分钟余量、过期不命中、命中不触发出站；
--   5) 预绑定匹配与回调错误映射：wecom userid 命中 / 未绑定 / 停用；未启用 → im_unavailable（不出站）。
-- 说明：真实出站（extensions.http → 企业微信）不依赖外网，pgTAP 以纯函数解析层 + 参数校验层
--       覆盖；出站成功路径由本地 mock 全链路验证（docs/evidence/im-004/README.md）。
-- 运行：supabase db reset && supabase test db
begin;

select plan(63);

-- ===========================================================================
-- 1. 结构与授权面（19）
-- ===========================================================================
select has_table('app', 'im_wecom_token_cache', 'app.im_wecom_token_cache 存在');
select has_function('app', 'im_wecom_cache_key', array['text','text'], 'app.im_wecom_cache_key 存在');
select has_function('app', 'im_wecom_parse_token_response', array['integer','text'], 'app.im_wecom_parse_token_response 存在');
select has_function('app', 'im_wecom_parse_identity_response', array['integer','text'], 'app.im_wecom_parse_identity_response 存在');
select has_function('app', 'im_wecom_cached_token', array['text','text'], 'app.im_wecom_cached_token 存在');
select has_function('app', 'im_wecom_store_token', array['text','text','text','integer'], 'app.im_wecom_store_token 存在');
select has_function('app', 'im_wecom_access_token', array['text','text'], 'app.im_wecom_access_token 存在');
select has_function('app', 'im_wecom_build_authorize_url', array['text','text'], 'app.im_wecom_build_authorize_url 存在');
select has_function('app', 'im_wecom_exchange_code', array['text'], 'app.im_wecom_exchange_code 存在');
select has_function('app', 'im_wecom_handle_callback', array['text','text'], 'app.im_wecom_handle_callback 存在');

-- 公开包装签名不变（im/004 验收项）：仍是 (text,text,text) → text / jsonb
select has_function('public', 'im_start_auth', array['text','text','text'],
  'public.im_start_auth(text,text,text) 签名未变');
select has_function('public', 'im_handle_callback', array['text','text','text'],
  'public.im_handle_callback(text,text,text) 签名未变');

select ok(
  (select bool_and(p.prosecdef and p.proconfig @> array['search_path=""'])
     from pg_proc p
    where p.oid in (
      'app.im_wecom_cached_token(text,text)'::regprocedure,
      'app.im_wecom_store_token(text,text,text,integer)'::regprocedure,
      'app.im_wecom_access_token(text,text)'::regprocedure,
      'app.im_wecom_build_authorize_url(text,text)'::regprocedure,
      'app.im_wecom_exchange_code(text)'::regprocedure,
      'app.im_wecom_handle_callback(text,text)'::regprocedure
    )),
  '企业微信厂商函数（涉及凭据/缓存/出站）security definer + search_path 固定为空'
);
select ok(
  (select bool_and(p.prosecdef and p.proconfig @> array['search_path=""'])
     from pg_proc p
    where p.oid in (
      'public.im_start_auth(text,text,text)'::regprocedure,
      'public.im_handle_callback(text,text,text)'::regprocedure
    )),
  '两薄包装 security definer + search_path 固定为空'
);
select ok(
  not exists (
    select 1
      from pg_proc p
     where p.oid in (
       'app.im_wecom_cache_key(text,text)'::regprocedure,
       'app.im_wecom_parse_token_response(integer,text)'::regprocedure,
       'app.im_wecom_parse_identity_response(integer,text)'::regprocedure,
       'app.im_wecom_cached_token(text,text)'::regprocedure,
       'app.im_wecom_store_token(text,text,text,integer)'::regprocedure,
       'app.im_wecom_access_token(text,text)'::regprocedure,
       'app.im_wecom_build_authorize_url(text,text)'::regprocedure,
       'app.im_wecom_exchange_code(text)'::regprocedure,
       'app.im_wecom_handle_callback(text,text)'::regprocedure
     )
       and (
         has_function_privilege('anon', p.oid, 'EXECUTE')
         or has_function_privilege('authenticated', p.oid, 'EXECUTE')
         or has_function_privilege('service_role', p.oid, 'EXECUTE')
         or has_function_privilege('im_backend', p.oid, 'EXECUTE')
       )
  ),
  '9 个 app.im_wecom_* 实现函数零 API 角色 / im_backend 执行权'
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
select ok(
  (select relrowsecurity from pg_class where oid = 'app.im_wecom_token_cache'::regclass),
  'token 缓存表启用 RLS'
);
select ok(
  not has_table_privilege('anon', 'app.im_wecom_token_cache', 'SELECT')
    and not has_table_privilege('authenticated', 'app.im_wecom_token_cache', 'SELECT')
    and not has_table_privilege('service_role', 'app.im_wecom_token_cache', 'SELECT')
    and not has_table_privilege('im_backend', 'app.im_wecom_token_cache', 'SELECT'),
  'token 缓存表无任何 API 角色 / im_backend 表权限'
);

-- ===========================================================================
-- 2. 授权 URL：PC 扫码 / App 内免登（11）
-- ===========================================================================
-- 夹具：启用企业微信配置（含加密凭据）；同一时刻至多一行 enabled
update public.im_auth_configs set enabled = false where enabled;
insert into public.im_auth_configs (provider, enabled, credentials)
values (
  'wecom', true,
  app.encrypt_secret('{"corp_id":"ww_test_corp","agent_id":"1000002","secret":"wecom_test_secret"}')
)
on conflict (provider) do update
   set enabled = true, credentials = excluded.credentials;

select is(
  app.im_wecom_build_authorize_url(
    'https://admin.example.com/auth/callback/wecom',
    'teststate_0123456789abcdef'
  ),
  'https://open.work.weixin.qq.com/wwopen/sso/qrConnect'
    || '?appid=ww_test_corp'
    || '&agentid=1000002'
    || '&redirect_uri=https%3A%2F%2Fadmin.example.com%2Fauth%2Fcallback%2Fwecom'
    || '&state=teststate_0123456789abcdef',
  'PC 扫码授权 URL 精确匹配（qrConnect）'
);
select is(
  app.im_wecom_build_authorize_url(
    'https://admin.example.com/auth/callback/wecom',
    'm.teststate_0123456789abcdef'
  ),
  'https://open.weixin.qq.com/connect/oauth2/authorize'
    || '?appid=ww_test_corp'
    || '&redirect_uri=https%3A%2F%2Fadmin.example.com%2Fauth%2Fcallback%2Fwecom'
    || '&response_type=code'
    || '&scope=snsapi_privateinfo'
    || '&agentid=1000002'
    || '&state=m.teststate_0123456789abcdef'
    || '#wechat_redirect',
  'App 内免登授权 URL 精确匹配（state m. 前缀 → oauth2 + snsapi_privateinfo）'
);
select ok(
  position('wecom_test_secret' in app.im_wecom_build_authorize_url(
    'https://admin.example.com/auth/callback/wecom',
    'teststate_0123456789abcdef'
  )) = 0,
  '授权 URL 不含 secret（secret 不出库）'
);

-- 公开包装分派（im_backend 视角；pgTAP 断言函数位于 extensions schema，临时授权 USAGE）
grant usage on schema extensions to im_backend;
set local role im_backend;
select is(
  public.im_start_auth(
    'wecom',
    'https://admin.example.com/auth/callback/wecom',
    'teststate_0123456789abcdef'
  ),
  'https://open.work.weixin.qq.com/wwopen/sso/qrConnect'
    || '?appid=ww_test_corp'
    || '&agentid=1000002'
    || '&redirect_uri=https%3A%2F%2Fadmin.example.com%2Fauth%2Fcallback%2Fwecom'
    || '&state=teststate_0123456789abcdef',
  'im_backend 经薄包装取企业微信 PC 扫码 URL（按 provider 分派）'
);
select is(
  public.im_start_auth(
    'wecom',
    'https://admin.example.com/auth/callback/wecom',
    'm.teststate_0123456789abcdef'
  ) like '%connect/oauth2/authorize%#wechat_redirect',
  true,
  'im_backend 经薄包装取 App 内免登 URL'
);
reset role;

-- 未启用 / 凭据缺失 / 参数非法
update public.im_auth_configs set enabled = false where provider = 'wecom';
select throws_ok(
  $$ select app.im_wecom_build_authorize_url(
       'https://admin.example.com/auth/callback/wecom',
       'teststate_0123456789abcdef') $$,
  '42501', null, '停用企业微信后拒绝构造授权 URL'
);
update public.im_auth_configs
   set enabled = true,
       credentials = app.encrypt_secret('{"agent_id":"1000002","secret":"wecom_test_secret"}')
 where provider = 'wecom';
select throws_ok(
  $$ select app.im_wecom_build_authorize_url(
       'https://admin.example.com/auth/callback/wecom',
       'teststate_0123456789abcdef') $$,
  '42501', null, '缺少 corp_id 拒绝构造授权 URL'
);
update public.im_auth_configs
   set credentials = app.encrypt_secret('{"corp_id":"ww_test_corp","secret":"wecom_test_secret"}')
 where provider = 'wecom';
select throws_ok(
  $$ select app.im_wecom_build_authorize_url(
       'https://admin.example.com/auth/callback/wecom',
       'teststate_0123456789abcdef') $$,
  '42501', null, '缺少 agent_id 拒绝构造授权 URL'
);
update public.im_auth_configs
   set credentials = app.encrypt_secret('{"corp_id":"ww_test_corp","agent_id":"1000002","secret":"wecom_test_secret"}')
 where provider = 'wecom';
select throws_ok(
  $$ select app.im_wecom_build_authorize_url(
       'https://admin.example.com/auth/callback/wecom', 'bad') $$,
  '22023', null, 'state 格式非法被拒'
);
select throws_ok(
  $$ select app.im_wecom_build_authorize_url(
       'javascript:alert(1)', 'teststate_0123456789abcdef') $$,
  '22023', null, '回调地址非法被拒'
);
select throws_ok(
  $$ select public.im_start_auth(
       'dingtalk', 'https://admin.example.com/auth/callback/dingtalk',
       'teststate_0123456789abcdef') $$,
  '22023', null, '未接入厂商（dingtalk）经薄包装被拒'
);

-- ===========================================================================
-- 3. 响应解析（纯函数）（13）
-- ===========================================================================
select is(
  app.im_wecom_parse_token_response(
    200, '{"errcode":0,"errmsg":"ok","access_token":"tok_a","expires_in":7200}'),
  jsonb_build_object('ok', true, 'access_token', 'tok_a', 'expires_in', 7200),
  'gettoken 成功响应解析出 access_token / expires_in'
);
select ok(
  (app.im_wecom_parse_token_response(200, '{"errcode":40013,"errmsg":"invalid corpid"}') ->> 'error') = 'im_failed'
    and position('40013' in app.im_wecom_parse_token_response(200, '{"errcode":40013,"errmsg":"invalid corpid"}') ->> 'detail') > 0,
  'gettoken errcode<>0 映射 im_failed 且 detail 带 errcode'
);
select ok(
  (app.im_wecom_parse_token_response(500, '{}') ->> 'ok')::boolean = false
    and position('HTTP 500' in app.im_wecom_parse_token_response(500, '{}') ->> 'detail') > 0,
  'gettoken HTTP 非 200 映射 im_failed'
);
select ok(
  (app.im_wecom_parse_token_response(200, 'not-json') ->> 'error') = 'im_failed',
  'gettoken 非法 JSON 映射 im_failed'
);
select ok(
  (app.im_wecom_parse_token_response(200, '{"errcode":0,"errmsg":"ok"}') ->> 'error') = 'im_failed',
  'gettoken 缺少 access_token 映射 im_failed'
);
select is(
  app.im_wecom_parse_token_response(200, '{"errcode":0,"access_token":"tok_b"}'),
  jsonb_build_object('ok', true, 'access_token', 'tok_b', 'expires_in', null::integer),
  'gettoken 缺 expires_in 仍成功（缓存层按缺省 7200 处理）'
);

select is(
  app.im_wecom_parse_identity_response(200, '{"errcode":0,"errmsg":"ok","userid":"wx_user_001"}'),
  jsonb_build_object('ok', true, 'userid', 'wx_user_001'),
  'auth/getuserinfo 成功解析出 userid'
);
select is(
  app.im_wecom_parse_identity_response(200, '{"errcode":0,"errmsg":"ok","UserId":"Wx_User_001"}') ->> 'userid',
  'Wx_User_001'::text,
  '旧版 user/getuserinfo 的 UserId 字段兼容'
);
select ok(
  (app.im_wecom_parse_identity_response(200, '{"errcode":40029,"errmsg":"invalid code"}') ->> 'error') = 'im_failed'
    and position('40029' in app.im_wecom_parse_identity_response(200, '{"errcode":40029,"errmsg":"invalid code"}') ->> 'detail') > 0,
  'getuserinfo errcode 40029 映射 im_failed 且 detail 带 errcode'
);
select ok(
  (app.im_wecom_parse_identity_response(200, '{"errcode":0,"errmsg":"ok","openid":"op_1","external_userid":"ex_1"}') ->> 'error') = 'im_failed'
    and position('userid' in app.im_wecom_parse_identity_response(200, '{"errcode":0,"errmsg":"ok","openid":"op_1"}') ->> 'detail') > 0,
  '非企业成员（仅 openid）映射 im_failed'
);
select ok(
  (app.im_wecom_parse_identity_response(200, '{"errcode":0,"errmsg":"ok","userid":"corp/user"}') ->> 'error') = 'im_failed',
  '含 / 的 userid（互联企业形态）按格式非法拒绝'
);
select ok(
  (app.im_wecom_parse_identity_response(401, '{"errcode":0,"errmsg":"ok","userid":"x"}') ->> 'ok')::boolean = false,
  'getuserinfo HTTP 401 映射 im_failed'
);
select ok(
  (app.im_wecom_parse_identity_response(200, 'not-json') ->> 'error') = 'im_failed',
  'getuserinfo 非法 JSON 映射 im_failed'
);

-- ===========================================================================
-- 4. token 缓存（10）
-- ===========================================================================
select lives_ok(
  $$ select app.im_wecom_store_token('ww_test_corp', 'wecom_test_secret', 'tok-cache-1', 7200) $$,
  '写入 access_token 缓存'
);
select is(
  app.im_wecom_cached_token('ww_test_corp', 'wecom_test_secret'),
  'tok-cache-1'::text,
  '缓存命中返回明文 token'
);
select ok(
  not exists (
    select 1 from app.im_wecom_token_cache
     where access_token::text like '%tok-cache-1%'
  ),
  '缓存落库为密文（不含 token 明文）'
);
select ok(
  (select expires_at between now() + interval '7000 seconds' and now() + interval '7300 seconds'
     from app.im_wecom_token_cache
    where cache_key = app.im_wecom_cache_key('ww_test_corp', 'wecom_test_secret')),
  '缓存过期时间 = now + expires_in'
);
select is(
  app.im_wecom_cached_token('ww_test_corp', 'other_secret'),
  null::text,
  'secret 指纹不同 → 缓存不命中'
);
select is(
  app.im_wecom_access_token('ww_test_corp', 'wecom_test_secret'),
  jsonb_build_object('ok', true, 'access_token', 'tok-cache-1', 'cached', true),
  'access_token 缓存命中不触发出站'
);
insert into app.im_wecom_token_cache (cache_key, access_token, expires_at)
values (app.im_wecom_cache_key('ww_expired', 'sec'), app.encrypt_secret('tok-old'), now() - interval '1 minute');
select is(
  app.im_wecom_cached_token('ww_expired', 'sec'),
  null::text,
  '已过期缓存不命中'
);
insert into app.im_wecom_token_cache (cache_key, access_token, expires_at)
values (app.im_wecom_cache_key('ww_soon', 'sec'), app.encrypt_secret('tok-soon'), now() + interval '2 minutes');
select is(
  app.im_wecom_cached_token('ww_soon', 'sec'),
  null::text,
  '剩余有效期 < 5 分钟不命中（临界过期防护）'
);
select throws_ok(
  $$ select app.im_wecom_store_token('ww_test_corp', 'wecom_test_secret', '', 7200) $$,
  '22023', null, '空 access_token 拒绝写缓存'
);
select lives_ok(
  $$ select app.im_wecom_store_token('ww_test_corp', 'wecom_test_secret', 'tok-cache-2', 10) $$,
  'expires_in 极小时仍可写缓存（TTL 收敛到 60s）'
);

-- ===========================================================================
-- 5. 预绑定匹配与回调错误映射（10）
-- ===========================================================================
update public.profiles
   set wecom_userid = 'wx_wecom_eng_001'
 where id = '22222222-2222-2222-2222-222222220001';
select is(
  app.im_resolve_binding('wecom', 'wx_wecom_eng_001'),
  jsonb_build_object(
    'user_id', '22222222-2222-2222-2222-222222220001'::uuid,
    'email', 'engineer@example.com',
    'status', 'active'
  ),
  '已绑定 wecom userid 解析出 user_id / email / status'
);
select is(
  app.im_resolve_binding('wecom', 'wx_wecom_ghost_001'),
  null::jsonb,
  '未绑定 wecom userid 返回 NULL'
);
update public.profiles set status = 'inactive'
 where id = '22222222-2222-2222-2222-222222220001';
select is(
  app.im_resolve_binding('wecom', 'wx_wecom_eng_001') ->> 'status',
  'inactive'::text,
  '停用账号绑定解析出 status=inactive（由编排层映射 im_banned）'
);
update public.profiles set status = 'active'
 where id = '22222222-2222-2222-2222-222222220001';

select throws_ok(
  $$ select app.im_wecom_handle_callback('', 'https://admin.example.com/auth/callback/wecom') $$,
  '22023', null, '空授权码被拒'
);
select throws_ok(
  $$ select app.im_wecom_handle_callback('code', 'notaurl') $$,
  '22023', null, '回调地址非法被拒'
);

-- 未启用厂商：回调返回 im_unavailable，且不触发出站
update public.im_auth_configs set enabled = false where provider = 'wecom';
select is(
  app.im_wecom_handle_callback('anything', 'https://admin.example.com/auth/callback/wecom'),
  jsonb_build_object('ok', false, 'error', 'im_unavailable', 'detail', null),
  '未启用企业微信回调返回 im_unavailable（不出站）'
);
set local role im_backend;
select is(
  public.im_handle_callback('wecom', 'anything', 'https://admin.example.com/auth/callback/wecom') ->> 'error',
  'im_unavailable'::text,
  'im_backend 经薄包装回调未启用企业微信 → im_unavailable'
);
reset role;
select throws_ok(
  $$ select public.im_handle_callback(
       'dingtalk', 'anything', 'https://admin.example.com/auth/callback/dingtalk') $$,
  '22023', null, '未接入厂商（dingtalk）回调经薄包装被拒'
);

-- 企业微信打点通道：匿名未绑定拒绝留痕 via=im_wecom
select set_config('request.jwt.claims', '{}', true);
set local role anon;
select lives_ok(
  $$ select public.record_im_login_attempt('wecom', 'wx_wecom_ghost_001', false, 'im_not_bound') $$,
  '匿名可记录企业微信未绑定拒绝（im_not_bound）'
);
reset role;
select results_eq(
  $$ select via, im_userid, success from public.audit_logins
      where im_userid = 'wx_wecom_ghost_001' order by id desc limit 1 $$,
  $$ values ('im_wecom'::text, 'wx_wecom_ghost_001'::text, false) $$,
  '企业微信拒绝行 via=im_wecom / im_userid 留痕'
);

select * from finish();
rollback;
