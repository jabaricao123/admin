-- pgTAP：im/006 —— IM 配置页数据面
-- 覆盖（issue #6 验收相关）：
--   1) 结构与授权面：6 个新 RPC 签名 / security definer + search_path / GRANT 面（anon 仅登录读取口）
--   2) system_settings 三键 seed（管理员联系方式 / 密码登录开关 / 应急管理员邮箱）
--   3) 掩码与厂商测试连接响应解析纯函数（不出站）
--   4) im_get_config：非 admin 拒绝 / 掩码不含明文 / 查看写 audit
--   5) im_test_config：非 admin 拒绝 / 未保存凭据 / 凭据不完整（均不出站）
--   6) im_switch_provider：非 admin 拒绝 / 无凭据不可启用 / 三选一原子切换 / 全局签出计数 /
--      审计 switch_provider + force_logout / 幂等 no-op
--   7) im_clear_all_bindings：非 admin 拒绝 / 三家清空计数 / 审计
--   8) im_get_login_options：anon 可读且返回三键
--   9) im_password_login_allowed：开关开恒 true / 关闭后仅名单内且 role=admin 放行
-- 运行：supabase db reset && supabase test db
-- 说明：真实出站（extensions.http）不在 pgTAP 覆盖（本地栈无外网 mock）；出站成功路径为
--       纯解析函数 + 界面证据。夹具只在本事务内生效，finish 后 rollback。
begin;

select plan(70);

-- ---------------------------------------------------------------------------
-- 0. 夹具清理（事务内，finish 后 rollback）：共享本地库里可能有他单 / 人工留下的
--    IM 配置、绑定与审计；先抹平再断言，保证结论只反映本文件行为。
-- ---------------------------------------------------------------------------
delete from public.im_auth_configs where true;
delete from public.audit_operations
 where module = 'system'
   and object_type in ('im_auth_config', 'im_binding');
update public.profiles
   set wecom_userid = null,
       feishu_userid = null,
       dingtalk_userid = null
 where wecom_userid is not null
    or feishu_userid is not null
    or dingtalk_userid is not null;
update public.system_settings
   set value = to_jsonb(''::text)
 where key = 'im_admin_contact';
update public.system_settings
   set value = to_jsonb(true)
 where key = 'password_login_enabled';
update public.system_settings
   set value = '[]'::jsonb
 where key = 'password_login_admin_emails';

-- ===========================================================================
-- 1. 结构与授权面（15）
-- ===========================================================================
select has_function('public', 'im_get_config', array['text'], 'im_get_config(text) 存在');
select has_function('public', 'im_test_config', array['text', 'jsonb'], 'im_test_config(text,jsonb) 存在');
select has_function('public', 'im_switch_provider', array['text'], 'im_switch_provider(text) 存在');
select has_function('public', 'im_clear_all_bindings', array[]::text[], 'im_clear_all_bindings() 存在');
select has_function('public', 'im_get_login_options', array[]::text[], 'im_get_login_options() 存在');
select has_function('public', 'im_password_login_allowed', array['text'], 'im_password_login_allowed(text) 存在');

select ok(
  (select count(*) = 6
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
            ('public', 'im_get_config'), ('public', 'im_test_config'),
            ('public', 'im_switch_provider'), ('public', 'im_clear_all_bindings'),
            ('public', 'im_get_login_options'), ('public', 'im_password_login_allowed')
          )
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '6 个新 RPC 均 security definer + search_path 固定为空'
);

