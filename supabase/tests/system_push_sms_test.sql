-- pgTAP：system/004 + system/005 —— 推送/短信测试 RPC + push 双渠道保存与脱敏
-- 运行：supabase db reset && supabase test db
-- 覆盖：函数存在性 + SECURITY DEFINER + search_path=''；GRANT 面（authenticated 可执行、anon 无）；
--       非 admin 越权拒绝；未配置 P0002；push 渠道白名单与启用必填校验；
--       双渠道合并保存（不互相覆盖）；凭据密文非明文、解密往返、get_push_status 仅返掩码；
--       测试推送完整 → verified / 缺失 → failed；secret 清除语义；审计不含凭据明文；
--       sms 通道未启用 → 22023 且状态不变；启用后完整 → verified；审计备注含手机号。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(64);

-- ===========================================================================
-- 1. 函数存在性 + 安全属性 + GRANT 面（19）
-- ===========================================================================
select has_function('app', 'get_push_status', array[]::text[], 'app.get_push_status() 存在');
select has_function('public', 'get_push_status', array[]::text[], 'public.get_push_status() 薄包装存在');
select has_function('app', 'upsert_push_channel', array['text', 'text', 'text', 'boolean'], 'app.upsert_push_channel 存在');
select has_function('public', 'upsert_push_channel', array['text', 'text', 'text', 'boolean'], 'public.upsert_push_channel 薄包装存在');
select has_function('app', 'test_push_config', array['text'], 'app.test_push_config(text) 存在');
select has_function('public', 'test_push_config', array['text'], 'public.test_push_config(text) 薄包装存在');
select has_function('app', 'test_sms_config', array['text'], 'app.test_sms_config(text) 存在');
select has_function('public', 'test_sms_config', array['text'], 'public.test_sms_config(text) 薄包装存在');

select ok(
  (select count(*) = 8
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
            ('app', 'get_push_status'), ('public', 'get_push_status'),
            ('app', 'upsert_push_channel'), ('public', 'upsert_push_channel'),
            ('app', 'test_push_config'), ('public', 'test_push_config'),
            ('app', 'test_sms_config'), ('public', 'test_sms_config')
          )
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '8 个函数均 security definer + search_path 固定为空'
);

select ok(has_function_privilege('authenticated', 'public.get_push_status()', 'EXECUTE'), 'authenticated 可执行 public.get_push_status');
select ok(has_function_privilege('authenticated', 'public.upsert_push_channel(text,text,text,boolean)', 'EXECUTE'), 'authenticated 可执行 public.upsert_push_channel');
select ok(has_function_privilege('authenticated', 'public.test_push_config(text)', 'EXECUTE'), 'authenticated 可执行 public.test_push_config');
select ok(has_function_privilege('authenticated', 'public.test_sms_config(text)', 'EXECUTE'), 'authenticated 可执行 public.test_sms_config');

select ok(has_function_privilege('authenticated', 'app.get_push_status()', 'EXECUTE'), 'authenticated 可执行 app.get_push_status');
select ok(has_function_privilege('authenticated', 'app.upsert_push_channel(text,text,text,boolean)', 'EXECUTE'), 'authenticated 可执行 app.upsert_push_channel');
select ok(has_function_privilege('authenticated', 'app.test_push_config(text)', 'EXECUTE'), 'authenticated 可执行 app.test_push_config');
select ok(has_function_privilege('authenticated', 'app.test_sms_config(text)', 'EXECUTE'), 'authenticated 可执行 app.test_sms_config');

select ok(
  not exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'public' and p.proname in ('get_push_status', 'upsert_push_channel', 'test_push_config', 'test_sms_config'))
       and has_function_privilege('anon', p.oid, 'EXECUTE')
  ),
  'anon 无 public 面执行权'
);
select ok(
  not exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname in ('get_push_status', 'upsert_push_channel', 'test_push_config', 'test_sms_config'))
       and has_function_privilege('anon', p.oid, 'EXECUTE')
  ),
  'anon 无 app 面执行权'
);

