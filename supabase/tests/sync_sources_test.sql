-- pgTAP：sync/001 —— sync_sources 表 + 凭据加密 + 验证状态机 + 停用引用守卫 + RLS
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构（列/类型/约束/RLS/触发器）；函数存在性 + SECURITY DEFINER + search_path=''；
--       GRANT 面（authenticated 有管理/列表 RPC、无内部 helper；anon 无路径；表仅 SELECT 无写）；
--       admin CRUD + 凭据 pgcrypto 加密（非明文、可解密、NULL=保留）；掩码只露尾 4 位；
--       验证状态机（failed/verified 回写、已验证配置变更降级并清空 last_verified_at、同内容不降级）；
--       excel 模板对象存在性校验；停用守卫（被 active 任务引用拒绝，disabled 任务不算）；
--       越权（engineer 读 0 行、RPC 42501；anon 无 GRANT）；审计摘要（不落凭据明文）。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(95);

-- ===========================================================================
-- 1. 结构：表 / 列 / 类型 / 约束 / RLS / 触发器（20）
-- ===========================================================================
select has_table('public', 'sync_sources', 'sync_sources 表存在');

select col_is_pk('public', 'sync_sources', 'id', 'id 为主键');
select col_type_is('public', 'sync_sources', 'id', 'uuid', 'id 为 uuid');
select col_type_is('public', 'sync_sources', 'name', 'text', 'name 为 text');
select col_type_is('public', 'sync_sources', 'type', 'text', 'type 为 text');
select col_type_is('public', 'sync_sources', 'config', 'jsonb', 'config 为 jsonb');
select col_type_is('public', 'sync_sources', 'credentials', 'bytea', 'credentials 为 bytea');
select col_type_is('public', 'sync_sources', 'verify_status', 'text', 'verify_status 为 text');
select col_type_is('public', 'sync_sources', 'last_verified_at', 'timestamp with time zone', 'last_verified_at 为 timestamptz');
select col_type_is('public', 'sync_sources', 'status', 'text', 'status 为 text');
select col_not_null('public', 'sync_sources', 'name', 'name 非空');
select col_not_null('public', 'sync_sources', 'config', 'config 非空');
select col_has_default('public', 'sync_sources', 'config', 'config 有默认值');
select col_has_default('public', 'sync_sources', 'verify_status', 'verify_status 有默认值');
select col_has_default('public', 'sync_sources', 'status', 'status 有默认值');
select col_has_check('public', 'sync_sources', 'type', 'type 有取值 check 约束');
select col_has_check('public', 'sync_sources', 'verify_status', 'verify_status 有取值 check 约束');
select col_has_check('public', 'sync_sources', 'status', 'status 有取值 check 约束');
select is(
  (select relrowsecurity from pg_class where oid = 'public.sync_sources'::regclass),
  true,
  'sync_sources 已启用 RLS'
);
select has_trigger('public', 'sync_sources', 'sync_sources_set_updated_at', 'updated_at 触发器存在');

-- ===========================================================================
-- 2. 函数存在性 + SECURITY DEFINER + search_path + GRANT 面（22）
-- ===========================================================================
select has_function(
  'app', 'upsert_sync_source', array['uuid', 'text', 'text', 'jsonb', 'text', 'text'],
  'app.upsert_sync_source(uuid,text,text,jsonb,text,text) 存在'
);
select has_function('app', 'test_sync_source', array['uuid'], 'app.test_sync_source(uuid) 存在');
select has_function('app', 'disable_sync_source', array['uuid'], 'app.disable_sync_source(uuid) 存在');
select has_function('app', 'get_sync_sources', array[]::text[], 'app.get_sync_sources() 存在');
select has_function(
  'public', 'upsert_sync_source', array['uuid', 'text', 'text', 'jsonb', 'text', 'text'],
  'public.upsert_sync_source 薄包装存在'
);
select has_function('public', 'test_sync_source', array['uuid'], 'public.test_sync_source 薄包装存在');
select has_function('public', 'disable_sync_source', array['uuid'], 'public.disable_sync_source 薄包装存在');
select has_function('public', 'get_sync_sources', array[]::text[], 'public.get_sync_sources 薄包装存在');

