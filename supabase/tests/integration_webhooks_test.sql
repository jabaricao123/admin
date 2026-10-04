-- pgTAP：integration/004 —— webhooks 表 + 事件入队 + 管理 RPC + emit_event + RLS
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构（两表列/约束/RLS/触发器/投递索引/identity）；函数存在性 + SECURITY DEFINER + search_path=''；
--       GRANT 面（authenticated 可管理、无 emit_event，规则 10；anon 无路径）；
--       secret 生成（whsec_ + 32 hex）一次性返回、pgcrypto 加密落库可解密、明文零落库；
--       headers 整串加密可解密 + 掩码回显（app.decrypt_secret 在 admin RPC 上下文）；
--       url https / events / retry_policy / headers 校验；更新（保持语义与重加密）；
--       停用；emit_event 入队 + 匹配 active 订阅计数；越权（authenticated 调 emit_event 被拒）；
--       RLS（engineer 0 行、admin 可见）；审计摘要（create/update/disable，不落 secret/header 明文）。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(133);

-- ===========================================================================
-- 1. 结构：webhooks + integration_events（28）
-- ===========================================================================
select has_table('public', 'webhooks', 'webhooks 表存在');
select has_table('public', 'integration_events', 'integration_events 表存在');
select col_is_pk('public', 'webhooks', 'id', 'webhooks.id 为主键');
select col_is_pk('public', 'integration_events', 'id', 'integration_events.id 为主键');
select col_type_is('public', 'webhooks', 'id', 'uuid', 'webhooks.id 为 uuid');
select col_type_is('public', 'webhooks', 'name', 'text', 'webhooks.name 为 text');
select col_type_is('public', 'webhooks', 'url', 'text', 'webhooks.url 为 text');
select col_type_is('public', 'webhooks', 'secret_enc', 'bytea', 'webhooks.secret_enc 为 bytea');
select col_type_is('public', 'webhooks', 'events', 'text[]', 'webhooks.events 为 text[]');
select col_type_is('public', 'webhooks', 'retry_policy', 'jsonb', 'webhooks.retry_policy 为 jsonb');
select col_type_is('public', 'webhooks', 'headers_enc', 'bytea', 'webhooks.headers_enc 为 bytea');
select col_type_is('public', 'webhooks', 'status', 'text', 'webhooks.status 为 text');
select col_not_null('public', 'webhooks', 'name', 'webhooks.name 非空');
select col_not_null('public', 'webhooks', 'url', 'webhooks.url 非空');
select col_not_null('public', 'webhooks', 'secret_enc', 'webhooks.secret_enc 非空');
select col_not_null('public', 'webhooks', 'events', 'webhooks.events 非空');
select col_has_default('public', 'webhooks', 'retry_policy', 'webhooks.retry_policy 有默认值');
select col_has_default('public', 'webhooks', 'status', 'webhooks.status 有默认值');
select col_has_check('public', 'webhooks', 'url', 'webhooks.url 有 https check');
select col_has_check('public', 'webhooks', 'status', 'webhooks.status 有取值 check');
select col_has_check('public', 'webhooks', 'events', 'webhooks.events 有非空 check');
select col_type_is('public', 'integration_events', 'id', 'bigint', 'events.id 为 bigint');
select is(
  (select a.attidentity::text
     from pg_attribute a
    where a.attrelid = 'public.integration_events'::regclass and a.attname = 'id'),
  'a',
  'events.id 为 generated always as identity'
);
select col_type_is('public', 'integration_events', 'event', 'text', 'events.event 为 text');
select col_type_is('public', 'integration_events', 'payload', 'jsonb', 'events.payload 为 jsonb');
select col_type_is('public', 'integration_events', 'status', 'text', 'events.status 为 text');
select col_type_is('public', 'integration_events', 'attempts', 'integer', 'events.attempts 为 integer');
select is(
  (select a.atttypid::regtype::text
     from pg_attribute a
    where a.attrelid = 'public.integration_events'::regclass and a.attname = 'next_retry_at'),
  'timestamp with time zone',
  'events.next_retry_at 为 timestamptz'
);
select col_not_null('public', 'integration_events', 'event', 'events.event 非空');
select col_not_null('public', 'integration_events', 'payload', 'events.payload 非空');
select col_not_null('public', 'integration_events', 'status', 'events.status 非空');
select col_not_null('public', 'integration_events', 'attempts', 'events.attempts 非空');
select col_not_null('public', 'integration_events', 'next_retry_at', 'events.next_retry_at 非空');
select col_has_default('public', 'integration_events', 'payload', 'events.payload 有默认值');
select col_has_default('public', 'integration_events', 'status', 'events.status 有默认值');
select col_has_default('public', 'integration_events', 'attempts', 'events.attempts 有默认值');
select col_has_default('public', 'integration_events', 'next_retry_at', 'events.next_retry_at 有默认值');
select col_has_check('public', 'integration_events', 'status', 'events.status 有状态机 check');
select is(
  (select relrowsecurity from pg_class where oid = 'public.webhooks'::regclass),
  true,
  'webhooks 已启用 RLS'
);
select is(
  (select relrowsecurity from pg_class where oid = 'public.integration_events'::regclass),
  true,
  'integration_events 已启用 RLS'
);
select has_trigger('public', 'webhooks', 'webhooks_set_updated_at', 'webhooks updated_at 触发器存在');
select has_index('public', 'integration_events', 'integration_events_dispatch_idx',
  '投递轮询索引（status + next_retry_at）存在');

