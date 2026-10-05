-- pgTAP：integration 批次 1/4 —— service_role 权限清理（ADR-001）
-- 运行：supabase db reset && supabase test db
-- 覆盖：管理/测试 RPC（public 薄包装 + app 实现）service_role 零执行权；
--       integration_call_logs / integration_call_stats_daily service_role 零 SELECT；
--       authenticated 权限不受影响（sanity）。
-- 说明：对标 integration_api_docs_test 的断言模式；夹具只在本事务内生效，finish 后 rollback。

begin;

select plan(25);

-- ===========================================================================
-- 1. public 薄包装：service_role 零执行权（9）
-- ===========================================================================
select ok(
  not has_function_privilege('service_role', 'public.create_api_key(text,jsonb,timestamptz)', 'EXECUTE'),
  'service_role 无 public.create_api_key 执行权'
);
select ok(
  not has_function_privilege('service_role', 'public.revoke_api_key(uuid)', 'EXECUTE'),
  'service_role 无 public.revoke_api_key 执行权'
);
select ok(
  not has_function_privilege('service_role', 'public.create_webhook(text,text,text[],jsonb,jsonb)', 'EXECUTE'),
  'service_role 无 public.create_webhook 执行权'
);
select ok(
  not has_function_privilege('service_role', 'public.update_webhook(uuid,text,text,text[],jsonb,jsonb)', 'EXECUTE'),
  'service_role 无 public.update_webhook 执行权'
);
select ok(
  not has_function_privilege('service_role', 'public.disable_webhook(uuid)', 'EXECUTE'),
  'service_role 无 public.disable_webhook 执行权'
);
select ok(
  not has_function_privilege('service_role', 'public.enable_webhook(uuid)', 'EXECUTE'),
  'service_role 无 public.enable_webhook 执行权'
);
select ok(
  not has_function_privilege('service_role', 'public.get_webhooks()', 'EXECUTE'),
  'service_role 无 public.get_webhooks 执行权'
);
select ok(
  not has_function_privilege('service_role', 'public.test_webhook(uuid)', 'EXECUTE'),
  'service_role 无 public.test_webhook 执行权'
);
select ok(
  not has_function_privilege('service_role', 'public.webhook_test_result(bigint)', 'EXECUTE'),
  'service_role 无 public.webhook_test_result 执行权'
);

-- ===========================================================================
-- 2. app 实现：service_role 零执行权（纵深防御，9）
-- ===========================================================================
select ok(
  not has_function_privilege('service_role', 'app.create_api_key(text,jsonb,timestamptz)', 'EXECUTE'),
  'service_role 无 app.create_api_key 执行权'
);
select ok(
  not has_function_privilege('service_role', 'app.revoke_api_key(uuid)', 'EXECUTE'),
  'service_role 无 app.revoke_api_key 执行权'
);
select ok(
  not has_function_privilege('service_role', 'app.create_webhook(text,text,text[],jsonb,jsonb)', 'EXECUTE'),
  'service_role 无 app.create_webhook 执行权'
);
select ok(
  not has_function_privilege('service_role', 'app.update_webhook(uuid,text,text,text[],jsonb,jsonb)', 'EXECUTE'),
  'service_role 无 app.update_webhook 执行权'
);
select ok(
  not has_function_privilege('service_role', 'app.disable_webhook(uuid)', 'EXECUTE'),
  'service_role 无 app.disable_webhook 执行权'
);
select ok(
  not has_function_privilege('service_role', 'app.enable_webhook(uuid)', 'EXECUTE'),
  'service_role 无 app.enable_webhook 执行权'
);
select ok(
  not has_function_privilege('service_role', 'app.get_webhooks()', 'EXECUTE'),
  'service_role 无 app.get_webhooks 执行权'
);
select ok(
  not has_function_privilege('service_role', 'app.test_webhook(uuid)', 'EXECUTE'),
  'service_role 无 app.test_webhook 执行权'
);
select ok(
  not has_function_privilege('service_role', 'app.webhook_test_result(bigint)', 'EXECUTE'),
  'service_role 无 app.webhook_test_result 执行权'
);

-- ===========================================================================
-- 3. 调用日志表：service_role 零 SELECT（2）
-- ===========================================================================
select ok(
  not has_table_privilege('service_role', 'public.integration_call_logs', 'SELECT'),
  'service_role 无 integration_call_logs SELECT'
);
select ok(
  not has_table_privilege('service_role', 'public.integration_call_stats_daily', 'SELECT'),
  'service_role 无 integration_call_stats_daily SELECT'
);

-- ===========================================================================
-- 4. sanity：authenticated 权限不受影响（2）
-- ===========================================================================
select ok(
  has_function_privilege('authenticated', 'public.create_api_key(text,jsonb,timestamptz)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.create_webhook(text,text,text[],jsonb,jsonb)', 'EXECUTE'),
  'authenticated 仍可执行管理 RPC（函数内 admin 校验）'
);
select ok(
  has_table_privilege('authenticated', 'public.integration_call_logs', 'SELECT')
  and has_table_privilege('authenticated', 'public.integration_call_stats_daily', 'SELECT'),
  'authenticated 仍可读调用日志/聚合（RLS 再收口 admin）'
);

-- ===========================================================================
-- 5. 调用日志分区表：API 角色零直读（service_role bypassrls，不能只靠 RLS）（3）
-- ===========================================================================
select ok(
  not has_table_privilege('service_role',
    'public.integration_call_logs_' || to_char(current_date, 'YYYY_MM'), 'SELECT'),
  '当月分区：service_role 零直读（分区级授权收口）'
);
select ok(
  not has_table_privilege('anon',
      'public.integration_call_logs_' || to_char(current_date, 'YYYY_MM'), 'SELECT')
  and not has_table_privilege('authenticated',
      'public.integration_call_logs_' || to_char(current_date, 'YYYY_MM'), 'SELECT'),
  '当月分区：anon/authenticated 零直读（访问一律经父表）'
);
select app.ensure_integration_call_log_partition((current_date + interval '2 months')::date) as future_part \gset
select ok(
  (select not has_table_privilege('service_role', ('public.' || :'future_part')::regclass, 'SELECT')
      and not has_table_privilege('service_role', ('public.' || :'future_part')::regclass, 'INSERT')
      and not has_table_privilege('anon', ('public.' || :'future_part')::regclass, 'SELECT')
      and not has_table_privilege('authenticated', ('public.' || :'future_part')::regclass, 'SELECT')),
  '新建分区（ensure 动态创建）同样零授权'
);

select * from finish();
rollback;
