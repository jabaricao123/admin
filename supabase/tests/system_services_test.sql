-- pgTAP：system/001 —— system_services 通用表 + pgcrypto 共享加密 helper + 管理/展示 RPC + RLS
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构（表/列/约束/RLS/密钥 seed）；函数存在性 + SECURITY DEFINER + search_path=''；
--       GRANT 面（authenticated 有管理/展示、无内部 helper 与读取口；anon 无）；
--       加密往返一致 / 随机盐 / NULL 语义；authenticated 直查表与越权调用被拒；
--       admin upsert 后凭据非明文且可解密；掩码只露尾 4 位；审计摘要（无明文）；
--       验证状态机（verified → 修改降级 unverified 清空 verified_at；相同内容不降级；failed 保持）。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(95);

-- ===========================================================================
-- 1. 结构：表 / 列 / 约束 / RLS / 密钥 seed（17）
-- ===========================================================================
select has_table('public', 'system_services', 'system_services 表存在');
select has_table('app', 'encryption_key', 'app.encryption_key 密钥表存在');

select col_is_pk('public', 'system_services', 'service', 'service 为主键');
select col_type_is('public', 'system_services', 'config', 'jsonb', 'config 为 jsonb');
select col_type_is('public', 'system_services', 'credentials', 'bytea', 'credentials 为 bytea');
select col_not_null('public', 'system_services', 'config', 'config 非空');
select col_has_default('public', 'system_services', 'config', 'config 有默认值');
select col_has_check('public', 'system_services', 'service', 'service 有白名单 check 约束');
select col_has_check('public', 'system_services', 'verify_status', 'verify_status 有取值 check 约束');
select has_column('public', 'system_services', 'verify_status', 'verify_status 列存在');
select has_column('public', 'system_services', 'verified_at', 'verified_at 列存在');
select has_column('public', 'system_services', 'updated_by', 'updated_by 列存在');
select has_column('public', 'system_services', 'updated_at', 'updated_at 列存在');
select has_column('app', 'encryption_key', 'key', 'encryption_key.key 列存在');
select has_column('app', 'encryption_key', 'rotated_at', 'encryption_key.rotated_at 列存在');

select is(
  (select relrowsecurity from pg_class where oid = 'public.system_services'::regclass),
  true,
  'system_services 已启用 RLS'
);
select is(
  (select count(*) from app.encryption_key where key_id = 1 and key <> ''),
  1::bigint,
  '加密密钥 seed（key_id=1 且非空）恰 1 行'
);

-- ===========================================================================
-- 2. 函数存在性 + SECURITY DEFINER + search_path（10）
-- ===========================================================================
select has_function('app', 'encrypt_secret', array['text'], 'app.encrypt_secret(text) 存在');
select has_function('app', 'decrypt_secret', array['bytea'], 'app.decrypt_secret(bytea) 存在');
select has_function('app', 'get_service_config', array['text'], 'app.get_service_config(text) 存在');
select has_function(
  'app', 'upsert_service_config', array['text', 'jsonb', 'text'],
  'app.upsert_service_config(text,jsonb,text) 存在'
);
select has_function(
  'app', 'mark_service_verified', array['text', 'boolean', 'text'],
  'app.mark_service_verified(text,boolean,text) 存在'
);
select has_function('app', 'get_service_status', 'app.get_service_status() 存在');
select has_function(
  'public', 'upsert_service_config', array['text', 'jsonb', 'text'],
  'public.upsert_service_config 薄包装存在'
);
select has_function(
  'public', 'mark_service_verified', array['text', 'boolean', 'text'],
  'public.mark_service_verified 薄包装存在'
);
select has_function('public', 'get_service_status', 'public.get_service_status 薄包装存在');

select ok(
  (select count(*) = 9
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
      ('app', 'encrypt_secret'),
      ('app', 'decrypt_secret'),
      ('app', 'get_service_config'),
      ('app', 'upsert_service_config'),
      ('app', 'mark_service_verified'),
      ('app', 'get_service_status'),
      ('public', 'upsert_service_config'),
      ('public', 'mark_service_verified'),
      ('public', 'get_service_status')
    )
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '9 个 helper/管理/展示函数全部 security definer + search_path 固定为空'
);

