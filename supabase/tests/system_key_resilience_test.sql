-- pgTAP：system 批次 2 修复项 1 —— 凭据加密密钥容错与轮换（system_key_resilience）
-- 覆盖：rotate RPC 存在/授权；get_service_config 可读解密错误 + verify_status；
--       get_service_status 坏凭据行不锁页（其他行正常显示，坏行 failed + _decrypt_error）；
--       get_push_status 解密失败显式标注（不再伪装未配置）；掩码口径 ≤8 全掩（合并批 1）；
--       rotate 成功：全部目标表重加密后内容不变、key 已更换、缓存清空、审计留痕；
--       rotate 失败：坏密文 → 报错且整体回滚（key 与既有密文原样）；engineer/anon 越权拒绝。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(47);

-- ---------------------------------------------------------------------------
-- 夹具（superuser 直插；本事务 rollback）
-- ---------------------------------------------------------------------------
delete from public.system_services;

insert into public.system_services (service, config, credentials, verify_status, verified_at)
values
  ('mail',
   '{"host":"smtp.example.com","port":587,"username":"u"}'::jsonb,
   app.encrypt_secret('smtp-secret-abcd'), 'verified', now()),
  ('storage',
   '{"provider":"supabase-storage","bucket":"exports"}'::jsonb,
   null, 'unverified', null),
  ('push',
   '{"wecom":{"webhook_url":"https://qyapi.weixin.qq.com/hook?key=x","enabled":true}}'::jsonb,
   app.encrypt_secret('push-secret-3456'), 'verified', now()),
  ('sms',
   '{"provider":"aliyun"}'::jsonb,
   app.encrypt_secret('abcd1234'), 'unverified', null);

insert into public.webhooks (name, url, secret_enc, events, headers_enc)
values (
  'pgtap-rotate-hook',
  'https://example.com/hook',
  app.encrypt_secret('whsec_rotate_secret'),
  array['announcement.published'],
  app.encrypt_secret('{"X-Trace":"pgtap"}')
);

insert into public.sync_sources (name, type, config, credentials)
values (
  'pgtap-rotate-source',
  'api',
  '{"base_url":"https://api.example.com"}'::jsonb,
  app.encrypt_secret('sync-secret-9876')
);

insert into public.im_auth_configs (provider, enabled, credentials)
values ('feishu', false, app.encrypt_secret('{"appid":"cli_x","secret":"im-secret-4321"}'));

insert into app.im_wecom_token_cache (cache_key, access_token, expires_at)
values ('pgtap-key:cache', app.encrypt_secret('token-plain'), now() + interval '1 hour');

-- ---------------------------------------------------------------------------
-- 1. 函数存在性与授权面（8）
-- ---------------------------------------------------------------------------
select has_function('app', 'get_service_config', array['text'], 'app.get_service_config(text) 存在');
select has_function('app', 'get_service_status', array[]::text[], 'app.get_service_status() 存在');
select has_function('app', 'get_push_status', array[]::text[], 'app.get_push_status() 存在');
select has_function('app', 'rotate_encryption_key', array[]::text[], 'app.rotate_encryption_key() 存在');
select has_function('public', 'rotate_encryption_key', array[]::text[], 'public.rotate_encryption_key() 薄包装存在');
select ok(
  has_function_privilege('authenticated', 'public.rotate_encryption_key()', 'EXECUTE'),
  'authenticated 可执行 public.rotate_encryption_key（函数内 admin 校验）'
);
select ok(
  not has_function_privilege('anon', 'public.rotate_encryption_key()', 'EXECUTE'),
  'anon 无 public.rotate_encryption_key 执行权'
);
select ok(
  not has_function_privilege('service_role', 'app.rotate_encryption_key()', 'EXECUTE'),
  'service_role 无 app.rotate_encryption_key 执行权'
);

-- ---------------------------------------------------------------------------
-- 2. get_service_config：verify_status + 可读解密错误（5，superuser 直调）
-- ---------------------------------------------------------------------------
select is(
  (app.get_service_config('mail')) ->> 'credentials',
  'smtp-secret-abcd',
  'get_service_config 返回解密后的 credentials'
);
select is(
  (app.get_service_config('mail')) ->> 'verify_status',
  'verified',
  'get_service_config 追加返回 verify_status（分发侧降级判据）'
);
select is(app.get_service_config('nope'), null::jsonb, '未知 service 返回 NULL');