-- ===========================================================================
-- 2. 越权与前置校验（6）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.test_push_config('wecom') $$,
  '42501', null, 'engineer 调 test_push_config 被 admin 校验拒绝'
);
select throws_ok(
  $$ select public.upsert_push_channel('wecom', 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=x', 's', true) $$,
  '42501', null, 'engineer 调 upsert_push_channel 被 admin 校验拒绝'
);
select throws_ok(
  $$ select public.test_sms_config('12345678901') $$,
  '42501', null, 'engineer 调 test_sms_config 被 admin 校验拒绝'
);
reset role;

set local role anon;
select throws_ok(
  $$ select public.test_push_config('wecom') $$,
  '42501', null, 'anon 调 test_push_config 被拒（无 GRANT）'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.test_push_config('wecom') $$,
  'P0002', null, '未保存 push 配置时报 P0002'
);
select throws_ok(
  $$ select public.test_sms_config('12345678901') $$,
  'P0002', null, '未保存 sms 配置时报 P0002'
);
reset role;

-- ===========================================================================
-- 3. push 单渠道保存与双渠道合并（17）
-- ===========================================================================
set local role authenticated;

-- 渠道白名单 / 启用必填
select throws_ok(
  $$ select public.upsert_push_channel('feishu', 'https://example.com/hook', null, false) $$,
  '22023', null, '未知推送渠道报 22023'
);
select throws_ok(
  $$ select public.upsert_push_channel('wecom', '', null, true) $$,
  '22023', null, '启用渠道但 Webhook URL 为空报 22023'
);

-- 草稿态：未启用可先存空 URL
select lives_ok(
  $$ select public.upsert_push_channel('wecom', '', null, false) $$,
  'admin 保存未启用的空 wecom 渠道（草稿）'
);

-- 企业微信：URL + secret + 启用
select lives_ok(
  $$ select public.upsert_push_channel(
       'wecom',
       'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abc123',
       'wecom-secret-9876',
       true
     ) $$,
  'admin 保存 wecom 渠道（URL + secret + 启用）'
);
select is(
  (select (public.upsert_push_channel(
     'dingtalk',
     'https://oapi.dingtalk.com/robot/send?access_token=xyz789',
     'ding-secret-4321',
     true
   )) ->> 'channel'),
  'dingtalk',
  'upsert_push_channel 返回 channel=dingtalk'
);
reset role;

select is(
  (select verify_status from public.system_services where service = 'push'),
  'unverified',
  'push 配置保存后为 unverified（待测试）'
);
select ok(
  (select credentials::text not like '%wecom-secret-9876%'
      and credentials::text not like '%ding-secret-4321%'
     from public.system_services where service = 'push'),
  'push 凭据密文不含明文'
);
select is(
  (select app.decrypt_secret(credentials)::jsonb ->> 'wecom'
     from public.system_services where service = 'push'),
  'wecom-secret-9876',
  'wecom secret 加密往返一致'
);
select is(
  (select app.decrypt_secret(credentials)::jsonb ->> 'dingtalk'
     from public.system_services where service = 'push'),
  'ding-secret-4321',
  'dingtalk secret 加密往返一致'
);

-- 合并语义：后写渠道不覆盖先写渠道
select is(
  (select count(*) from public.system_services where service = 'push'),
  1::bigint,
  'push 双渠道共用单行（service=push）'
);
reset role;
select is(
  (select config -> 'wecom' ->> 'webhook_url'
     from public.system_services where service = 'push'),
  'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abc123',
  '保存 dingtalk 后 wecom Webhook URL 保留'
);
select is(
  (select config -> 'dingtalk' ->> 'webhook_url'
     from public.system_services where service = 'push'),
  'https://oapi.dingtalk.com/robot/send?access_token=xyz789',
  'dingtalk Webhook URL 正确落库'
);

-- 脱敏读取：get_push_status 仅返回掩码
set local role authenticated;
select is(
  (select count(*) from public.get_push_status()),
  2::bigint,
  'get_push_status 返回 wecom/dingtalk 两行'
);
select is(
  (select enabled from public.get_push_status() where channel = 'wecom'),
  true,
  'get_push_status wecom enabled=true'
);
select is(
  (select secret_masked from public.get_push_status() where channel = 'wecom'),
  '****9876',
  'get_push_status wecom 掩码为 **** + 尾 4 位'
);
select is(
  (select secret_masked from public.get_push_status() where channel = 'dingtalk'),
  '****4321',
  'get_push_status dingtalk 掩码为 **** + 尾 4 位'
);
select ok(
  (select bool_and(secret_masked not like '%secret%') from public.get_push_status()),
  'get_push_status 不下发明文'
);

-- ===========================================================================
-- 4. 测试推送（7）
-- ===========================================================================
select is(
  (select (public.test_push_config('wecom')) ->> 'ok'),
  'true',
  'wecom 配置完整：返回 ok=true'
);
select is(
  (select (public.test_push_config('wecom')) ->> 'verify_status'),
  'verified',
  'wecom 测试通过：verify_status=verified'
);
select ok(
  (select (public.test_push_config('wecom')) ->> 'message') like '配置校验通过%',
  'wecom 测试通过：message 说明真实推送待接入'
);
select is(
  (select (public.test_push_config('dingtalk')) ->> 'ok'),
  'true',
  'dingtalk 配置完整：返回 ok=true'
);
select throws_ok(
  $$ select public.test_push_config('feishu') $$,
  '22023', null, '测试未知渠道报 22023'
);

-- 关闭渠道后测试 → failed（可读提示）
select lives_ok(
  $$ select public.upsert_push_channel(
       'dingtalk',
       'https://oapi.dingtalk.com/robot/send?access_token=xyz789',
       null,
       false
     ) $$,
  'admin 停用 dingtalk 渠道（不传 secret = 保留）'
);
select is(
  (select (public.test_push_config('dingtalk')) ->> 'ok'),
  'false',
  '停用渠道测试：ok=false'
);

-- ===========================================================================
-- 5. 审计与 secret 清除（4）
-- ===========================================================================
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'verify'
      and object_type = 'service_config' and object_id = 'push'
      and diff ->> 'note' like '%wecom%'
  ),
  'push verify 审计备注含测试渠道'
);
select ok(
  not exists (
    select 1 from public.audit_operations
    where module = 'system'
      and diff::text like '%wecom-secret-9876%'
  ),
  'push 审计摘要不落凭据明文'
);