select ok(
  (select count(*) = 9
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
      ('app', 'ensure_sync_source_disableable'),
      ('app', 'upsert_sync_source'),
      ('app', 'test_sync_source'),
      ('app', 'disable_sync_source'),
      ('app', 'get_sync_sources'),
      ('public', 'upsert_sync_source'),
      ('public', 'test_sync_source'),
      ('public', 'disable_sync_source'),
      ('public', 'get_sync_sources')
    )
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '9 个 helper/管理/列表函数全部 security definer + search_path 固定为空'
);

select ok(
  has_function_privilege('authenticated', 'app.upsert_sync_source(uuid,text,text,jsonb,text,text)', 'EXECUTE'),
  'authenticated 可执行 app.upsert_sync_source'
);
select ok(
  has_function_privilege('authenticated', 'app.test_sync_source(uuid)', 'EXECUTE'),
  'authenticated 可执行 app.test_sync_source'
);
select ok(
  has_function_privilege('authenticated', 'app.disable_sync_source(uuid)', 'EXECUTE'),
  'authenticated 可执行 app.disable_sync_source'
);
select ok(
  has_function_privilege('authenticated', 'app.get_sync_sources()', 'EXECUTE'),
  'authenticated 可执行 app.get_sync_sources'
);
select ok(
  has_function_privilege('authenticated', 'public.get_sync_sources()', 'EXECUTE'),
  'authenticated 可执行 public.get_sync_sources'
);
select ok(
  not has_function_privilege('authenticated', 'app.ensure_sync_source_disableable(uuid)', 'EXECUTE'),
  'authenticated 无内部 helper 执行权'
);
select ok(
  not has_function_privilege('anon', 'public.get_sync_sources()', 'EXECUTE'),
  'anon 无列表 RPC 执行权'
);
select ok(
  not has_function_privilege('service_role', 'public.get_sync_sources()', 'EXECUTE'),
  'service_role 无列表 RPC 执行权（全局禁 service_role）'
);
select ok(
  has_table_privilege('authenticated', 'public.sync_sources', 'SELECT'),
  'authenticated 表级 SELECT 已授予（RLS 再收口 admin）'
);
select ok(
  not has_table_privilege('authenticated', 'public.sync_sources', 'INSERT'),
  'authenticated 无 INSERT（写仅经 RPC）'
);
select ok(
  not has_table_privilege('authenticated', 'public.sync_sources', 'UPDATE'),
  'authenticated 无 UPDATE（写仅经 RPC）'
);
select ok(
  not has_table_privilege('authenticated', 'public.sync_sources', 'DELETE'),
  'authenticated 无 DELETE（写仅经 RPC）'
);
select ok(
  not has_table_privilege('service_role', 'public.sync_sources', 'SELECT'),
  'service_role 无表级 SELECT'
);

-- ===========================================================================
-- 3. admin 新建 + 凭据加密（草稿态）（9）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.upsert_sync_source(
  null,
  'CRM 接口',
  'api',
  '{}'::jsonb,
  'sync-secret-1234',
  null
) as s1 \gset

reset role;

select is(
  (select verify_status from public.sync_sources where id = (:'s1'::jsonb ->> 'id')::uuid),
  'unverified',
  '新建后 verify_status=unverified（草稿可存）'
);
select is(
  (select last_verified_at from public.sync_sources where id = (:'s1'::jsonb ->> 'id')::uuid),
  null::timestamptz,
  '新建后 last_verified_at 为 NULL'
);
select is(
  (select created_by from public.sync_sources where id = (:'s1'::jsonb ->> 'id')::uuid),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'created_by 记录操作人 auth.uid()'
);
select is(
  (:'s1'::jsonb) ->> 'credentials_set',
  'true',
  'upsert 返回 credentials_set=true'
);
select ok(
  (select position(convert_to('sync-secret-1234', 'UTF8') in credentials) = 0
     from public.sync_sources where id = (:'s1'::jsonb ->> 'id')::uuid),
  'credentials 列不含明文（bytea 非原文）'
);
select is(
  app.decrypt_secret((select credentials from public.sync_sources where id = (:'s1'::jsonb ->> 'id')::uuid)),
  'sync-secret-1234',
  'credentials 密文可解密回原文'
);
select ok(
  (select credentials <> app.encrypt_secret('sync-secret-1234')
     from public.sync_sources where id = (:'s1'::jsonb ->> 'id')::uuid),
  '随机盐：同明文两次加密密文不同（落库非确定性密文）'
);
select is(
  (select count(*) from public.audit_operations
    where module = 'sync' and action = 'upsert' and object_type = 'sync_source'
      and object_id = (:'s1'::jsonb ->> 'id')),
  1::bigint,
  '新建写入审计摘要（sync/upsert/sync_source）'
);
select ok(
  not exists (
    select 1 from public.audit_operations
     where module = 'sync' and diff::text like '%sync-secret-1234%'
  ),
  '审计摘要不含凭据明文'
);