update public.system_services
   set credentials = '\xdeadbeef'::bytea
 where service = 'mail';

select throws_ok(
  $$ select app.get_service_config('mail') $$,
  'P0001',
  '凭据解密失败，可能密钥已轮换（service=mail）：请重新保存该服务凭据',
  '坏密文：get_service_config raise 可读错误（不裸抛 pgcrypto 错误）'
);

update public.system_services
   set credentials = app.encrypt_secret('smtp-secret-abcd')
 where service = 'mail';

-- ---------------------------------------------------------------------------
-- 3. get_service_status：坏凭据行不锁页（8，admin 身份）
-- ---------------------------------------------------------------------------
update public.system_services
   set credentials = '\xdeadbeef'::bytea
 where service = 'mail';

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$ select * from public.get_service_status() $$,
  '单行凭据损坏：get_service_status 不抛错（不锁死整页）'
);
select is(
  (select count(*) from public.get_service_status()),
  4::bigint,
  '坏凭据行仍返回全部 4 行（不丢行）'
);
select is(
  (select verify_status from public.get_service_status() where service = 'mail'),
  'failed',
  '坏凭据行 verify_status 显示 failed'
);
select is(
  (select credentials_masked from public.get_service_status() where service = 'mail'),
  '解密失败',
  '坏凭据行掩码位标注「解密失败」'
);
select ok(
  (select config ? '_decrypt_error' from public.get_service_status() where service = 'mail'),
  '坏凭据行 config 附 _decrypt_error 错误标注'
);
select is(
  (select verify_status from public.get_service_status() where service = 'storage'),
  'unverified',
  '其他行不受影响：storage 行保持原 verify_status'
);
select is(
  (select credentials_masked from public.get_service_status() where service = 'push'),
  '****3456',
  '正常长凭据行：掩码 = **** + 尾 4 位'
);
select is(
  (select credentials_masked from public.get_service_status() where service = 'sms'),
  '****',
  '正常短凭据行（8 位）：掩码全掩 ''****''（批 1 口径）'
);

reset role;

update public.system_services
   set credentials = app.encrypt_secret('smtp-secret-abcd')
 where service = 'mail';

-- ---------------------------------------------------------------------------
-- 4. get_push_status：解密失败显式标注（6，admin 身份）
-- ---------------------------------------------------------------------------
update public.system_services
   set credentials = '\xdeadbeef'::bytea
 where service = 'push';

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$ select * from public.get_push_status() $$,
  'push 凭据损坏：get_push_status 不抛错'
);
select is(
  (select secret_masked from public.get_push_status() where channel = 'wecom'),
  '解密失败',
  '解密失败：wecom secret_masked 标「解密失败」（不再伪装未配置）'
);
select is(
  (select secret_masked from public.get_push_status() where channel = 'dingtalk'),
  '解密失败',
  '解密失败：dingtalk secret_masked 标「解密失败」'
);
select is(
  (select webhook_url from public.get_push_status() where channel = 'wecom'),
  'https://qyapi.weixin.qq.com/hook?key=x',
  '解密失败不连带丢失已存 webhook_url'
);

reset role;

update public.system_services
   set credentials = app.encrypt_secret('{"wecom":"w-secret-1234"}')
 where service = 'push';

set local role authenticated;
select is(
  (select secret_masked from public.get_push_status() where channel = 'wecom'),
  '****1234',
  '恢复后：正常长凭据掩码 **** + 尾 4 位'
);
reset role;

update public.system_services
   set credentials = app.encrypt_secret('{"wecom":"w1"}')
 where service = 'push';

set local role authenticated;
select is(
  (select secret_masked from public.get_push_status() where channel = 'wecom'),
  '****',
  '短凭据（≤8 位）：掩码全掩 ''****'''
);
reset role;

update public.system_services
   set credentials = app.encrypt_secret('{"wecom":"w-secret-1234"}')
 where service = 'push';

