-- pgTAP：integration/005 —— webhook_deliveries + 投递器（签名/退避/队列选取/响应收口/测试投递）
-- 运行：supabase db reset && supabase test db
-- 覆盖：pg_net 扩展与 net.http_post；webhook_deliveries 结构/约束/索引/RLS；
--       函数存在性 + SECURITY/volatility/search_path + GRANT 面（worker 仅 pg_cron 可达）；
--       HMAC-SHA256 签名（已知向量 / 与 pgcrypto 一致 / 规范化）；next_retry 退避（指数/线性/上限）；
--       请求头组装（保留头不可被自定义头覆盖）；派发（active 订阅匹配、disabled 排除、无订阅终结）；
--       响应收口状态机（2xx done、非 2xx 退避、max_attempts 终态 failed + audit + 通知、超时失败、
--       重试后成功）；到期重派；test_webhook 越权拒绝与两段式结果查询（发送返回 request_id，
--       结果经 webhook_test_result 注入响应验证）；cron 注册断言；RLS（engineer 不可见 /
--       admin 可见 / anon 无路径）；表约束兜底。
-- 说明：pgTAP 事务内 net.http_post 的入队行随回滚消失，pg_net worker 不会真实出站；
--       响应收口用注入 net._http_response 行的方式模拟；真实公网投递需 webhook.site 实测。
--       夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(155);

-- ===========================================================================
-- 1. 扩展 / 表结构（30）
-- ===========================================================================
select has_extension('extensions', 'pg_net', 'pg_net 扩展已安装（extensions schema）');
select has_function('net', 'http_post',
  array['text', 'jsonb', 'jsonb', 'jsonb', 'integer'],
  'net.http_post(text,jsonb,jsonb,jsonb,integer) 存在');
select has_table('public', 'webhook_deliveries', 'webhook_deliveries 表存在');
select col_is_pk('public', 'webhook_deliveries', 'id', 'id 为主键');
select is(
  (select a.attidentity::text
     from pg_attribute a
    where a.attrelid = 'public.webhook_deliveries'::regclass and a.attname = 'id'),
  'a',
  'id 为 generated always as identity'
);
select col_type_is('public', 'webhook_deliveries', 'event_id', 'bigint', 'event_id 为 bigint');
select col_type_is('public', 'webhook_deliveries', 'webhook_id', 'uuid', 'webhook_id 为 uuid');
select col_type_is('public', 'webhook_deliveries', 'attempt_no', 'integer', 'attempt_no 为 integer');
select col_type_is('public', 'webhook_deliveries', 'request_id', 'bigint', 'request_id 为 bigint');
select col_type_is('public', 'webhook_deliveries', 'status', 'text', 'status 为 text');
select col_type_is('public', 'webhook_deliveries', 'http_status', 'integer', 'http_status 为 integer');
select col_type_is('public', 'webhook_deliveries', 'duration_ms', 'integer', 'duration_ms 为 integer');
select col_type_is('public', 'webhook_deliveries', 'error', 'text', 'error 为 text');
select is(
  (select a.atttypid::regtype::text
     from pg_attribute a
    where a.attrelid = 'public.webhook_deliveries'::regclass and a.attname = 'attempted_at'),
  'timestamp with time zone',
  'attempted_at 为 timestamptz'
);
select is(
  (select a.atttypid::regtype::text
     from pg_attribute a
    where a.attrelid = 'public.webhook_deliveries'::regclass and a.attname = 'finished_at'),
  'timestamp with time zone',
  'finished_at 为 timestamptz'
);
select col_not_null('public', 'webhook_deliveries', 'event_id', 'event_id 非空');
select col_not_null('public', 'webhook_deliveries', 'webhook_id', 'webhook_id 非空');
select col_not_null('public', 'webhook_deliveries', 'attempt_no', 'attempt_no 非空');
select col_not_null('public', 'webhook_deliveries', 'status', 'status 非空');
select col_not_null('public', 'webhook_deliveries', 'attempted_at', 'attempted_at 非空');
select col_has_default('public', 'webhook_deliveries', 'status', 'status 有默认值');
select col_has_default('public', 'webhook_deliveries', 'attempt_no', 'attempt_no 有默认值');
select col_has_default('public', 'webhook_deliveries', 'attempted_at', 'attempted_at 有默认值');
select col_has_check('public', 'webhook_deliveries', 'status', 'status 有状态机 check');
select col_has_check('public', 'webhook_deliveries', 'attempt_no', 'attempt_no 有非负 check');
select col_has_check('public', 'webhook_deliveries', 'duration_ms', 'duration_ms 有非负 check');
select is(
  (select relrowsecurity from pg_class where oid = 'public.webhook_deliveries'::regclass),
  true,
  'webhook_deliveries 已启用 RLS'
);
select has_index('public', 'webhook_deliveries', 'webhook_deliveries_pending_idx',
  'delivering 部分索引存在');
