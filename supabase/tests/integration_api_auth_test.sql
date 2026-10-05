-- pgTAP：integration/002 —— api_client_role + API key 换短期 JWT + token 守卫 + 资源演示 RPC
-- 运行：supabase db reset && supabase test db
-- 覆盖：角色属性/成员资格/白名单授权/RLS 策略；函数存在性 + SECURITY 属性 + search_path=''；
--       GRANT 面（anon 可 issue/调资源、authenticated/service_role 无签发票，规则 10 例外声明）；
--       合法 key 签发 token（类型/有效期/claims role/key_id/scopes/exp）；篡改/过期/错误 role/
--       缺 exp/损坏 token 拒绝；api_departments 端到端（jsonb 状态包：ok:true/data、401/403 错误包、
--       失败留痕 integration_call_logs + audit denied、角色还原）；anon 无权直查资源；api_client_role 只读。
-- 说明：批次 2 起资源 RPC 守卫失败不再 raise，返回 {ok:false,status,error} 并同事务写调用日志；
--       夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(92);

-- ===========================================================================
-- 1. 角色属性 / 成员资格 / 白名单授权 / RLS 策略（19）
-- ===========================================================================
select has_role('api_client_role', 'api_client_role 角色存在');
select ok(
  (select not rolcanlogin from pg_catalog.pg_roles where rolname = 'api_client_role'),
  'api_client_role 为 nologin'
);
select ok(
  (select not rolsuper from pg_catalog.pg_roles where rolname = 'api_client_role'),
  'api_client_role 非 superuser'
);
select ok(
  (select not rolbypassrls from pg_catalog.pg_roles where rolname = 'api_client_role'),
  'api_client_role 非 bypassrls（不绕过 RLS）'
);
select ok(
  pg_has_role('authenticator', 'api_client_role', 'MEMBER'),
  'authenticator 是 api_client_role 成员（PostgREST SET ROLE 前提）'
);
select ok(
  has_schema_privilege('api_client_role', 'public', 'USAGE'),
  'api_client_role 有 public schema USAGE'
);
select ok(
  has_table_privilege('api_client_role', 'public.departments_v', 'SELECT'),
  'api_client_role 有 departments_v SELECT（白名单）'
);
select ok(
  has_table_privilege('api_client_role', 'public.positions', 'SELECT'),
  'api_client_role 有 positions SELECT（白名单）'
);
select ok(
  has_table_privilege('api_client_role', 'public.departments', 'SELECT'),
  'api_client_role 有 departments 底层表 SELECT（security_invoker 视图需要）'
);
select ok(
  not has_table_privilege('api_client_role', 'public.departments', 'INSERT')
  and not has_table_privilege('api_client_role', 'public.departments', 'UPDATE')
  and not has_table_privilege('api_client_role', 'public.departments', 'DELETE'),
  'api_client_role 对 departments 无写权限'
);
select ok(
  not has_table_privilege('api_client_role', 'public.api_keys', 'SELECT'),
  'api_client_role 读不到 api_keys'
);
select ok(
  not has_table_privilege('api_client_role', 'public.webhooks', 'SELECT'),
  'api_client_role 读不到 webhooks'
);
select ok(
  not has_table_privilege('api_client_role', 'public.webhook_deliveries', 'SELECT'),
  'api_client_role 读不到 webhook_deliveries'
);
select ok(
  not has_schema_privilege('api_client_role', 'app', 'USAGE'),
  'api_client_role 无 app schema USAGE（不能调内部函数）'
);
select is(
  (select roles from pg_policies
    where schemaname = 'public' and tablename = 'departments'
      and policyname = 'departments_select_api_client'),
  array['api_client_role']::name[],
  'departments 有 api_client_role 只读策略'
);
select ok(
  (select qual from pg_policies
    where schemaname = 'public' and tablename = 'departments'
      and policyname = 'departments_select_api_client') like '%deleted%',
  'departments 策略排除 deleted'
);
select is(
  (select roles from pg_policies
    where schemaname = 'public' and tablename = 'positions'
      and policyname = 'positions_select_api_client'),
  array['api_client_role']::name[],
  'positions 有 api_client_role 只读策略'
);
select has_extension('extensions', 'pgjwt', 'pgjwt 扩展已安装（extensions schema）');
select ok(
  has_schema_privilege('anon', 'app', 'USAGE'),
  'anon 有 app schema USAGE（匿名网关入口的前提）'
);

