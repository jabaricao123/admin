-- pgTAP：integration/009 —— api_docs（OpenAPI 发布快照 + 版本唯一 + 登录可见）
-- 运行：supabase db reset && supabase test db
-- 覆盖：表结构/唯一约束/结构校验/RLS/授权；seed v1（openapi/info/paths/事件清单/验签示例）；
--       publish_api_doc（admin 校验、版本格式、OpenAPI 结构、重复版本拒绝、审计）；
--       登录用户可见、匿名不可见。
-- 说明：engineer 为 seeds 内部账号（非 admin）；夹具只在本事务内生效，finish 后 rollback。
begin;

select plan(39);

-- ===========================================================================
-- 1. 结构：表 / 列 / 约束 / 索引 / RLS（12）
-- ===========================================================================
select has_table('public', 'api_docs', 'api_docs 表存在');
select col_is_pk('public', 'api_docs', 'id', 'id 为主键');
select col_type_is('public', 'api_docs', 'version', 'text', 'version 为 text');
select col_type_is('public', 'api_docs', 'spec', 'jsonb', 'spec 为 jsonb');
select col_type_is('public', 'api_docs', 'changelog', 'text', 'changelog 为 text');
select col_type_is('public', 'api_docs', 'published_by', 'uuid', 'published_by 为 uuid');
select is(
  (select a.atttypid::regtype::text
     from pg_attribute a
    where a.attrelid = 'public.api_docs'::regclass and a.attname = 'created_at'),
  'timestamp with time zone',
  'created_at 为 timestamptz'
);
select ok(
  exists (
    select 1 from pg_constraint c
     where c.conrelid = 'public.api_docs'::regclass
       and c.contype = 'u'
       and pg_get_constraintdef(c.oid) like '%(version)%'
  ),
  'version 唯一约束存在'
);
select ok(
  exists (
    select 1 from pg_constraint c
     where c.conrelid = 'public.api_docs'::regclass
       and c.contype = 'c'
       and pg_get_constraintdef(c.oid) like '%v[0-9]%'
  ),
  'version 格式 check（vN / vN.M）存在'
);
select ok(
  exists (
    select 1 from pg_constraint c
     where c.conrelid = 'public.api_docs'::regclass
       and c.contype = 'c'
       and pg_get_constraintdef(c.oid) like '%openapi%'
       and pg_get_constraintdef(c.oid) like '%paths%'
  ),
  'spec OpenAPI 结构 check（openapi/info/paths）存在'
);
select is(
  (select relrowsecurity from pg_class where oid = 'public.api_docs'::regclass),
  true,
  'api_docs 已启用 RLS'
);
select has_index('public', 'api_docs', 'api_docs_created_idx', '版本列表索引存在');

-- ===========================================================================
-- 2. 函数与安全属性（4）
-- ===========================================================================
select has_function('app', 'publish_api_doc', array['text', 'jsonb', 'text'],
  'app.publish_api_doc(text,jsonb,text) 存在');
select has_function('public', 'publish_api_doc', array['text', 'jsonb', 'text'],
  'public.publish_api_doc 薄包装存在');
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'publish_api_doc'),
  'app.publish_api_doc 为 SECURITY DEFINER + search_path 空'
);
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'publish_api_doc'),
  'public.publish_api_doc 为 SECURITY DEFINER + search_path 空'
);

