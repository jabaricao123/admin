-- pgTAP：message/003 补丁 — mark_notification_unread（已读回退）
-- 运行：supabase db reset && supabase test db
-- 覆盖：函数存在性 / SECURITY DEFINER + search_path 固定 / GRANT（public 包装 authenticated 有、anon 无；
--       app 实现不授 API 角色，INDEX 规则 10）/ 属主可回退且幂等 / 未读数同源一致 /
--       非属主与不存在的 id 报 42501 且他人数据不受影响 / anon 与无身份调用被拒。
-- 说明：夹具只在事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(19);

-- ---------------------------------------------------------------------------
-- 夹具（as postgres；auth.users 触发器自动建 profiles）
-- u1：1 条已读 + 1 条未读；u2：哨兵 424244（已读，供越权检测）
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-4000-a000-000000000011', 'msg-unread-t1@example.com'),
  ('00000000-0000-4000-a000-000000000012', 'msg-unread-t2@example.com');

insert into public.messages (recipient_id, event_key, title, body, read_at, created_at) values
  ('00000000-0000-4000-a000-000000000011', 'manual.read',   '已读通知', '正文 read',   '2026-02-01T00:00:00Z', '2026-02-01T00:00:00Z'),
  ('00000000-0000-4000-a000-000000000011', 'manual.unread', '未读通知', '正文 unread', null,                   '2026-02-02T00:00:00Z');

insert into public.messages (id, recipient_id, event_key, title, body, read_at, created_at)
overriding system value
values (424244, '00000000-0000-4000-a000-000000000012', 'manual.u2', '他人已读消息', '不可见', '2026-02-03T00:00:00Z', '2026-02-03T00:00:00Z');

-- ---------------------------------------------------------------------------
-- A. 函数存在性、安全属性与执行权限（8）
-- ---------------------------------------------------------------------------
select has_function('app', 'mark_notification_unread', array['bigint'], 'app.mark_notification_unread 存在');
select has_function('public', 'mark_notification_unread', array['bigint'], 'public.mark_notification_unread 包装存在');

select is(
  (select count(*)
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = 'mark_notification_unread'
      and p.prosecdef
      and p.proconfig = array['search_path=""']),
  1::bigint, 'app.mark_notification_unread：security definer + search_path 固定为空'
);
select is(
  (select count(*)
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'mark_notification_unread'
      and p.prosecdef
      and p.proconfig = array['search_path=""']),
  1::bigint, 'public.mark_notification_unread 包装：security definer + search_path 固定为空'
);

select ok(
  has_function_privilege('authenticated', 'public.mark_notification_unread(bigint)', 'EXECUTE'),
  'authenticated 可执行 public.mark_notification_unread'
);
select ok(
  not has_function_privilege('anon', 'public.mark_notification_unread(bigint)', 'EXECUTE'),
  'anon 无 public.mark_notification_unread 执行权'
);
select ok(
  not has_function_privilege('authenticated', 'app.mark_notification_unread(bigint)', 'EXECUTE'),
  'authenticated 不可执行 app.mark_notification_unread（INDEX 规则 10）'
);
select ok(
  not has_function_privilege('anon', 'app.mark_notification_unread(bigint)', 'EXECUTE'),
  'anon 不可执行 app.mark_notification_unread'
);

-- ---------------------------------------------------------------------------
-- B. 功能：以 authenticated（u1）身份（8）
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-a000-000000000011', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select is((select public.unread_count()), 1::bigint, 'u1 初始未读数为 1');

select lives_ok(
  $$ select public.mark_notification_unread((select id from public.messages where event_key = 'manual.read')) $$,
  '对本人已读消息回退未读不报错'
);
select is(
  (select read_at from public.messages where event_key = 'manual.read'),
  null, 'manual.read 的 read_at 已置回 null'
);
select is((select public.unread_count()), 2::bigint, '回退后未读数升为 2（同源一致）');

select lives_ok(
  $$ select public.mark_notification_unread((select id from public.messages where event_key = 'manual.unread')) $$,
  '对已未读消息重复调用幂等不报错'
);
select is(
  (select read_at from public.messages where event_key = 'manual.unread'),
  null, 'manual.unread 保持未读'
);

select throws_ok(
  'select public.mark_notification_unread(424244)',
  '42501', '消息不存在或无权操作', '不可将他人消息回退未读'
);
select throws_ok(
  'select public.mark_notification_unread(999999)',
  '42501', '消息不存在或无权操作', '不存在 id 报 42501'
);

-- ---------------------------------------------------------------------------
-- C. 回到 postgres：他人在此过程未被篡改（1）
-- ---------------------------------------------------------------------------
reset role;

select is(
  (select read_at from public.messages where id = 424244),
  '2026-02-03T00:00:00Z'::timestamptz, '他人消息的已读时间未被 u1 操作改动'
);

-- ---------------------------------------------------------------------------
-- D. anon 与无身份调用被拒（2）
-- ---------------------------------------------------------------------------
set local role anon;
select throws_ok(
  'select public.mark_notification_unread(1)',
  '42501', null, 'anon 调用被拒（无执行权限）'
);

reset role;
set local request.jwt.claims = '{"role":"authenticated"}';
set local role authenticated;
select throws_ok(
  'select public.mark_notification_unread(1)',
  '42501', '消息不存在或无权操作', '无 sub 身份（auth.uid() 为空）被拒'
);

select * from finish();
rollback;
