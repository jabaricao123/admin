-- pgTAP：im/002 —— 飞书扫码登录数据面（含 im/002 修复：厂商逻辑下沉 + im_backend 最小角色）
-- 覆盖：
--   1) audit_logins.via / im_userid 结构与取值约束；app.audit_login 扩参（唯一写入入口）
--   2) record_im_login_attempt：匿名仅失败 + 身份按绑定推导（未绑定仍留痕）、
--      已登录仅成功 + userid 与本人绑定一致校验、限流、IP/UA 采集
--   3) 授权面（im/002 修复）：im_get_provider_config 已删除；public.im_start_auth /
--      public.im_handle_callback 仅 GRANT im_backend（nologin / 非 BYPASSRLS / 无表权限）；
--      app.* 实现函数零 API 角色授权；service_role 全链路零执行权
--   4) 授权 URL 构造（凭据解密不出库；secret 不出现）、token / userinfo 响应解析、
--      绑定匹配、回调错误映射（未启用 → im_unavailable）；参数校验
--   5) password 通道回归：via 默认 password / im_userid NULL
-- 说明：真实出站（extensions.http → 飞书）不依赖外网，pgTAP 以纯函数解析层 + 参数校验层
--       覆盖；出站成功路径由本地 mock 全链路验证（docs/evidence/im-002/README.md）。
-- 运行：supabase db reset && supabase test db
begin;

select plan(70);

-- ===========================================================================
-- 1. 结构与安全属性 + 授权面（12）
-- ===========================================================================
select has_column('public', 'audit_logins', 'via', 'audit_logins.via 存在');
select has_column('public', 'audit_logins', 'im_userid', 'audit_logins.im_userid 存在');
select col_has_check('public', 'audit_logins', 'via', 'via 有取值 CHECK');
select has_function(
  'app', 'audit_login',
  array['uuid','text','boolean','text','inet','text','text','text'],
  'app.audit_login 扩为 8 参（via/im_userid）'
);
select has_function(
  'public', 'record_im_login_attempt',
  array['text','text','boolean','text'],
  'public.record_im_login_attempt(text,text,boolean,text) 存在'
);
select has_function(
  'public', 'im_start_auth',
  array['text','text','text'],
  'public.im_start_auth(text,text,text) 存在'
);
select has_function(
  'public', 'im_handle_callback',
  array['text','text','text'],
  'public.im_handle_callback(text,text,text) 存在'
);
select hasnt_function(
  'public', 'im_get_provider_config', array['text'],
  'im_get_provider_config 已删除（废弃 secret 出库读取口）'
);
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p
    where p.oid = 'public.record_im_login_attempt(text,text,boolean,text)'::regprocedure),
  'record_im_login_attempt security definer + search_path 固定为空'
);
select ok(
  (select bool_and(p.prosecdef and p.proconfig @> array['search_path=""'])
     from pg_proc p
    where p.oid in (
      'public.im_start_auth(text,text,text)'::regprocedure,
      'public.im_handle_callback(text,text,text)'::regprocedure,
      'app.im_build_authorize_url(text,text,text)'::regprocedure,
      'app.im_handle_callback(text,text,text)'::regprocedure
    )),
  '厂商逻辑 RPC（public 包装 + app 实现）security definer + search_path 固定为空'
);
select ok(
  has_function_privilege('anon', 'public.record_im_login_attempt(text,text,boolean,text)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.record_im_login_attempt(text,text,boolean,text)', 'EXECUTE'),
  'anon + authenticated 可执行 record_im_login_attempt'
);
select ok(
  not has_function_privilege('anon', 'public.im_start_auth(text,text,text)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.im_start_auth(text,text,text)', 'EXECUTE')
    and not has_function_privilege('anon', 'public.im_handle_callback(text,text,text)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.im_handle_callback(text,text,text)', 'EXECUTE'),
  'anon / authenticated 无 im_start_auth / im_handle_callback 执行权'
);