-- ===========================================================================
-- 3. 授权面（5）
-- ===========================================================================
select ok(
  has_function_privilege('authenticated', 'public.publish_api_doc(text,jsonb,text)', 'EXECUTE'),
  'authenticated 可执行发布 RPC（函数内 admin 校验）'
);
select ok(
  not has_function_privilege('authenticated', 'app.publish_api_doc(text,jsonb,text)', 'EXECUTE'),
  'authenticated 无 app 实现执行权（规则 10）'
);
select ok(
  not has_function_privilege('anon', 'public.publish_api_doc(text,jsonb,text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.publish_api_doc(text,jsonb,text)', 'EXECUTE'),
  'anon/service_role 无发布执行权'
);
select ok(
  has_table_privilege('authenticated', 'public.api_docs', 'SELECT')
  and not has_table_privilege('authenticated', 'public.api_docs', 'INSERT')
  and not has_table_privilege('authenticated', 'public.api_docs', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.api_docs', 'DELETE'),
  'authenticated 只读（无表级写）'
);
select ok(
  not has_table_privilege('anon', 'public.api_docs', 'SELECT'),
  'anon 无文档 SELECT'
);

-- ===========================================================================
-- 4. seed v1：现有开放面 + 事件清单 + 验签示例（6）
-- ===========================================================================
select is(
  (select count(*) from public.api_docs where version = 'v1'),
  1::bigint,
  'seed：v1 已发布'
);
select ok(
  (select (spec ->> 'openapi') ~ '^3\.' from public.api_docs where version = 'v1'),
  'v1 规格为 OpenAPI 3'
);
select ok(
  (select jsonb_typeof(spec -> 'info') = 'object' and jsonb_typeof(spec -> 'paths') = 'object'
     from public.api_docs where version = 'v1'),
  'v1 含 info / paths 对象'
);
select ok(
  (select (spec -> 'paths') ? '/rpc/issue_api_token'
       and (spec -> 'paths') ? '/rpc/api_departments'
     from public.api_docs where version = 'v1'),
  'v1 覆盖现有开放面（issue_api_token / api_departments）'
);
select is(
  (select count(*) from public.api_docs d,
                        jsonb_array_elements(d.spec -> 'x-webhook-events')
    where d.version = 'v1'),
  6::bigint,
  'v1 事件清单 6 条（approval 3 + org 1 + sync 1 + ping 1）'
);
select ok(
  (select jsonb_array_length(spec -> 'x-webhook-signature' -> 'examples') = 2
       and exists (
         select 1
         from jsonb_array_elements(spec -> 'x-webhook-signature' -> 'examples') e
         where e ->> 'language' = 'node' and e ->> 'code' like '%createHmac%'
       )
       and exists (
         select 1
         from jsonb_array_elements(spec -> 'x-webhook-signature' -> 'examples') e
         where e ->> 'language' = 'python' and e ->> 'code' like '%compare_digest%'
       )
     from public.api_docs where version = 'v1'),
  'v1 验签示例含 Node/Python 可复制代码'
);

-- ===========================================================================
-- 5. 发布行为：越权/校验/成功/重复（9）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.publish_api_doc('v9', '{"openapi":"3.1.0","info":{},"paths":{}}'::jsonb, null) $$,
  '42501', null, '非 admin 发布被拒（42501）'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.publish_api_doc('x1', '{"openapi":"3.1.0","info":{},"paths":{}}'::jsonb, null) $$,
  '22023', null, '版本号格式非法拒绝'
);
select throws_ok(
  $$ select public.publish_api_doc('v1.1', '{"openapi":"3.1.0","info":{}}'::jsonb, null) $$,
  '22023', null, '缺少 paths 拒绝'
);
select throws_ok(
  $$ select public.publish_api_doc('v1.1', '{"info":{},"paths":{}}'::jsonb, null) $$,
  '22023', null, '缺少 openapi 版本字段拒绝'
);
select public.publish_api_doc(
  'v1.1',
  '{"openapi":"3.1.0","info":{"title":"企业管理系统 · 开放 API","version":"v1.1"},"paths":{"/rpc/api_departments":{"post":{}}}}'::jsonb,
  '测试版本：补充部门 RPC'
) as newdoc \gset
reset role;

select isnt(:'newdoc', null::uuid, 'publish 返回快照 id');
select ok(
  (select changelog = '测试版本：补充部门 RPC'
       and published_by = '11111111-1111-1111-1111-111111111111'::uuid
     from public.api_docs where version = 'v1.1'),
  'v1.1 落库 changelog 与发布人'
);
select ok(
  exists (
    select 1 from public.audit_operations
     where module = 'integration' and action = 'publish'
       and object_type = 'api_doc' and object_id = 'v1.1'
  ),
  '发布写审计摘要（publish/api_doc）'
);
select throws_ok(
  $$ select app.publish_api_doc('v1.1', '{"openapi":"3.1.0","info":{},"paths":{}}'::jsonb, null) $$,
  'P0001', null, '重复版本被拒（快照不可变）'
);

-- ===========================================================================
-- 6. 可见性：登录可见 / 匿名拒绝（4）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select count(*) from public.api_docs),
  2::bigint,
  'RLS：登录用户（非 admin）可见全部版本'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select ok(
  (select count(*) >= 2 and bool_and(spec ? 'paths') from public.api_docs),
  'RLS：admin 可见全部版本且规格可读'
);
reset role;

set local role anon;
select throws_ok(
  $$ select count(*) from public.api_docs $$,
  '42501', null, 'anon 直读文档被拒（未登录不可访问）'
);
reset role;

select ok(
  (select count(*) = 1 from public.api_docs where version = 'v1.1'),
  '版本切换数据源：v1.1 快照唯一'
);

select * from finish();
rollback;
