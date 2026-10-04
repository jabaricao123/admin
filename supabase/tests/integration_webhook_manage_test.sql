-- pgTAP：integration/006 增量 —— Webhook 启用 RPC + 脱敏列表口（app.get_webhooks）
-- 运行：supabase db reset && supabase test db
-- 覆盖：函数存在性 + SECURITY DEFINER + search_path 为空；GRANT 面（authenticated 可用、
--       anon 无路径、内部掩码函数仍不可直调）；越权（engineer 被 admin 校验拒绝）；
--       启用状态机（disable→enable 往返、审计摘要、emit_event 匹配恢复、updated_by）；
--       列表口脱敏（headers 仅 '****' + 尾 4 位、保留键、无 header 为 null、
--       不下发 secret/header 明文）；参数错误（不存在端点 P0002）。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(32);

-- ===========================================================================
-- 1. 函数存在性 + SECURITY DEFINER + search_path（6）
-- ===========================================================================
select has_function('app', 'enable_webhook', array['uuid'], 'app.enable_webhook 存在');
select has_function('public', 'enable_webhook', array['uuid'], 'public.enable_webhook 薄包装存在');
select has_function('app', 'get_webhooks', array[]::text[], 'app.get_webhooks 存在');
select has_function('public', 'get_webhooks', array[]::text[], 'public.get_webhooks 薄包装存在');
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'enable_webhook'),
  'app.enable_webhook 为 SECURITY DEFINER 且 search_path 为空'
);
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'get_webhooks'),
  'app.get_webhooks 为 SECURITY DEFINER 且 search_path 为空'
);

-- ===========================================================================
-- 2. 授权面（6）
-- ===========================================================================
select ok(
  has_function_privilege('authenticated', 'app.enable_webhook(uuid)', 'EXECUTE'),
  'authenticated 可执行 app.enable_webhook'
);
select ok(
  has_function_privilege('authenticated', 'public.enable_webhook(uuid)', 'EXECUTE'),
  'authenticated 可执行 public.enable_webhook'
);
select ok(
  has_function_privilege('authenticated', 'app.get_webhooks()', 'EXECUTE'),
  'authenticated 可执行 app.get_webhooks'
);
select ok(
  has_function_privilege('authenticated', 'public.get_webhooks()', 'EXECUTE'),
  'authenticated 可执行 public.get_webhooks'
);
select ok(
  not has_function_privilege('anon', 'app.enable_webhook(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.enable_webhook(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'app.get_webhooks()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.get_webhooks()', 'EXECUTE'),
  'anon 对本增量四个函数均无执行权'
);
select ok(
  not has_function_privilege('authenticated', 'app.mask_jsonb_values(jsonb)', 'EXECUTE'),
  'authenticated 无可直调 app.mask_jsonb_values（掩码只在 SECURITY DEFINER 内）'
);

-- ===========================================================================
-- 3. 越权调用：engineer / anon 被拒（4）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$ select app.get_webhooks() $$,
  '42501', null, 'engineer 调 app.get_webhooks 被 admin 校验拒绝'
);
select throws_ok(
  $$ select public.enable_webhook('00000000-0000-0000-0000-000000000000'::uuid) $$,
  '42501', null, 'engineer 启用 webhook 被 admin 校验拒绝'
);

reset role;
set local role anon;

select throws_ok(
  $$ select public.get_webhooks() $$,
  '42501', null, 'anon 调 public.get_webhooks 被拒（无 GRANT）'
);
select throws_ok(
  $$ select public.enable_webhook('00000000-0000-0000-0000-000000000000'::uuid) $$,
  '42501', null, 'anon 启用 webhook 被拒（无 GRANT）'
);

reset role;

-- ===========================================================================
-- 4. admin 启用：状态机 + 审计 + 事件匹配恢复（8）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.create_webhook(
  '启用测试端点',
  'https://hooks.example.com/enable',
  array['approval.approved'],
  null,
  '{"Authorization":"Bearer tok-abcdefgh","X-Trace":"0123456789"}'::jsonb
) as wa \gset

select public.create_webhook(
  '无 header 端点',
  'https://hooks.example.com/plain',
  array['sync.run_finished']
) as wb \gset