select lives_ok(
  $$ select public.upsert_push_channel(
       'wecom',
       'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abc123',
       '',
       true
     ) $$,
  'admin 清除 wecom secret（空串语义）'
);
select is(
  (select secret_masked from public.get_push_status() where channel = 'wecom'),
  null,
  '清除后 get_push_status wecom 掩码为 null'
);

-- ===========================================================================
-- 6. sms 配置与测试（11）
-- ===========================================================================
-- 草稿态：不完整配置可存；通道默认停用
select lives_ok(
  $$ select public.upsert_service_config(
       'sms',
       '{"provider":"aliyun","access_key_id":"","sign_name":"","enabled":false}'::jsonb,
       'sms-secret-abcd'
     ) $$,
  'admin 保存不完整短信配置（草稿、停用态）'
);

select throws_ok(
  $$ select public.test_sms_config('') $$,
  '22023', null, '测试手机号为空报 22023'
);
select throws_ok(
  $$ select public.test_sms_config('not-a-phone') $$,
  '22023', null, '测试手机号格式错误报 22023'
);
select throws_ok(
  $$ select public.test_sms_config('12345678901') $$,
  '22023', null, '通道未启用时报 22023'
);

reset role;
select is(
  (select verify_status from public.system_services where service = 'sms'),
  'unverified',
  '通道未启用测试失败不改变验证状态（仍 unverified）'
);

-- 启用通道并补全配置
set local role authenticated;
select lives_ok(
  $$ select public.upsert_service_config(
       'sms',
       '{"provider":"aliyun","access_key_id":"LTAI5tTestKeyId0001","sign_name":"企业管理系统","enabled":true}'::jsonb,
       null
     ) $$,
  'admin 补全短信配置并启用（不传 secret = 保留原凭据）'
);
select is(
  (select (public.test_sms_config('12345678901')) ->> 'ok'),
  'true',
  '启用且配置完整：test_sms_config 返回 ok=true'
);
select is(
  (select (public.test_sms_config('12345678901')) ->> 'verify_status'),
  'verified',
  '启用且配置完整：verify_status=verified'
);
select ok(
  (select (public.test_sms_config('12345678901')) ->> 'message') like '配置校验通过%',
  '短信 message 说明真实发送待商业化启用'
);

reset role;
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'verify'
      and object_type = 'service_config' and object_id = 'sms'
      and diff ->> 'note' like '%12345678901%'
  ),
  'sms verify 审计备注含测试手机号'
);
select ok(
  not exists (
    select 1 from public.audit_operations
    where module = 'system' and diff::text like '%sms-secret-abcd%'
  ),
  'sms 审计摘要不落凭据明文'
);

select * from finish();
rollback;
