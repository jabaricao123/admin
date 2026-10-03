-- pgTAP：integration/001 —— api_keys 表 + 签发/吊销/校验 RPC + RLS
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构（列/约束/唯一索引/RLS/触发器）；函数存在性 + SECURITY DEFINER + search_path=''；
--       GRANT 面（authenticated 可签发/吊销、无 verify_api_key，规则 10；anon 无路径）；
--       签发一次性返回完整 key、prefix 掩码、sha256 落库、明文零落库；scopes/有效期校验；
--       verify（成功返回 key_id+scopes 并更新 last_used_at；未知/吊销/过期返回 NULL）；
--       吊销即时失效；越权（engineer/anon）被拒；RLS（engineer 读 0 行、admin 可见）；
--       审计摘要（create/revoke；不落 key 明文与哈希）。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(96);

-- ===========================================================================
-- 1. 结构：列 / 约束 / 唯一索引 / RLS / 触发器（25）
-- ===========================================================================
select has_table('public', 'api_keys', 'api_keys 表存在');
select col_is_pk('public', 'api_keys', 'id', 'id 为主键');
select col_type_is('public', 'api_keys', 'id', 'uuid', 'id 为 uuid');
select col_type_is('public', 'api_keys', 'name', 'text', 'name 为 text');
select col_type_is('public', 'api_keys', 'key_prefix', 'text', 'key_prefix 为 text');
select col_type_is('public', 'api_keys', 'key_hash', 'text', 'key_hash 为 text');
select col_type_is('public', 'api_keys', 'scopes', 'jsonb', 'scopes 为 jsonb');
select col_type_is('public', 'api_keys', 'status', 'text', 'status 为 text');
select is(
  (select a.atttypid::regtype::text
     from pg_attribute a
    where a.attrelid = 'public.api_keys'::regclass and a.attname = 'expires_at'),
  'timestamp with time zone',
  'expires_at 为 timestamptz'
);
select is(
  (select a.atttypid::regtype::text
     from pg_attribute a
    where a.attrelid = 'public.api_keys'::regclass and a.attname = 'last_used_at'),
  'timestamp with time zone',
  'last_used_at 为 timestamptz'
);
select has_column('public', 'api_keys', 'created_by', 'created_by 列存在');
select has_column('public', 'api_keys', 'updated_by', 'updated_by 列存在');
select has_column('public', 'api_keys', 'created_at', 'created_at 列存在');
select has_column('public', 'api_keys', 'updated_at', 'updated_at 列存在');
select col_not_null('public', 'api_keys', 'name', 'name 非空');
select col_not_null('public', 'api_keys', 'key_prefix', 'key_prefix 非空');
select col_not_null('public', 'api_keys', 'key_hash', 'key_hash 非空');
select col_not_null('public', 'api_keys', 'scopes', 'scopes 非空');
select col_has_default('public', 'api_keys', 'scopes', 'scopes 有默认值');
select col_has_default('public', 'api_keys', 'status', 'status 有默认值');
select col_has_check('public', 'api_keys', 'status', 'status 有取值 check 约束');
select col_has_check('public', 'api_keys', 'key_prefix', 'key_prefix 有格式 check 约束');
select col_has_check('public', 'api_keys', 'scopes', 'scopes 有类型 check 约束');
select col_is_unique('public', 'api_keys', 'key_hash', 'key_hash 有唯一索引');
select is(
  (select relrowsecurity from pg_class where oid = 'public.api_keys'::regclass),
  true,
  'api_keys 已启用 RLS'
);
select has_trigger('public', 'api_keys', 'api_keys_set_updated_at', 'updated_at 触发器存在');

-- ===========================================================================
-- 2. 函数存在性 + SECURITY DEFINER + search_path（7）
-- ===========================================================================
select has_function('app', 'create_api_key', array['text', 'jsonb', 'timestamptz'],
  'app.create_api_key(text,jsonb,timestamptz) 存在');
select has_function('app', 'revoke_api_key', array['uuid'], 'app.revoke_api_key(uuid) 存在');
select has_function('app', 'verify_api_key', array['text'], 'app.verify_api_key(text) 存在');
select has_function('public', 'create_api_key', array['text', 'jsonb', 'timestamptz'],
  'public.create_api_key 薄包装存在');
select has_function('public', 'revoke_api_key', array['uuid'], 'public.revoke_api_key 薄包装存在');
select hasnt_function('public', 'verify_api_key', array['text'],
  'public.verify_api_key 不存在（规则 10：不经 Data API 暴露）');