-- ===========================================================================
-- 2. 函数存在性 + SECURITY DEFINER + search_path（11）
-- ===========================================================================
select has_function('app', 'create_webhook', array['text', 'text', 'text[]', 'jsonb', 'jsonb'],
  'app.create_webhook 存在');
select has_function('app', 'update_webhook', array['uuid', 'text', 'text', 'text[]', 'jsonb', 'jsonb'],
  'app.update_webhook 存在');
select has_function('app', 'disable_webhook', array['uuid'], 'app.disable_webhook 存在');
select has_function('app', 'emit_event', array['text', 'jsonb'], 'app.emit_event(text,jsonb) 存在');
select has_function('app', 'validate_webhook_fields', array['text', 'text', 'text[]', 'jsonb', 'jsonb'],
  'app.validate_webhook_fields 存在');
select has_function('app', 'mask_jsonb_values', array['jsonb'], 'app.mask_jsonb_values 存在');
select has_function('public', 'create_webhook', array['text', 'text', 'text[]', 'jsonb', 'jsonb'],
  'public.create_webhook 薄包装存在');
select has_function('public', 'update_webhook', array['uuid', 'text', 'text', 'text[]', 'jsonb', 'jsonb'],
  'public.update_webhook 薄包装存在');
select has_function('public', 'disable_webhook', array['uuid'], 'public.disable_webhook 薄包装存在');
select hasnt_function('public', 'emit_event', array['text', 'jsonb'],
  'public.emit_event 不存在（规则 10：不经 Data API 暴露）');
select ok(
  (select count(*) = 7
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
      ('app', 'create_webhook'),
      ('app', 'update_webhook'),
      ('app', 'disable_webhook'),
      ('app', 'emit_event'),
      ('public', 'create_webhook'),
      ('public', 'update_webhook'),
      ('public', 'disable_webhook')
    )
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '7 个 RPC/管理函数全部 security definer + search_path 固定为空'
);