-- ===========================================================================
-- 3. GRANT 面（14）
-- ===========================================================================
select ok(
  has_function_privilege('authenticated', 'app.upsert_service_config(text,jsonb,text)', 'EXECUTE'),
  'authenticated 可执行 app.upsert_service_config'
);
select ok(
  has_function_privilege('authenticated', 'app.mark_service_verified(text,boolean,text)', 'EXECUTE'),
  'authenticated 可执行 app.mark_service_verified'
);
select ok(
  has_function_privilege('authenticated', 'app.get_service_status()', 'EXECUTE'),
  'authenticated 可执行 app.get_service_status'
);
select ok(
  has_function_privilege('authenticated', 'public.upsert_service_config(text,jsonb,text)', 'EXECUTE'),
  'authenticated 可执行 public.upsert_service_config'
);
select ok(
  has_function_privilege('authenticated', 'public.get_service_status()', 'EXECUTE'),
  'authenticated 可执行 public.get_service_status'
);
select ok(
  not has_function_privilege('authenticated', 'app.get_service_config(text)', 'EXECUTE'),
  'authenticated 无 app.get_service_config 执行权（规则 10）'
);
select ok(
  not has_function_privilege('authenticated', 'app.encrypt_secret(text)', 'EXECUTE'),
  'authenticated 无 app.encrypt_secret 执行权'
);
select ok(
  not has_function_privilege('authenticated', 'app.decrypt_secret(bytea)', 'EXECUTE'),
  'authenticated 无 app.decrypt_secret 执行权'
);
select ok(
  not has_function_privilege('anon', 'public.get_service_status()', 'EXECUTE'),
  'anon 无 public.get_service_status 执行权'
);
select ok(
  not has_function_privilege('anon', 'public.upsert_service_config(text,jsonb,text)', 'EXECUTE'),
  'anon 无 public.upsert_service_config 执行权'
);
select ok(
  not has_table_privilege('authenticated', 'public.system_services', 'SELECT'),
  'authenticated 对 system_services 无 SELECT（连读也不给）'
);
select ok(
  not has_table_privilege('authenticated', 'public.system_services', 'INSERT'),
  'authenticated 对 system_services 无 INSERT'
);
select ok(
  not has_table_privilege('authenticated', 'app.encryption_key', 'SELECT'),
  'authenticated 对 app.encryption_key 无 SELECT'
);
select ok(
  not has_table_privilege('anon', 'public.system_services', 'SELECT'),
  'anon 对 system_services 无 SELECT'
);

-- ===========================================================================
-- 4. 加密 helper：往返 / 随机盐 / NULL（4，superuser 直调）
-- ===========================================================================
select is(
  app.decrypt_secret(app.encrypt_secret('smtp-p@ss-中文-9876')),
  'smtp-p@ss-中文-9876',
  '加密→解密往返一致（含中文特殊字符）'
);
select ok(
  app.encrypt_secret('same-plaintext') <> app.encrypt_secret('same-plaintext'),
  '随机盐：同一明文两次密文不同'
);
select is(app.encrypt_secret(null), null::bytea, 'NULL 明文加密结果为 NULL');
select is(app.decrypt_secret(null), null::text, 'NULL 密文解密结果为 NULL');

-- ===========================================================================
-- 5. 越权：authenticated（engineer）直查表 / 调用内部函数被拒（7）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$ select * from public.system_services $$,
  '42501', null, 'engineer 直查 system_services 被拒'
);
select throws_ok(
  $$ insert into public.system_services (service) values ('mail') $$,
  '42501', null, 'engineer 直写 system_services 被拒'
);
select throws_ok(
  $$ select app.encrypt_secret('x') $$,
  '42501', null, 'engineer 调 app.encrypt_secret 被拒'
);
select throws_ok(
  $$ select app.get_service_config('mail') $$,
  '42501', null, 'engineer 调 app.get_service_config 被拒（规则 10）'
);
select throws_ok(
  $$ select public.upsert_service_config('mail', '{}'::jsonb, 'x') $$,
  '42501', null, 'engineer 调 upsert_service_config 被 admin 校验拒绝'
);
select throws_ok(
  $$ select public.mark_service_verified('mail', true, null) $$,
  '42501', null, 'engineer 调 mark_service_verified 被 admin 校验拒绝'
);
select throws_ok(
  $$ select * from public.get_service_status() $$,
  '42501', null, 'engineer 调 get_service_status 被 admin 校验拒绝'
);

