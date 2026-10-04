-- pgTAP：audit/003+005 —— audit_logins 表 / app.audit_login / public.record_login_attempt
--        行为（匿名失败留痕、身份按邮箱解析、会话邮箱归一、IP/UA 采集、限流）
--        RLS（admin 全量、本人只见本人、anon 不可直读）
-- 运行：supabase test db
begin;
select plan(38);

-- ---------------------------------------------------------------------------
-- 结构（14）
-- ---------------------------------------------------------------------------
select has_table('public', 'audit_logins', 'audit_logins 表存在');
select has_column('public', 'audit_logins', 'user_id', 'user_id 列存在');
select has_column('public', 'audit_logins', 'email', 'email 列存在');
select has_column('public', 'audit_logins', 'success', 'success 列存在');
select has_column('public', 'audit_logins', 'fail_reason', 'fail_reason 列存在');
select has_column('public', 'audit_logins', 'ip', 'ip 列存在');
select has_column('public', 'audit_logins', 'ua', 'ua 列存在');
select has_column('public', 'audit_logins', 'created_at', 'created_at 列存在');
select col_is_pk('public', 'audit_logins', 'id', 'id 为主键');
select has_index('public', 'audit_logins', 'audit_logins_user_created_idx', '(user_id, created_at) 索引存在');
select has_index('public', 'audit_logins', 'audit_logins_created_idx', 'created_at 索引存在');
select has_function('app', 'audit_login', array['uuid','text','boolean','text','inet','text','text','text'], 'app.audit_login(uuid,text,boolean,text,inet,text,text,text) 存在（im/002 扩 via/im_userid）');
select has_function('public', 'record_login_attempt', array['text','boolean','text'], 'public.record_login_attempt(text,boolean,text) 存在');
select is(
  (select relrowsecurity from pg_class where oid = 'public.audit_logins'::regclass),
  true,
  'audit_logins 已启用 RLS'
);

-- ---------------------------------------------------------------------------
-- append-only：API 角色直写被拒（6）
-- ---------------------------------------------------------------------------
set local role authenticated;
select throws_ok(
  $$ insert into public.audit_logins (email, success) values ('x@example.com', true) $$,
  '42501', null, 'authenticated 直 INSERT 被拒'
);
select throws_ok(
  $$ update public.audit_logins set success = true $$,
  '42501', null, 'authenticated 直 UPDATE 被拒'
);
select throws_ok(
  $$ delete from public.audit_logins $$,
  '42501', null, 'authenticated 直 DELETE 被拒'
);
select throws_ok(
  $$ select app.audit_login(null, 'x@example.com', false, 'other', null, null) $$,
  '42501', null, 'authenticated 无 EXECUTE：audit_login 越权调用被拒'
);
reset role;

set local role anon;
select throws_ok(
  $$ insert into public.audit_logins (email, success) values ('x@example.com', false) $$,
  '42501', null, 'anon 直 INSERT 被拒'
);
select throws_ok(
  $$ select count(*) from public.audit_logins $$,
  '42501', null, 'anon 直读 audit_logins 被拒'
);
reset role;

-- ---------------------------------------------------------------------------
-- 匿名失败留痕：身份按邮箱解析、IP/UA 采集（8）
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims', '{}', true);
select set_config(
  'request.headers',
  json_build_object('x-forwarded-for', '203.0.113.9', 'user-agent', 'pgTAP')::text,
  true
);

set local role anon;
select lives_ok(
  $$ select public.record_login_attempt('engineer@example.com', false, 'invalid_credentials') $$,
  '匿名可记录失败尝试'
);
reset role;

select is(
  (select user_id from public.audit_logins where email = 'engineer@example.com' order by id desc limit 1),
  '22222222-2222-2222-2222-222222220001'::uuid,
  '匿名失败按邮箱解析 user_id'
);
select is(
  (select ip from public.audit_logins where email = 'engineer@example.com' order by id desc limit 1),
  '203.0.113.9'::inet,
  'IP 取自 request.headers 的 X-Forwarded-For'
);
select is(
  (select ua from public.audit_logins where email = 'engineer@example.com' order by id desc limit 1),
  'pgTAP'::text,
  'UA 取自 request.headers'
);