-- ===========================================================================
-- 4. test_sync_source：api 缺 base_url → failed；补全后 → verified（6）
-- ===========================================================================
set local role authenticated;

select public.test_sync_source((:'s1'::jsonb ->> 'id')::uuid) as r1 \gset

reset role;

select is((:'r1'::jsonb) ->> 'ok', 'false', 'api 缺 base_url 测试返回 ok=false');
select is((:'r1'::jsonb) ->> 'verify_status', 'failed', '失败结果回写 verify_status=failed');
select ok(
  (select last_verified_at is not null from public.sync_sources where id = (:'s1'::jsonb ->> 'id')::uuid),
  '失败同样记录 last_verified_at（最近一次验证尝试时间）'
);
select ok(
  (:'r1'::jsonb) ->> 'message' like '%base_url%',
  '失败原因可读（含缺失字段名 base_url）'
);

set local role authenticated;
select public.upsert_sync_source(
  (:'s1'::jsonb ->> 'id')::uuid,
  'CRM 接口',
  'api',
  '{"base_url":"https://crm.example.com","auth_type":"bearer"}'::jsonb,
  null,
  null
) as s1u \gset
select public.test_sync_source((:'s1'::jsonb ->> 'id')::uuid) as r2 \gset
reset role;

select is((:'r2'::jsonb) ->> 'verify_status', 'verified', '补全 base_url 后测试 → verified');
select is(
  (select app.decrypt_secret(credentials) from public.sync_sources where id = (:'s1'::jsonb ->> 'id')::uuid),
  'sync-secret-1234',
  '凭据传 NULL=保留原值（密文未变）'
);

-- ===========================================================================
-- 5. 验证状态机：已验证配置变更 → 降级并清空 last_verified_at；同内容不降级（6）
-- ===========================================================================
set local role authenticated;
-- 同内容 upsert：不降级
select public.upsert_sync_source(
  (:'s1'::jsonb ->> 'id')::uuid,
  'CRM 接口',
  'api',
  '{"base_url":"https://crm.example.com","auth_type":"bearer"}'::jsonb,
  null,
  null
) as s1same \gset
reset role;
select is(
  (:'s1same'::jsonb) ->> 'verify_status',
  'verified',
  '相同配置 upsert 不降级（保持 verified）'
);

set local role authenticated;
select public.upsert_sync_source(
  (:'s1'::jsonb ->> 'id')::uuid,
  'CRM 接口',
  'api',
  '{"base_url":"https://crm2.example.com","auth_type":"bearer"}'::jsonb,
  null,
  null
) as s1chg \gset
reset role;
select is(
  (:'s1chg'::jsonb) ->> 'verify_status',
  'unverified',
  '已验证配置变更 → 降级 unverified'
);
select is(
  (select last_verified_at from public.sync_sources where id = (:'s1'::jsonb ->> 'id')::uuid),
  null::timestamptz,
  '降级同时清空 last_verified_at'
);

-- 凭据变更同样降级：先重新验证，再换凭据
set local role authenticated;
select public.test_sync_source((:'s1'::jsonb ->> 'id')::uuid) as r3 \gset
select public.upsert_sync_source(
  (:'s1'::jsonb ->> 'id')::uuid,
  'CRM 接口',
  'api',
  '{"base_url":"https://crm2.example.com","auth_type":"bearer"}'::jsonb,
  'new-secret-5678',
  null
) as s1cred \gset
reset role;
select is((:'r3'::jsonb) ->> 'verify_status', 'verified', '重新测试后恢复 verified');
select is((:'s1cred'::jsonb) ->> 'verify_status', 'unverified', '凭据变更同样触发降级');
select is(
  (select app.decrypt_secret(credentials) from public.sync_sources where id = (:'s1'::jsonb ->> 'id')::uuid),
  'new-secret-5678',
  '新凭据整体替换旧凭据'
);