-- ===========================================================================
-- 3. GRANT 面（15）
-- ===========================================================================
select ok(
  has_function_privilege('authenticated', 'app.create_webhook(text,text,text[],jsonb,jsonb)', 'EXECUTE'),
  'authenticated 可执行 app.create_webhook'
);
select ok(
  has_function_privilege('authenticated', 'public.create_webhook(text,text,text[],jsonb,jsonb)', 'EXECUTE'),
  'authenticated 可执行 public.create_webhook'
);
select ok(
  has_function_privilege('authenticated', 'app.update_webhook(uuid,text,text,text[],jsonb,jsonb)', 'EXECUTE'),
  'authenticated 可执行 app.update_webhook'
);
select ok(
  has_function_privilege('authenticated', 'public.update_webhook(uuid,text,text,text[],jsonb,jsonb)', 'EXECUTE'),
  'authenticated 可执行 public.update_webhook'
);
select ok(
  has_function_privilege('authenticated', 'app.disable_webhook(uuid)', 'EXECUTE'),
  'authenticated 可执行 app.disable_webhook'
);
select ok(
  has_function_privilege('authenticated', 'public.disable_webhook(uuid)', 'EXECUTE'),
  'authenticated 可执行 public.disable_webhook'
);
select ok(
  not has_function_privilege('authenticated', 'app.emit_event(text,jsonb)', 'EXECUTE'),
  'authenticated 无 app.emit_event 执行权（规则 10）'
);
select ok(
  not has_function_privilege('anon', 'public.create_webhook(text,text,text[],jsonb,jsonb)', 'EXECUTE'),
  'anon 无 public.create_webhook 执行权'
);
select ok(
  not has_function_privilege('authenticated', 'app.validate_webhook_fields(text,text,text[],jsonb,jsonb)', 'EXECUTE'),
  'authenticated 无 app.validate_webhook_fields 执行权'
);
select ok(
  not has_function_privilege('authenticated', 'app.mask_jsonb_values(jsonb)', 'EXECUTE'),
  'authenticated 无 app.mask_jsonb_values 执行权'
);
select ok(
  has_table_privilege('authenticated', 'public.webhooks', 'SELECT'),
  'authenticated 有 webhooks SELECT（RLS 再收口 admin）'
);
select ok(
  has_table_privilege('authenticated', 'public.integration_events', 'SELECT'),
  'authenticated 有 integration_events SELECT（RLS 再收口 admin）'
);
select ok(
  not has_table_privilege('authenticated', 'public.webhooks', 'INSERT')
  and not has_table_privilege('authenticated', 'public.webhooks', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.webhooks', 'DELETE'),
  'authenticated 对 webhooks 无表级写'
);
select ok(
  not has_table_privilege('authenticated', 'public.integration_events', 'INSERT')
  and not has_table_privilege('authenticated', 'public.integration_events', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.integration_events', 'DELETE'),
  'authenticated 对 integration_events 无表级写'
);
select ok(
  not has_table_privilege('anon', 'public.webhooks', 'SELECT'),
  'anon 对 webhooks 无 SELECT'
);

-- ===========================================================================
-- 4. 越权调用：engineer / anon 被拒（4）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$ select public.create_webhook('越权', 'https://x.example.com', array['x']) $$,
  '42501', null, 'engineer 创建 webhook 被 admin 校验拒绝'
);
select throws_ok(
  $$ select public.disable_webhook('00000000-0000-0000-0000-000000000000'::uuid) $$,
  '42501', null, 'engineer 停用 webhook 被 admin 校验拒绝'
);
select throws_ok(
  $$ select app.emit_event('x.y', '{}'::jsonb) $$,
  '42501', null, 'engineer 调用 emit_event 被拒（规则 10 无 GRANT）'
);

reset role;
set local role anon;

select throws_ok(
  $$ select public.create_webhook('未登录', 'https://x.example.com', array['x']) $$,
  '42501', null, 'anon 创建 webhook 被拒（无 GRANT）'
);

reset role;

-- ===========================================================================
-- 5. admin 创建：secret 一次性返回 + 加密落库（14）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.create_webhook(
  '审批通知',
  'https://hooks.example.com/approval',
  array['approval.approved'],
  null,
  '{"Authorization":"Bearer tok-abcdefgh","X-Env":"prod"}'::jsonb
) as w1 \gset

select public.create_webhook(
  '同步通知',
  'https://hooks.example.com/sync',
  array['approval.approved', 'org.user_changed']
) as w2 \gset

select public.create_webhook(
  '停用目标',
  'https://hooks.example.com/off',
  array['sync.run_finished'],
  '{"max_attempts":5,"backoff":"linear"}'::jsonb
) as w3 \gset

reset role;

select ok(
  (:'w1'::jsonb) ->> 'secret' ~ '^whsec_[0-9a-f]{32}$',
  '创建返回 secret 形如 whsec_ + 32 位十六进制'
);
select is(length((:'w1'::jsonb) ->> 'secret'), 38, 'secret 长度 38');
select is((:'w1'::jsonb) ->> 'status', 'active', '创建返回 status=active');
select is(
  (:'w1'::jsonb) -> 'events',
  '["approval.approved"]'::jsonb,
  '创建返回 events 数组'
);
select ok(
  (select events = array['approval.approved']::text[] from public.webhooks
    where id = (:'w1'::jsonb ->> 'id')::uuid),
  'events 落库为 text[]'
);
select is(
  (select retry_policy from public.webhooks where id = (:'w1'::jsonb ->> 'id')::uuid),
  '{"max_attempts":3,"backoff":"exponential"}'::jsonb,
  'retry_policy 未传时落默认策略'
);
select is(
  (:'w3'::jsonb) -> 'retry_policy',
  '{"max_attempts":5,"backoff":"linear"}'::jsonb,
  '自定义 retry_policy 原样落库'
);
select is(
  (select created_by from public.webhooks where id = (:'w1'::jsonb ->> 'id')::uuid),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'created_by 记录操作人 auth.uid()'
);
select is(
  app.decrypt_secret((select secret_enc from public.webhooks where id = (:'w1'::jsonb ->> 'id')::uuid)),
  (:'w1'::jsonb) ->> 'secret',
  'secret_enc 可解密回一次性返回的明文'
);
select ok(
  (select position(convert_to((:'w1'::jsonb) ->> 'secret', 'UTF8') in secret_enc) = 0
     from public.webhooks where id = (:'w1'::jsonb ->> 'id')::uuid),
  'secret_enc 不含 secret 明文（加密落库）'
);
select is(
  (:'w1'::jsonb) -> 'headers_masked',
  '{"Authorization":"****efgh","X-Env":"****"}'::jsonb,
  'headers_masked 只露值尾 4 位（admin RPC 内解密后掩码）'
);
select is(
  app.decrypt_secret((select headers_enc from public.webhooks where id = (:'w1'::jsonb ->> 'id')::uuid))::jsonb,
  '{"Authorization":"Bearer tok-abcdefgh","X-Env":"prod"}'::jsonb,
  'headers 整串加密落库且可解密回原 jsonb'
);
select is(
  (select headers_enc from public.webhooks where id = (:'w2'::jsonb ->> 'id')::uuid),
  null::bytea,
  '未传 headers 时 headers_enc 为 NULL'
);
select is((:'w2'::jsonb) -> 'headers_masked', 'null'::jsonb, '未传 headers 时掩码为 null');

-- ===========================================================================
-- 6. emit_event：入队 + 匹配 active 订阅计数（15，superuser 直调）
-- ===========================================================================
select is(
  app.emit_event('approval.approved', '{"instance_id":"i-1"}'::jsonb),
  2,
  'emit approval.approved 匹配 2 个 active 订阅'
);
select is(
  app.emit_event('org.user_changed', '{"user_id":"u-1"}'::jsonb),
  1,
  'emit org.user_changed 匹配 1 个 active 订阅'
);
select is(
  app.emit_event('sync.run_finished', '{"run_id":"r-1"}'::jsonb),
  1,
  'emit sync.run_finished 匹配 1 个 active 订阅'
);
select is(app.emit_event('unknown.event', '{}'::jsonb), 0, '无订阅事件匹配数为 0 但仍入队');
-- 队列断言按本文件夹具事件过滤（抗并发 E2E 事件污染）
select is(
  (select count(*) from public.integration_events
    where event in ('approval.approved','org.user_changed','sync.run_finished','unknown.event')),
  4::bigint,
  '4 次 emit 入队 4 条'
);
select is(
  (select event from public.integration_events
    where payload = '{"instance_id":"i-1"}'::jsonb),
  'approval.approved',
  '队列记录事件名'
);
select is(
  (select payload from public.integration_events
    where event = 'approval.approved' and payload ? 'instance_id'
    order by id limit 1),
  '{"instance_id":"i-1"}'::jsonb,
  '队列记录 payload'
);
select is(
  (select status from public.integration_events
    where payload = '{"instance_id":"i-1"}'::jsonb),
  'pending',
  '入队默认 status=pending'
);
select is(
  (select attempts from public.integration_events
    where payload = '{"instance_id":"i-1"}'::jsonb),
  0,
  '入队默认 attempts=0'
);
select ok(
  (select next_retry_at is not null from public.integration_events order by id limit 1),
  '入队默认 next_retry_at 非空（立即可投递）'
);

-- ===========================================================================
-- 7. 更新：保持语义 + headers 重加密（10，admin 身份）
-- ===========================================================================
set local role authenticated;

select public.update_webhook(
  (:'w1'::jsonb ->> 'id')::uuid,
  '审批通知 v2',
  'https://hooks.example.com/approval-v2',
  array['approval.rejected']
) as u1 \gset

select public.update_webhook(
  (:'w3'::jsonb ->> 'id')::uuid,
  '停用目标 v2',
  'https://hooks.example.com/off-v2',
  array['sync.run_finished'],
  null,
  '{"X-Trace":"0123456789"}'::jsonb
) as u3 \gset

select throws_ok(
  $$ select public.update_webhook(gen_random_uuid(), 'x', 'https://x.example.com', null) $$,
  'P0002', null, '更新不存在的 webhook 报 P0002（先定位记录）'
);
select throws_ok(
  format(
    'select public.update_webhook(%L::uuid, %L, %L, null)',
    (:'w1'::jsonb) ->> 'id', 'x', 'https://x.example.com'
  ),
  '22023', null, '已存在记录的 events 为 NULL 报 22023'
);

reset role;

select is((:'u1'::jsonb) ->> 'name', '审批通知 v2', '更新返回新名称');
select is((:'u1'::jsonb) ->> 'url', 'https://hooks.example.com/approval-v2', '更新返回新 URL');
select ok(
  (select events = array['approval.rejected']::text[] from public.webhooks
    where id = (:'w1'::jsonb ->> 'id')::uuid),
  '更新后 events 落库为新数组'
);
select is(
  (select retry_policy from public.webhooks where id = (:'w1'::jsonb ->> 'id')::uuid),
  '{"max_attempts":3,"backoff":"exponential"}'::jsonb,
  'retry_policy 传 NULL 保持原值'
);
select is(
  (select name from public.webhooks where id = (:'w3'::jsonb ->> 'id')::uuid),
  '停用目标 v2',
  '更新名称生效'
);
select is(
  (select retry_policy from public.webhooks where id = (:'w3'::jsonb ->> 'id')::uuid),
  '{"max_attempts":5,"backoff":"linear"}'::jsonb,
  '自定义 retry_policy 更新时保持'
);
select is(
  (:'u3'::jsonb) -> 'headers_masked',
  '{"X-Trace":"****6789"}'::jsonb,
  'headers 传入后重加密并掩码回显'
);
select is(
  app.decrypt_secret((select headers_enc from public.webhooks where id = (:'w3'::jsonb ->> 'id')::uuid))::jsonb,
  '{"X-Trace":"0123456789"}'::jsonb,
  '更新后的 headers_enc 可解密回新值'
);
select is(
  (select updated_by from public.webhooks where id = (:'w1'::jsonb ->> 'id')::uuid),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'updated_by 记录更新人'
);

-- 更新后再次 emit：w1 已改订阅，approval.approved 只剩 w2 匹配
select is(
  app.emit_event('approval.approved', '{}'::jsonb),
  1,
  '更新订阅后 approval.approved 仅匹配 w2'
);
select is(
  app.emit_event('approval.rejected', '{"instance_id":"i-2"}'::jsonb),
  1,
  'approval.rejected 匹配更新后的 w1'
);
select is(
  app.emit_event('org.user_changed', '{}'::jsonb),
  1,
  'org.user_changed 仍匹配 w2'
);

-- ===========================================================================
-- 8. 停用：不再收到事件（4）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.disable_webhook((:'w3'::jsonb ->> 'id')::uuid) as d3 \gset

select throws_ok(
  $$ select public.disable_webhook('00000000-0000-0000-0000-000000000000'::uuid) $$,
  'P0002', null, '停用不存在的 webhook 报 P0002'
);

reset role;
select is((:'d3'::jsonb) ->> 'status', 'disabled', '停用返回 status=disabled');
select is(
  (select status from public.webhooks where id = (:'w3'::jsonb ->> 'id')::uuid),
  'disabled',
  '落库 status=disabled'
);
select is(app.emit_event('sync.run_finished', '{}'::jsonb), 0, '停用端点不再计入匹配订阅数');

-- ===========================================================================
-- 9. emit_event 参数校验（2，superuser）
-- ===========================================================================
select throws_ok(
  $$ select app.emit_event('  ', '{}'::jsonb) $$,
  '22023', null, '事件名为空报 22023'
);
select throws_ok(
  $$ select app.emit_event('x.y', '[]'::jsonb) $$,
  '22023', null, 'payload 非对象报 22023'
);

-- ===========================================================================
-- 10. RLS：engineer 不可见 / admin 可见 / anon 无路径（6）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;

select is((select count(*) from public.webhooks), 0::bigint, 'engineer 读取 webhooks 为 0 行');
select is((select count(*) from public.integration_events), 0::bigint, 'engineer 读取 integration_events 为 0 行');

reset role;
set local role anon;

select throws_ok(
  $$ select * from public.webhooks $$,
  '42501', null, 'anon 直查 webhooks 被拒（无 GRANT）'
);
select throws_ok(
  $$ select * from public.integration_events $$,
  '42501', null, 'anon 直查 integration_events 被拒（无 GRANT）'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select is((select count(*) from public.webhooks), 3::bigint, 'admin 通过 RLS 可见全部 3 个 webhook');
select is(
  (select count(*) from public.integration_events),
  8::bigint,
  'admin 可见队列全部 8 条事件'
);

reset role;

-- ===========================================================================
-- 11. 表约束兜底（3，superuser）
-- ===========================================================================
select throws_ok(
  $$ insert into public.webhooks (name, url, secret_enc, events)
     values ('x', 'http://insecure.example.com', app.encrypt_secret('s'), array['a']) $$,
  '23514', null, '非 https URL 被 check 约束拒绝'
);
select throws_ok(
  $$ insert into public.webhooks (name, url, secret_enc, events)
     values ('x', 'https://x.example.com', app.encrypt_secret('s'), array[]::text[]) $$,
  '23514', null, '空 events 被 check 约束拒绝'
);
select throws_ok(
  $$ insert into public.webhooks (name, url, secret_enc, events, status)
     values ('x', 'https://x.example.com', app.encrypt_secret('s'), array['a'], 'weird') $$,
  '23514', null, 'status 非法取值被 check 约束拒绝'
);

-- ===========================================================================
-- 12. 审计摘要（8，superuser 直查 audit_operations）
-- ===========================================================================
select ok(
  exists (
    select 1 from public.audit_operations
     where module = 'integration' and action = 'create'
       and object_type = 'webhook' and object_id = (:'w1'::jsonb ->> 'id')
  ),
  '创建 webhook 写审计摘要（create/webhook）'
);
select ok(
  exists (
    select 1 from public.audit_operations
     where module = 'integration' and action = 'update'
       and object_type = 'webhook' and object_id = (:'w1'::jsonb ->> 'id')
  ),
  '更新 webhook 写审计摘要（update/webhook）'
);
select ok(
  exists (
    select 1 from public.audit_operations
     where module = 'integration' and action = 'disable'
       and object_type = 'webhook' and object_id = (:'w3'::jsonb ->> 'id')
  ),
  '停用 webhook 写审计摘要（disable/webhook）'
);
select ok(
  (select diff ->> 'secret_set' = 'true'
     from public.audit_operations
    where module = 'integration' and action = 'create'
      and object_id = (:'w1'::jsonb ->> 'id')),
  '创建审计记录 secret_set=true（不落 secret 明文）'
);
select ok(
  (select diff ->> 'headers_set' = 'true'
     from public.audit_operations
    where module = 'integration' and action = 'create'
      and object_id = (:'w1'::jsonb ->> 'id')),
  '创建审计记录 headers_set 标记'
);
select ok(
  (select diff ->> 'events_changed' = 'true'
     from public.audit_operations
    where module = 'integration' and action = 'update'
      and object_id = (:'w1'::jsonb ->> 'id')),
  '更新审计记录 events_changed=true'
);
select ok(
  not exists (
    select 1 from public.audit_operations
     where module = 'integration'
       and diff::text like '%' || ((:'w1'::jsonb) ->> 'secret') || '%'
  ),
  '审计摘要不落 webhook secret 明文'
);
select ok(
  not exists (
    select 1 from public.audit_operations
     where module = 'integration' and diff::text like '%tok-abcdefgh%'
  ),
  '审计摘要不落自定义 header 明文'
);

select * from finish();
rollback;
