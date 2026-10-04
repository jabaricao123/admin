-- pgTAP：audit 批次 1 修复 ——
--   修复项 1：public.record_denied_attempt（denied 留痕生产者：白名单/截断/限流/GRANT）
--             + audit_denied_v 可见性（admin 可见、engineer 零行）
--   修复项 2：access seed 补授 /audit + /audit/logins（内部 4 角色；supplier/customer 不授；
--             operations/changes/compliance 仍 admin 专属）
--   修复项 3：list_recent_versions 返回 change_type（insert/update/delete，与 get_row_versions 对齐）
-- 运行：supabase db reset && supabase test db
-- 说明：夹具仅在本事务内生效，finish 后 rollback，不污染其他测试文件；
--       非 admin 账号用 seeds 的 engineer（2222...0001）/ planner（2222...0002）。

begin;

select plan(33);

-- ===========================================================================
-- 1. record_denied_attempt：结构 / 授权 / 入参校验（8）
-- ===========================================================================
select has_function(
  'public', 'record_denied_attempt', array['text', 'text', 'text'],
  'public.record_denied_attempt(text,text,text) 存在'
);
select ok(
  (select count(*) = 1
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'record_denied_attempt'
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  'record_denied_attempt：security definer + search_path 固定为空'
);
select ok(
  has_function_privilege(
    'authenticated',
    'public.record_denied_attempt(text,text,text)',
    'EXECUTE'
  ),
  'authenticated 可执行 record_denied_attempt'
);
select ok(
  not has_function_privilege(
    'anon',
    'public.record_denied_attempt(text,text,text)',
    'EXECUTE'
  ),
  'anon 无 record_denied_attempt 执行权'
);

set local role anon;
select throws_ok(
  $$ select public.record_denied_attempt('org', '/org/users', 'x') $$,
  '42501', null,
  'anon 调用被拒（无 GRANT）'
);
reset role;

select set_config('request.jwt.claims', '{}', true);
set local role authenticated;
select throws_ok(
  $$ select public.record_denied_attempt('org', '/org/users', 'x') $$,
  '42501', '未登录不可记录越权尝试',
  'authenticated 但无会话身份（auth.uid() 为空）被拒'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
select throws_ok(
  $$ select public.record_denied_attempt('billing', '/billing', 'x') $$,
  '22023', '未知模块：billing',
  '白名单外 module 被拒'
);
select throws_ok(
  $$ select public.record_denied_attempt('org', '   ', 'x') $$,
  '22023', '路由不能为空',
  '空 route 被拒'
);

-- ===========================================================================
-- 2. record_denied_attempt：写入 / 视图 / auth 标识 / 截断（9）
-- ===========================================================================
select set_config(
  'request.headers',
  json_build_object(
    'x-forwarded-for', '203.0.113.9',
    'user-agent', 'pgTAP-denied'
  )::text,
  true
);

set local role authenticated;
select public.record_denied_attempt('org', '/org/users', 'admin_only') as d1 \gset
reset role;

select ok(
  :d1::bigint is not null,
  'engineer 越权打点成功并返回记录 id'
);
select results_eq(
  $$ select actor_id, module, action, object_type, object_id, diff ->> 'reason'
       from public.audit_operations
      where actor_id = '22222222-2222-2222-2222-222222220001'
        and action = 'denied'
        and object_id = '/org/users'
      order by id desc
      limit 1 $$,
  $$ values (
       '22222222-2222-2222-2222-222222220001'::uuid,
       'org'::text, 'denied'::text, 'route'::text, '/org/users'::text,
       'admin_only'::text
     ) $$,
  'audit_operations 落 actor/module/action/object_type/object_id/reason'
);
select results_eq(
  $$ select ip, ua
       from public.audit_operations
      where actor_id = '22222222-2222-2222-2222-222222220001'
        and action = 'denied'
        and object_id = '/org/users'
      order by id desc
      limit 1 $$,
  $$ values ('203.0.113.9'::inet, 'pgTAP-denied'::text) $$,
  'IP/UA 由 app.audit_log 自动采集'
);

-- 视图映射：audit_denied_v（admin 可见）
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select results_eq(
  $$ select user_id, module, route, reason
       from public.audit_denied_v
      where user_id = '22222222-2222-2222-2222-222222220001'
        and route = '/org/users'
      order by time desc
      limit 1 $$,
  $$ values (
       '22222222-2222-2222-2222-222222220001'::uuid,
       'org'::text, '/org/users'::text, 'admin_only'::text
     ) $$,
  'audit_denied_v 可见 denied 记录（user/module/route/reason）'
);
reset role;

-- engineer 本人看不到 denied 视图（RLS：仅 admin）
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select count(*)::int from public.audit_denied_v),
  0,
  'engineer 读取 audit_denied_v 为零行（RLS 仅 admin）'
);

-- auth 标识（proxy 封禁场景）在 10 个业务模块之外单独放行
select public.record_denied_attempt(
  'auth', '/audit/operations', 'user_banned'
) as d_auth \gset
reset role;

select ok(
  :d_auth::bigint is not null,
  'module=auth（代理封禁专用标识）可打点'
);

-- 截断：route ≤200 / reason ≤500
set local role authenticated;
select public.record_denied_attempt(
  'report', repeat('r', 250), repeat('x', 600)
) as d_trunc \gset
reset role;
select is(
  (select length(object_id)::int from public.audit_operations where id = :d_trunc),
  200,
  'route 超长截断为 200'
);
select is(
  (select length(diff ->> 'reason')::int from public.audit_operations where id = :d_trunc),
  500,
  'reason 超长截断为 500'
);

