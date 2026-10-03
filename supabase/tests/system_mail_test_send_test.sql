-- pgTAP：system/002 —— 邮件配置「测试验证」RPC + upsert「不传凭据=保留」契约补充
-- 运行：supabase db reset && supabase test db
-- 覆盖：函数存在性 + SECURITY DEFINER + search_path=''；GRANT 面（authenticated 可执行、anon 无）；
--       非 admin 越权拒绝；未配置 P0002；配置缺失 → failed（可读提示）；配置完整 → verified；
--       参数校验失败不改变验证状态；审计备注含收件邮箱且不落凭据明文；
--       upsert 编辑不传凭据保留原密文 / config 未变不降级 / config 变更降级；
--       显式新凭据替换；新建行 NULL 凭据语义与 system/001 契约一致。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(37);

-- ===========================================================================
-- 1. 函数存在性 + 安全属性 + GRANT 面（7）
-- ===========================================================================
select has_function('app', 'test_mail_config', array['text'], 'app.test_mail_config(text) 存在');
select has_function('public', 'test_mail_config', array['text'], 'public.test_mail_config(text) 薄包装存在');
select ok(
  (select count(*) = 2
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (('app', 'test_mail_config'), ('public', 'test_mail_config'))
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '两个 test_mail_config 均 security definer + search_path 固定为空'
);
select ok(
  has_function_privilege('authenticated', 'app.test_mail_config(text)', 'EXECUTE'),
  'authenticated 可执行 app.test_mail_config'
);
select ok(
  has_function_privilege('authenticated', 'public.test_mail_config(text)', 'EXECUTE'),
  'authenticated 可执行 public.test_mail_config'
);
select ok(
  not has_function_privilege('anon', 'public.test_mail_config(text)', 'EXECUTE'),
  'anon 无 public.test_mail_config 执行权'
);
select ok(
  not has_function_privilege('anon', 'app.test_mail_config(text)', 'EXECUTE'),
  'anon 无 app.test_mail_config 执行权'
);

-- ===========================================================================
-- 2. 越权与前置校验（4）
-- ===========================================================================
-- engineer 调 public 面：admin 校验先于业务逻辑
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.test_mail_config('eng@example.com') $$,
  '42501', null, 'engineer 调 test_mail_config 被 admin 校验拒绝'
);
reset role;

-- anon 无 GRANT（先于函数体）
set local role anon;
select throws_ok(
  $$ select public.test_mail_config('anon@example.com') $$,
  '42501', null, 'anon 调 test_mail_config 被拒（无 GRANT）'
);
reset role;

-- admin：未配置 mail 时报 P0002
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.test_mail_config('admin@example.com') $$,
  'P0002', null, '未保存邮件配置时报 P0002'
);

-- 草稿可存：不完整配置（缺 port/username）
select lives_ok(
  $$ select public.upsert_service_config('mail', '{"host":"smtp.example.com"}'::jsonb, 'smtp-pass-9876') $$,
  'admin 保存不完整邮件配置（草稿态）'
);
reset role;

-- ===========================================================================
-- 3. 配置缺失 → failed + 可读提示 + 审计（7）
-- ===========================================================================
set local role authenticated;

select is(
  (select (public.test_mail_config('admin@example.com')) ->> 'ok'),
  'false',
  '配置缺失：test_mail_config 返回 ok=false'
);
select is(
  (select (public.test_mail_config('admin@example.com')) ->> 'message'),
  '配置不完整：host / port / username 均为必填',
  '配置缺失：message 提示必填字段'
);
select is(
  (select (public.test_mail_config('admin@example.com')) ->> 'verify_status'),
  'failed',
  '配置缺失：返回 verify_status=failed'
);

reset role;

select is(
  (select verify_status from public.system_services where service = 'mail'),
  'failed',
  '配置缺失：库内 verify_status=failed'
);
select ok(
  (select verified_at is not null from public.system_services where service = 'mail'),
  '配置缺失：verified_at 记录最近一次尝试时间'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'verify'
      and object_type = 'service_config' and object_id = 'mail'
      and diff ->> 'note' like '%admin@example.com%'
  ),
  'verify 审计备注含测试收件邮箱'
);
select ok(
  not exists (
    select 1 from public.audit_operations
    where module = 'system' and diff::text like '%smtp-pass-9876%'
  ),
  '审计摘要不落凭据明文'
);

-- ===========================================================================
-- 4. 配置完整 → verified（6）
-- ===========================================================================
set local role authenticated;