reset role;

-- ===========================================================================
-- 6. 越权：anon 全部无路径（3）
-- ===========================================================================
set local role anon;

select throws_ok(
  $$ select * from public.system_services $$,
  '42501', null, 'anon 直查 system_services 被拒'
);
select throws_ok(
  $$ select * from public.get_service_status() $$,
  '42501', null, 'anon 调 get_service_status 被拒（无 GRANT）'
);
select throws_ok(
  $$ select public.upsert_service_config('mail', '{}'::jsonb, 'x') $$,
  '42501', null, 'anon 调 upsert_service_config 被拒（无 GRANT）'
);

reset role;

-- ===========================================================================
-- 7. admin 新建（草稿）：加密落库 + 非明文 + 返回 summary（9）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$ select public.upsert_service_config(
       'mail',
       '{"host":"smtp.example.com","port":587,"secure":true}'::jsonb,
       'smtp-pass-9876'
     ) $$,
  'admin 新建 mail 配置成功（草稿态）'
);

select is(
  (select (public.upsert_service_config('storage', '{"bucket":"files"}'::jsonb, null)) ->> 'credentials_set'),
  'false',
  'upsert 返回 summary：未传凭据 credentials_set=false'
);

reset role;

select is(
  (select verify_status from public.system_services where service = 'mail'),
  'unverified',
  '新建后 verify_status=unverified（待复验）'
);
select is(
  (select verified_at from public.system_services where service = 'mail'),
  null::timestamptz,
  '新建后 verified_at 为 NULL'
);
select is(
  (select updated_by from public.system_services where service = 'mail'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'updated_by 记录操作人 auth.uid()'
);
select ok(
  (select position(convert_to('smtp-pass-9876', 'UTF8') in credentials) = 0
     from public.system_services
    where service = 'mail'),
  'credentials 列不含明文（bytea 非原文）'
);
select is(
  app.decrypt_secret((select credentials from public.system_services where service = 'mail')),
  'smtp-pass-9876',
  'credentials 密文可解密回原文'
);
select is(
  (select credentials from public.system_services where service = 'storage'),
  null::bytea,
  '不传凭据时 credentials 为 NULL'
);

-- ===========================================================================
-- 8. 白名单读取口 app.get_service_config（3，superuser 直调）
-- ===========================================================================
select is(
  (app.get_service_config('mail')) ->> 'credentials',
  'smtp-pass-9876',
  'get_service_config 返回解密后的 credentials'
);
select is(
  (app.get_service_config('mail')) ->> 'host',
  'smtp.example.com',
  'get_service_config 含 config 字段'
);
select is(app.get_service_config('nope'), null::jsonb, '未知 service 返回 NULL');

-- ===========================================================================
-- 9. 脱敏展示 get_service_status（5，admin 身份）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select is(
  (select credentials_masked from public.get_service_status() where service = 'mail'),
  '****9876',
  '掩码只露尾 4 位（****9876）'
);
select is(
  length((select credentials_masked from public.get_service_status() where service = 'mail')),
  8,
  '掩码长度为 8（4 星号 + 尾 4 位）'
);
select is(
  (select config ->> 'host' from public.get_service_status() where service = 'mail'),
  'smtp.example.com',
  'get_service_status 返回非敏感 config'
);
select is(
  (select credentials_masked from public.get_service_status() where service = 'storage'),
  null::text,
  '无凭据服务掩码为 NULL'
);
select is(
  (select count(*) from public.get_service_status()),
  2::bigint,
  'get_service_status 返回全部已配置服务（2 行）'
);

-- ===========================================================================
-- 10. 管理 RPC 参数校验（4，admin 身份）
-- ===========================================================================
select throws_ok(
  $$ select public.upsert_service_config('nope', '{}'::jsonb, null) $$,
  '22023', null, '未知 service 报 22023'
);
select throws_ok(
  $$ select public.upsert_service_config('mail', '[]'::jsonb, null) $$,
  '22023', null, 'config 非对象报 22023'
);
select throws_ok(
  $$ select public.mark_service_verified('nope', true, null) $$,
  'P0002', null, 'mark 未配置服务报 P0002'
);
select throws_ok(
  $$ select public.mark_service_verified('mail', null, null) $$,
  '22023', null, 'mark p_ok 为 NULL 报 22023'
);

reset role;

-- ===========================================================================
-- 11. 验证状态机（8）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$ select public.mark_service_verified('mail', true, '连接成功') $$,
  '测试连接成功 → mark verified'
);