select ok(
  (select count(*) = 5
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
      ('app', 'create_api_key'),
      ('app', 'revoke_api_key'),
      ('app', 'verify_api_key'),
      ('public', 'create_api_key'),
      ('public', 'revoke_api_key')
    )
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '5 个函数全部 security definer + search_path 固定为空'
);

-- ===========================================================================
-- 3. GRANT 面（12）
-- ===========================================================================
select ok(
  has_function_privilege('authenticated', 'app.create_api_key(text,jsonb,timestamptz)', 'EXECUTE'),
  'authenticated 可执行 app.create_api_key'
);
select ok(
  has_function_privilege('authenticated', 'public.create_api_key(text,jsonb,timestamptz)', 'EXECUTE'),
  'authenticated 可执行 public.create_api_key'
);
select ok(
  has_function_privilege('authenticated', 'app.revoke_api_key(uuid)', 'EXECUTE'),
  'authenticated 可执行 app.revoke_api_key'
);
select ok(
  has_function_privilege('authenticated', 'public.revoke_api_key(uuid)', 'EXECUTE'),
  'authenticated 可执行 public.revoke_api_key'
);
select ok(
  not has_function_privilege('authenticated', 'app.verify_api_key(text)', 'EXECUTE'),
  'authenticated 无 app.verify_api_key 执行权（规则 10）'
);
select ok(
  not has_function_privilege('service_role', 'app.verify_api_key(text)', 'EXECUTE'),
  'service_role 无 app.verify_api_key 执行权（不预置后端通道）'
);
select ok(
  not has_function_privilege('anon', 'public.create_api_key(text,jsonb,timestamptz)', 'EXECUTE'),
  'anon 无 public.create_api_key 执行权'
);
select ok(
  not has_function_privilege('anon', 'public.revoke_api_key(uuid)', 'EXECUTE'),
  'anon 无 public.revoke_api_key 执行权'
);
select ok(
  has_table_privilege('authenticated', 'public.api_keys', 'SELECT'),
  'authenticated 有 api_keys SELECT（RLS 再收口 admin）'
);
select ok(
  not has_table_privilege('authenticated', 'public.api_keys', 'INSERT'),
  'authenticated 无 api_keys INSERT（无表级写）'
);
select ok(
  not has_table_privilege('authenticated', 'public.api_keys', 'UPDATE'),
  'authenticated 无 api_keys UPDATE（无表级写）'
);
select ok(
  not has_table_privilege('authenticated', 'public.api_keys', 'DELETE'),
  'authenticated 无 api_keys DELETE（无表级写）'
);

-- ===========================================================================
-- 4. 越权调用：engineer / anon 被拒（4）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$ select public.create_api_key('越权', '[]'::jsonb, null) $$,
  '42501', null, 'engineer 签发被 admin 校验拒绝'
);
select throws_ok(
  $$ select public.revoke_api_key('00000000-0000-0000-0000-000000000000'::uuid) $$,
  '42501', null, 'engineer 吊销被 admin 校验拒绝'
);

reset role;
set local role anon;

select throws_ok(
  $$ select public.create_api_key('未登录', '[]'::jsonb, null) $$,
  '42501', null, 'anon 签发被拒（无 GRANT）'
);
select throws_ok(
  $$ select public.revoke_api_key('00000000-0000-0000-0000-000000000000'::uuid) $$,
  '42501', null, 'anon 吊销被拒（无 GRANT）'
);

reset role;

-- ===========================================================================
-- 5. admin 签发：一次性返回完整 key + prefix；sha256 落库（14）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.create_api_key(
  '数据同步密钥',
  '["org:read","report:read"]'::jsonb,
  now() + interval '30 days'
) as k1 \gset

select public.create_api_key('无范围密钥', '[]'::jsonb, null) as k2 \gset

reset role;