-- ===========================================================================
-- 2. 函数存在性 + SECURITY 属性 + search_path（9）
-- ===========================================================================
select has_function('app', 'issue_api_token', array['text'], 'app.issue_api_token(text) 存在');
select has_function('app', 'verify_api_token', array['text'], 'app.verify_api_token(text) 存在');
select has_function('app', 'api_departments', array['text'], 'app.api_departments(text) 存在');
select has_function('public', 'issue_api_token', array['text'], 'public.issue_api_token 薄包装存在');
select has_function('public', 'api_departments', array['text'], 'public.api_departments 薄包装存在');
select hasnt_function('public', 'verify_api_token', array['text'],
  'public.verify_api_token 不存在（守卫仅内部用，不经 Data API 暴露）');
select ok(
  (select count(*) = 2
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (('app', 'issue_api_token'), ('app', 'verify_api_token'))
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  'issue/verify 均 security definer + search_path 固定为空'
);
select ok(
  (select not p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'api_departments'),
  'api_departments 为 SECURITY INVOKER + search_path 固定为空（PG17 禁 definer 内 SET ROLE）'
);
select ok(
  (select p.proconfig @> array['search_path=""']
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'api_departments'),
  'public.api_departments 为 invoker 链 + search_path 固定为空'
);

-- ===========================================================================
-- 3. GRANT 面：anon 可签可调，authenticated/service_role 无签发票（9）
-- ===========================================================================
select ok(
  has_function_privilege('anon', 'app.issue_api_token(text)', 'EXECUTE'),
  'anon 可执行 app.issue_api_token（API 网关匿名入口）'
);
select ok(
  has_function_privilege('anon', 'public.issue_api_token(text)', 'EXECUTE'),
  'anon 可执行 public.issue_api_token'
);
select ok(
  has_function_privilege('anon', 'app.verify_api_token(text)', 'EXECUTE'),
  'anon 可执行 app.verify_api_token（守卫 RPC 以调用者身份验 token）'
);
select ok(
  has_function_privilege('anon', 'app.api_departments(text)', 'EXECUTE'),
  'anon 可执行 app.api_departments'
);
select ok(
  has_function_privilege('anon', 'public.api_departments(text)', 'EXECUTE'),
  'anon 可执行 public.api_departments'
);
select ok(
  not has_function_privilege('authenticated', 'app.issue_api_token(text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.issue_api_token(text)', 'EXECUTE'),
  'authenticated 无签发票（不 GRANT authenticated）'
);
select ok(
  not has_function_privilege('service_role', 'app.issue_api_token(text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'app.verify_api_token(text)', 'EXECUTE'),
  'service_role 无签发/验签执行权（ADR-001 禁 service_role）'
);
select ok(
  not has_function_privilege('anon', 'app.create_api_key(text,jsonb,timestamptz)', 'EXECUTE'),
  'anon 仍无管理票（create_api_key 只有 authenticated）'
);
select ok(
  has_table_privilege('authenticated', 'public.api_keys', 'SELECT')
  and not has_table_privilege('anon', 'public.api_keys', 'SELECT'),
  'api_keys 仍是 authenticated 可读、anon 不可读'
);

-- ===========================================================================
-- 4. 签发：admin 创建 key → anon 换 token（13，夹具）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.create_api_key(
  '开放 API 认证', '["org:read"]'::jsonb, now() + interval '30 days'
) as ak1 \gset

select public.create_api_key('无范围密钥', '[]'::jsonb, null) as ak2 \gset

reset role;

set local role anon;

select app.issue_api_token((:'ak1'::jsonb) ->> 'key') as t1 \gset
select public.issue_api_token((:'ak2'::jsonb) ->> 'key') as t2 \gset

select throws_ok(
  $$ select app.issue_api_token('ak_00000000000000000000000000000000') $$,
  '42501', null, '未知 key 签发被拒（42501）'
);
select throws_ok(
  $$ select app.issue_api_token('') $$,
  '22023', null, '空 key 报 22023'
);
select throws_ok(
  $$ select app.issue_api_token(null) $$,
  '22023', null, 'NULL key 报 22023'
);

reset role;

select is((:'t1'::jsonb) ->> 'token_type', 'Bearer', '签发返回 token_type=Bearer');
select is((:'t1'::jsonb) ->> 'expires_in', '3600', '签发返回 expires_in=3600');
select is((:'t1'::jsonb) ->> 'key_id', (:'ak1'::jsonb) ->> 'id', '签发返回 key_id');
select is((:'t1'::jsonb) -> 'scopes', '["org:read"]'::jsonb, '签发返回 scopes');
select ok(
  (:'t1'::jsonb) ->> 'token' ~ '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$',
  'token 为标准三段式 JWT'
);
select is(
  split_part((:'t1'::jsonb) ->> 'token', '.', 1),
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9',
  'JWT header = HS256/JWT'
);
select ok(
  (select last_used_at is not null from public.api_keys
    where id = (:'ak1'::jsonb ->> 'id')::uuid),
  '签发复用 verify_api_key 并更新 last_used_at'
);
select is(
  (:'t2'::jsonb) -> 'scopes', '[]'::jsonb,
  '无范围 key 也能签发（scopes 空数组进 claims）'
);
select ok(
  (:'t1'::jsonb) ->> 'token' <> (:'t2'::jsonb) ->> 'token',
  '不同 key 签发 token 不同'
);
select is((:'t1'::jsonb) ->> 'expires_at' is not null, true, '签发返回 expires_at');

-- ===========================================================================
-- 5. verify：claims 解析 + 各类非法 token 拒绝（13）
-- ===========================================================================
select is(
  app.verify_api_token((:'t1'::jsonb) ->> 'token') ->> 'role',
  'api_client_role',
  'verify 返回 role=api_client_role'
);
select is(
  app.verify_api_token((:'t1'::jsonb) ->> 'token') ->> 'key_id',
  (:'ak1'::jsonb) ->> 'id',
  'verify 返回 claims.key_id'
);
select is(
  app.verify_api_token((:'t1'::jsonb) ->> 'token') -> 'scopes',
  '["org:read"]'::jsonb,
  'verify 返回 claims.scopes'
);
select ok(
  (app.verify_api_token((:'t1'::jsonb) ->> 'token') ->> 'exp')::bigint
    - extract(epoch from now())::bigint between 3500 and 3600,
  'claims.exp 约为 1 小时后（3500~3600 秒）'
);
select is(
  app.verify_api_token((:'t1'::jsonb) ->> 'token') ->> 'iss',
  'admin-api',
  'verify 返回 iss=admin-api'
);
select is(app.verify_api_token((:'t1'::jsonb) ->> 'token' || 'x'), null::jsonb,
  '篡改签名返回 NULL');
select is(app.verify_api_token('abc'), null::jsonb, '非 JWT 结构返回 NULL');
select is(app.verify_api_token('a.b.c'), null::jsonb, '错误 base64/结构返回 NULL');
select is(app.verify_api_token(null), null::jsonb, 'NULL token 返回 NULL');
select is(app.verify_api_token(''), null::jsonb, '空 token 返回 NULL');

-- 真密钥直签非法形态（签名有效但语义非法）：
select extensions.sign(
  json_build_object(
    'role', 'api_client_role',
    'scopes', '["org:read"]'::jsonb,
    'exp', floor(extract(epoch from now() - interval '1 hour'))::bigint
  ),
  (select key from app.encryption_key where key_id = 1)
) as t_expired \gset

select is(app.verify_api_token(:'t_expired'), null::jsonb, '过期 token 拒绝');

select extensions.sign(
  json_build_object(
    'role', 'authenticated',
    'scopes', '["org:read"]'::jsonb,
    'exp', floor(extract(epoch from now() + interval '1 hour'))::bigint
  ),
  (select key from app.encryption_key where key_id = 1)
) as t_wrongrole \gset

select is(app.verify_api_token(:'t_wrongrole'), null::jsonb, 'role 不符（非 api_client_role）拒绝');

select extensions.sign(
  json_build_object('role', 'api_client_role', 'scopes', '[]'::jsonb),
  (select key from app.encryption_key where key_id = 1)
) as t_noexp \gset

select is(app.verify_api_token(:'t_noexp'), null::jsonb, '缺 exp 的 token 拒绝');

-- ===========================================================================
-- 6. api_departments：端到端 jsonb 状态包 + 失败留痕（16）
-- ===========================================================================
insert into public.departments (id, name, status, sort_order)
values ('33333333-3333-3333-3333-3333333300ff', '已删除测试部', 'deleted', 99);

select app.api_departments((:'t1'::jsonb) ->> 'token') as d1 \gset
select ok(
  (:'d1'::jsonb ->> 'ok')::boolean
    and jsonb_array_length(:'d1'::jsonb -> 'data') >= 6,
  'org:read token 返回 {ok:true,data}（≥ 种子 6 个部门）'
);
select ok(
  not exists (
    select 1
    from jsonb_array_elements(:'d1'::jsonb -> 'data') dv
    where dv ->> 'id' = '33333333-3333-3333-3333-3333333300ff'
  ),
  'deleted 部门不在 API 结果中'
);

select app.api_departments((:'t2'::jsonb) ->> 'token') as d2 \gset
select is((:'d2'::jsonb ->> 'ok')::boolean, false, 'scopes 不含 org:read 返回 ok=false（不再 raise）');
select is((:'d2'::jsonb ->> 'status')::integer, 403, '缺 scope：状态包 status=403');
select is(
  :'d2'::jsonb ->> 'error',
  'API token 缺少所需范围：org:read',
  '缺 scope：error 说明所需范围'
);

select app.api_departments('garbage') as d3 \gset
select is((:'d3'::jsonb ->> 'status')::integer, 401, '无效 token：状态包 status=401');

select app.api_departments(null) as d4 \gset
select is((:'d4'::jsonb ->> 'status')::integer, 401, 'NULL token：状态包 status=401');

select ok(
  exists (
    select 1
    from public.integration_call_logs
    where kind = 'api' and method_event = 'api_departments'
      and status_code = 403
      and key_id = (:'ak2'::jsonb ->> 'id')::uuid
      and error like '%缺少所需范围%'
  ),
  '缺 scope 失败调用留痕（kind=api/status=403/关联 key_id）'
);
select ok(
  exists (
    select 1
    from public.integration_call_logs
    where kind = 'api' and method_event = 'api_departments'
      and status_code = 401
      and error like '%无效%'
  ),
  '无效 token 失败调用留痕（kind=api/status=401）'
);
select ok(
  exists (
    select 1
    from public.audit_operations
    where module = 'integration' and action = 'denied'
      and object_type = 'api_request' and object_id = 'api_departments'
  ),
  '失败调用写审计摘要（integration/denied/api_request）'
);
select is(
  public.record_api_failure((:'t1'::jsonb ->> 'token'), 'api_custom', '自定义拒绝'),
  true,
  '公开入口 record_api_failure 直接调用返回 true（已留痕）'
);
select ok(
  exists (
    select 1
    from public.integration_call_logs
    where kind = 'api' and method_event = 'api_custom'
      and status_code = 403
      and key_id = (:'ak1'::jsonb ->> 'id')::uuid
      and error = '自定义拒绝'
  ),
  '直接调用写 403 明细（方法名/错误原因/关联 key_id）'
);
select ok(
  not exists (
    select 1
    from public.audit_operations
    where action = 'denied' and object_id = 'api_custom'
      and diff::text like '%' || (:'t1'::jsonb ->> 'token') || '%'
  ),
  '审计摘要不落 token 明文（仅 key_prefix）'
);
select ok(
  has_function_privilege('anon', 'public.record_api_failure(text,text,text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.record_api_failure(text,text,text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.record_api_failure(text,text,text)', 'EXECUTE'),
  'record_api_failure 仅 GRANT anon（网关入口）'
);

-- anon 持 token 走 Data API 薄包装；调用后角色还原
set local role anon;

select public.api_departments((:'t1'::jsonb) ->> 'token') as anon_dept_pack \gset
select current_setting('role') as anon_role_after \gset

select throws_ok(
  $$ select * from public.departments_v $$,
  '42501', null, 'anon 无 token 直查 departments_v 被拒'
);
select throws_ok(
  $$ select * from public.positions $$,
  '42501', null, 'anon 直查 positions 被拒'
);
select throws_ok(
  $$ select * from public.webhooks $$,
  '42501', null, 'anon 直查 webhooks 被拒'
);
select throws_ok(
  $$ select * from public.api_keys $$,
  '42501', null, 'anon 直查 api_keys 被拒'
);

reset role;

select ok(
  (:'anon_dept_pack'::jsonb ->> 'ok')::boolean
    and jsonb_array_length(:'anon_dept_pack'::jsonb -> 'data') >= 6,
  'anon 持有效 token 经薄包装读取 {ok:true,data}'
);
select is(:'anon_role_after'::text, 'anon', '资源 RPC 返回后角色还原为 anon（不影响同事务后续语句）');

-- ===========================================================================
-- 7. api_client_role 直接数据面：只读白名单（6）
-- ===========================================================================
set local role api_client_role;

select count(*) as ac_direct from public.departments \gset
select count(*) as ac_view from public.departments_v \gset
select count(*) as ac_deleted from public.departments
where id = '33333333-3333-3333-3333-3333333300ff'::uuid \gset

reset role;

select is(:'ac_direct'::int, 6, 'api_client_role 直读 departments 仅 6 个未删除种子部门');
select is(:'ac_view'::int, 6, 'api_client_role 经 departments_v 读同样 6 行');
select is(:'ac_deleted'::int, 0, 'api_client_role 对 deleted 部门不可见（RLS 策略生效）');
select ok(
  has_table_privilege('api_client_role', 'public.positions', 'SELECT')
  and not has_table_privilege('api_client_role', 'public.positions', 'INSERT')
  and not has_table_privilege('api_client_role', 'public.positions', 'UPDATE'),
  'positions 对 api_client_role 只读'
);
select ok(
  not has_table_privilege('api_client_role', 'public.integration_events', 'SELECT')
  and not has_table_privilege('api_client_role', 'public.integration_events', 'INSERT'),
  'api_client_role 不可见/不可写 integration_events'
);
select ok(
  not has_table_privilege('api_client_role', 'public.profiles', 'SELECT'),
  'api_client_role 不可见 profiles（白名单最小面）'
);

-- ===========================================================================
-- 8. 吊销即时失效：吊销后换 token 被拒（2）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select public.revoke_api_key((:'ak2'::jsonb ->> 'id')::uuid) as revoked \gset
reset role;

select is((:'revoked'::jsonb) ->> 'status', 'revoked', '吊销返回 status=revoked');
select throws_ok(
  format('select app.issue_api_token(%L)', (:'ak2'::jsonb) ->> 'key'),
  '42501', null, '吊销后凭原 key 换 token 被拒（即时失效）'
);

-- ===========================================================================
-- 9. 过期 key：签发票被拒（1）
-- ===========================================================================
insert into public.api_keys (name, key_prefix, key_hash, scopes, status, expires_at)
values (
  '过期密钥', 'ak_deadbeef',
  encode(extensions.digest('ak_expired_api_auth', 'sha256'), 'hex'),
  '["org:read"]'::jsonb, 'active', now() - interval '1 day'
);

select throws_ok(
  $$ select app.issue_api_token('ak_expired_api_auth') $$,
  '42501', null, '过期 key 换 token 被拒'
);

select * from finish();
rollback;