select ok(has_function_privilege('anon', 'public.im_get_login_options()', 'EXECUTE'), 'anon 可执行 im_get_login_options');
select ok(
  not has_function_privilege('anon', 'public.im_get_config(text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.im_test_config(text,jsonb)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.im_switch_provider(text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.im_clear_all_bindings()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.im_password_login_allowed(text)', 'EXECUTE'),
  'anon 无其余 5 个 RPC 执行权'
);
select ok(
  (select count(*) = 6
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
            ('public', 'im_get_config'), ('public', 'im_test_config'),
            ('public', 'im_switch_provider'), ('public', 'im_clear_all_bindings'),
            ('public', 'im_get_login_options'), ('public', 'im_password_login_allowed')
          )
      and has_function_privilege('authenticated', p.oid, 'EXECUTE')),
  'authenticated 可执行全部 6 个新 RPC'
);
select ok(
  not exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('im_get_config', 'im_test_config', 'im_switch_provider',
                         'im_clear_all_bindings', 'im_get_login_options',
                         'im_password_login_allowed')
       and has_function_privilege('service_role', p.oid, 'EXECUTE')
  ),
  'service_role 无新 RPC 执行权（ADR-001）'
);
select ok(
  not exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app'
       and p.proname in ('im_config_credentials', 'im_mask_credential_value',
                         'im_test_parse_feishu', 'im_test_parse_wecom', 'im_test_parse_dingtalk')
       and (has_function_privilege('anon', p.oid, 'EXECUTE')
            or has_function_privilege('authenticated', p.oid, 'EXECUTE')
            or has_function_privilege('service_role', p.oid, 'EXECUTE'))
  ),
  'app 内部 helper 零 API 角色授权'
);

select is(
  (select value from public.system_settings where key = 'password_login_enabled'),
  'true'::jsonb,
  'password_login_enabled 默认 true'
);
select is(
  (select value from public.system_settings where key = 'password_login_admin_emails'),
  '[]'::jsonb,
  'password_login_admin_emails 默认空数组'
);
select ok(
  exists (
    select 1 from public.system_settings
    where key = 'im_admin_contact' and value_type = 'string'
  ),
  'im_admin_contact 存在且为 string 类型'
);

-- ===========================================================================
-- 2. 掩码 / 解析纯函数（10）
-- ===========================================================================
select is(app.im_mask_credential_value('app_secret', 'super-secret'), '••••••••', 'secret 字段全掩码');
select is(app.im_mask_credential_value('secret', 'abc'), '••••••••', '短 secret 全掩码');
select is(
  app.im_mask_credential_value('app_id', 'cli_a1b2c3d4e5f6'),
  'cli_' || repeat('•', 6) || 'f6',
  '长标识保留首 4 尾 2'
);
select is(app.im_mask_credential_value('app_id', null), null, '空值掩码为 NULL');

select is(
  app.im_test_parse_feishu(200, '{"code":0,"tenant_access_token":"t-abc"}') ->> 'ok',
  'true',
  '飞书解析：code=0 + token → ok'
);
select is(
  app.im_test_parse_feishu(200, '{"code":10003,"msg":"invalid app_secret"}') ->> 'message',
  '飞书校验失败（code=10003）：invalid app_secret',
  '飞书解析：code<>0 → 带厂商描述的错误'
);
select is(
  app.im_test_parse_wecom(200, '{"errcode":0,"access_token":"w-abc","expires_in":7200}') ->> 'ok',
  'true',
  '企业微信解析：errcode=0 + token → ok'
);
select is(
  app.im_test_parse_wecom(200, '{"errcode":40001,"errmsg":"invalid secret"}') ->> 'ok',
  'false',
  '企业微信解析：errcode<>0 → 失败'
);
select is(
  app.im_test_parse_dingtalk(200, '{"accessToken":"d-abc","expireIn":7200}') ->> 'ok',
  'true',
  '钉钉解析：accessToken → ok'
);
select is(
  app.im_test_parse_dingtalk(401, '{}') ->> 'message',
  '钉钉返回 HTTP 401',
  '钉钉解析：HTTP 非 200 → 失败'
);

-- ===========================================================================
-- 3. im_get_config：权限 / 掩码 / 查看审计（9）
--    先以 engineer 身份验证拒绝，再以 admin 配置飞书凭据
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$ select public.im_get_config('feishu') $$,
  '42501', null,
  'engineer 调 im_get_config 被 admin 校验拒绝'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);

select is(
  public.im_get_config('feishu') ->> 'exists',
  'false',
  '未配置厂返回 exists=false'
);