-- ===========================================================================
-- 2. 授权面（11）
-- ===========================================================================
select ok(
  not has_function_privilege('service_role', 'public.im_start_auth(text,text,text)', 'EXECUTE')
    and not has_function_privilege('service_role', 'public.im_handle_callback(text,text,text)', 'EXECUTE'),
  'service_role 零执行权（ADR-001 全局禁令）'
);
select ok(
  has_function_privilege('im_backend', 'public.im_start_auth(text,text,text)', 'EXECUTE')
    and has_function_privilege('im_backend', 'public.im_handle_callback(text,text,text)', 'EXECUTE'),
  'im_backend 可执行两个薄包装（Next.js 服务端专用最小角色）'
);
select ok(
  not has_function_privilege('anon', 'app.audit_login(uuid,text,boolean,text,inet,text,text,text)', 'EXECUTE'),
  'anon 无 app.audit_login 执行权'
);
select ok(
  not has_function_privilege('authenticated', 'app.audit_login(uuid,text,boolean,text,inet,text,text,text)', 'EXECUTE'),
  'authenticated 无 app.audit_login 执行权'
);
set local role anon;
select throws_ok(
  $$ select public.im_get_provider_config('feishu') $$,
  '42883', null, 'im_get_provider_config 已不存在（anon 调用报未定义函数）'
);
select throws_ok(
  $$ select public.im_start_auth('feishu', 'https://admin.example.com/auth/callback/feishu', 'teststate_0123456789abcdef') $$,
  '42501', null, 'anon 越权调用 im_start_auth 被拒'
);
reset role;
select ok(
  not has_function_privilege('service_role', 'public.record_im_login_attempt(text,text,boolean,text)', 'EXECUTE'),
  'service_role 无 record_im_login_attempt 执行权（写路径不经 service_role）'
);
select ok(
  not exists (
    select 1
      from pg_proc p
     where p.oid in (
       'app.urlencode(text)'::regprocedure,
       'app.im_provider_credentials(text)'::regprocedure,
       'app.im_http_timeout()'::regprocedure,
       'app.im_parse_exchange_response(integer,text)'::regprocedure,
       'app.im_parse_identity_response(integer,text)'::regprocedure,
       'app.im_resolve_binding(text,text)'::regprocedure,
       'app.im_build_authorize_url(text,text,text)'::regprocedure,
       'app.im_exchange_code(text,text,text)'::regprocedure,
       'app.im_fetch_userid(text,text)'::regprocedure,
       'app.im_handle_callback(text,text,text)'::regprocedure
     )
       and (
         has_function_privilege('anon', p.oid, 'EXECUTE')
         or has_function_privilege('authenticated', p.oid, 'EXECUTE')
         or has_function_privilege('service_role', p.oid, 'EXECUTE')
       )
  ),
  '10 个 app 实现函数零 API 角色 / service_role 执行权'
);
select ok(
  (select not rolcanlogin and not rolsuper and not rolbypassrls
     from pg_roles
    where rolname = 'im_backend'),
  'im_backend：nologin + 非 superuser + 非 bypassrls'
);
select ok(
  exists (
    select 1
      from pg_auth_members m
      join pg_roles r on r.oid = m.member
      join pg_roles g on g.oid = m.roleid
     where r.rolname = 'authenticator' and g.rolname = 'im_backend'
  ),
  'authenticator 是 im_backend 成员（PostgREST SET ROLE 前提）'
);
select ok(
  not has_table_privilege('im_backend', 'public.im_auth_configs', 'SELECT')
    and not has_table_privilege('im_backend', 'public.profiles', 'SELECT'),
  'im_backend 无 im_auth_configs / profiles 表级读权限（凭据只经 SECURITY DEFINER）'
);

-- ===========================================================================
-- 3. 授权 URL / 响应解析 / 绑定匹配 / 回调错误映射（24）
-- ===========================================================================
-- 未配置厂商：拒绝且不返回授权 URL
select throws_ok(
  $$ select app.im_build_authorize_url(
       'feishu',
       'https://admin.example.com/auth/callback/feishu',
       'teststate_0123456789abcdef') $$,
  '42501', null, '未配置的厂商拒绝构造授权 URL'
);

-- 夹具：启用飞书配置（含加密凭据）+ 绑定 engineer
insert into public.im_auth_configs (provider, enabled, credentials)
values (
  'feishu', true,
  app.encrypt_secret('{"app_id":"cli_test_app","app_secret":"test_secret_value"}')
);

update public.profiles
   set feishu_userid = 'feishu_eng_001'
 where id = '22222222-2222-2222-2222-222222220001';

-- URL 编码 helper
select is(
  app.urlencode('Az-._~09 a&b=c?d/e:f'),
  'Az-._~09%20a%26b%3Dc%3Fd%2Fe%3Af',
  'urlencode：保留 unreserved，其余百分号编码'
);
select is(app.urlencode('中'), '%E4%B8%AD', 'urlencode：多字节按 UTF-8 字节编码');