-- ===========================================================================
-- 6. db / excel 验证门（7）
-- ===========================================================================
set local role authenticated;
select public.upsert_sync_source(
  null,
  'ERP 库',
  'db',
  '{"engine":"postgres","host":"db.example.com"}'::jsonb,
  'db-pass-9999',
  null
) as s2 \gset
select public.test_sync_source((:'s2'::jsonb ->> 'id')::uuid) as r4 \gset
reset role;
select is((:'r4'::jsonb) ->> 'ok', 'false', 'db 缺 port/database → ok=false');
select ok(
  (:'r4'::jsonb) ->> 'message' like '%port%' and (:'r4'::jsonb) ->> 'message' like '%database%',
  'db 失败原因列出缺失字段 port/database'
);

set local role authenticated;
select public.upsert_sync_source(
  null,
  '组织导入模板',
  'excel',
  '{"template_path":"templates/org-import.xlsx"}'::jsonb,
  null,
  null
) as s3 \gset
select public.test_sync_source((:'s3'::jsonb ->> 'id')::uuid) as r5 \gset
reset role;
select is((:'r5'::jsonb) ->> 'ok', 'false', 'excel 模板对象不存在 → ok=false');
select ok(
  (:'r5'::jsonb) ->> 'message' like '%templates/org-import.xlsx%',
  'excel 失败原因带 template_path'
);

-- 夹具：模板对象写入 sync-templates bucket（本事务 rollback）
insert into storage.objects (bucket_id, name, metadata)
values ('sync-templates', 'templates/org-import.xlsx', '{"size":"1024","mimetype":"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"}'::jsonb);

set local role authenticated;
select public.test_sync_source((:'s3'::jsonb ->> 'id')::uuid) as r6 \gset
reset role;
select is((:'r6'::jsonb) ->> 'ok', 'true', 'excel 模板对象存在 → verified（免连通性测试）');
select is((:'r6'::jsonb) ->> 'verify_status', 'verified', 'excel 验证结果回写 verified');

-- db 补全后 verified
set local role authenticated;
select public.upsert_sync_source(
  (:'s2'::jsonb ->> 'id')::uuid,
  'ERP 库',
  'db',
  '{"engine":"postgres","host":"db.example.com","port":"5432","database":"erp","username":"sync"}'::jsonb,
  null,
  null
) as s2u \gset
select public.test_sync_source((:'s2'::jsonb ->> 'id')::uuid) as r7 \gset
reset role;
select is((:'r7'::jsonb) ->> 'verify_status', 'verified', 'db 补全 host/port/database 后 verified');

-- ===========================================================================
-- 7. 列表口 get_sync_sources：掩码 + config（4，admin 身份）
-- ===========================================================================
set local role authenticated;
select is(
  (select credentials_masked from public.get_sync_sources() where id = (:'s1'::jsonb ->> 'id')::uuid),
  '****5678',
  '列表返回凭据掩码（**** + 尾 4 位）'
);
select is(
  (select config ->> 'base_url' from public.get_sync_sources() where id = (:'s1'::jsonb ->> 'id')::uuid),
  'https://crm2.example.com',
  '列表返回非敏感 config 原文'
);
select is(
  (select credentials_masked from public.get_sync_sources() where id = (:'s3'::jsonb ->> 'id')::uuid),
  null::text,
  '无凭据源掩码为 NULL'
);
select ok(
  (select count(*) >= 3 from public.get_sync_sources()),
  '列表返回全部已建数据源'
);

-- ===========================================================================
-- 8. 停用守卫：被 active 任务引用拒绝（7）
-- ===========================================================================
-- 前置：s1 因凭据变更已降级，重新测试恢复 verified 后才能创建 active 任务
set local role authenticated;
select public.test_sync_source((:'s1'::jsonb ->> 'id')::uuid) as r8 \gset
reset role;
select is((:'r8'::jsonb) ->> 'verify_status', 'verified', '前置：重新测试 s1 恢复 verified');

set local role authenticated;
select public.upsert_sync_task(
  null, '组织同步', (:'s1'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"dept_name","target_field":"name"}]'::jsonb, 'skip', null
) as t1 \gset
select throws_ok(
  format($$ select public.disable_sync_source(%L::uuid) $$, (:'s1'::jsonb ->> 'id')),
  '22023', null, '被 active 任务引用：disable_sync_source 拒绝'
);
select throws_ok(
  format(
    $$ select public.upsert_sync_source(%L::uuid, 'CRM 接口', 'api',
         '{"base_url":"https://crm2.example.com","auth_type":"bearer"}'::jsonb, null, 'disabled') $$,
    (:'s1'::jsonb ->> 'id')
  ),
  '22023', null, '被 active 任务引用：upsert p_status=disabled 同样拒绝'
);
reset role;

