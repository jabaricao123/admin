-- pgTAP：im/002 —— 飞书扫码登录数据面
-- 覆盖：
--   1) audit_logins.via / im_userid 结构与取值约束；app.audit_login 扩参（唯一写入入口）
--   2) record_im_login_attempt：匿名仅失败 + 身份按绑定推导（未绑定仍留痕）、
--      已登录仅成功 + userid 与本人绑定一致校验、限流、IP/UA 采集
--   3) im_get_provider_config：service_role 专属凭据读取口（解密往返、未配置 NULL、API 角色拒绝）
--   4) password 通道回归：via 默认 password / im_userid NULL
-- 运行：supabase db reset && supabase test db
begin;

select plan(42);

-- ===========================================================================
-- 1. 结构与安全属性 + 授权面（10）
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
  'public', 'im_get_provider_config',
  array['text'],
  'public.im_get_provider_config(text) 存在'
);
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p
    where p.oid = 'public.record_im_login_attempt(text,text,boolean,text)'::regprocedure),
  'record_im_login_attempt security definer + search_path 固定为空'
);
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p
    where p.oid = 'public.im_get_provider_config(text)'::regprocedure),
  'im_get_provider_config security definer + search_path 固定为空'
);
select ok(
  has_function_privilege('anon', 'public.record_im_login_attempt(text,text,boolean,text)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.record_im_login_attempt(text,text,boolean,text)', 'EXECUTE'),
  'anon + authenticated 可执行 record_im_login_attempt'
);
select ok(
  not has_function_privilege('anon', 'public.im_get_provider_config(text)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.im_get_provider_config(text)', 'EXECUTE'),
  'anon / authenticated 无 im_get_provider_config 执行权（仅后端）'
);

-- ===========================================================================
-- 2. 授权面（5）
-- ===========================================================================
select ok(
  has_function_privilege('service_role', 'public.im_get_provider_config(text)', 'EXECUTE'),
  'service_role 可执行 im_get_provider_config（后端凭据读取口）'
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
  '42501', null, 'anon 越权调用 im_get_provider_config 被拒'
);
reset role;
select ok(
  not has_function_privilege('service_role', 'public.record_im_login_attempt(text,text,boolean,text)', 'EXECUTE'),
  'service_role 无 record_im_login_attempt 执行权（写路径不经 service_role）'
);

-- ===========================================================================
-- 3. 夹具：启用飞书配置（含加密凭据）+ 绑定 engineer（4）
-- ===========================================================================
insert into public.im_auth_configs (provider, enabled, credentials)
values (
  'feishu', true,
  app.encrypt_secret('{"app_id":"cli_test_app","app_secret":"test_secret_value"}')
);

update public.profiles
   set feishu_userid = 'feishu_eng_001'
 where id = '22222222-2222-2222-2222-222222220001';

set local role service_role;
select is(
  (select public.im_get_provider_config('feishu') ->> 'enabled'),
  'true',
  'service_role 读到 enabled=true'
);
select is(
  (select public.im_get_provider_config('feishu') #>> '{credentials,app_id}'),
  'cli_test_app',
  '凭据解密往返：app_id 一致'
);
select is(
  (select public.im_get_provider_config('feishu') #>> '{credentials,app_secret}'),
  'test_secret_value',
  '凭据解密往返：app_secret 一致'
);
reset role;
set local role service_role;
select is(
  (select public.im_get_provider_config('wecom')),
  null::jsonb,
  '未配置厂商返回 NULL（service_role）'
);
reset role;

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
-- 5. 匿名单成功拒绝 + 已登录成功（8）
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
