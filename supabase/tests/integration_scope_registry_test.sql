-- pgTAP：integration 批次 2 —— scope 白名单注册表 + require_scope 守卫 helper
-- 运行：supabase db reset && supabase test db
-- 覆盖：api_scope_registry 结构/seed/RLS/授权；create_api_key 白名单校验（表外 scope 拒绝、
--       表内 scope 签发成功）；app.require_scope 判定（含/不含/缺 scopes/非数组/NULL 入参）；
--       helper 授权面（anon 可执行、authenticated 不可）。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(23);

-- ===========================================================================
-- 1. 结构 / seed / RLS（7）
-- ===========================================================================
select has_table('public', 'api_scope_registry', 'api_scope_registry 表存在');
select col_is_pk('public', 'api_scope_registry', 'scope', 'scope 为主键');
select col_type_is('public', 'api_scope_registry', 'resource', 'text', 'resource 为 text');
select col_type_is('public', 'api_scope_registry', 'description', 'text', 'description 为 text');
select is(
  (select count(*) from public.api_scope_registry),
  4::bigint,
  'seed 4 条只读 scope（org/report/audit/integration）'
);
select ok(
  (select count(*) = 4
     from public.api_scope_registry
    where scope in ('org:read', 'report:read', 'audit:read', 'integration:read')),
  'seed scope 与模块只读清单一致'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.api_scope_registry'::regclass)
  and exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'api_scope_registry'
       and policyname = 'api_scope_registry_select_admin'
  ),
  'RLS 已启用且有 admin 只读策略'
);

-- ===========================================================================
-- 2. 函数属性 / 授权（5）
-- ===========================================================================
select has_function('app', 'require_scope', array['jsonb', 'text'],
  'app.require_scope(jsonb,text) 存在');
select ok(
  (select p.provolatile = 'i' and not p.prosecdef
          and p.proconfig @> array['search_path=""']
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'require_scope'),
  'require_scope 为 immutable + SECURITY INVOKER + search_path 空'
);
select ok(
  has_function_privilege('anon', 'app.require_scope(jsonb,text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.require_scope(jsonb,text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'app.require_scope(jsonb,text)', 'EXECUTE'),
  'require_scope 仅 GRANT anon（资源 RPC invoker 链；规则 10 最小例外）'
);
select ok(
  has_table_privilege('authenticated', 'public.api_scope_registry', 'SELECT')
  and not has_table_privilege('authenticated', 'public.api_scope_registry', 'INSERT')
  and not has_table_privilege('authenticated', 'public.api_scope_registry', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.api_scope_registry', 'DELETE'),
  'authenticated 只读注册表（无表级写）'
);
select ok(
  not has_table_privilege('anon', 'public.api_scope_registry', 'SELECT'),
  'anon 无注册表 SELECT'
);

-- ===========================================================================
-- 3. create_api_key：白名单校验（4，admin 身份）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$ select public.create_api_key('越白范围', '["org:read","billing:read"]'::jsonb, null) $$,
  '22023', null, '白名单外 scope 建 key 被拒（22023）'
);
select throws_ok(
  $$ select public.create_api_key('全未知范围', '["nope:read","nope:write"]'::jsonb, null) $$,
  '22023', null, '全部未知 scope 建 key 被拒（22023）'
);

select public.create_api_key('白名单范围', '["org:read","audit:read"]'::jsonb, null) as sk \gset
reset role;

select is(
  (select scopes from public.api_keys where id = (:'sk'::jsonb ->> 'id')::uuid),
  '["org:read","audit:read"]'::jsonb,
  '表内 scope 组合签发成功并原样落库'
);

-- ===========================================================================
-- 4. require_scope 判定（8）
-- ===========================================================================
select ok(
  app.require_scope('{"scopes":["org:read"]}'::jsonb, 'org:read'),
  'claims.scopes 含目标 scope → true'
);
select ok(
  app.require_scope('{"scopes":["x","org:read","y"]}'::jsonb, 'org:read'),
  '多 scope 数组中命中 → true'
);
select ok(
  not app.require_scope('{"scopes":["report:read"]}'::jsonb, 'org:read'),
  '不含目标 scope → false'
);
select ok(
  not app.require_scope('{"scopes":[]}'::jsonb, 'org:read'),
  '空 scopes 数组 → false'
);
select ok(
  not app.require_scope('{}'::jsonb, 'org:read'),
  '缺 scopes 键 → false'
);
select ok(
  not app.require_scope('{"scopes":"org:read"}'::jsonb, 'org:read'),
  'scopes 非数组 → false'
);
select ok(
  not app.require_scope(null, 'org:read'),
  'claims 为 NULL → false'
);
select ok(
  not app.require_scope('{"scopes":["org:read"]}'::jsonb, '')
  and not app.require_scope('{"scopes":["org:read"]}'::jsonb, null),
  'p_scope 为空/NULL → false'
);

select * from finish();
rollback;