select lives_ok(
  $$ select public.im_upsert_config('feishu', '{"app_id":"cli_test_123456","app_secret":"feishu-secret-xyz"}'::jsonb, false) $$,
  'admin 保存飞书凭据（不启用）'
);

select is(
  public.im_get_config('feishu') ->> 'credentials_set',
  'true',
  '查看返回 credentials_set=true'
);
select is(
  public.im_get_config('feishu') #>> '{credentials_masked,app_id}',
  'cli_' || repeat('•', 6) || '56',
  'app_id 掩码保留首 4 尾 2'
);
select is(
  public.im_get_config('feishu') #>> '{credentials_masked,app_secret}',
  repeat('•', 8),
  'app_secret 全掩码'
);
select ok(
  public.im_get_config('feishu')::text not like '%feishu-secret-xyz%'
  and public.im_get_config('feishu')::text not like '%cli_test_123456%',
  '查看结果不含任何凭据明文'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'view_credentials'
      and object_type = 'im_auth_config' and object_id = 'feishu'
      and actor_id = '11111111-1111-1111-1111-111111111111'
  ),
  '查看凭据写 audit view_credentials（谁 / 哪家）'
);

-- ===========================================================================
-- 4. im_test_config：权限 / 未保存 / 不完整（不出站）（5）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
select throws_ok(
  $$ select public.im_test_config('feishu', null) $$,
  '42501', null,
  'engineer 调 im_test_config 被拒绝'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
select throws_ok(
  $$ select public.im_test_config('qq', null) $$,
  '22023', null,
  '未知厂商报 22023'
);
select is(
  public.im_test_config('wecom', null) ->> 'ok',
  'false',
  '未保存凭据的厂商测试返回 ok=false'
);
select ok(
  public.im_test_config('wecom', null) ->> 'message' like '尚未保存凭据%',
  '未保存凭据给出可读提示（不出站）'
);
select ok(
  public.im_test_config('feishu', '{"app_id":"only-id"}'::jsonb) ->> 'message' like '飞书凭据不完整%',
  '凭据不完整给出可读提示（不出站）'
);

-- ===========================================================================
-- 5. im_switch_provider：权限 / 前置校验 / 原子切换 / 全局签出 / 审计（14）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
select throws_ok(
  $$ select public.im_switch_provider('feishu') $$,
  '42501', null,
  'engineer 调 im_switch_provider 被拒绝'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
select throws_ok(
  $$ select public.im_switch_provider('wecom') $$,
  '22023', null,
  '未保存凭据的厂商不可启用（22023）'
);

select lives_ok(
  $$ select public.im_upsert_config('wecom', '{"corp_id":"ww_test","agent_id":"1000002","secret":"wecom-secret"}'::jsonb, false) $$,
  'admin 保存企业微信凭据（不启用）'
);

select is(
  public.im_switch_provider('wecom') ->> 'changed',
  'true',
  '启用企业微信返回 changed=true'
);
select is(
  (select c.provider from public.im_auth_configs c where c.enabled),
  'wecom',
  '启用后 enabled 行为 wecom'
);
select is(
  (select count(*) from public.im_auth_configs where enabled),
  1::bigint,
  '任一时刻至多一行 enabled'
);

select lives_ok(
  $$ select public.im_upsert_config('feishu', null, false) $$,
  'admin 保存飞书时凭据保持（p_credentials=null）'
);
select is(
  public.im_switch_provider('feishu') ->> 'provider',
  'feishu',
  '切换到飞书返回 provider=feishu'
);
select is(
  (select count(*) from public.im_auth_configs where enabled and provider = 'wecom'),
  0::bigint,
  '切换后企业微信被原子停用'
);
select is(
  public.im_switch_provider(null) ->> 'changed',
  'true',
  'p_provider=NULL 停用当前厂商'
);
select is(
  (select count(*) from public.im_auth_configs where enabled),
  0::bigint,
  '停用后无 enabled 行'
);
select is(
  public.im_switch_provider(null) ->> 'changed',
  'false',
  '重复停用为幂等 no-op'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'switch_provider'
      and object_type = 'im_auth_config'
      and actor_id = '11111111-1111-1111-1111-111111111111'
  ),
  '切换写 audit switch_provider'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'force_logout'
      and object_type = 'im_auth_config'
      and (diff ->> 'sessions_revoked') is not null
  ),
  '全局签出写 audit force_logout（含会话计数）'
);