select ok(
  exists (
    select 1 from pg_constraint
     where conrelid = 'public.webhook_deliveries'::regclass
       and contype = 'f'
       and conname = 'webhook_deliveries_event_id_fkey'
  ) and exists (
    select 1 from pg_constraint
     where conrelid = 'public.webhook_deliveries'::regclass
       and contype = 'f'
       and conname = 'webhook_deliveries_webhook_id_fkey'
  ),
  'event_id/webhook_id 双外键存在'
);

-- ===========================================================================
-- 2. 函数存在性 + SECURITY/volatility/search_path（13）
-- ===========================================================================
select has_function('app', 'webhook_signature', array['text', 'jsonb'],
  'app.webhook_signature(text,jsonb) 存在');
select has_function('app', 'next_retry', array['integer'], 'app.next_retry(integer) 存在');
select has_function('app', 'next_retry', array['integer', 'text'],
  'app.next_retry(integer,text) 存在');
select has_function('app', 'webhook_request_headers', array['text', 'jsonb', 'text', 'bytea'],
  'app.webhook_request_headers 存在');
select has_function('app', 'finalize_webhook_deliveries', array[]::text[],
  'app.finalize_webhook_deliveries() 存在');
select has_function('app', 'process_webhook_events', array[]::text[],
  'app.process_webhook_events() 存在');
select has_function('app', 'test_webhook', array['uuid'], 'app.test_webhook(uuid) 存在');
select has_function('public', 'test_webhook', array['uuid'], 'public.test_webhook 薄包装存在');
select has_function('app', 'webhook_test_result', array['bigint'],
  'app.webhook_test_result(bigint) 存在');
select has_function('public', 'webhook_test_result', array['bigint'],
  'public.webhook_test_result 薄包装存在');
select ok(
  (select p.provolatile = 'i'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'webhook_signature'),
  'webhook_signature 为 immutable'
);
select ok(
  (select count(*) = 2
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'next_retry'
      and p.provolatile = 'i'),
  'next_retry 两个重载均为 immutable'
);
select ok(
  (select count(*) = 6
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
      ('app', 'webhook_signature'),
      ('app', 'next_retry'),
      ('app', 'webhook_request_headers'),
      ('app', 'finalize_webhook_deliveries'),
      ('app', 'process_webhook_events')
    )
      and not p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '纯函数/worker 均为 SECURITY INVOKER + search_path 固定为空（count=6 含 2 个重载）'
);
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'test_webhook'),
  'app.test_webhook 为 SECURITY DEFINER + search_path 固定为空'
);
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'test_webhook'),
  'public.test_webhook 为 SECURITY DEFINER + search_path 固定为空'
);
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'webhook_test_result'),
  'app.webhook_test_result 为 SECURITY DEFINER + search_path 固定为空'
);