select lives_ok(
  $$ select public.upsert_service_config(
       'mail',
       '{"host":"smtp.example.com","port":587,"secure":true,"username":"mailer@example.com","from_addr":"noreply@example.com","from_name":"企业管理系统","reply_to":""}'::jsonb,
       'smtp-pass-9876'
     ) $$,
  'admin 保存完整邮件配置'
);
select is(
  (select (public.test_mail_config('admin@example.com')) ->> 'ok'),
  'true',
  '配置完整：test_mail_config 返回 ok=true'
);
select ok(
  (select (public.test_mail_config('admin@example.com')) ->> 'message') like '配置校验通过%',
  '配置完整：message 说明真实发送待投递器上线'
);

reset role;

select is(
  (select verify_status from public.system_services where service = 'mail'),
  'verified',
  '配置完整：库内 verify_status=verified'
);
select ok(
  (select verified_at is not null from public.system_services where service = 'mail'),
  '配置完整：verified_at 记录最近一次尝试时间'
);
select ok(
  (select diff ->> 'note'
     from public.audit_operations
    where module = 'system' and action = 'verify'
    order by id desc limit 1) like '%配置校验通过%',
  'verify 审计备注含校验通过说明'
);

-- ===========================================================================
-- 5. 参数校验失败不改变验证状态（2）
-- ===========================================================================
set local role authenticated;
select throws_ok(
  $$ select public.test_mail_config('') $$,
  '22023', null, '测试收件邮箱为空报 22023'
);
reset role;

select is(
  (select verify_status from public.system_services where service = 'mail'),
  'verified',
  '参数校验失败不改变验证状态（仍 verified）'
);

-- ===========================================================================
-- 6. upsert 凭据保留语义（11）
-- ===========================================================================
-- 相同 config + 不传凭据：不算修改，保持 verified，原密文保留
set local role authenticated;
select is(
  (select (public.upsert_service_config(
     'mail',
     '{"host":"smtp.example.com","port":587,"secure":true,"username":"mailer@example.com","from_addr":"noreply@example.com","from_name":"企业管理系统","reply_to":""}'::jsonb,
     null
   )) ->> 'verify_status'),
  'verified',
  '相同配置 + 不传凭据：保持 verified（不视为修改）'
);
select is(
  (select (public.upsert_service_config(
     'mail',
     '{"host":"smtp.example.com","port":587,"secure":true,"username":"mailer@example.com","from_addr":"noreply@example.com","from_name":"企业管理系统","reply_to":""}'::jsonb,
     null
   )) ->> 'credentials_set'),
  'true',
  '相同配置 + 不传凭据：返回 credentials_set=true'
);
reset role;

select is(
  app.decrypt_secret((select credentials from public.system_services where service = 'mail')),
  'smtp-pass-9876',
  '不传凭据编辑保存：原密文保留且可解密'
);
select ok(
  (select (diff ->> 'credentials_kept')::boolean
      and not (diff ->> 'credentials_changed')::boolean
     from public.audit_operations
    where module = 'system' and action = 'upsert'
      and object_type = 'service_config' and object_id = 'mail'
    order by id desc limit 1),
  '审计记录 credentials_kept=true 且 credentials_changed=false'
);

-- config 变更 + 不传凭据：降级 unverified，凭据仍保留
set local role authenticated;
select is(
  (select (public.upsert_service_config(
     'mail',
     '{"host":"smtp2.example.com","port":587,"secure":true,"username":"mailer@example.com","from_addr":"noreply@example.com","from_name":"企业管理系统","reply_to":""}'::jsonb,
     null
   )) ->> 'verify_status'),
  'unverified',
  '改配置 + 不传凭据：降级 unverified'
);
reset role;

select is(
  app.decrypt_secret((select credentials from public.system_services where service = 'mail')),
  'smtp-pass-9876',
  '改配置 + 不传凭据：凭据仍保留'
);

-- 复验后显式传入新凭据（同 config）：降级 unverified，新凭据替换
set local role authenticated;
select lives_ok(
  $$ select public.mark_service_verified('mail', true, '复验通过') $$,
  '复验通过 → verified'
);
select is(
  (select (public.upsert_service_config(
     'mail',
     '{"host":"smtp2.example.com","port":587,"secure":true,"username":"mailer@example.com","from_addr":"noreply@example.com","from_name":"企业管理系统","reply_to":""}'::jsonb,
     'new-pass-4321'
   )) ->> 'verify_status'),
  'unverified',
  '仅改凭据（同配置）：降级 unverified'
);
reset role;

select is(
  app.decrypt_secret((select credentials from public.system_services where service = 'mail')),
  'new-pass-4321',
  '显式新凭据替换写入'
);

-- 新建行不传凭据仍为 NULL（system/001 契约不变）
set local role authenticated;
select lives_ok(
  $$ select public.upsert_service_config('push', '{"provider":"fcm"}'::jsonb, null) $$,
  '新建 push 配置（不传凭据）'
);
reset role;

select is(
  (select credentials from public.system_services where service = 'push'),
  null::bytea,
  '新建行不传凭据仍为 NULL（system/001 契约不变）'
);

select * from finish();
rollback;