select is((:'k1'::jsonb) ->> 'status', 'active', '签发返回 status=active');
select ok(
  (:'k1'::jsonb) ->> 'key' ~ '^ak_[0-9a-f]{32}$',
  '返回完整 key 形如 ak_ + 32 位十六进制'
);
select is(length((:'k1'::jsonb) ->> 'key'), 35, '完整 key 长度 35');
select is(
  (:'k1'::jsonb) ->> 'key_prefix',
  left((:'k1'::jsonb) ->> 'key', 11),
  '返回 key_prefix = key 前 11 位（ak_ + 8 位）'
);
select is(
  (select key_prefix from public.api_keys where id = (:'k1'::jsonb ->> 'id')::uuid),
  (:'k1'::jsonb) ->> 'key_prefix',
  '落库 key_prefix 与返回一致'
);
select is(
  (select key_hash from public.api_keys where id = (:'k1'::jsonb ->> 'id')::uuid),
  encode(extensions.digest((:'k1'::jsonb) ->> 'key', 'sha256'), 'hex'),
  '落库 key_hash = 完整 key 的 sha256 hex'
);
select ok(
  (select key_hash <> (:'k1'::jsonb) ->> 'key'
     from public.api_keys where id = (:'k1'::jsonb ->> 'id')::uuid),
  'key_hash 列不等于明文（明文零落库）'
);
select ok(
  not exists (
    select 1 from public.api_keys
     where key_hash = (:'k1'::jsonb) ->> 'key'
        or name = (:'k1'::jsonb) ->> 'key'
        or key_prefix = (:'k1'::jsonb) ->> 'key'
  ),
  '任何列都不含完整 key 明文'
);
select is(
  (select scopes from public.api_keys where id = (:'k1'::jsonb ->> 'id')::uuid),
  '["org:read","report:read"]'::jsonb,
  'scopes 落库为传入数组'
);
select is(
  (:'k1'::jsonb) -> 'scopes',
  '["org:read","report:read"]'::jsonb,
  '签发响应回显 scopes'
);
select is(
  (:'k2'::jsonb) ->> 'expires_at',
  null,
  'expires_at 传 NULL 表示不过期'
);
select is(
  (select created_by from public.api_keys where id = (:'k1'::jsonb ->> 'id')::uuid),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'created_by 记录操作人 auth.uid()'
);
select is(
  (select last_used_at from public.api_keys where id = (:'k1'::jsonb ->> 'id')::uuid),
  null::timestamptz,
  '签发后 last_used_at 为 NULL'
);
select ok(
  (:'k1'::jsonb) ->> 'key' <> (:'k2'::jsonb) ->> 'key',
  '两次签发 key 不同'
);

-- ===========================================================================
-- 6. 签发参数校验（6，admin 身份）
-- ===========================================================================
set local role authenticated;

select throws_ok(
  $$ select public.create_api_key(null, '[]'::jsonb, null) $$,
  '22023', null, 'name 为 NULL 报 22023'
);
select throws_ok(
  $$ select public.create_api_key('   ', '[]'::jsonb, null) $$,
  '22023', null, 'name 空白报 22023'
);
select throws_ok(
  $$ select public.create_api_key('x', '{"a":1}'::jsonb, null) $$,
  '22023', null, 'scopes 非数组报 22023'
);
select throws_ok(
  $$ select public.create_api_key('x', '[1,2]'::jsonb, null) $$,
  '22023', null, 'scopes 含非字符串元素报 22023'
);
select throws_ok(
  $$ select public.create_api_key('x', '[""]'::jsonb, null) $$,
  '22023', null, 'scopes 含空字符串报 22023'
);
select throws_ok(
  $$ select public.create_api_key('x', '[]'::jsonb, now() - interval '1 day') $$,
  '22023', null, '有效期早于当前时间报 22023'
);

reset role;

-- ===========================================================================
-- 7. verify_api_key：哈希 + 状态 + 有效期（8，superuser 直调——不 GRANT API 角色）
-- ===========================================================================
select is(
  app.verify_api_key((:'k1'::jsonb) ->> 'key') ->> 'key_id',
  (:'k1'::jsonb) ->> 'id',
  'verify 通过返回 key_id'
);
select is(
  app.verify_api_key((:'k1'::jsonb) ->> 'key') -> 'scopes',
  '["org:read","report:read"]'::jsonb,
  'verify 通过返回 scopes'
);
select ok(
  (select last_used_at is not null from public.api_keys where id = (:'k1'::jsonb ->> 'id')::uuid),
  'verify 通过更新 last_used_at'
);
select is(app.verify_api_key('ak_00000000000000000000000000000000'), null::jsonb,
  '未知 key 返回 NULL');
select is(app.verify_api_key(''), null::jsonb, '空字符串返回 NULL');
select is(app.verify_api_key(null), null::jsonb, 'NULL 返回 NULL');
select is(app.verify_api_key((:'k2'::jsonb) ->> 'key') -> 'scopes', '[]'::jsonb,
  'scopes 为空的 key 校验通过返回空数组');

-- 过期 key：直插绕过签发校验（测试夹具）
insert into public.api_keys (name, key_prefix, key_hash, scopes, status, expires_at)
values (
  '过期密钥', 'ak_deadbeef',
  encode(extensions.digest('ak_expired_raw', 'sha256'), 'hex'),
  '["org:read"]'::jsonb, 'active', now() - interval '1 day'
);
select is(app.verify_api_key('ak_expired_raw'), null::jsonb, '过期 key 返回 NULL');