-- ---------------------------------------------------------------------------
-- 5. rotate_encryption_key 成功路径（14，admin 身份）
-- ---------------------------------------------------------------------------
select key as old_key from app.encryption_key where key_id = 1 \gset

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.rotate_encryption_key() as rot \gset

select is((:'rot'::jsonb ->> 'system_services')::integer, 3, '轮换覆盖 system_services 3 条有凭据行');
select is((:'rot'::jsonb ->> 'webhooks_secret')::integer, 1, '轮换覆盖 webhooks.secret_enc 1 条');
select is((:'rot'::jsonb ->> 'webhooks_headers')::integer, 1, '轮换覆盖 webhooks.headers_enc 1 条');
select is((:'rot'::jsonb ->> 'sync_sources')::integer, 1, '轮换覆盖 sync_sources.credentials 1 条');
select is((:'rot'::jsonb ->> 'im_auth_configs')::integer, 1, '轮换覆盖 im_auth_configs.credentials 1 条');
select ok(
  (:'rot'::jsonb ->> 'rotated_at') is not null,
  'rotate 返回 rotated_at'
);

reset role;

select ok(
  (select key from app.encryption_key where key_id = 1) <> :'old_key',
  '轮换后 key_id=1 密钥值已更换'
);
select is(
  app.decrypt_secret((select credentials from public.system_services where service = 'mail')),
  'smtp-secret-abcd',
  '轮换后 system_services 密文可解密且内容不变'
);
select is(
  app.decrypt_secret((select secret_enc from public.webhooks where name = 'pgtap-rotate-hook')),
  'whsec_rotate_secret',
  '轮换后 webhooks.secret_enc 内容不变'
);
select is(
  app.decrypt_secret((select headers_enc from public.webhooks where name = 'pgtap-rotate-hook'))::jsonb ->> 'X-Trace',
  'pgtap',
  '轮换后 webhooks.headers_enc 内容不变'
);
select is(
  app.decrypt_secret((select credentials from public.sync_sources where name = 'pgtap-rotate-source')),
  'sync-secret-9876',
  '轮换后 sync_sources.credentials 内容不变'
);
select is(
  app.decrypt_secret((select credentials from public.im_auth_configs where provider = 'feishu'))::jsonb ->> 'appid',
  'cli_x',
  '轮换后 im_auth_configs.credentials 内容不变'
);
select is((select count(*) from app.im_wecom_token_cache), 0::bigint, '轮换清空企业微信 token 缓存');
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'rotate' and object_type = 'encryption_key'
  ),
  '轮换写审计摘要（system/rotate/encryption_key）'
);
select is(
  (app.get_service_config('mail')) ->> 'credentials',
  'smtp-secret-abcd',
  '轮换后白名单读取口仍返回原凭据明文'
);

-- ---------------------------------------------------------------------------
-- 6. rotate_encryption_key 失败原子回滚（4，坏密文阻断）
-- ---------------------------------------------------------------------------
update public.sync_sources
   set credentials = '\xdeadbeef'::bytea
 where name = 'pgtap-rotate-source';

select key as key_before from app.encryption_key where key_id = 1 \gset

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_like(
  $$ select public.rotate_encryption_key() $$,
  'sync_sources.credentials 重加密失败%',
  '坏密文：rotate 报可读错误并中断'
);

reset role;

select is(
  (select key from app.encryption_key where key_id = 1),
  :'key_before',
  '轮换失败：key_id=1 未被改动（整体回滚）'
);
select is(
  app.decrypt_secret((select credentials from public.system_services where service = 'mail')),
  'smtp-secret-abcd',
  '轮换失败：已扫描表的密文未被部分改写'
);
select is(
  (select count(*) from app.encryption_key),
  1::bigint,
  '轮换失败：密钥表仍为单行 key_id=1'
);

-- ---------------------------------------------------------------------------
-- 7. 越权拒绝（2）
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$ select public.rotate_encryption_key() $$,
  '42501', null,
  'engineer 调 rotate_encryption_key 被 admin 校验拒绝'
);

reset role;

set local role anon;
select throws_ok(
  $$ select public.rotate_encryption_key() $$,
  '42501', null,
  'anon 调 rotate_encryption_key 被拒（无 GRANT）'
);
reset role;

select * from finish();
rollback;