-- 授权 URL：与飞书现行 OAuth 2.0 形态逐参数一致；secret 不出现在 URL
select is(
  app.im_build_authorize_url(
    'feishu',
    'https://admin.example.com/auth/callback/feishu',
    'teststate_0123456789abcdef'
  ),
  'https://accounts.feishu.cn/open-apis/authen/v1/authorize'
    || '?client_id=cli_test_app'
    || '&response_type=code'
    || '&redirect_uri=https%3A%2F%2Fadmin.example.com%2Fauth%2Fcallback%2Ffeishu'
    || '&scope=contact%3Auser.employee_id%3Areadonly'
    || '&state=teststate_0123456789abcdef',
  '授权 URL 精确匹配（client_id / redirect_uri / scope / state）'
);
select ok(
  position('test_secret_value' in app.im_build_authorize_url(
    'feishu',
    'https://admin.example.com/auth/callback/feishu',
    'teststate_0123456789abcdef'
  )) = 0,
  '授权 URL 不含 app_secret（secret 不出库）'
);
-- pgTAP 断言函数位于 extensions schema；下面两条 im_backend 实测用例需要在被测角色下
-- 解析 is()/throws_ok()，故事务内临时授予 USAGE（测试结束 rollback 撤销）。
-- 生产环境 im_backend 不需要该权限（PostgREST 只调 public 包装，链式调用在 definer 内完成）。
grant usage on schema extensions to im_backend;

set local role im_backend;
select is(
  public.im_start_auth(
    'feishu',
    'https://admin.example.com/auth/callback/feishu',
    'teststate_0123456789abcdef'
  ),
  'https://accounts.feishu.cn/open-apis/authen/v1/authorize'
    || '?client_id=cli_test_app'
    || '&response_type=code'
    || '&redirect_uri=https%3A%2F%2Fadmin.example.com%2Fauth%2Fcallback%2Ffeishu'
    || '&scope=contact%3Auser.employee_id%3Areadonly'
    || '&state=teststate_0123456789abcdef',
  'im_backend 可经薄包装取得授权 URL'
);
reset role;
select throws_ok(
  $$ select app.im_build_authorize_url('feishu', 'https://admin.example.com/auth/callback/feishu', 'bad') $$,
  '22023', null, 'state 格式非法被拒'
);
select throws_ok(
  $$ select app.im_build_authorize_url('wecom', 'https://admin.example.com/auth/callback/wecom', 'teststate_0123456789abcdef') $$,
  '22023', null, '未接入厂商（wecom）被拒'
);

-- 停用厂商：授权 URL 拒绝
update public.im_auth_configs set enabled = false where provider = 'feishu';
select throws_ok(
  $$ select app.im_build_authorize_url('feishu', 'https://admin.example.com/auth/callback/feishu', 'teststate_0123456789abcdef') $$,
  '42501', null, '停用厂商拒绝构造授权 URL'
);
update public.im_auth_configs set enabled = true where provider = 'feishu';

-- token 响应解析（纯函数；真实出站见本地 mock 证据）
select is(
  app.im_parse_exchange_response(200, '{"code":0,"access_token":"u-token","expires_in":7200}'),
  jsonb_build_object('ok', true, 'access_token', 'u-token'),
  '换 token 成功响应解析出 access_token'
);
select ok(
  (app.im_parse_exchange_response(200, '{"code":20005,"error_description":"invalid code"}') ->> 'error') = 'im_failed'
    and position('code=20005' in app.im_parse_exchange_response(200, '{"code":20005,"error_description":"invalid code"}') ->> 'detail') > 0,
  '厂商错误码（code<>0）映射 im_failed 且 detail 带 code'
);
select ok(
  (app.im_parse_exchange_response(500, '{}') ->> 'ok')::boolean = false
    and position('HTTP 500' in app.im_parse_exchange_response(500, '{}') ->> 'detail') > 0,
  'HTTP 非 200 映射 im_failed'
);
select ok(
  (app.im_parse_exchange_response(200, 'not-json') ->> 'error') = 'im_failed',
  '非法 JSON 响应映射 im_failed'
);
select ok(
  (app.im_parse_exchange_response(200, '{"code":0}') ->> 'error') = 'im_failed',
  '缺少 access_token 映射 im_failed'
);