reset role;
select is(
  (select verify_status from public.system_services where service = 'mail'),
  'verified',
  '验证通过后 verify_status=verified'
);
select ok(
  (select verified_at is not null from public.system_services where service = 'mail'),
  '验证通过后 verified_at 非空'
);

set local role authenticated;
select is(
  (select (public.upsert_service_config(
     'mail',
     '{"host":"smtp2.example.com","port":587,"secure":true}'::jsonb,
     'smtp-pass-9876'
   )) ->> 'verify_status'),
  'unverified',
  '已验证配置被修改 → 返回并落库 unverified（降级待复验）'
);

reset role;
select is(
  (select verify_status from public.system_services where service = 'mail'),
  'unverified',
  '降级后 verify_status=unverified'
);
select is(
  (select verified_at from public.system_services where service = 'mail'),
  null::timestamptz,
  '降级后旧 verified_at 清空'
);

-- 相同内容再次保存：不降级
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.mark_service_verified('mail', true, '再次连接成功') $$,
  '复验通过 → verified'
);
select is(
  (select (public.upsert_service_config(
     'mail',
     '{"host":"smtp2.example.com","port":587,"secure":true}'::jsonb,
     'smtp-pass-9876'
   )) ->> 'verify_status'),
  'verified',
  '相同 config + 相同凭据保存：保持 verified（不算修改）'
);

reset role;

-- ===========================================================================
-- 12. 验证失败与 failed 终态保持（5）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.mark_service_verified('mail', false, '连接超时：ETIMEDOUT') $$,
  '测试连接失败 → mark failed'
);

reset role;
select is(
  (select verify_status from public.system_services where service = 'mail'),
  'failed',
  '验证失败后 verify_status=failed'
);
select ok(
  (select verified_at is not null from public.system_services where service = 'mail'),
  '失败也更新 verified_at（最近一次验证尝试时间）'
);

set local role authenticated;
select is(
  (select (public.upsert_service_config(
     'mail',
     '{"host":"smtp3.example.com","port":465,"secure":true}'::jsonb,
     'smtp-pass-9876'
   )) ->> 'verify_status'),
  'failed',
  'failed 配置被修改：保持 failed（仅 verified 才降级）'
);
reset role;

-- ===========================================================================
-- 13. 表约束兜底（2，superuser）
-- ===========================================================================
select throws_ok(
  $$ insert into public.system_services (service) values ('unknown') $$,
  '23514', null, 'service 白名单 check 约束兜底'
);
select throws_ok(
  $$ insert into public.system_services (service, verify_status) values ('push', 'weird') $$,
  '23514', null, 'verify_status 取值 check 约束兜底'
);

-- ===========================================================================
-- 14. 审计摘要（6，superuser 直查 audit_operations）
-- ===========================================================================
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'upsert'
      and object_type = 'service_config' and object_id = 'mail'
  ),
  'upsert 写审计摘要（module=system/action=upsert）'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'verify'
      and object_type = 'service_config' and object_id = 'mail'
  ),
  'mark_service_verified 写审计摘要（action=verify）'
);
select is(
  (select diff ->> 'note'
     from public.audit_operations
    where module = 'system' and action = 'verify'
    order by id desc limit 1),
  '连接超时：ETIMEDOUT',
  'verify 审计带 p_note（表不存备注列）'
);
select ok(
  (select diff ? 'config_changed' and diff ? 'credentials_changed'
     from public.audit_operations
    where module = 'system' and action = 'upsert'
      and object_id = 'mail'
    order by id desc limit 1),
  'upsert 审计记录变更标记与状态迁移'
);
select ok(
  not exists (
    select 1 from public.audit_operations
    where module = 'system' and diff::text like '%smtp-pass-9876%'
  ),
  '审计摘要不落凭据明文'
);
select ok(
  (select diff ->> 'verify_status_after' = 'unverified'
     from public.audit_operations
    where module = 'system' and action = 'upsert'
      and object_id = 'mail'
      and diff ->> 'verify_status_before' = 'verified'
    limit 1),
  '降级审计记录 verify_status_before=verified → after=unverified'
);

select * from finish();
rollback;
