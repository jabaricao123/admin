-- pgTAP：integration 批次 4 —— Webhook 投递级重试（success 端点不重复投递）
-- 运行：supabase db reset && supabase test db
-- 覆盖：首轮双端点一成功一失败 → 事件 pending 且重派只为失败端点新建投递；
--       重试成功 → 事件 done；max_attempts=1 耗尽 → 事件 failed + audit + 通知且不再投递；
--       已 done 端点 + 耗尽端点混合 → 事件 failed（不因成功端点而 done）；
--       失败端点停用（无其他可重试）→ 事件 done 且不通知。
-- 说明：pgTAP 事务内 net.http_post 入队行随回滚消失，pg_net 不会真实出站；
--       响应收口用注入 net._http_response 行模拟；夹具 finish 后 rollback。

begin;

select plan(32);

-- ===========================================================================
-- 0. 夹具：端点 A/B（默认策略）、C/D/E（按场景）——admin 创建
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.create_webhook(
  '重试 A', 'https://hooks.example.com/ra', array['pgtap.delivery.retry', 'pgtap.mix']
) as wa \gset
select public.create_webhook(
  '重试 B', 'https://hooks.example.com/rb', array['pgtap.delivery.retry']
) as wb \gset
select public.create_webhook(
  '终态 C', 'https://hooks.example.com/rc', array['pgtap.delivery.exhaust'],
  '{"max_attempts":1,"backoff":"linear"}'::jsonb
) as wc \gset
select public.create_webhook(
  '停用 E', 'https://hooks.example.com/re', array['pgtap.delivery.disabled']
) as we \gset

reset role;

-- ===========================================================================
-- 1. A 成功 + B 失败：事件 pending，重派只为 B（14）
-- ===========================================================================
insert into public.integration_events (event, payload, status, attempts, next_retry_at)
values ('pgtap.delivery.retry', '{"k":"v"}'::jsonb, 'pending', 0, now())
returning id as e1 \gset

select is(app.process_webhook_events(), 1, '首轮派发 1 条事件');
select is(
  (select count(*) from public.webhook_deliveries where event_id = :'e1'),
  2::bigint,
  '首轮为 A/B 各建 1 条投递（attempt 0）'
);

select request_id as req_a
  from public.webhook_deliveries
 where event_id = :'e1' and webhook_id = (:'wa'::jsonb ->> 'id')::uuid \gset
select request_id as req_b
  from public.webhook_deliveries
 where event_id = :'e1' and webhook_id = (:'wb'::jsonb ->> 'id')::uuid \gset

insert into net._http_response (id, status_code, created)
values (:'req_a', 200, now());
insert into net._http_response (id, status_code, error_msg, created)
values (:'req_b', 503, 'Service Unavailable', now());

select is(app.finalize_webhook_deliveries(), 1, 'finalize 收口 1 条事件');
select is(
  (select status from public.integration_events where id = :'e1'),
  'pending',
  'B 未耗尽 → 事件 pending（A 成功不阻塞）'
);
select is(
  (select attempts from public.integration_events where id = :'e1'),
  1,
  '事件 attempts 递增为 1'
);
select is(
  (select status from public.webhook_deliveries
    where event_id = :'e1' and webhook_id = (:'wa'::jsonb ->> 'id')::uuid),
  'done',
  'A 第一轮 done'
);
select is(
  (select status from public.webhook_deliveries
    where event_id = :'e1' and webhook_id = (:'wb'::jsonb ->> 'id')::uuid),
  'failed',
  'B 第一轮 failed'
);

update public.integration_events
   set next_retry_at = now() - interval '1 minute'
 where id = :'e1';

select is(app.process_webhook_events(), 1, '到期重派 1 条事件');
select is(
  (select count(*) from public.webhook_deliveries where event_id = :'e1'),
  3::bigint,
  '重派只为 B 新建投递（总行数 3）'
);
select is(
  (select count(*) from public.webhook_deliveries
    where event_id = :'e1' and webhook_id = (:'wa'::jsonb ->> 'id')::uuid),
  1::bigint,
  'success 端点 A 不重复投递（仅首轮 1 行）'
);
select ok(
  exists (
    select 1 from public.webhook_deliveries
     where event_id = :'e1' and webhook_id = (:'wb'::jsonb ->> 'id')::uuid
       and attempt_no = 1 and status = 'delivering'
  ),
  'B 新增 attempt 1（delivering）'
);

select request_id as req_b2
  from public.webhook_deliveries
 where event_id = :'e1' and webhook_id = (:'wb'::jsonb ->> 'id')::uuid
   and attempt_no = 1 \gset
insert into net._http_response (id, status_code, created)
values (:'req_b2', 200, now());

select is(app.finalize_webhook_deliveries(), 1, '第二轮收口 1 条事件');
select is(
  (select status from public.integration_events where id = :'e1'),
  'done',
  'B 重试成功 → 事件 done'
);
select is(
  (select status from public.webhook_deliveries
    where event_id = :'e1' and webhook_id = (:'wb'::jsonb ->> 'id')::uuid
      and attempt_no = 1),
  'done',
  'B 第二轮 done'
);

