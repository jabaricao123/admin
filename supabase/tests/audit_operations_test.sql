-- pgTAP：audit/001-002 —— audit_operations 表 / app.audit_log / append-only / 仅 admin 可见
-- 运行：supabase test db
begin;
select plan(22);

-- ---------------------------------------------------------------------------
-- 结构
-- ---------------------------------------------------------------------------
select has_table('public', 'audit_operations', 'audit_operations 表存在');
select has_column('public', 'audit_operations', 'actor_id', 'actor_id 列存在');
select col_is_pk('public', 'audit_operations', 'id', 'id 为主键');
select has_function('app', 'audit_log', array['text','text','text','text','jsonb'], 'app.audit_log(text,text,text,text,jsonb) 存在');
select has_view('public', 'audit_operations_v', 'audit_operations_v 视图存在');
select has_view('public', 'audit_denied_v', 'audit_denied_v 视图存在');
select is(
  (select relrowsecurity from pg_class where oid = 'public.audit_operations'::regclass),
  true,
  'audit_operations 已启用 RLS'
);

-- ---------------------------------------------------------------------------
-- append-only：API 角色直写被拒
-- ---------------------------------------------------------------------------
set local role authenticated;

select throws_ok(
  $$ insert into public.audit_operations (module, action, object_type) values ('pgtap', 'create', 'x') $$,
  '42501', null, 'authenticated 直 INSERT 被拒'
);
select throws_ok(
  $$ update public.audit_operations set action = 'x' $$,
  '42501', null, 'authenticated 直 UPDATE 被拒'
);
select throws_ok(
  $$ delete from public.audit_operations $$,
  '42501', null, 'authenticated 直 DELETE 被拒'
);
select throws_ok(
  $$ select app.audit_log('pgtap', 'create', 'x', null, null) $$,
  '42501', null, 'authenticated 无 EXECUTE：audit_log 越权调用被拒'
);

reset role;

set local role anon;
select throws_ok(
  $$ insert into public.audit_operations (module, action, object_type) values ('pgtap', 'create', 'x') $$,
  '42501', null, 'anon 直 INSERT 被拒'
);
reset role;

-- ---------------------------------------------------------------------------
-- app.audit_log 行为：自动带 actor / ip / ua
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '11111111-1111-1111-1111-111111111111')::text,
  true
);
select set_config(
  'request.headers',
  json_build_object('x-forwarded-for', '203.0.113.9', 'user-agent', 'pgTAP')::text,
  true
);

select lives_ok(
  $$ select app.audit_log('org', 'update', 'department', '42', '{"name":["A","B"]}'::jsonb) $$,
  'audit_log 5 参调用成功'
);
select results_eq(
  $$ select actor_id, module, action, object_type, object_id, diff, ip, ua
       from public.audit_operations
      where module = 'org' and action = 'update' $$,
  $$ values (
       '11111111-1111-1111-1111-111111111111'::uuid,
       'org'::text, 'update'::text, 'department'::text, '42'::text,
       '{"name":["A","B"]}'::jsonb, '203.0.113.9'::inet, 'pgTAP'::text
     ) $$,
  'audit_log 自动落 actor/ip/ua 与 diff'
);

-- 无会话（后台）调用：actor_id 为 NULL
select set_config('request.jwt.claims', '{}', true);
select set_config('request.headers', '{}', true);
select lives_ok(
  $$ select app.audit_log('system', 'cleanup', 'job', null, null) $$,
  '无会话后台调用可写'
);
select is(
  (select actor_id from public.audit_operations where module = 'system'),
  null::uuid,
  '后台调用 actor_id 为 NULL'
);

-- XFF 多段：取第一段且不报错
select set_config(
  'request.headers',
  json_build_object('x-forwarded-for', '198.51.100.5, 10.0.0.1')::text,
  true
);
select lives_ok(
  $$ select app.audit_log('org', 'create', 'department', '43', null) $$,
  '多段 X-Forwarded-For 不报错'
);
select is(
  (select ip from public.audit_operations where module = 'org' and object_id = '43'),
  '198.51.100.5'::inet,
  'IP 取 X-Forwarded-For 第一段'
);

-- ---------------------------------------------------------------------------
-- RLS：仅 admin 可读
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '11111111-1111-1111-1111-111111111111')::text,
  true
);
set local role authenticated;
select cmp_ok(
  (select count(*)::int from public.audit_operations),
  '>', 0,
  'admin 可读 audit_operations'
);
reset role;

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '22222222-2222-2222-2222-222222220001')::text,
  true
);
set local role authenticated;
select is(
  (select count(*)::int from public.audit_operations),
  0,
  'engineer 读不到操作日志'
);
reset role;

-- 视图：admin 可读
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '11111111-1111-1111-1111-111111111111')::text,
  true
);
set local role authenticated;
select cmp_ok(
  (select count(*)::int from public.audit_operations_v),
  '>', 0,
  'admin 可经 audit_operations_v 读取'
);
reset role;

-- denied 视图映射（object_type=route、object_id=route、diff.reason）
select app.audit_log(
  'access', 'denied', 'route', '/admin/users', '{"reason":"缺少 role:admin"}'::jsonb
);
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '11111111-1111-1111-1111-111111111111')::text,
  true
);
set local role authenticated;
select results_eq(
  $$ select route, reason from public.audit_denied_v where route = '/admin/users' $$,
  $$ values ('/admin/users'::text, '缺少 role:admin'::text) $$,
  'audit_denied_v 映射 route/reason'
);
reset role;

select * from finish();
rollback;