-- ===========================================================================
-- 6. im_clear_all_bindings：权限 / 计数 / 审计（7）
-- ===========================================================================
select lives_ok(
  $$ select public.im_admin_set_userid('22222222-2222-2222-2222-222222220001', 'feishu', 'fs_clear_test') $$,
  '夹具：engineer 绑定飞书'
);
select lives_ok(
  $$ select public.im_admin_set_userid('22222222-2222-2222-2222-222222220001', 'wecom', 'wx_clear_test') $$,
  '夹具：engineer 绑定企业微信'
);
select lives_ok(
  $$ select public.im_admin_set_userid('22222222-2222-2222-2222-222222220001', 'dingtalk', 'dt_clear_test') $$,
  '夹具：engineer 绑定钉钉'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
select throws_ok(
  $$ select public.im_clear_all_bindings() $$,
  '42501', null,
  'engineer 调 im_clear_all_bindings 被拒绝'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
select is(
  public.im_clear_all_bindings() ->> 'total_cleared',
  '3',
  '清空返回三家总计数=3'
);
select is(
  (select count(*) from public.profiles
    where wecom_userid is not null or feishu_userid is not null or dingtalk_userid is not null),
  0::bigint,
  '清空后无任何绑定残留'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'clear_bindings'
      and object_type = 'im_binding' and object_id = 'all'
      and (diff ->> 'total_cleared') = '3'
  ),
  '清空绑定写 audit clear_bindings（含计数）'
);

-- ===========================================================================
-- 7. im_get_login_options：anon 可读；im_password_login_allowed 开关语义（11）
-- ===========================================================================
reset role;

set local role anon;
select is(
  public.im_get_login_options() ->> 'password_login_enabled',
  'true',
  'anon 可读登录选项：密码登录默认开启'
);
select is(
  public.im_get_login_options() #>> '{admin_contact}',
  '',
  'anon 读取管理员联系方式（未配置为空串）'
);
select throws_ok(
  $$ select public.im_get_config('feishu') $$,
  '42501', null,
  'anon 调 im_get_config 被权限拒绝'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$ select public.upsert_setting('password_login_enabled', 'false'::jsonb, '安全', 'bool', '密码登录全局开关（测试）') $$,
  'admin 关闭密码登录开关'
);
select is(
  public.im_password_login_allowed('engineer@example.com'),
  false,
  '开关关闭后普通用户不允许密码登录'
);
select lives_ok(
  $$ select public.upsert_setting('password_login_admin_emails', '["engineer@example.com"]'::jsonb, '安全', 'json', '应急名单（测试）') $$,
  'admin 写入应急名单（非 admin 邮箱）'
);
select is(
  public.im_password_login_allowed('engineer@example.com'),
  false,
  '名单内非 admin 账号仍不放行（名单只是过滤条件）'
);
select lives_ok(
  $$ select public.upsert_setting('password_login_admin_emails', '["admin@example.com"]'::jsonb, '安全', 'json', '应急名单（测试）') $$,
  'admin 写入应急名单（admin 邮箱）'
);
select is(
  public.im_password_login_allowed('admin@example.com'),
  true,
  '名单内 active admin 放行密码登录'
);
select is(
  public.im_password_login_allowed('nobody@example.com'),
  false,
  '名单外账号不放行'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
select lives_ok(
  $$ select public.upsert_setting('password_login_enabled', 'true'::jsonb, '安全', 'bool', '密码登录全局开关（测试）') $$,
  '恢复密码登录开关为开启（夹具清理）'
);

select * from finish();
rollback;