-- 无引用源可停用 + 幂等
set local role authenticated;
select public.disable_sync_source((:'s3'::jsonb ->> 'id')::uuid) as d1 \gset
select public.disable_sync_source((:'s3'::jsonb ->> 'id')::uuid) as d2 \gset
reset role;
select is((:'d1'::jsonb) ->> 'status', 'disabled', '无引用源停用成功');
select is((:'d2'::jsonb) ->> 'status', 'disabled', '重复停用幂等');
select is(
  (select count(*) from public.audit_operations
    where module = 'sync' and action = 'disable' and object_id = (:'s3'::jsonb ->> 'id')),
  1::bigint,
  '停用审计只写一次（幂等不重复）'
);

-- disabled 任务引用不算阻断
set local role authenticated;
select public.upsert_sync_task(
  null, 'ERP 停用草稿', (:'s2'::jsonb ->> 'id')::uuid, 'positions', 'pull',
  '[{"source_field":"code","target_field":"code"}]'::jsonb, 'skip', 'disabled'
) as t2 \gset
select public.disable_sync_source((:'s2'::jsonb ->> 'id')::uuid) as d3 \gset
reset role;
select is((:'d3'::jsonb) ->> 'status', 'disabled', '被 disabled 任务引用的源可停用');

-- ===========================================================================
-- 9. 越权：engineer 读 0 行 / RPC 被拒；anon 无路径（10）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;

select is(
  (select count(*) from public.sync_sources),
  0::bigint,
  'engineer 直查 sync_sources：表级 SELECT 可见但 RLS 过滤后 0 行'
);
select throws_ok(
  $$ select public.get_sync_sources() $$,
  '42501', null, 'engineer 调列表 RPC 被 admin 校验拒绝'
);
select throws_ok(
  $$ select public.upsert_sync_source(null, 'x', 'api', '{}'::jsonb, null, null) $$,
  '42501', null, 'engineer 调 upsert 被 admin 校验拒绝'
);
select throws_ok(
  $$ select public.test_sync_source('00000000-0000-0000-0000-000000000000'::uuid) $$,
  '42501', null, 'engineer 调 test 被 admin 校验拒绝'
);
select throws_ok(
  $$ select public.disable_sync_source('00000000-0000-0000-0000-000000000000'::uuid) $$,
  '42501', null, 'engineer 调 disable 被 admin 校验拒绝'
);
select throws_ok(
  $$ insert into public.sync_sources (name, type) values ('x', 'api') $$,
  '42501', null, 'engineer 直写被拒（无 INSERT 权限）'
);

reset role;
set local role anon;

select throws_ok(
  $$ select * from public.sync_sources $$,
  '42501', null, 'anon 直查被拒（无表级权限）'
);
select throws_ok(
  $$ select public.get_sync_sources() $$,
  '42501', null, 'anon 调列表 RPC 被拒（无 GRANT）'
);
select throws_ok(
  $$ select public.upsert_sync_source(null, 'x', 'api', '{}'::jsonb, null, null) $$,
  '42501', null, 'anon 调 upsert 被拒（无 GRANT）'
);
select throws_ok(
  $$ select public.disable_sync_source('00000000-0000-0000-0000-000000000000'::uuid) $$,
  '42501', null, 'anon 调 disable 被拒（无 GRANT）'
);

reset role;

-- ===========================================================================
-- 10. 参数校验（4，admin 身份）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$ select public.upsert_sync_source(null, '  ', 'api', '{}'::jsonb, null, null) $$,
  '22023', null, '名称为空报 22023'
);
select throws_ok(
  $$ select public.upsert_sync_source(null, 'x', 'ftp', '{}'::jsonb, null, null) $$,
  '22023', null, '类型不在 api/db/excel 报 22023'
);
select throws_ok(
  $$ select public.upsert_sync_source(null, 'x', 'api', '[]'::jsonb, null, null) $$,
  '22023', null, 'config 非对象报 22023'
);
select throws_ok(
  $$ select public.test_sync_source('00000000-0000-0000-0000-000000000000'::uuid) $$,
  'P0002', null, '测试不存在的数据源报 P0002'
);

reset role;

select * from finish();
rollback;
