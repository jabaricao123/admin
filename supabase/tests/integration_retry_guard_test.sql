-- pgTAP：integration 批次 1 —— retry_policy 防御（防全管线停滞）+ SSRF 内网校验
-- 运行：supabase db reset && supabase test db
-- 覆盖：
--   1. SSRF：create_webhook 拒绝私网/环回/link-local IP literal、localhost/*.local/*.internal、
--      userinfo、超长 URL、header CR/LF；公网域名（含端口/路径）通过；
--   2. retry_policy：max_attempts 非整数/越界（0、11、1.5）、backoff 非法、非对象被拒；
--      合法值（1..10 + linear/exponential）通过；
--   3. update_webhook 同样拒绝非法 retry_policy 与内网 URL；
--   4. finalize_webhook_deliveries 对直接 SQL 插入的非法存量 max_attempts（字符串/超大数/负数）
--      不再抛错（regex 预检 + 兜底默认 3），其他事件正常收口；
--   5. 单事件异常隔离：毒事件（attempt_no 上限 +1 溢出）被置 failed，其他事件继续收口，
--      整个收口事务不被回滚（防全管线停滞）。
-- 说明：夹具只在本事务内生效，finish 后 rollback；直接 SQL 插入绕过 RPC 模拟存量脏数据。

begin;

select plan(45);

-- ===========================================================================
-- 1. 函数存在性与属性（3）
-- ===========================================================================
select has_function('app', 'is_forbidden_webhook_host', array['text'],
  'app.is_forbidden_webhook_host(text) 存在');
select ok(
  (select p.provolatile = 'i' and p.proconfig @> array['search_path=""']
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'is_forbidden_webhook_host'),
  'SSRF 主机判定为 immutable + search_path 空'
);
select has_function('app', 'validate_webhook_fields', array['text', 'text', 'text[]', 'jsonb', 'jsonb'],
  'validate_webhook_fields 强化后仍存在（签名不变）');

-- ===========================================================================
-- 2. SSRF：create_webhook 主机校验（17）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$ select public.create_webhook('环回', 'https://127.0.0.1:9/hook', array['x']) $$,
  '22023', null, '拒绝 127.0.0.1（环回）'
);
select throws_ok(
  $$ select public.create_webhook('元数据', 'https://169.254.169.254/latest', array['x']) $$,
  '22023', null, '拒绝 169.254.169.254（云元数据/link-local）'
);
select throws_ok(
  $$ select public.create_webhook('私网', 'https://192.168.1.1', array['x']) $$,
  '22023', null, '拒绝 192.168.1.1（私网）'
);
select throws_ok(
  $$ select public.create_webhook('私网10', 'https://10.1.2.3', array['x']) $$,
  '22023', null, '拒绝 10.1.2.3（私网）'
);
select throws_ok(
  $$ select public.create_webhook('私网172', 'https://172.16.5.5', array['x']) $$,
  '22023', null, '拒绝 172.16.5.5（私网）'
);
select throws_ok(
  $$ select public.create_webhook('IPv6环回', 'https://[::1]:9', array['x']) $$,
  '22023', null, '拒绝 [::1]（IPv6 环回）'
);
select throws_ok(
  $$ select public.create_webhook('localhost', 'https://localhost/hook', array['x']) $$,
  '22023', null, '拒绝 localhost'
);
select throws_ok(
  $$ select public.create_webhook('local', 'https://foo.local/hook', array['x']) $$,
  '22023', null, '拒绝 *.local'
);
select throws_ok(
  $$ select public.create_webhook('internal', 'https://foo.internal/hook', array['x']) $$,
  '22023', null, '拒绝 *.internal'
);
select throws_ok(
  $$ select public.create_webhook('userinfo', 'https://user:pass@example.com/hook', array['x']) $$,
  '22023', null, '拒绝 userinfo（user@host）'
);
select throws_ok(
  $$ select public.create_webhook('超长', 'https://example.com/' || repeat('a', 500), array['x']) $$,
  '22023', null, '拒绝超过 500 字符的 URL'
);
select throws_ok(
  $$ select public.create_webhook('换行头', 'https://example.com/h', array['x'], null,
       jsonb_build_object('X-Test', E'v\nInjected: 1')) $$,
  '22023', null, '拒绝 header 值含换行（CRLF 注入）'
);
select throws_ok(
  $$ select public.create_webhook('回车头名', 'https://example.com/h', array['x'], null,
       jsonb_build_object(E'X-Test\r', 'v')) $$,
  '22023', null, '拒绝 header 名含回车'
);
select throws_ok(
  $$ select public.create_webhook('非https', 'http://example.com/h', array['x']) $$,
  '22023', null, '非 https 仍被拒（既有约束不变）'
);

select public.create_webhook('公网 A', 'https://example.com/hook', array['ssrf.a']) as s1 \gset
select public.create_webhook('公网端口', 'https://example.com:8443/hook', array['ssrf.b']) as s2 \gset
select public.create_webhook('公网路径', 'https://hooks.example.com/path?x=1&y=2', array['ssrf.c']) as s3 \gset

select ok((:'s1'::jsonb) ? 'id', '公网域名通过（example.com）');
select ok((:'s2'::jsonb) ? 'id', '公网域名带端口通过（example.com:8443）');
select ok((:'s3'::jsonb) ? 'id', '公网域名带路径/查询串通过');

-- ===========================================================================
-- 3. retry_policy：create_webhook 校验（9）
-- ===========================================================================
select throws_ok(
  $$ select public.create_webhook('策略串', 'https://example.com/h', array['x'],
       '{"max_attempts":"3"}'::jsonb) $$,
  '22023', null, 'max_attempts 为字符串被拒'
);
select throws_ok(
  $$ select public.create_webhook('策略零', 'https://example.com/h', array['x'],
       '{"max_attempts":0}'::jsonb) $$,
  '22023', null, 'max_attempts=0 被拒（下界 1）'
);
select throws_ok(
  $$ select public.create_webhook('策略超界', 'https://example.com/h', array['x'],
       '{"max_attempts":11}'::jsonb) $$,
  '22023', null, 'max_attempts=11 被拒（上界 10）'
);
select throws_ok(
  $$ select public.create_webhook('策略小数', 'https://example.com/h', array['x'],
       '{"max_attempts":1.5}'::jsonb) $$,
  '22023', null, 'max_attempts=1.5 被拒（必须整数）'
);
select throws_ok(
  $$ select public.create_webhook('策略退避', 'https://example.com/h', array['x'],
       '{"backoff":"quadratic"}'::jsonb) $$,
  '22023', null, 'backoff=quadratic 被拒（仅 linear/exponential）'
);
select throws_ok(
  $$ select public.create_webhook('策略非对象', 'https://example.com/h', array['x'],
       '[1,2]'::jsonb) $$,
  '22023', null, 'retry_policy 非对象被拒'
);

select public.create_webhook('策略合法', 'https://example.com/h', array['x'],
  '{"max_attempts":5,"backoff":"linear"}'::jsonb) as p1 \gset
select public.create_webhook('策略边界', 'https://example.com/h', array['x'],
  '{"max_attempts":10,"backoff":"exponential"}'::jsonb) as p2 \gset
select public.create_webhook('策略缺省键', 'https://example.com/h', array['x'], '{}'::jsonb) as p3 \gset

select is((:'p1'::jsonb) -> 'retry_policy', '{"max_attempts":5,"backoff":"linear"}'::jsonb,
  '合法策略（5/linear）原样落库');
select ok((:'p2'::jsonb) ? 'id', '边界策略（10/exponential）通过');
select ok((:'p3'::jsonb) ? 'id', '缺省键的对象通过（finalize 兜底默认）');

-- ===========================================================================
-- 4. update_webhook：同样拒绝非法策略与内网 URL（2）
-- ===========================================================================
select throws_ok(
  format(
    'select public.update_webhook(%L::uuid, %L, %L, %L, %L)',
    (:'s1'::jsonb ->> 'id'), 'x', 'https://example.com/hook2', array['ssrf.a'],
    '{"max_attempts":0}'::jsonb
  ),
  '22023', null, 'update 拒绝非法 max_attempts'
);
select throws_ok(
  format(
    'select public.update_webhook(%L::uuid, %L, %L, %L)',
    (:'s1'::jsonb ->> 'id'), 'x', 'https://127.0.0.1:9/hook', array['ssrf.a']
  ),
  '22023', null, 'update 拒绝内网 URL（SSRF）'
);

reset role;

-- ===========================================================================
-- 5. finalize 安全解析：存量非法 max_attempts 不阻塞，其他事件正常收口（6）
-- ===========================================================================
insert into public.webhooks (name, url, secret_enc, events, retry_policy)
values ('脏策略端点', 'https://hooks.example.com/bad', app.encrypt_secret('s'),
        array['pgtap.bad'], '{"max_attempts":"abc","backoff":"weird"}'::jsonb)
returning id as wa \gset

insert into public.webhooks (name, url, secret_enc, events, retry_policy)
values ('正常端点', 'https://hooks.example.com/ok', app.encrypt_secret('s'),
        array['pgtap.ok'], '{"max_attempts":1,"backoff":"linear"}'::jsonb)
returning id as wb \gset

insert into public.integration_events (event, payload, status, attempts)
values ('pgtap.bad', '{}'::jsonb, 'delivering', 0)
returning id as e_bad \gset

insert into public.webhook_deliveries
  (event_id, webhook_id, attempt_no, status, attempted_at, http_status, error, finished_at)
values
  (:'e_bad', :'wa', 0, 'failed', now() - interval '1 minute', 500, 'boom', now() - interval '1 minute');

insert into public.integration_events (event, payload, status, attempts)
values ('pgtap.ok', '{}'::jsonb, 'delivering', 0)
returning id as e_ok \gset

insert into public.webhook_deliveries
  (event_id, webhook_id, attempt_no, status, attempted_at, http_status, error, finished_at)
values
  (:'e_ok', :'wb', 0, 'failed', now() - interval '1 minute', 500, 'boom', now() - interval '1 minute');

select ok(app.finalize_webhook_deliveries() >= 2,
  '非法存量 max_attempts 不抛错，脏事件与正常事件均被收口');

select is(
  (select status from public.integration_events where id = :'e_bad'),
  'pending',
  '脏策略事件按兜底默认 3 退避（pending，不再中止整个收口）'
);
select is(
  (select attempts from public.integration_events where id = :'e_bad'),
  1,
  '脏策略事件 attempts 递增为 1（第一次收口）'
);
select is(
  (select status from public.integration_events where id = :'e_ok'),
  'failed',
  '正常事件按自己策略正常收口（max=1 终态 failed）'
);
select is(
  (select attempts from public.integration_events where id = :'e_ok'),
  1,
  '正常事件 attempts=1'
);
select is(
  (select status from public.webhook_deliveries where event_id = :'e_bad'),
  'failed',
  '脏策略事件的投递明细保持 failed（不二次改写）'
);

-- ===========================================================================
-- 6. finalize 安全解析：超大数/负数兜底为 3（4）
-- ===========================================================================
insert into public.webhooks (name, url, secret_enc, events, retry_policy)
values ('超大策略', 'https://hooks.example.com/huge', app.encrypt_secret('s'),
        array['pgtap.huge'], '{"max_attempts":"999999999999999999999999999"}'::jsonb)
returning id as wc \gset

insert into public.integration_events (event, payload, status, attempts)
values ('pgtap.huge', '{}'::jsonb, 'delivering', 0)
returning id as e_huge \gset

insert into public.webhook_deliveries
  (event_id, webhook_id, attempt_no, status, attempted_at, http_status, error, finished_at)
values
  (:'e_huge', :'wc', 0, 'failed', now() - interval '1 minute', 500, 'boom', now() - interval '1 minute');

insert into public.webhooks (name, url, secret_enc, events, retry_policy)
values ('负数策略', 'https://hooks.example.com/neg', app.encrypt_secret('s'),
        array['pgtap.neg'], '{"max_attempts":-5}'::jsonb)
returning id as wd \gset

insert into public.integration_events (event, payload, status, attempts)
values ('pgtap.neg', '{}'::jsonb, 'delivering', 0)
returning id as e_neg \gset

insert into public.webhook_deliveries
  (event_id, webhook_id, attempt_no, status, attempted_at, http_status, error, finished_at)
values
  (:'e_neg', :'wd', 0, 'failed', now() - interval '1 minute', 500, 'boom', now() - interval '1 minute');

select app.finalize_webhook_deliveries() as fin2 \gset

select ok(:'fin2'::integer >= 2, '超大数/负数策略事件均被收口（不抛错）');
select is(
  (select status from public.integration_events where id = :'e_huge'),
  'pending',
  '超大数 max_attempts 按兜底默认 3（pending）'
);
select is(
  (select status from public.integration_events where id = :'e_neg'),
  'pending',
  '负数 max_attempts 按兜底默认 3（pending）'
);
select is(
  (select attempts from public.integration_events where id = :'e_huge'),
  1,
  '超大数事件 attempts 递增为 1'
);

-- ===========================================================================
-- 7. finalize 单事件异常隔离：毒事件置 failed，其余事件继续收口（4）
-- ===========================================================================
insert into public.integration_events (event, payload, status, attempts)
values ('pgtap.poison', '{}'::jsonb, 'delivering', 2147483647)
returning id as e_poison \gset

-- attempt_no 取 integer 上限：v_done := v_attempt + 1 必然溢出（模拟不可解析的毒数据，
-- 触发单事件 exception 分支）
insert into public.webhook_deliveries
  (event_id, webhook_id, attempt_no, status, attempted_at, http_status, error, finished_at)
values
  (:'e_poison', :'wb', 2147483647, 'failed', now() - interval '1 minute', 500, 'poison', now() - interval '1 minute');

insert into public.integration_events (event, payload, status, attempts)
values ('pgtap.normal', '{}'::jsonb, 'delivering', 0)
returning id as e_normal \gset

insert into public.webhook_deliveries
  (event_id, webhook_id, attempt_no, status, attempted_at, http_status, error, finished_at)
values
  (:'e_normal', :'wb', 0, 'failed', now() - interval '1 minute', 500, 'boom', now() - interval '1 minute');

select app.finalize_webhook_deliveries() as fin3 \gset

select ok(:'fin3'::integer >= 2, '毒事件异常被隔离，收口事务继续执行');
select is(
  (select status from public.integration_events where id = :'e_poison'),
  'failed',
  '毒事件被置 failed（when others 分支）'
);
select is(
  (select status from public.integration_events where id = :'e_normal'),
  'failed',
  '其他事件正常收口（不被毒事件回滚）'
);
select is(
  (select attempts from public.integration_events where id = :'e_normal'),
  1,
  '其他事件 attempts=1（正常路径完成）'
);

select * from finish();
rollback;