select ok(
  (:'wa'::jsonb) ->> 'secret' ~ '^whsec_[0-9a-f]{32}$',
  '测试夹具：创建返回一次性 secret'
);

select public.disable_webhook((:'wa'::jsonb ->> 'id')::uuid) as da \gset
select is((:'da'::jsonb) ->> 'status', 'disabled', '停用返回 status=disabled');

select public.enable_webhook((:'wa'::jsonb ->> 'id')::uuid) as ea \gset
select is((:'ea'::jsonb) ->> 'status', 'active', '启用返回 status=active');
select is(
  (select status from public.webhooks where id = (:'wa'::jsonb ->> 'id')::uuid),
  'active',
  '落库 status=active'
);
select is(
  (select updated_by from public.webhooks where id = (:'wa'::jsonb ->> 'id')::uuid),
  '11111111-1111-1111-1111-111111111111'::uuid,
  '启用记录 updated_by'
);

select throws_ok(
  $$ select public.enable_webhook('00000000-0000-0000-0000-000000000000'::uuid) $$,
  'P0002', null, '启用不存在的 webhook 报 P0002'
);

reset role;

select ok(
  (select (o.diff ->> 'status_before') = 'disabled'
      and (o.diff ->> 'status_after') = 'active'
     from public.audit_operations o
    where o.module = 'integration' and o.action = 'enable'
      and o.object_id = (:'wa'::jsonb ->> 'id')),
  '启用写审计摘要（enable/webhook，before=disabled / after=active）'
);

select is(
  app.emit_event('approval.approved', '{}'::jsonb),
  1,
  '启用后端点恢复匹配事件（emit 计数 = 1）'
);

-- ===========================================================================
-- 5. app.get_webhooks：脱敏列表口（8）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select is(
  (select count(*) from public.get_webhooks() g where g.id = (:'wa'::jsonb ->> 'id')::uuid),
  1::bigint,
  'get_webhooks 返回目标端点一行'
);
select is(
  (select g.headers_masked from public.get_webhooks() g where g.id = (:'wa'::jsonb ->> 'id')::uuid),
  '{"Authorization":"****efgh","X-Trace":"****6789"}'::jsonb,
  'headers_masked 仅露值尾 4 位且保留原键'
);
select is(
  (select array_agg(k order by k)
     from public.get_webhooks() g, jsonb_object_keys(g.headers_masked) k
    where g.id = (:'wa'::jsonb ->> 'id')::uuid),
  array['Authorization', 'X-Trace'],
  '掩码结果的键集合与存量 header 一致'
);
select is(
  (select g.headers_masked from public.get_webhooks() g where g.id = (:'wb'::jsonb ->> 'id')::uuid),
  null::jsonb,
  '未配置 header 的端点返回 null'
);
select is(
  (select g.url from public.get_webhooks() g where g.id = (:'wa'::jsonb ->> 'id')::uuid),
  'https://hooks.example.com/enable',
  '返回目标 URL'
);
select is(
  (select g.events from public.get_webhooks() g where g.id = (:'wa'::jsonb ->> 'id')::uuid),
  array['approval.approved']::text[],
  '返回订阅事件数组'
);
select is(
  (select g.retry_policy from public.get_webhooks() g where g.id = (:'wa'::jsonb ->> 'id')::uuid),
  '{"max_attempts":3,"backoff":"exponential"}'::jsonb,
  '返回重试策略'
);
select ok(
  (select to_jsonb(g)::text
     from public.get_webhooks() g
    where g.id = (:'wa'::jsonb ->> 'id')::uuid)
    not like '%tok-abcdefgh%'
  and (select to_jsonb(g)::text
         from public.get_webhooks() g
        where g.id = (:'wa'::jsonb ->> 'id')::uuid)
    not like '%0123456789%'
  and (select to_jsonb(g)::text
         from public.get_webhooks() g
        where g.id = (:'wa'::jsonb ->> 'id')::uuid)
    not like '%whsec_%',
  '列表口不下发 secret/header 明文（仅掩码）'
);

reset role;

select * from finish();
rollback;