-- reason 为空：仍留痕，reason 记 null
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select public.record_denied_attempt('system', '/system/settings', null) as d_null \gset
reset role;
select ok(
  (select diff from public.audit_operations where id = :d_null)
    = '{"reason": null}'::jsonb,
  'reason 为空时 diff.reason 为 null 且记录仍写入'
);

-- ===========================================================================
-- 3. record_denied_attempt：限流（同用户 1 分钟 ≤20 条）（3）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220002","role":"authenticated"}',
  true
);
set local role authenticated;
select count(public.record_denied_attempt(
  'audit', '/audit/operations', 'ratelimit'
)) as n20
from generate_series(1, 20) \gset
select is(
  :n20::int,
  20,
  '限流窗口内 20 条全部写入'
);
select is(
  (select public.record_denied_attempt('audit', '/audit/operations', 'ratelimit')),
  null::bigint,
  '第 21 条被静默丢弃（返回 NULL）'
);
reset role;
select is(
  (select count(*)::int from public.audit_operations
    where actor_id = '22222222-2222-2222-2222-222222220002'
      and action = 'denied'),
  20,
  '限流丢弃后仍为 20 条'
);

-- ===========================================================================
-- 4. access seed：/audit + /audit/logins 补授（8）
-- ===========================================================================
select is(
  (select count(*)::int
     from public.role_menu_grants g
     join public.roles r on r.id = g.role_id
    where r.code in ('engineer', 'planner', 'buyer', 'quality')
      and g.menu_key in ('/audit', '/audit/logins')
      and g.granted_by is null),
  8,
  '4 个内部角色各补授 /audit + /audit/logins（系统默认 8 条）'
);
select is(
  (select count(*)::int
     from public.role_menu_grants g
     join public.roles r on r.id = g.role_id
    where r.code in ('supplier', 'customer')
      and g.menu_key in ('/audit', '/audit/logins')),
  0,
  'supplier/customer 不授审计菜单'
);
select is(
  (select count(*)::int
     from public.role_menu_grants g
     join public.roles r on r.id = g.role_id
    where r.code <> 'admin'
      and g.menu_key in ('/audit/operations', '/audit/changes', '/audit/compliance')),
  0,
  'operations/changes/compliance 不授非 admin（admin 专属）'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select ok(
  exists (select 1 from public.visible_menus() where key = '/audit')
    and exists (select 1 from public.visible_menus() where key = '/audit/logins'),
  'engineer visible_menus 含 /audit + /audit/logins'
);
select ok(
  not exists (select 1 from public.visible_menus() where key = '/audit/operations')
    and not exists (select 1 from public.visible_menus() where key = '/audit/changes')
    and not exists (select 1 from public.visible_menus() where key = '/audit/compliance'),
  'engineer visible_menus 不含 operations/changes/compliance'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220002","role":"authenticated"}',
  true
);
set local role authenticated;
select ok(
  exists (select 1 from public.visible_menus() where key = '/audit/logins'),
  'planner visible_menus 含 /audit/logins'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220003","role":"authenticated"}',
  true
);
set local role authenticated;
select ok(
  exists (select 1 from public.visible_menus() where key = '/audit/logins'),
  'buyer visible_menus 含 /audit/logins'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220004","role":"authenticated"}',
  true
);
set local role authenticated;
select ok(
  exists (select 1 from public.visible_menus() where key = '/audit/logins'),
  'quality visible_menus 含 /audit/logins'
);
reset role;

-- ===========================================================================
-- 5. list_recent_versions：change_type 列与推断（5）
-- ===========================================================================
select ok(
  (select pg_get_function_result(p.oid) like '%change_type text%'
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'list_recent_versions'),
  'public.list_recent_versions 返回列含 change_type'
);

-- 夹具：插入 → 更新 → 删除（profiles 触发器产生 v1/v2/v3 快照）
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, confirmation_token, recovery_token,
  email_change_token_new, email_change
) values (
  '00000000-0000-0000-0000-000000000000',
  '99999999-9999-9999-9999-99999999a001',
  'authenticated', 'authenticated',
  'audit-batch1-change@example.com',
  crypt('batch1-123', gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}',
  '{"full_name":"批次1变更类型用户"}',
  now(), now(), '', '', '', ''
);
update public.profiles
   set full_name = '批次1变更类型用户（改）'
 where id = '99999999-9999-9999-9999-99999999a001';

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select results_eq(
  $$ select version, change_type
       from public.list_recent_versions('profiles', 200)
      where record_id = '99999999-9999-9999-9999-99999999a001'
      order by version $$,
  $$ values (1, 'insert'::text), (2, 'update'::text) $$,
  '插入/更新后 change_type 推断为 insert/update'
);
reset role;

delete from public.profiles
 where id = '99999999-9999-9999-9999-99999999a001';

set local role authenticated;
select results_eq(
  $$ select version, change_type
       from public.list_recent_versions('profiles', 200)
      where record_id = '99999999-9999-9999-9999-99999999a001'
      order by version $$,
  $$ values (1, 'insert'::text), (2, 'update'::text), (3, 'delete'::text) $$,
  '删除后末版 change_type 推断为 delete'
);
select is(
  (select count(*)::int from public.list_recent_versions('profiles', 1)),
  1,
  'list_recent_versions 仍遵守 limit'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select * from public.list_recent_versions('profiles', 10) $$,
  '42501', null,
  'engineer 调用最近变更 RPC 仍被拒（admin 校验保留）'
);
reset role;

select * from finish();
rollback;