-- ===========================================================================
-- 3. GRANT 面（14）
-- ===========================================================================
select ok(
  has_function_privilege('authenticated', 'app.test_webhook(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.test_webhook(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'app.webhook_test_result(bigint)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.webhook_test_result(bigint)', 'EXECUTE'),
  'authenticated 可执行测试投递/结果查询（函数内 admin 校验）'
);
select ok(
  not has_function_privilege('authenticated', 'app.process_webhook_events()', 'EXECUTE'),
  'authenticated 无 process_webhook_events 执行权（仅 pg_cron 可达）'
);
select ok(
  not has_function_privilege('authenticated', 'app.finalize_webhook_deliveries()', 'EXECUTE'),
  'authenticated 无 finalize_webhook_deliveries 执行权'
);
select ok(
  not has_function_privilege('authenticated', 'app.webhook_signature(text,jsonb)', 'EXECUTE'),
  'authenticated 无 webhook_signature 执行权'
);
select ok(
  not has_function_privilege('authenticated', 'app.next_retry(integer)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.next_retry(integer,text)', 'EXECUTE'),
  'authenticated 无 next_retry 执行权'
);
select ok(
  not has_function_privilege('authenticated', 'app.webhook_request_headers(text,jsonb,text,bytea)', 'EXECUTE'),
  'authenticated 无 webhook_request_headers 执行权'
);
select ok(
  not has_function_privilege('anon', 'app.test_webhook(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.test_webhook(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'app.webhook_test_result(bigint)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.webhook_test_result(bigint)', 'EXECUTE'),
  'anon 无测试投递/结果查询执行权'
);
select ok(
  not has_function_privilege('service_role', 'app.process_webhook_events()', 'EXECUTE')
  and not has_function_privilege('service_role', 'app.finalize_webhook_deliveries()', 'EXECUTE'),
  'service_role 无 worker 执行权（ADR-001）'
);
select ok(
  has_table_privilege('authenticated', 'public.webhook_deliveries', 'SELECT'),
  'authenticated 有 webhook_deliveries SELECT（RLS 再收口 admin）'
);
select ok(
  not has_table_privilege('authenticated', 'public.webhook_deliveries', 'INSERT')
  and not has_table_privilege('authenticated', 'public.webhook_deliveries', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.webhook_deliveries', 'DELETE'),
  'authenticated 对 webhook_deliveries 无表级写'
);
select ok(
  not has_table_privilege('anon', 'public.webhook_deliveries', 'SELECT'),
  'anon 无 webhook_deliveries SELECT'
);
select ok(
  not has_sequence_privilege('authenticated', 'public.webhook_deliveries_id_seq', 'USAGE')
  and not has_sequence_privilege('anon', 'public.webhook_deliveries_id_seq', 'USAGE'),
  'identity 序列不暴露给 API 角色'
);
select ok(
  not has_function_privilege('anon', 'app.emit_event(text,jsonb)', 'EXECUTE'),
  'anon 仍无 emit_event 执行权（integration/004 契约不变）'
);
select ok(
  has_function_privilege('authenticated', 'public.disable_webhook(uuid)', 'EXECUTE'),
  '既有 webhook 管理票不受影响（sanity）'
);

-- ===========================================================================
-- 4. HMAC 签名：已知向量 / pgcrypto 一致 / 规范化（7）
-- ===========================================================================
select is(
  app.webhook_signature('secret', '{"a": 1}'::jsonb),
  '9efa14a18410a57a432fbf0ce38d4bc33339036a64e57b8c86da0bb1e122d972',
  'HMAC-SHA256 已知向量匹配（jsonb 规范化文本 {"a": 1}）'
);
select is(
  app.webhook_signature('secret', '{"a": 1}'::jsonb),
  encode(extensions.hmac(('{"a": 1}'::jsonb)::text, 'secret', 'sha256'), 'hex'),
  '签名与 pgcrypto hmac 独立计算结果一致'
);
select ok(
  app.webhook_signature('secret', '{"a": 1}'::jsonb) ~ '^[0-9a-f]{64}$',
  '签名为 64 位十六进制'
);
select ok(
  app.webhook_signature('secret', '{"a": 1}'::jsonb)
    <> app.webhook_signature('other-secret', '{"a": 1}'::jsonb),
  '不同 secret 签名不同'
);
select ok(
  app.webhook_signature('secret', '{"a": 1}'::jsonb)
    <> app.webhook_signature('secret', '{"a": 2}'::jsonb),
  '不同 payload 签名不同'
);
select is(
  app.webhook_signature('secret', '{"b": 2, "a": 1}'::jsonb),
  app.webhook_signature('secret', '{"a": 1, "b": 2}'::jsonb),
  'jsonb 规范化后键序不影响签名（与发送字节一致的前提）'
);
select is(
  app.webhook_signature('secret', '{"a": 1}'::jsonb),
  app.webhook_signature('secret', '{"a": 1}'::jsonb),
  '同输入签名稳定'
);

-- ===========================================================================
-- 5. next_retry：指数退避 / 线性 / 上限（10）
-- ===========================================================================
select is(app.next_retry(0), interval '1 minute', 'next_retry(0)=1 分钟（2^0）');
select is(app.next_retry(1), interval '2 minutes', 'next_retry(1)=2 分钟（2^1）');
select is(app.next_retry(2), interval '4 minutes', 'next_retry(2)=4 分钟（2^2）');
select is(app.next_retry(3), interval '8 minutes', 'next_retry(3)=8 分钟（2^3）');
select is(app.next_retry(5), interval '32 minutes', 'next_retry(5)=32 分钟（2^5）');
select is(app.next_retry(20), interval '60 minutes', 'next_retry 上限 60 分钟');
select is(app.next_retry(-1), interval '1 minute', '负数按 0 处理');
select is(app.next_retry(3, 'linear'), interval '3 minutes', 'linear 退避 = n 分钟');
select is(app.next_retry(3, 'exponential'), interval '8 minutes', 'exponential 走指数');
select is(app.next_retry(3, null), interval '8 minutes', 'backoff 为 NULL 时默认指数');

-- ===========================================================================
-- 6. webhook_request_headers：保留头不可被自定义头覆盖（夹具同段创建）（5）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.create_webhook(
  '投递 A', 'https://hooks.example.com/a', array['approval.approved'],
  null,
  '{"Authorization":"Bearer abcdefgh","X-Webhook-Signature":"forged","Content-Type":"text/plain"}'::jsonb
) as w1 \gset

select public.create_webhook(
  '投递 B', 'https://hooks.example.com/b',
  array['approval.approved', 'sync.run_finished', 'manual.retry', 'manual.retry2']
) as w2 \gset

select public.create_webhook(
  '停用 C', 'https://hooks.example.com/c', array['approval.approved']
) as w3 \gset

select public.create_webhook(
  '终态 D', 'https://hooks.example.com/d', array['manual.only'],
  '{"max_attempts":1,"backoff":"linear"}'::jsonb
) as w4 \gset

select public.disable_webhook((:'w3'::jsonb ->> 'id')::uuid) as w3d \gset

reset role;

select app.webhook_request_headers(
  'sec', '{"event":"ping"}'::jsonb, 'ping',
  (select headers_enc from public.webhooks where id = (:'w1'::jsonb ->> 'id')::uuid)
) as hdr \gset

select app.webhook_request_headers('sec', '{"a":1}'::jsonb, 'evt', null) as hdr0 \gset

select is((:'hdr'::jsonb) ->> 'Content-Type', 'application/json',
  'Content-Type 固定 application/json（自定义 text/plain 被剔除）');
select is((:'hdr'::jsonb) ->> 'x-webhook-event', 'ping', 'x-webhook-event 为事件名');
select is(
  (:'hdr'::jsonb) ->> 'x-webhook-signature',
  app.webhook_signature('sec', '{"event":"ping"}'::jsonb),
  'x-webhook-signature 由保留头重算（forged 被覆盖）'
);
select is((:'hdr'::jsonb) ->> 'Authorization', 'Bearer abcdefgh',
  '非保留自定义头（Authorization）保留');
select is(
  (select count(*) from jsonb_object_keys(:'hdr'::jsonb))::int,
  4,
  '合并后恰为 4 个头（Authorization + 3 个保留头）'
);

-- ===========================================================================
-- 7. 派发：队列选取 + active 匹配 + disabled 排除 + 无订阅终结（12）
-- ===========================================================================
select is(app.emit_event('approval.approved', '{"k":"v"}'::jsonb), 2,
  'approval.approved 匹配 2 个 active 端点（B + 停用前 C 已停用）');
select is(app.emit_event('orphan.event', '{}'::jsonb), 0, '无订阅事件匹配 0');
select is(app.process_webhook_events(), 2, 'process 派发 2 条到期事件');
select is(
  (select status from public.integration_events where event = 'approval.approved'),
  'delivering',
  '匹配到端点的事件进入 delivering'
);
select is(
  (select status from public.integration_events where event = 'orphan.event'),
  'done',
  '无 active 订阅的事件直接 done（不永久 pending）'
);
select is(
  (select count(*)
     from public.webhook_deliveries d
     join public.integration_events e on e.id = d.event_id
    where e.event = 'approval.approved'),
  2::bigint,
  'approval.approved 生成 2 条投递明细（A/B）'
);
select is(
  (select count(*)
     from public.webhook_deliveries d
     join public.integration_events e on e.id = d.event_id
    where e.event = 'orphan.event'),
  0::bigint,
  '无订阅事件不生成投递明细'
);
select ok(
  (select bool_and(d.status = 'delivering')
     from public.webhook_deliveries d
     join public.integration_events e on e.id = d.event_id
    where e.event = 'approval.approved'),
  '派发后明细均为 delivering'
);
select ok(
  (select bool_and(d.request_id is not null)
     from public.webhook_deliveries d
     join public.integration_events e on e.id = d.event_id
    where e.event = 'approval.approved'),
  '每条明细记录 pg_net request_id'
);
select ok(
  (select bool_and(d.attempt_no = 0)
     from public.webhook_deliveries d
     join public.integration_events e on e.id = d.event_id
    where e.event = 'approval.approved'),
  '首次派发 attempt_no=0'
);
select ok(
  not exists (select 1 from public.webhook_deliveries d where d.webhook_id = (:'w3'::jsonb ->> 'id')::uuid),
  '停用端点（C）不产生投递'
);
select ok(
  not exists (
    select 1
    from public.webhook_deliveries d
    where d.webhook_id = (:'w4'::jsonb ->> 'id')::uuid
      and d.event_id = (select id from public.integration_events where event = 'approval.approved')
  ),
  '未订阅该事件的 active 端点（D）不产生投递'
);

-- ===========================================================================
-- 8. 收口状态机：2xx done / 非 2xx 退避 / 终态 failed + audit + 通知 / 超时（23）
-- ===========================================================================
insert into public.integration_events (event, payload, status, attempts)
values ('manual.ok', '{}'::jsonb, 'delivering', 0)
returning id as e_ok \gset

insert into public.webhook_deliveries
  (event_id, webhook_id, attempt_no, request_id, status, attempted_at)
values
  (:'e_ok', (:'w1'::jsonb ->> 'id')::uuid, 0, 921000000000000001, 'delivering', now() - interval '2 seconds');

insert into net._http_response (id, status_code, created)
values (921000000000000001, 201, now());

insert into public.integration_events (event, payload, status, attempts)
values ('manual.retry', '{}'::jsonb, 'delivering', 0)
returning id as e_retry \gset

insert into public.webhook_deliveries
  (event_id, webhook_id, attempt_no, request_id, status, attempted_at)
values
  (:'e_retry', (:'w2'::jsonb ->> 'id')::uuid, 0, 921000000000000002, 'delivering', now() - interval '2 seconds');

insert into net._http_response (id, status_code, error_msg, created)
values (921000000000000002, 503, 'Service Unavailable', now());

insert into public.integration_events (event, payload, status, attempts)
values ('manual.fail', '{}'::jsonb, 'delivering', 0)
returning id as e_fail \gset

insert into public.webhook_deliveries
  (event_id, webhook_id, attempt_no, request_id, status, attempted_at)
values
  (:'e_fail', (:'w4'::jsonb ->> 'id')::uuid, 0, 921000000000000003, 'delivering', now() - interval '2 seconds');

insert into net._http_response (id, status_code, error_msg, created)
values (921000000000000003, 500, 'Internal Server Error', now());

insert into public.integration_events (event, payload, status, attempts)
values ('manual.stale', '{}'::jsonb, 'delivering', 0)
returning id as e_stale \gset

insert into public.webhook_deliveries
  (event_id, webhook_id, attempt_no, request_id, status, attempted_at)
values
  (:'e_stale', (:'w1'::jsonb ->> 'id')::uuid, 0, 921000000000000004, 'delivering', now() - interval '11 minutes');

select is(app.finalize_webhook_deliveries(), 4, 'finalize 收口 4 条事件');

select is(
  (select status from public.integration_events where event = 'manual.ok'),
  'done',
  '2xx：事件 done'
);
select is(
  (select status from public.webhook_deliveries where request_id = 921000000000000001),
  'done',
  '2xx：明细 done'
);
select is(
  (select http_status from public.webhook_deliveries where request_id = 921000000000000001),
  201,
  '2xx：记录 http_status=201'
);
select is(
  (select error from public.webhook_deliveries where request_id = 921000000000000001),
  null::text,
  '2xx：error 为空'
);
select ok(
  (select duration_ms is not null and finished_at is not null
     from public.webhook_deliveries where request_id = 921000000000000001),
  '2xx：记录耗时与收口时间'
);
select is(
  (select status from public.integration_events where event = 'manual.retry'),
  'pending',
  '非 2xx：事件回到 pending 等待重试'
);
select is(
  (select attempts from public.integration_events where event = 'manual.retry'),
  1,
  '非 2xx：attempts 递增为 1'
);
select ok(
  (select next_retry_at between now() + interval '1 minute' and now() + interval '3 minutes'
     from public.integration_events where event = 'manual.retry'),
  '非 2xx：首次退避约 2 分钟（2^1）'
);
select is(
  (select status from public.webhook_deliveries where request_id = 921000000000000002),
  'failed',
  '非 2xx：明细 failed'
);
select is(
  (select http_status from public.webhook_deliveries where request_id = 921000000000000002),
  503,
  '非 2xx：记录 http_status=503'
);
select is(
  (select error from public.webhook_deliveries where request_id = 921000000000000002),
  'Service Unavailable',
  '非 2xx：记录响应错误信息'
);
select is(
  (select status from public.integration_events where event = 'manual.fail'),
  'failed',
  '达 max_attempts：事件终态 failed'
);
select is(
  (select attempts from public.integration_events where event = 'manual.fail'),
  1,
  '达 max_attempts：attempts=1（max=1）'
);
select is(
  (select http_status from public.webhook_deliveries where request_id = 921000000000000003),
  500,
  '失败明细记录 http_status=500'
);
select ok(
  exists (
    select 1 from public.audit_operations
     where module = 'integration' and action = 'fail'
       and object_type = 'webhook_event'
       and object_id = (select id::text from public.integration_events where event = 'manual.fail')
  ),
  '终态失败写审计摘要（fail/webhook_event）'
);
select is(
  (select diff ->> 'event' from public.audit_operations
    where module = 'integration' and action = 'fail'
      and object_id = (select id::text from public.integration_events where event = 'manual.fail')),
  'manual.fail',
  '审计摘要含事件名'
);
select ok(
  exists (
    select 1 from public.messages
     where recipient_id = '11111111-1111-1111-1111-111111111111'
       and event_key = 'webhook.delivery_failed'
       and ref_id = (:'w4'::jsonb ->> 'id')
  ),
  '终态失败通知端点创建人（webhook.delivery_failed）'
);
select ok(
  (select position('manual.fail' in body) > 0
     from public.messages
    where event_key = 'webhook.delivery_failed'
      and ref_id = (:'w4'::jsonb ->> 'id')),
  '通知正文含事件名'
);
select is(
  (select status from public.integration_events where event = 'manual.stale'),
  'pending',
  '超时：事件按失败退避（pending）'
);
select is(
  (select attempts from public.integration_events where event = 'manual.stale'),
  1,
  '超时：attempts 递增为 1'
);
select ok(
  (select error like '投递超时%' and http_status is null
     from public.webhook_deliveries where request_id = 921000000000000004),
  '超时：明细 failed 且标记投递超时'
);
select is(
  (select count(*) from public.messages where event_key = 'webhook.delivery_failed'),
  1::bigint,
  '仅终态失败才通知（退避事件不通知）'
);

-- ===========================================================================
-- 9. 重试后成功：最新一轮成功即事件 done（5）
-- ===========================================================================
insert into public.integration_events (event, payload, status, attempts)
values ('manual.retry2', '{}'::jsonb, 'delivering', 1)
returning id as e_r2 \gset

insert into public.webhook_deliveries
  (event_id, webhook_id, attempt_no, request_id, status, attempted_at, http_status, error, finished_at)
values
  (:'e_r2', (:'w2'::jsonb ->> 'id')::uuid, 0, 921000000000000005, 'failed',
   now() - interval '5 minutes', 500, 'Internal Server Error', now() - interval '5 minutes');

insert into public.webhook_deliveries
  (event_id, webhook_id, attempt_no, request_id, status, attempted_at)
values
  (:'e_r2', (:'w2'::jsonb ->> 'id')::uuid, 1, 921000000000000006, 'delivering', now() - interval '2 seconds');

insert into net._http_response (id, status_code, created)
values (921000000000000006, 200, now());

select is(app.finalize_webhook_deliveries(), 1, 'finalize 收口重试后成功的事件');

select is(
  (select status from public.integration_events where event = 'manual.retry2'),
  'done',
  '最新一轮 2xx：事件 done（旧轮次失败不阻塞）'
);
select is(
  (select status from public.webhook_deliveries
    where event_id = :'e_r2' and attempt_no = 1),
  'done',
  '最新一轮明细 done'
);
select is(
  (select status from public.webhook_deliveries
    where event_id = :'e_r2' and attempt_no = 0),
  'failed',
  '旧轮次明细保留 failed（历史留痕）'
);
select is(
  (select attempts from public.integration_events where event = 'manual.retry2'),
  1,
  '事件 attempts 保持派发次数'
);

-- ===========================================================================
-- 10. 到期重派：pending 事件按 next_retry_at 再派发（5）
-- ===========================================================================
update public.integration_events
   set next_retry_at = now() - interval '1 minute'
 where event = 'manual.retry';

select is(app.process_webhook_events(), 1, '到期后 process 重派 1 条事件');

select is(
  (select status from public.integration_events where event = 'manual.retry'),
  'delivering',
  '重派后事件回到 delivering'
);
select is(
  (select count(*) from public.webhook_deliveries d
    join public.integration_events e on e.id = d.event_id
   where e.event = 'manual.retry'),
  2::bigint,
  '重派新增一条投递明细（共 2 条）'
);
select ok(
  exists (
    select 1
    from public.webhook_deliveries d
    join public.integration_events e on e.id = d.event_id
    where e.event = 'manual.retry'
      and d.attempt_no = 1
      and d.status = 'delivering'
  ),
  '新明细 attempt_no=1 且 delivering'
);
select is(
  (select attempt_no from public.webhook_deliveries
    where status = 'delivering'
      and event_id = (select id from public.integration_events where event = 'manual.retry')),
  1,
  '新明细 attempt_no 与事件 attempts 对齐'
);

-- ===========================================================================
-- 11. test_webhook / webhook_test_result：越权拒绝 + 两段式结果（19）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  format('select app.test_webhook(%L::uuid)', (:'w1'::jsonb ->> 'id')),
  '42501', null, 'engineer 调 app.test_webhook 被 admin 校验拒绝'
);
select throws_ok(
  $$ select app.webhook_test_result(1) $$,
  '42501', null, 'engineer 查测试投递结果被拒'
);
select throws_ok(
  format('select public.test_webhook(%L::uuid)', (:'w1'::jsonb ->> 'id')),
  '42501', null, 'engineer 调 public.test_webhook 被拒'
);

reset role;
set local role anon;

select throws_ok(
  format('select public.test_webhook(%L::uuid)', (:'w1'::jsonb ->> 'id')),
  '42501', null, 'anon 调 test_webhook 被拒（无 GRANT）'
);
select throws_ok(
  $$ select public.webhook_test_result(1) $$,
  '42501', null, 'anon 查测试投递结果被拒（无 GRANT）'
);

reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.test_webhook((:'w1'::jsonb ->> 'id')::uuid) as ping1 \gset

select throws_ok(
  $$ select app.test_webhook('00000000-0000-0000-0000-000000000000'::uuid) $$,
  'P0002', null, '不存在的 webhook 测试投递报 P0002'
);
select throws_ok(
  $$ select app.test_webhook(null) $$,
  '22023', null, 'NULL webhook id 报 22023'
);
select throws_ok(
  $$ select app.webhook_test_result(null) $$,
  '22023', null, 'NULL request_id 报 22023'
);

reset role;

-- 两段式：发送返回 request_id；先无响应，注入响应行后可查结果
select app.webhook_test_result((:'ping1'::jsonb ->> 'request_id')::bigint) as res0 \gset

insert into net._http_response (id, status_code, content_type, content, created)
values (
  (:'ping1'::jsonb ->> 'request_id')::bigint,
  200, 'application/json', '{"ok":true}', now()
);

select app.webhook_test_result((:'ping1'::jsonb ->> 'request_id')::bigint) as res1 \gset

select is((:'ping1'::jsonb) ->> 'queued', 'true', '测试投递返回 queued=true（异步）');
select ok((:'ping1'::jsonb) ->> 'request_id' is not null, '测试投递返回 request_id');
select is(
  (:'ping1'::jsonb) ->> 'url',
  (select url from public.webhooks where id = (:'w1'::jsonb ->> 'id')::uuid),
  '测试投递返回目标 URL'
);
select is((:'res0'::jsonb) ->> 'responded', 'false', '响应未到时结果 responded=false');
select is((:'res0'::jsonb) ->> 'pending', 'true', '响应未到时结果 pending=true');
select is((:'res1'::jsonb) ->> 'responded', 'true', '响应到达后结果 responded=true');
select is((:'res1'::jsonb) ->> 'ok', 'true', '2xx 响应 ok=true');
select is((:'res1'::jsonb) ->> 'http_status', '200', '结果返回 http_status=200');
select is((:'res1'::jsonb) ->> 'pending', 'false', '响应到达后 pending=false');
select ok((:'res1'::jsonb) ->> 'content' like '%ok%', '结果回传响应内容（截断）');
select ok(
  exists (
    select 1 from public.audit_operations
     where module = 'integration' and action = 'test'
       and object_type = 'webhook'
       and object_id = (:'w1'::jsonb ->> 'id')
  ),
  '测试投递写审计摘要（test/webhook）'
);

-- ===========================================================================
-- 12. pg_cron 注册（2）
-- ===========================================================================
select ok(
  exists (
    select 1 from cron.job
     where jobname = 'process-webhook-events'
       and schedule = '* * * * *'
       and command like '%app.process_webhook_events%'
  ),
  'cron job process-webhook-events 每分钟注册'
);
select is(
  (select count(*) from cron.job where jobname = 'process-webhook-events'),
  1::bigint,
  'cron job 名称唯一'
);

-- ===========================================================================
-- 13. RLS：engineer 不可见 / anon 无路径 / admin 可见（3）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;

select is(
  (select count(*) from public.webhook_deliveries),
  0::bigint,
  'engineer 读取投递明细 0 行'
);

reset role;
set local role anon;

select throws_ok(
  $$ select * from public.webhook_deliveries $$,
  '42501', null, 'anon 直查投递明细被拒（无 GRANT）'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select ok(
  (select count(*) from public.webhook_deliveries) >= 9,
  'admin 通过 RLS 可见全部投递明细（≥9）'
);

reset role;

-- ===========================================================================
-- 14. 表约束兜底（5）
-- ===========================================================================
select throws_ok(
  format(
    'insert into public.webhook_deliveries (event_id, webhook_id, status)
     values ((select id from public.integration_events where event = %L), %L::uuid, %L)',
    'manual.ok', (:'w1'::jsonb ->> 'id'), 'weird'
  ),
  '23514', null, 'status 非法取值被 check 拒绝'
);
select throws_ok(
  format(
    'insert into public.webhook_deliveries (event_id, webhook_id, attempt_no)
     values ((select id from public.integration_events where event = %L), %L::uuid, -1)',
    'manual.ok', (:'w1'::jsonb ->> 'id')
  ),
  '23514', null, 'attempt_no 负数被 check 拒绝'
);
select throws_ok(
  format(
    'insert into public.webhook_deliveries (event_id, webhook_id, duration_ms)
     values ((select id from public.integration_events where event = %L), %L::uuid, -5)',
    'manual.ok', (:'w1'::jsonb ->> 'id')
  ),
  '23514', null, 'duration_ms 负数被 check 拒绝'
);
select throws_ok(
  $$ insert into public.webhook_deliveries (event_id, webhook_id)
     values ((select id from public.integration_events where event = 'manual.ok'), gen_random_uuid()) $$,
  '23503', null, '未知 webhook_id 被外键拒绝'
);
select throws_ok(
  $$ insert into public.webhook_deliveries (event_id, webhook_id)
     values (999999999, (select id from public.webhooks limit 1)) $$,
  '23503', null, '未知 event_id 被外键拒绝'
);

select * from finish();
rollback;
