-- pgTAP：message 批次 2 修复项 2 — 发送限流（同事件 5 条/分钟、同 recipient 50 条/小时）
-- 运行：supabase db reset && supabase test db
-- 覆盖：check_notification_rate 结构/授权/参数校验；第 6 条同事件被拒（53400/429）且不写库；
--       滑窗过期后恢复；第 51 条同 recipient 被拒且不写库；窗口外恢复；recipient 隔离。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(15);

-- ---------------------------------------------------------------------------
-- 夹具：u1（限流对象）/ u2（对照，独立窗口）
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-4000-a000-000000000091', 'msg-rate-u1@example.com'),
  ('00000000-0000-4000-a000-000000000092', 'msg-rate-u2@example.com');

-- ---------------------------------------------------------------------------
-- A. 结构 / 授权 / 参数校验（6）
-- ---------------------------------------------------------------------------
select has_function('app', 'check_notification_rate', array['uuid', 'text'],
                    'app.check_notification_rate 存在');
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'check_notification_rate'),
  'check_notification_rate = SECURITY DEFINER + search_path 固定为空'
);
select ok(
  not has_function_privilege('authenticated', 'app.check_notification_rate(uuid,text)', 'EXECUTE'),
  'authenticated 无执行权（INDEX 规则 10）'
);
select ok(
  not has_function_privilege('anon', 'app.check_notification_rate(uuid,text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'app.check_notification_rate(uuid,text)', 'EXECUTE'),
  'anon / service_role 无执行权'
);
select throws_ok(
  $$ select app.check_notification_rate(null, 'rate.test') $$,
  '22023', '收件人不能为空',
  'recipient 为空被拒（22023）'
);
select throws_ok(
  $$ select app.check_notification_rate('00000000-0000-4000-a000-000000000091', '') $$,
  '22023', 'event_key 不能为空',
  'event_key 为空被拒（22023）'
);

-- ---------------------------------------------------------------------------
-- B. 同事件限流：1 分钟 ≤ 5（4）
-- ---------------------------------------------------------------------------
select app.send_notification('00000000-0000-4000-a000-000000000091', 'rate.test', '{"title":"1"}'::jsonb);
select app.send_notification('00000000-0000-4000-a000-000000000091', 'rate.test', '{"title":"2"}'::jsonb);
select app.send_notification('00000000-0000-4000-a000-000000000091', 'rate.test', '{"title":"3"}'::jsonb);
select app.send_notification('00000000-0000-4000-a000-000000000091', 'rate.test', '{"title":"4"}'::jsonb);
select app.send_notification('00000000-0000-4000-a000-000000000091', 'rate.test', '{"title":"5"}'::jsonb);

select throws_ok(
  $$ select app.send_notification(
       '00000000-0000-4000-a000-000000000091', 'rate.test', '{"title":"6"}'::jsonb) $$,
  '53400', '同一事件通知超过速率限制（5 条/分钟），请稍后重试',
  '第 6 条同事件通知被拒（53400 / 429）'
);
select is(
  (select count(*) from public.messages
    where recipient_id = '00000000-0000-4000-a000-000000000091'
      and event_key = 'rate.test'),
  5::bigint,
  '被拒通知未写入 messages（仅前 5 条落库）'
);

update public.messages
   set created_at = now() - interval '2 minutes'
 where recipient_id = '00000000-0000-4000-a000-000000000091'
   and event_key = 'rate.test';

select lives_ok(
  $$ select app.send_notification(
       '00000000-0000-4000-a000-000000000091', 'rate.test', '{"title":"7"}'::jsonb) $$,
  '滑出 1 分钟窗口后第 6 条恢复发送'
);
select is(
  (select count(*) from public.messages
    where recipient_id = '00000000-0000-4000-a000-000000000091'
      and event_key = 'rate.test'),
  6::bigint,
  '窗口过期后配额释放（共 6 条）'
);

-- ---------------------------------------------------------------------------
-- C. 每小时总量限流：50 条（3）
-- ---------------------------------------------------------------------------
delete from public.messages where recipient_id = '00000000-0000-4000-a000-000000000091';

insert into public.messages (recipient_id, event_key, title, body, created_at)
select '00000000-0000-4000-a000-000000000091',
       'rate.hist.' || i, 't', 'b', now() - interval '30 minutes'
from generate_series(1, 50) i;

select throws_ok(
  $$ select app.send_notification(
       '00000000-0000-4000-a000-000000000091', 'rate.hist.x', '{"title":"51"}'::jsonb) $$,
  '53400', '通知发送超过速率限制（50 条/小时），请稍后重试',
  '第 51 条同 recipient 通知被拒（53400 / 429）'
);
select is(
  (select count(*) from public.messages
    where recipient_id = '00000000-0000-4000-a000-000000000091'),
  50::bigint,
  '每小时维度被拒时也不写库'
);

update public.messages
   set created_at = now() - interval '2 hours'
 where recipient_id = '00000000-0000-4000-a000-000000000091';

select lives_ok(
  $$ select app.send_notification(
       '00000000-0000-4000-a000-000000000091', 'rate.hist.fresh', '{"title":"恢复"}'::jsonb) $$,
  '滑出 1 小时窗口后恢复发送'
);

-- ---------------------------------------------------------------------------
-- D. recipient 隔离与独立窗口（2）
-- ---------------------------------------------------------------------------
select app.send_notification('00000000-0000-4000-a000-000000000092', 'rate.other', '{"title":"u2-1"}'::jsonb);

update public.messages
   set created_at = now() - interval '2 minutes'
 where recipient_id = '00000000-0000-4000-a000-000000000092';

select app.send_notification('00000000-0000-4000-a000-000000000092', 'rate.other', '{"title":"u2-2"}'::jsonb);
select app.send_notification('00000000-0000-4000-a000-000000000092', 'rate.other', '{"title":"u2-3"}'::jsonb);
select app.send_notification('00000000-0000-4000-a000-000000000092', 'rate.other', '{"title":"u2-4"}'::jsonb);
select app.send_notification('00000000-0000-4000-a000-000000000092', 'rate.other', '{"title":"u2-5"}'::jsonb);
select app.send_notification('00000000-0000-4000-a000-000000000092', 'rate.other', '{"title":"u2-6"}'::jsonb);

select is(
  (select count(*) from public.messages
    where recipient_id = '00000000-0000-4000-a000-000000000092'
      and event_key = 'rate.other'
      and created_at > now() - interval '1 minute'),
  5::bigint,
  'u1 被限流不影响 u2：窗口外旧消息不占配额（u2 窗口内可发满 5 条）'
);
select throws_ok(
  $$ select app.send_notification(
       '00000000-0000-4000-a000-000000000092', 'rate.other', '{"title":"u2-7"}'::jsonb) $$,
  '53400', '同一事件通知超过速率限制（5 条/分钟），请稍后重试',
  'u2 的新窗口同样在第 6 条拒绝（计数只算滑窗内消息）'
);

select * from finish();
rollback;