-- userinfo 响应解析（纯函数）
select is(
  app.im_parse_identity_response(200, '{"code":0,"data":{"user_id":"feishu_eng_001"}}'),
  jsonb_build_object('ok', true, 'userid', 'feishu_eng_001'),
  'userinfo 成功响应解析出 userid'
);
select ok(
  (app.im_parse_identity_response(200, '{"code":41001,"msg":"no permission"}') ->> 'error') = 'im_failed',
  'userinfo 厂商错误码映射 im_failed'
);
select ok(
  (app.im_parse_identity_response(200, '{"code":0,"data":{}}') ->> 'error') = 'im_failed',
  'userinfo 缺 user_id 映射 im_failed'
);
select ok(
  (app.im_parse_identity_response(401, '{"code":0,"data":{"user_id":"x"}}') ->> 'ok')::boolean = false,
  'userinfo HTTP 401 映射 im_failed'
);

-- 绑定匹配
select is(
  app.im_resolve_binding('feishu', 'feishu_eng_001'),
  jsonb_build_object(
    'user_id', '22222222-2222-2222-2222-222222220001'::uuid,
    'email', 'engineer@example.com',
    'status', 'active'
  ),
  '已绑定 userid 解析出 user_id / email / status'
);
select is(
  app.im_resolve_binding('feishu', 'feishu_ghost_001'),
  null::jsonb,
  '未绑定 userid 返回 NULL'
);
update public.profiles set status = 'inactive'
 where id = '22222222-2222-2222-2222-222222220001';
select is(
  app.im_resolve_binding('feishu', 'feishu_eng_001') ->> 'status',
  'inactive',
  '停用账号绑定解析出 status=inactive（由编排层映射 im_banned）'
);
update public.profiles set status = 'active'
 where id = '22222222-2222-2222-2222-222222220001';

-- 回调错误映射（不触发出站：参数校验 / 未启用路径）
select throws_ok(
  $$ select app.im_handle_callback('feishu', '', 'https://admin.example.com/auth/callback/feishu') $$,
  '22023', null, '空授权码被拒'
);
update public.im_auth_configs set enabled = false where provider = 'feishu';
select is(
  app.im_handle_callback('feishu', 'anything', 'https://admin.example.com/auth/callback/feishu'),
  jsonb_build_object('ok', false, 'error', 'im_unavailable', 'detail', null),
  '未启用厂商回调返回 im_unavailable（不出站）'
);
set local role im_backend;
select is(
  public.im_handle_callback('feishu', 'anything', 'https://admin.example.com/auth/callback/feishu') ->> 'error',
  'im_unavailable'::text,
  'im_backend 经薄包装回调未启用厂商 → im_unavailable'
);
reset role;
update public.im_auth_configs set enabled = true where provider = 'feishu';

-- ===========================================================================
-- 4. 匿名失败留痕：身份按绑定推导（10）
-- ===========================================================================
select set_config('request.jwt.claims', '{}', true);
select set_config(
  'request.headers',
  json_build_object('x-forwarded-for', '203.0.113.77', 'user-agent', 'pgTAP-im')::text,
  true
);

set local role anon;
select lives_ok(
  $$ select public.record_im_login_attempt('feishu', 'feishu_ghost_001', false, 'im_not_bound') $$,
  '匿名可记录未绑定拒绝（im_not_bound）'
);
reset role;

select is(
  (select via from public.audit_logins
    where im_userid = 'feishu_ghost_001' order by id desc limit 1),
  'im_feishu'::text,
  '未绑定行 via=im_feishu'
);
select is(
  (select user_id from public.audit_logins
    where im_userid = 'feishu_ghost_001' order by id desc limit 1),
  null::uuid,
  '未绑定行 user_id 为 NULL'
);
select is(
  (select success from public.audit_logins
    where im_userid = 'feishu_ghost_001' order by id desc limit 1),
  false,
  '未绑定行 success=false'
);
select is(
  (select fail_reason from public.audit_logins
    where im_userid = 'feishu_ghost_001' order by id desc limit 1),
  'im_not_bound'::text,
  '未绑定行 fail_reason=im_not_bound'
);
select is(
  (select ip from public.audit_logins
    where im_userid = 'feishu_ghost_001' order by id desc limit 1),
  '203.0.113.77'::inet,
  'IM 行 IP 取自 request.headers'
);
select is(
  (select ua from public.audit_logins
    where im_userid = 'feishu_ghost_001' order by id desc limit 1),
  'pgTAP-im'::text,
  'IM 行 UA 取自 request.headers'
);

