-- pgTAP：message/002 — messages RLS + 公开 RPC + send_notification 授权
-- 运行：supabase test db（建议先 supabase db reset）
-- 覆盖：结构/索引存在性、RLS 与表级权限、函数存在与安全性、本人可见/他人不可见、
--       recent_notifications 只回本人、mark_all_read / unread_count / 星标、
--       authenticated 直写与越权调用被拒、send_notification fallback 渲染。

begin;
select plan(62);

-- ---------------------------------------------------------------------------
-- 夹具（as postgres；auth.users 触发器自动建 profiles）
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-4000-a000-000000000001', 'msg-t1@example.com'),
  ('00000000-0000-4000-a000-000000000002', 'msg-t2@example.com');

-- u1：3 条手工消息（含 1 条已读、1 条星标）+ 1 条 send_notification；u2：哨兵 424242 + fallback 通知
insert into public.messages (recipient_id, event_key, title, body, starred, read_at, created_at) values
  ('00000000-0000-4000-a000-000000000001', 'manual.old',  '旧通知',   '正文 old',  false, null,                          '2026-01-01T00:00:00Z'),
  ('00000000-0000-4000-a000-000000000001', 'manual.mid',  '中间通知', '正文 mid',  true,  null,                          '2026-01-02T00:00:00Z'),
  ('00000000-0000-4000-a000-000000000001', 'manual.read', '已读通知', '正文 read', false, '2026-01-04T00:00:00Z',        '2026-01-03T00:00:00Z');

insert into public.messages (id, recipient_id, event_key, title, body, created_at)
overriding system value
values (424242, '00000000-0000-4000-a000-000000000002', 'manual.u2', '他人消息', '不可见', '2026-01-05T00:00:00Z');

select app.send_notification(
  '00000000-0000-4000-a000-000000000001',
  'approval.approved',
  '{"title":"审批通过","body":"你的申请已通过","source_module":"approval","ref_type":"approval","ref_id":"42"}'::jsonb
);
select app.send_notification('00000000-0000-4000-a000-000000000002', 'sync.failed', '{}'::jsonb);

-- ---------------------------------------------------------------------------
-- A. 结构（表 / 列 / 索引）
-- ---------------------------------------------------------------------------
select has_table('public', 'messages', 'messages 表存在');
select has_column('public', 'messages', 'recipient_id', 'recipient_id 列存在');
select has_column('public', 'messages', 'event_key', 'event_key 列存在');
select has_column('public', 'messages', 'read_at', 'read_at 列存在');
select has_column('public', 'messages', 'starred', 'starred 列存在');
select has_index('public', 'messages', 'messages_recipient_created_idx', 'recipient+created 索引存在');
select has_index('public', 'messages', 'messages_recipient_unread_idx', 'recipient 未读部分索引存在');

-- ---------------------------------------------------------------------------
-- B. RLS 与表级权限（敏感表二分：无任何角色表级写）
-- ---------------------------------------------------------------------------
select ok(
  (select c.relrowsecurity
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'messages'),
  'messages 已启用 RLS'
);
select is(
  (select count(*) from pg_policies where schemaname = 'public' and tablename = 'messages'),
  1::bigint, 'messages 仅 1 条策略'
);
select is(
  (select count(*) from pg_policies where schemaname = 'public' and tablename = 'messages' and cmd = 'SELECT'),
  1::bigint, '唯一策略是 SELECT'
);
select is(
  (select count(*) from pg_policies
    where schemaname = 'public' and tablename = 'messages' and cmd in ('INSERT', 'UPDATE', 'DELETE')),
  0::bigint, '无任何表级写策略'
);
select ok(has_table_privilege('authenticated', 'public.messages', 'SELECT'), 'authenticated 有 SELECT 权限');
select ok(not has_table_privilege('authenticated', 'public.messages', 'INSERT'), 'authenticated 无 INSERT 权限');
select ok(not has_table_privilege('authenticated', 'public.messages', 'UPDATE'), 'authenticated 无 UPDATE 权限');
select ok(not has_table_privilege('authenticated', 'public.messages', 'DELETE'), 'authenticated 无 DELETE 权限');
select ok(not has_table_privilege('anon', 'public.messages', 'SELECT'), 'anon 无 SELECT 权限');

-- ---------------------------------------------------------------------------
-- C. 函数存在性
-- ---------------------------------------------------------------------------
select has_function('app', 'send_notification', array['uuid', 'text', 'jsonb'], 'app.send_notification 存在');
select has_function('public', 'recent_notifications', array['integer'], 'recent_notifications 存在');
select has_function('public', 'mark_all_read', 'mark_all_read 存在');
select has_function('public', 'unread_count', 'unread_count 存在');
select has_function('public', 'mark_notification_read', array['bigint'], 'mark_notification_read 存在');
select has_function('public', 'toggle_notification_star', array['bigint'], 'toggle_notification_star 存在');

-- ---------------------------------------------------------------------------
-- D. 函数安全属性：SECURITY DEFINER + set search_path = ''
-- ---------------------------------------------------------------------------
select is(
  (select count(*)
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = 'send_notification'
      and p.prosecdef
      and p.proconfig = array['search_path=""']),
  1::bigint, 'app.send_notification：security definer + search_path 固定为空'
);
select is(
  (select count(*)
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('recent_notifications', 'mark_all_read', 'unread_count', 'mark_notification_read', 'toggle_notification_star')
      and p.prosecdef
      and p.proconfig = array['search_path=""']),
  5::bigint, '公开 RPC：全部 security definer + search_path 固定为空'
);