-- ===========================================================================
-- 2. max_attempts=1 耗尽：事件 failed + audit + 通知，不再投递（8）
-- ===========================================================================
insert into public.integration_events (event, payload, status, attempts, next_retry_at)
values ('pgtap.delivery.exhaust', '{}'::jsonb, 'pending', 0, now())
returning id as e2 \gset

select is(app.process_webhook_events(), 1, '耗尽场景派发 1 条事件');

select request_id as req_c
  from public.webhook_deliveries where event_id = :'e2' \gset
insert into net._http_response (id, status_code, error_msg, created)
values (:'req_c', 500, 'Internal Server Error', now());

select is(app.finalize_webhook_deliveries(), 1, '耗尽场景收口 1 条事件');
select is(
  (select status from public.integration_events where id = :'e2'),
  'failed',
  'max_attempts=1 耗尽 → 事件 failed'
);
select is(
  (select attempts from public.integration_events where id = :'e2'),
  1,
  '事件 attempts=1（仅一轮）'
);
select ok(
  exists (
    select 1 from public.audit_operations
     where module = 'integration' and action = 'fail'
       and object_type = 'webhook_event' and object_id = :'e2'::text
  ),
  '终态失败写审计摘要'
);
select ok(
  exists (
    select 1 from public.messages
     where event_key = 'webhook.delivery_failed'
       and ref_id = (:'wc'::jsonb ->> 'id')
  ),
  '耗尽端点创建人收到通知'
);
select is(
  (select count(*) from public.messages
    where event_key = 'webhook.delivery_failed'
      and ref_id = (:'wc'::jsonb ->> 'id')),
  1::bigint,
  '耗尽通知仅一条'
);
select is(
  (select count(*) from public.webhook_deliveries where event_id = :'e2'),
  1::bigint,
  '耗尽端点不再新增投递行'
);

-- ===========================================================================
-- 3. 已 done 端点 + 耗尽端点混合：事件 failed（6）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select public.create_webhook(
  '终态 D', 'https://hooks.example.com/rd', array['pgtap.mix'],
  '{"max_attempts":1,"backoff":"linear"}'::jsonb
) as wd \gset
reset role;

insert into public.integration_events (event, payload, status, attempts, next_retry_at)
values ('pgtap.mix', '{}'::jsonb, 'pending', 0, now())
returning id as e3 \gset

select is(app.process_webhook_events(), 1, '混合场景派发 1 条事件');
select is(
  (select count(*) from public.webhook_deliveries where event_id = :'e3'),
  2::bigint,
  'A/D 各建 1 条投递'
);

select request_id as req_a3
  from public.webhook_deliveries
 where event_id = :'e3' and webhook_id = (:'wa'::jsonb ->> 'id')::uuid \gset
select request_id as req_d3
  from public.webhook_deliveries
 where event_id = :'e3' and webhook_id = (:'wd'::jsonb ->> 'id')::uuid \gset

insert into net._http_response (id, status_code, created)
values (:'req_a3', 200, now());
insert into net._http_response (id, status_code, error_msg, created)
values (:'req_d3', 500, 'Internal Server Error', now());

select is(app.finalize_webhook_deliveries(), 1, '混合场景收口 1 条事件');
select is(
  (select status from public.integration_events where id = :'e3'),
  'failed',
  'D 耗尽且 A 已 done → 事件 failed（不因 A 成功而 done）'
);
select ok(
  exists (
    select 1 from public.messages
     where event_key = 'webhook.delivery_failed'
       and ref_id = (:'wd'::jsonb ->> 'id')
  ),
  '仅耗尽端点 D 收到通知'
);
select is(
  (select count(*) from public.webhook_deliveries
    where event_id = :'e3' and webhook_id = (:'wa'::jsonb ->> 'id')::uuid),
  1::bigint,
  'A 在该事件中同样不重复投递'
);

-- ===========================================================================
-- 4. 失败端点停用：事件 done 且不通知（4）
-- ===========================================================================
insert into public.integration_events (event, payload, status, attempts, next_retry_at)
values ('pgtap.delivery.disabled', '{}'::jsonb, 'pending', 0, now())
returning id as e4 \gset

select is(app.process_webhook_events(), 1, '停用场景派发 1 条事件');

select request_id as req_e4
  from public.webhook_deliveries where event_id = :'e4' \gset

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select public.disable_webhook((:'we'::jsonb ->> 'id')::uuid) as we_disabled \gset
reset role;

insert into net._http_response (id, status_code, error_msg, created)
values (:'req_e4', 500, 'Internal Server Error', now());

select is(app.finalize_webhook_deliveries(), 1, '停用场景收口 1 条事件');
select is(
  (select status from public.integration_events where id = :'e4'),
  'done',
  '失败端点已停用且无其他可重试 → 事件 done'
);
select is(
  (select count(*) from public.messages
    where event_key = 'webhook.delivery_failed'
      and ref_id = (:'we'::jsonb ->> 'id')),
  0::bigint,
  '停用端点不发送终态失败通知'
);

select * from finish();
rollback;