-- 未知邮箱：user_id 为 NULL，仍留痕
set local role anon;
select lives_ok(
  $$ select public.record_login_attempt('ghost@example.com', false, 'invalid_credentials') $$,
  '未知邮箱失败仍留痕'
);
reset role;
select is(
  (select user_id from public.audit_logins where email = 'ghost@example.com'),
  null::uuid,
  '未知邮箱 user_id 为 NULL'
);

-- 多段 X-Forwarded-For 取第一段
select set_config(
  'request.headers',
  json_build_object('x-forwarded-for', '198.51.100.5, 10.0.0.1', 'user-agent', 'pgTAP-2')::text,
  true
);
set local role anon;
select lives_ok(
  $$ select public.record_login_attempt('ghost@example.com', false, 'other') $$,
  '多段 X-Forwarded-For 不报错'
);
reset role;
select is(
  (select ip from public.audit_logins where email = 'ghost@example.com' order by id desc limit 1),
  '198.51.100.5'::inet,
  'IP 取 X-Forwarded-For 第一段'
);

-- 匿名不可记成功
set local role anon;
select throws_ok(
  $$ select public.record_login_attempt('engineer@example.com', true) $$,
  '42501', null, '匿名记录成功登录被拒'
);
reset role;

-- ---------------------------------------------------------------------------
-- 已登录成功：会话邮箱归一（3）
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '11111111-1111-1111-1111-111111111111', 'role', 'authenticated')::text,
  true
);

set local role authenticated;
select lives_ok(
  $$ select public.record_login_attempt('engineer@example.com', true) $$,
  '已登录可记录成功登录'
);
reset role;

select results_eq(
  $$ select user_id, email, success, fail_reason
       from public.audit_logins
      order by id desc limit 1 $$,
  $$ values (
       '11111111-1111-1111-1111-111111111111'::uuid,
       'admin@example.com'::text, true, null::text
     ) $$,
  '成功登录以会话邮箱为准（忽略传入他人邮箱）且 fail_reason 为空'
);

-- ---------------------------------------------------------------------------
-- 限流：同 email 1 分钟 ≤10 条（3）
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims', '{}', true);

set local role anon;
select count(public.record_login_attempt('ratelimit@example.com', false, 'other'))
  from generate_series(1, 10);
reset role;
select is(
  (select count(*)::integer from public.audit_logins where email = 'ratelimit@example.com'),
  10,
  '限流窗口内写入 10 条'
);

set local role anon;
select is(
  (select public.record_login_attempt('ratelimit@example.com', false, 'other')),
  null::bigint,
  '第 11 条被静默丢弃（返回 NULL）'
);
reset role;
select is(
  (select count(*)::integer from public.audit_logins where email = 'ratelimit@example.com'),
  10,
  '限流丢弃后仍为 10 条'
);

-- ---------------------------------------------------------------------------
-- RLS：本人自查 / admin 全量（4）
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '22222222-2222-2222-2222-222222220001')::text,
  true
);
set local role authenticated;
select cmp_ok(
  (select count(*)::int from public.audit_logins),
  '>', 0,
  'engineer 可见本人登录记录'
);
select is(
  (select count(*)::int from public.audit_logins
    where user_id is distinct from '22222222-2222-2222-2222-222222220001'::uuid),
  0,
  'engineer 看不到他人记录'
);
reset role;

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '11111111-1111-1111-1111-111111111111')::text,
  true
);
set local role authenticated;
select cmp_ok(
  (select count(*)::int from public.audit_logins
    where user_id is distinct from '11111111-1111-1111-1111-111111111111'::uuid),
  '>', 0,
  'admin 可见他人记录（全量）'
);
select cmp_ok(
  (select count(*)::int from public.audit_logins),
  '>',
  (select count(*)::int from public.audit_logins
    where user_id = '11111111-1111-1111-1111-111111111111'::uuid),
  'admin 全量大于本人子集'
);
reset role;

select * from finish();
rollback;