-- ---------------------------------------------------------------------------
-- E. 函数执行权限（INDEX 规则 10）
-- ---------------------------------------------------------------------------
select ok(
  not has_function_privilege('authenticated', 'app.send_notification(uuid,text,jsonb)', 'EXECUTE'),
  'authenticated 不可执行 app.send_notification'
);
select ok(
  not has_function_privilege('anon', 'app.send_notification(uuid,text,jsonb)', 'EXECUTE'),
  'anon 不可执行 app.send_notification'
);
select ok(has_function_privilege('authenticated', 'public.recent_notifications(integer)', 'EXECUTE'), 'authenticated 可执行 recent_notifications');
select ok(has_function_privilege('authenticated', 'public.mark_all_read()', 'EXECUTE'), 'authenticated 可执行 mark_all_read');
select ok(has_function_privilege('authenticated', 'public.unread_count()', 'EXECUTE'), 'authenticated 可执行 unread_count');
select ok(has_function_privilege('authenticated', 'public.mark_notification_read(bigint)', 'EXECUTE'), 'authenticated 可执行 mark_notification_read');
select ok(has_function_privilege('authenticated', 'public.toggle_notification_star(bigint)', 'EXECUTE'), 'authenticated 可执行 toggle_notification_star');

-- ---------------------------------------------------------------------------
-- F. 功能：以 authenticated（u1）身份
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-a000-000000000001', 'role', 'authenticated')::text,
  true
);
set local role authenticated;

select is((select count(*) from public.messages), 4::bigint, 'u1 仅能看到本人 4 条消息');
select is(
  (select count(*) from public.messages where recipient_id <> '00000000-0000-4000-a000-000000000001'),
  0::bigint, 'u1 看不到他人消息'
);
select is((select count(*) from public.recent_notifications()), 4::bigint, 'recent_notifications 默认只回本人 4 条');
select is((select count(*) from public.recent_notifications(2)), 2::bigint, 'recent_notifications limit 生效');
select is(
  (select event_key from public.recent_notifications(1)),
  'approval.approved', 'recent_notifications 最新在前'
);
select is((select public.unread_count()), 3::bigint, 'u1 未读数为 3');

select lives_ok(
  $$ select public.mark_notification_read((select id from public.messages where event_key = 'manual.old')) $$,
  '单条标记已读不报错'
);
select is(
  (select read_at is not null from public.messages where event_key = 'manual.old'),
  true, 'manual.old 已写入已读时间'
);
select is((select public.unread_count()), 2::bigint, '已读后未读数降为 2');

select throws_ok(
  'select public.mark_notification_read(424242)',
  '42501', '消息不存在或无权操作', '不可标记他人消息已读'
);
select throws_ok(
  'select public.toggle_notification_star(424242)',
  '42501', '消息不存在或无权操作', '不可星标他人消息'
);

select is(
  (select starred from public.messages where event_key = 'manual.old'),
  false, 'manual.old 初始未星标'
);
select lives_ok(
  $$ select public.toggle_notification_star((select id from public.messages where event_key = 'manual.old')) $$,
  '星标切换不报错'
);
select is(
  (select starred from public.messages where event_key = 'manual.old'),
  true, 'manual.old 已星标'
);
select lives_ok(
  $$ select public.toggle_notification_star((select id from public.messages where event_key = 'manual.old')) $$,
  '再次切换星标不报错'
);
select is(
  (select starred from public.messages where event_key = 'manual.old'),
  false, 'manual.old 星标已还原'
);

select is((select public.mark_all_read()), 2, 'mark_all_read 返回本次影响行数 2');
select is((select public.unread_count()), 0::bigint, 'mark_all_read 后未读清零');
select is(
  (select count(*) from public.messages where read_at is null),
  0::bigint, 'u1 已无未读行'
);

-- ---------------------------------------------------------------------------
-- G. 直写与越权调用拒绝（仍为 authenticated）
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ insert into public.messages (recipient_id, event_key, title, body)
     values ('00000000-0000-4000-a000-000000000001', 'hack.insert', 'x', 'x') $$,
  '42501', null, 'authenticated 直接 INSERT 被拒'
);
select throws_ok(
  $$ update public.messages set starred = true $$,
  '42501', null, 'authenticated 直接 UPDATE 被拒'
);
select throws_ok(
  $$ delete from public.messages $$,
  '42501', null, 'authenticated 直接 DELETE 被拒'
);
select throws_ok(
  $$ select app.send_notification('00000000-0000-4000-a000-000000000001', 'hack.rpc', '{}'::jsonb) $$,
  '42501', null, 'authenticated 越权调用 send_notification 被拒'
);

-- ---------------------------------------------------------------------------
-- H. 回到 postgres：验证他人数据未被影响 + send_notification 渲染
-- ---------------------------------------------------------------------------
reset role;

select is((select read_at from public.messages where id = 424242), null, '他人消息未被 u1 操作改已读');
select is((select starred from public.messages where id = 424242), false, '他人消息未被 u1 操作改星标');
select is(
  (select title from public.messages where recipient_id = '00000000-0000-4000-a000-000000000002' and event_key = 'sync.failed'),
  'sync.failed', 'fallback 标题取 event_key'
);
select is(
  (select body from public.messages where event_key = 'sync.failed'),
  '', 'fallback 正文为空串'
);
select is(
  (select source_module from public.messages where event_key = 'sync.failed'),
  'sync', 'source_module 由 event_key 前缀推断'
);
select is(
  (select title from public.messages where event_key = 'approval.approved'),
  '审批通过', 'vars.title 优先于 event_key'
);
select is(
  (select ref_id from public.messages where event_key = 'approval.approved'),
  '42', 'ref_type/ref_id 由 vars 回填'
);
select is(
  (select count(*) from public.messages where event_key = 'approval.approved'),
  1::bigint, 'send_notification 每次插入一行'
);

select * from finish();
rollback;