-- ===========================================================================
-- 8. 吊销：即时失效 + 校验（4）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.revoke_api_key((:'k1'::jsonb ->> 'id')::uuid) as revoked \gset

select throws_ok(
  $$ select public.revoke_api_key('00000000-0000-0000-0000-000000000000'::uuid) $$,
  'P0002', null, '吊销不存在的 key 报 P0002'
);

reset role;
select is((:'revoked'::jsonb) ->> 'status', 'revoked', '吊销返回 status=revoked');
select is(
  (select status from public.api_keys where id = (:'k1'::jsonb ->> 'id')::uuid),
  'revoked',
  '落库 status=revoked'
);
select is(app.verify_api_key((:'k1'::jsonb) ->> 'key'), null::jsonb, '吊销后 verify 返回 NULL（即时失效）');

-- ===========================================================================
-- 9. RLS：engineer 不可见 / admin 可见 / anon 无路径（5）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;

select is(
  (select count(*) from public.api_keys),
  0::bigint,
  'engineer（无 admin 角色）读取 api_keys 为 0 行'
);

reset role;
set local role anon;

select throws_ok(
  $$ select * from public.api_keys $$,
  '42501', null, 'anon 直查 api_keys 被拒（无 GRANT）'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select ok(
  (select count(*) from public.api_keys) >= 2,
  'admin 通过 RLS 可见全部密钥'
);

select is(
  (select count(*) from public.api_keys where status = 'revoked'),
  1::bigint,
  'admin 可见已吊销记录'
);

reset role;

-- ===========================================================================
-- 10. 表约束兜底（3，superuser）
-- ===========================================================================
select throws_ok(
  $$ insert into public.api_keys (name, key_prefix, key_hash, scopes)
     values ('x', 'bad-prefix', 'h', '[]'::jsonb) $$,
  '23514', null, 'key_prefix 非法格式被 check 约束拒绝'
);
select throws_ok(
  $$ insert into public.api_keys (name, key_prefix, key_hash, scopes)
     values ('x', 'ak_00000000', 'h2', '{"a":1}'::jsonb) $$,
  '23514', null, 'scopes 非数组被 check 约束拒绝'
);
select throws_ok(
  $$ insert into public.api_keys (name, key_prefix, key_hash, status)
     values ('x', 'ak_00000001', 'h3', 'weird') $$,
  '23514', null, 'status 非法取值被 check 约束拒绝'
);

-- ===========================================================================
-- 11. 审计摘要（8，superuser 直查 audit_operations）
-- ===========================================================================
select ok(
  exists (
    select 1 from public.audit_operations
     where module = 'integration' and action = 'create'
       and object_type = 'api_key' and object_id = (:'k1'::jsonb ->> 'id')
  ),
  '签发写审计摘要（create/api_key）'
);
select ok(
  exists (
    select 1 from public.audit_operations
     where module = 'integration' and action = 'revoke'
       and object_type = 'api_key' and object_id = (:'k1'::jsonb ->> 'id')
  ),
  '吊销写审计摘要（revoke/api_key）'
);
select is(
  (select diff ->> 'key_prefix'
     from public.audit_operations
    where module = 'integration' and action = 'create'
      and object_id = (:'k1'::jsonb ->> 'id')),
  (:'k1'::jsonb) ->> 'key_prefix',
  '签发审计记录 key_prefix'
);
select is(
  (select diff -> 'scopes'
     from public.audit_operations
    where module = 'integration' and action = 'create'
      and object_id = (:'k1'::jsonb ->> 'id')),
  '["org:read","report:read"]'::jsonb,
  '签发审计记录 scopes'
);
select ok(
  not exists (
    select 1 from public.audit_operations
     where module = 'integration'
       and diff::text like '%' || ((:'k1'::jsonb) ->> 'key') || '%'
  ),
  '审计摘要不落 key 明文'
);
select ok(
  not exists (
    select 1 from public.audit_operations
     where module = 'integration'
       and diff::text like '%' || (select key_hash from public.api_keys
                                    where id = (:'k1'::jsonb ->> 'id')::uuid) || '%'
  ),
  '审计摘要不落 key_hash'
);
select is(
  (select diff ->> 'status_after'
     from public.audit_operations
    where module = 'integration' and action = 'revoke'
      and object_id = (:'k1'::jsonb ->> 'id')),
  'revoked',
  '吊销审计记录 status_after=revoked'
);
select ok(
  (select count(*) >= 2
     from public.audit_operations
    where module = 'integration' and object_type = 'api_key'),
  'api_key 审计记录数与操作次数一致（≥2）'
);

select * from finish();
rollback;