set local role anon;
select lives_ok(
  $$ select public.record_im_login_attempt('feishu', 'feishu_eng_001', false, 'other') $$,
  '匿名失败可按已绑定 userid 留痕'
);
reset role;
select is(
  (select user_id from public.audit_logins
    where im_userid = 'feishu_eng_001' and not success order by id desc limit 1),
  '22222222-2222-2222-2222-222222220001'::uuid,
  '已绑定 userid 匿名失败解析出 user_id'
);
select is(
  (select email from public.audit_logins
    where im_userid = 'feishu_eng_001' and not success order by id desc limit 1),
  'engineer@example.com'::text,
  '已绑定 userid 匿名失败解析出会话邮箱'
);

-- ===========================================================================
-- 5. 匿名单成功拒绝 + 已登录成功 + password 回归（7）
-- ===========================================================================
set local role anon;
select throws_ok(
  $$ select public.record_im_login_attempt('feishu', 'feishu_ghost_001', true) $$,
  '42501', null, '匿名记录 IM 成功登录被拒'
);
reset role;

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '22222222-2222-2222-2222-222222220001', 'role', 'authenticated')::text,
  true
);

set local role authenticated;
select lives_ok(
  $$ select public.record_im_login_attempt('feishu', 'feishu_eng_001', true, 'other') $$,
  '已登录可记录 IM 成功登录（传入 fail_reason 也应清空）'
);
reset role;
select results_eq(
  $$ select user_id, email, success, fail_reason, via, im_userid
       from public.audit_logins
      where im_userid = 'feishu_eng_001' and success
      order by id desc limit 1 $$,
  $$ values (
       '22222222-2222-2222-2222-222222220001'::uuid,
       'engineer@example.com'::text, true, null::text, 'im_feishu'::text, 'feishu_eng_001'::text
     ) $$,
  'IM 成功行以会话身份归档且 fail_reason 为空'
);

set local role authenticated;
select throws_ok(
  $$ select public.record_im_login_attempt('feishu', 'feishu_ghost_001', true) $$,
  '42501', null, '已登录但 userid 与本人绑定不一致被拒'
);
select throws_ok(
  $$ select public.record_im_login_attempt('feishu', 'feishu_eng_001', false, 'other') $$,
  '42501', null, '已登录状态记录 IM 失败被拒'
);
reset role;

-- password 通道回归：via 默认 password、im_userid NULL
select set_config('request.jwt.claims', '{}', true);
set local role anon;
select lives_ok(
  $$ select public.record_login_attempt('engineer@example.com', false, 'invalid_credentials') $$,
  'password 通道打点回归不受扩参影响'
);
reset role;
select results_eq(
  $$ select via, im_userid from public.audit_logins order by id desc limit 1 $$,
  $$ values ('password'::text, null::text) $$,
  'password 行 via=password 且 im_userid 为 NULL'
);

-- ===========================================================================
-- 6. 参数校验 + 限流 + via CHECK 兜底（6）
-- ===========================================================================
select throws_ok(
  $$ select public.record_im_login_attempt('slack', 'x_001', false, 'other') $$,
  '22023', null, '未知厂商被拒'
);
select throws_ok(
  $$ select public.record_im_login_attempt('feishu', 'bad userid!', false, 'other') $$,
  '22023', null, '非法 userid 格式被拒'
);

select set_config('request.jwt.claims', '{}', true);
set local role anon;
select is(
  (select count(public.record_im_login_attempt('feishu', 'feishu_ratelimit_001', false, 'other'))
     from generate_series(1, 10)),
  10::bigint,
  '限流窗口内写入 10 条'
);
select is(
  (select public.record_im_login_attempt('feishu', 'feishu_ratelimit_001', false, 'other')),
  null::bigint,
  '第 11 条被静默丢弃（返回 NULL）'
);
reset role;
select is(
  (select count(*)::integer from public.audit_logins where im_userid = 'feishu_ratelimit_001'),
  10,
  '限流丢弃后仍为 10 条'
);
select throws_ok(
  $$ insert into public.audit_logins (email, success, via)
     values ('x@example.com', false, 'bogus_via') $$,
  '23514', null, '非法 via 被 CHECK 兜底拒绝'
);

select * from finish();
rollback;
