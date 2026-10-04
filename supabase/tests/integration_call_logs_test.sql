-- pgTAP：integration/007 —— 调用日志（月分区 + 截断写入 + 统计聚合 + 清理 + 导出源）
-- 运行：supabase db reset && supabase test db
-- 覆盖：分区表结构/预建分区/约束/RLS/授权；ensure 幂等与按需建分区；log_integration_call
--       校验/ref 归一/2048 截断；webhook finalize 写日志（2xx/非 2xx/超时）；api_departments
--       写日志（token 端到端）；stats_daily 聚合（幂等 + 名称快照）；30 天清理（分区+行级）；
--       integration.logs 导出源（admin 独占 + worker CSV）；pg_cron 与 system 登记处。
-- 说明：夹具只在本事务内生效，finish 后 rollback；engineer 为 seeds 内部账号（非 admin）。

begin;

select plan(89);

-- ===========================================================================
-- 1. 结构：分区 / 列 / 主键 / 约束 / RLS / 索引（19）
-- ===========================================================================
select has_table('public', 'integration_call_logs', 'integration_call_logs 表存在');
select is(
  (select c.relkind::text from pg_class c where c.oid = 'public.integration_call_logs'::regclass),
  'p',
  'integration_call_logs 为分区表（relkind=p）'
);
select ok(
  exists (
    select 1 from pg_class c
     where c.relname = 'integration_call_logs_' || to_char(current_date, 'YYYY_MM')
  ),
  '当月分区已预建（integration_call_logs_YYYY_MM）'
);
select ok(
  exists (
    select 1 from pg_class c
     where c.relname = 'integration_call_logs_'
       || to_char((date_trunc('month', current_date) + interval '1 month')::date, 'YYYY_MM')
  ),
  '下月分区已预建'
);
select ok(
  exists (
    select 1 from pg_constraint c
     where c.conrelid = 'public.integration_call_logs'::regclass
       and c.contype = 'p'
       and pg_get_constraintdef(c.oid) like '%(id, created_at)%'
  ),
  '复合主键 (id, created_at)（包含分区键）'
);
select col_type_is('public', 'integration_call_logs', 'kind', 'text', 'kind 为 text');
select col_type_is('public', 'integration_call_logs', 'key_id', 'uuid', 'key_id 为 uuid');
select col_type_is('public', 'integration_call_logs', 'webhook_id', 'uuid', 'webhook_id 为 uuid');
select col_type_is('public', 'integration_call_logs', 'method_event', 'text', 'method_event 为 text');
select col_type_is('public', 'integration_call_logs', 'status_code', 'integer', 'status_code 为 integer');
select col_type_is('public', 'integration_call_logs', 'duration_ms', 'integer', 'duration_ms 为 integer');
select col_type_is('public', 'integration_call_logs', 'request_excerpt', 'text', 'request_excerpt 为 text');
select col_type_is('public', 'integration_call_logs', 'response_excerpt', 'text', 'response_excerpt 为 text');
select col_type_is('public', 'integration_call_logs', 'error', 'text', 'error 为 text');
select col_not_null('public', 'integration_call_logs', 'kind', 'kind 非空');
select ok(
  exists (
    select 1 from pg_constraint c
     where c.conrelid = 'public.integration_call_logs'::regclass
       and c.contype = 'c'
       and pg_get_constraintdef(c.oid) like '%kind%api%webhook%'
  ),
  'kind check（api/webhook）存在'
);
select is(
  (select relrowsecurity from pg_class where oid = 'public.integration_call_logs'::regclass),
  true,
  'integration_call_logs 已启用 RLS'
);
select has_index(
  'public', 'integration_call_logs', 'integration_call_logs_created_idx',
  '列表索引（created_at desc, id desc）存在'
);

-- ===========================================================================
-- 2. 统计聚合表结构（8）
-- ===========================================================================
select has_table('public', 'integration_call_stats_daily', 'stats_daily 表存在');
select ok(
  exists (
    select 1 from pg_constraint c
     where c.conrelid = 'public.integration_call_stats_daily'::regclass
       and c.contype = 'p'
       and pg_get_constraintdef(c.oid) like '%(day, kind, ref_id)%'
  ),
  '复合主键 (day, kind, ref_id) 存在'
);
select col_type_is('public', 'integration_call_stats_daily', 'total', 'bigint', 'total 为 bigint');
select col_type_is('public', 'integration_call_stats_daily', 'failed', 'bigint', 'failed 为 bigint');
select col_type_is('public', 'integration_call_stats_daily', 'avg_duration_ms', 'numeric(12,1)',
  'avg_duration_ms 为 numeric(12,1)（可空）');
select is(
  (select relrowsecurity from pg_class where oid = 'public.integration_call_stats_daily'::regclass),
  true,
  'stats_daily 已启用 RLS'
);

-- ===========================================================================
-- 3. 函数与 SECURITY 属性（8）
-- ===========================================================================
select has_function('app', 'ensure_integration_call_log_partition', array['date'],
  'ensure_integration_call_log_partition(date) 存在');
select has_function('app', 'log_integration_call',
  array['text', 'uuid', 'uuid', 'text', 'integer', 'integer', 'text', 'text', 'text'],
  'log_integration_call(9 参) 存在');
select has_function('app', 'aggregate_integration_call_stats_daily', array['date'],
  'aggregate_integration_call_stats_daily(date) 存在');
select has_function('app', 'cleanup_integration_call_logs', array['integer'],
  'cleanup_integration_call_logs(integer) 存在');
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'ensure_integration_call_log_partition'),
  'ensure 为 SECURITY DEFINER + search_path 空'
);
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'log_integration_call'),
  'log_integration_call 为 SECURITY DEFINER + search_path 空'
);
select ok(
  (select bool_and(not p.prosecdef and p.proconfig @> array['search_path=""'])
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname in ('aggregate_integration_call_stats_daily',
                        'cleanup_integration_call_logs')),
  '聚合/清理为 SECURITY INVOKER + search_path 空'
);
select ok(
  (select count(*) = 2
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname in ('aggregate_integration_call_stats_daily', 'cleanup_integration_call_logs')
      and not p.prosecdef),
  '聚合/清理均为 SECURITY INVOKER（仅 pg_cron 可达）'
);

-- ===========================================================================
-- 4. 授权面（7）
-- ===========================================================================
select ok(
  has_table_privilege('authenticated', 'public.integration_call_logs', 'SELECT'),
  'authenticated 有明细 SELECT（RLS 再收口 admin）'
);
select ok(
  not has_table_privilege('authenticated', 'public.integration_call_logs', 'INSERT')
  and not has_table_privilege('authenticated', 'public.integration_call_logs', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.integration_call_logs', 'DELETE'),
  'authenticated 无明细表级写'
);
select ok(
  not has_table_privilege('anon', 'public.integration_call_logs', 'SELECT'),
  'anon 无明细 SELECT'
);
select ok(
  has_function_privilege('anon', 'app.log_integration_call(text,uuid,uuid,text,integer,integer,text,text,text)', 'EXECUTE'),
  'anon 可执行 log 入口（api_departments 以调用者身份记录）'
);
select ok(
  not has_function_privilege('authenticated', 'app.log_integration_call(text,uuid,uuid,text,integer,integer,text,text,text)', 'EXECUTE'),
  'authenticated 无 log 入口执行权（规则 10）'
);
select ok(
  not has_function_privilege('authenticated', 'app.aggregate_integration_call_stats_daily(date)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.cleanup_integration_call_logs(integer)', 'EXECUTE'),
  'authenticated 无聚合/清理执行权'
);
select ok(
  not has_function_privilege('service_role', 'app.cleanup_integration_call_logs(integer)', 'EXECUTE')
  and not has_function_privilege('service_role', 'app.log_integration_call(text,uuid,uuid,text,integer,integer,text,text,text)', 'EXECUTE'),
  'service_role 无清理/写入执行权（ADR-001）'
);
select ok(
  not has_sequence_privilege('authenticated', 'public.integration_call_logs_id_seq', 'USAGE')
  and not has_sequence_privilege('anon', 'public.integration_call_logs_id_seq', 'USAGE'),
  'identity 序列不暴露给 API 角色'
);

-- ===========================================================================
-- 5. log_integration_call：写入 / ref 归一 / 截断 / 校验（10）
-- ===========================================================================
select app.log_integration_call('api', null, null, 'unit.test', 200, 5, 'req', 'resp', null) as log1 \gset
select is(
  (select kind from public.integration_call_logs where id = :'log1'),
  'api',
  '写入 kind=api 明细'
);
select is(
  (select status_code from public.integration_call_logs where id = :'log1'),
  200,
  '写入状态码 200'
);
select is(
  (select request_excerpt from public.integration_call_logs where id = :'log1'),
  'req',
  '写入请求摘要'
);
select app.log_integration_call(
  'api', null, '99999999-9999-4999-8999-999999999999'::uuid, 'unit.ref', 200, 1, null, null, null
) as log2 \gset
select is(
  (select webhook_id from public.integration_call_logs where id = :'log2'),
  null::uuid,
  'kind=api 时 webhook_id 归一为 NULL（ref 约束）'
);
select app.log_integration_call(
  'api', null, null, 'unit.trunc', 500, 1, repeat('r', 3000), repeat('s', 3000), 'boom'
) as log3 \gset
select ok(
  (select char_length(request_excerpt) = 2048 and char_length(response_excerpt) = 2048
     from public.integration_call_logs where id = :'log3'),
  'excerpt 截断到 2048 字符'
);
select throws_ok(
  $$ select app.log_integration_call('cron', null, null, 'x', 200, 1, null, null, null) $$,
  '22023', null, 'kind 非法拒绝'
);
select throws_ok(
  $$ select app.log_integration_call('api', null, null, '  ', 200, 1, null, null, null) $$,
  '22023', null, 'method_event 为空拒绝'
);
select throws_ok(
  $$ select app.log_integration_call('api', null, null, 'x', 99, 1, null, null, null) $$,
  '22023', null, '状态码越界拒绝'
);
select throws_ok(
  $$ select app.log_integration_call('api', null, null, 'x', 200, -1, null, null, null) $$,
  '22023', null, '负耗时拒绝'
);

-- ===========================================================================
-- 6. ensure 分区：幂等 + 按需（3）
-- ===========================================================================
select app.ensure_integration_call_log_partition(date_trunc('month', current_date)::date) as part_a \gset
select app.ensure_integration_call_log_partition(current_date) as part_b \gset
select is(:'part_a'::text, :'part_b'::text, 'ensure 幂等（同月返回同名分区）');
select app.ensure_integration_call_log_partition((date_trunc('month', current_date) + interval '2 months')::date) as part_future \gset
select ok(
  to_regclass('public.' || :'part_future'::text) is not null,
  'ensure 按需创建未来月分区'
);
select ok(
  :'part_future'::text ~ '^integration_call_logs_[0-9]{4}_[0-9]{2}$',
  '分区命名规范（integration_call_logs_YYYY_MM）'
);

-- ===========================================================================
-- 7. webhook finalize 写入（11）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select public.create_webhook('调用日志测试', 'https://127.0.0.1:9/log', array['pgtap.log'],
                             '{"max_attempts":3,"backoff":"linear"}'::jsonb) as wh \gset
reset role;

insert into public.integration_events (event, payload, status, attempts)
values ('pgtap.log', '{"k":"v"}'::jsonb, 'delivering', 0)
returning id as ev \gset

insert into public.webhook_deliveries
  (event_id, webhook_id, attempt_no, request_id, status, attempted_at)
values
  (:'ev', (:'wh'::jsonb ->> 'id')::uuid, 0, 933000000000000011, 'delivering', now() - interval '2 seconds'),
  (:'ev', (:'wh'::jsonb ->> 'id')::uuid, 1, 933000000000000012, 'delivering', now() - interval '2 seconds'),
  (:'ev', (:'wh'::jsonb ->> 'id')::uuid, 2, 933000000000000013, 'delivering', now() - interval '11 minutes');

insert into net._http_response (id, status_code, created, content)
values (933000000000000011, 201, now(), '{"ok":true}');
insert into net._http_response (id, status_code, error_msg, created, content)
values (933000000000000012, 500, 'Internal Server Error', now(), 'boom');

select is(app.finalize_webhook_deliveries(), 1, 'finalize 收口 1 条事件（3 次投递）');
select is(
  (select count(*) from public.integration_call_logs where method_event = 'pgtap.log'),
  3::bigint,
  '3 次终态投递各写 1 条 webhook 调用日志'
);
select ok(
  (select kind = 'webhook'
          and status_code = 201
          and error is null
          and duration_ms >= 0
          and response_excerpt = '{"ok":true}'
          and request_excerpt like '%pgtap.log%'
     from public.integration_call_logs where method_event = 'pgtap.log' and status_code = 201),
  '2xx：状态/耗时/响应摘要/请求信封正确'
);
select is(
  (select webhook_id from public.integration_call_logs where method_event = 'pgtap.log' and status_code = 201),
  (:'wh'::jsonb ->> 'id')::uuid,
  '调用日志关联 webhook_id'
);
select is(
  (select error from public.integration_call_logs where method_event = 'pgtap.log' and status_code = 500),
  'Internal Server Error',
  '非 2xx：错误信息落日志'
);
select ok(
  (select status_code = 500 and duration_ms >= 0
     from public.integration_call_logs where method_event = 'pgtap.log' and status_code = 500),
  '非 2xx：状态码与耗时落日志'
);
select ok(
  (select status_code is null and error like '%超时%'
     from public.integration_call_logs where method_event = 'pgtap.log' and error like '%超时%'),
  '超时：状态码 NULL + 超时原因'
);
select ok(
  (select bool_and(char_length(coalesce(request_excerpt, '')) <= 2048
                   and char_length(coalesce(response_excerpt, '')) <= 2048)
     from public.integration_call_logs where method_event = 'pgtap.log'),
  'webhook 日志 excerpt 均不超过 2048 字符'
);
select ok(
  (select count(*) from public.integration_call_logs where method_event = 'pgtap.log' and kind = 'api') = 0,
  'webhook 日志不会误写 kind=api'
);

-- ===========================================================================
-- 8. api_departments 写入（5）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select public.create_api_key('pgTAP 日志密钥', '["org:read"]'::jsonb, now() + interval '1 day') as ck \gset
reset role;

set local role anon;
select public.issue_api_token((:'ck'::jsonb ->> 'key')) as tk \gset
select count(*) as dept_count from public.api_departments((:'tk'::jsonb ->> 'token')) \gset
reset role;

select ok(:'dept_count'::integer > 0, 'api_departments 端到端返回部门数据');
select ok(
  (select kind = 'api'
          and method_event = 'api_departments'
          and status_code = 200
          and key_id = (:'ck'::jsonb ->> 'id')::uuid
          and duration_ms >= 0
     from public.integration_call_logs
    where method_event = 'api_departments'),
  'api 调用写入日志（kind/key_id/状态/耗时）'
);
select ok(
  (select response_excerpt like '[%'
     from public.integration_call_logs where method_event = 'api_departments'),
  'api 日志响应摘要为 JSON 数组片段'
);
select ok(
  (select request_excerpt like '%org:read%'
     from public.integration_call_logs where method_event = 'api_departments'),
  'api 日志请求摘要含 scope（token 不落库）'
);
select ok(
  (select request_excerpt not like '%' || (:'tk'::jsonb ->> 'token') || '%'
     from public.integration_call_logs where method_event = 'api_departments'),
  'api 日志不落 token 明文'
);

-- ===========================================================================
-- 9. stats_daily 聚合（6）
-- ===========================================================================
select app.aggregate_integration_call_stats_daily(current_date) as agg_rows \gset
select ok(:'agg_rows'::integer >= 3, '聚合覆盖 ≥3 个 kind+ref 分组');
select ok(
  (select total = 1 and failed = 0 and avg_duration_ms is not null
          and ref_name = 'pgTAP 日志密钥'
     from public.integration_call_stats_daily
    where day = current_date and kind = 'api' and ref_id = (:'ck'::jsonb ->> 'id')::uuid),
  'api 聚合：total=1 / failed=0 / 名称快照正确'
);
select ok(
  (select total = 3 and failed = 2 and avg_duration_ms is not null
     from public.integration_call_stats_daily
    where day = current_date and kind = 'webhook' and ref_id = (:'wh'::jsonb ->> 'id')::uuid),
  'webhook 聚合：total=3 / failed=2（500+超时）/ 均值非空'
);
select ok(
  (select total = 3 and failed = 1
     from public.integration_call_stats_daily
    where day = current_date and kind = 'api'
      and ref_id = '00000000-0000-0000-0000-000000000000'::uuid),
  '无引用 api 日志归零 UUID 分组（含 500 记 failed）'
);
select app.aggregate_integration_call_stats_daily(current_date) as agg_again \gset
select is(
  (select count(*) from public.integration_call_stats_daily where day = current_date),
  (select count(distinct (kind, coalesce(key_id, webhook_id,
                                        '00000000-0000-0000-0000-000000000000'::uuid)))
     from public.integration_call_logs
    where created_at >= current_date and created_at < current_date + 1),
  '聚合幂等（重算后分组数与明细一致）'
);
select is(:'agg_rows'::integer, :'agg_again'::integer, '重复聚合返回分组数一致');

-- ===========================================================================
-- 10. 30 天清理（5）
-- ===========================================================================
select app.ensure_integration_call_log_partition((current_date - interval '45 days')::date) as old_part \gset
insert into public.integration_call_logs (kind, method_event, error, created_at)
values ('api', 'old.call', 'expired', now() - interval '45 days')
returning id as old_log \gset
select app.cleanup_integration_call_logs() as cleaned \gset
select ok(
  :'cleaned'::integer >= 1 or to_regclass('public.' || :'old_part'::text) is null,
  '清理整体过期分区（drop）或行级删除（返回行数 ≥1 / 分区不存在）'
);
select ok(
  not exists (select 1 from public.integration_call_logs where id = :'old_log'),
  '30 天前明细不可查'
);
select ok(
  not exists (select 1 from public.integration_call_logs where created_at < now() - interval '30 days'),
  '清理后不存在超过 30 天的明细'
);
select ok(
  exists (select 1 from public.integration_call_logs where method_event = 'api_departments'),
  '保留期内明细不受清理影响'
);
select ok(
  to_regclass('public.' || :'old_part') is null
  or not exists (
    select 1 from public.integration_call_logs where created_at < now() - interval '30 days'
  ),
  '过期月分区被 drop 或已清空（整体过期策略）'
);

-- 行级清理路径：保留期取本月天数，使 cutoff 落在上月分区内（分区保留、行删除）
select extract(day from now())::integer as dom \gset
select app.ensure_integration_call_log_partition(
  (date_trunc('month', now()) - interval '1 day')::date
) as boundary_part \gset
insert into public.integration_call_logs (kind, method_event, created_at)
values ('api', 'boundary.call', date_trunc('month', now()) - interval '1 day')
returning id as boundary_log \gset
select app.cleanup_integration_call_logs(:'dom'::integer) as cleaned_rows \gset
select ok(:'cleaned_rows'::integer >= 1, '保留分区内超过保留期的行被行级删除');
select ok(
  not exists (select 1 from public.integration_call_logs where id = :'boundary_log'),
  '行级清理后过期明细不可查'
);

-- ===========================================================================
-- 11. 导出源 integration.logs（4）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select public.request_export('integration.logs') as exp \gset
reset role;
select is(
  (select source from public.export_jobs where id = :'exp'),
  'integration.logs',
  'admin 可发起 integration.logs 导出'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.request_export('integration.logs') $$,
  '42501', null, '非 admin 发起 integration.logs 导出被拒（admin 独占源）'
);
reset role;

select ok(app.process_export_jobs() >= 1, 'worker 处理排队任务');
select ok(
  (select status = 'done'
          and content like 'id,created_at,kind,ref_name,method_event,status_code,duration_ms,error%'
          and content like '%api_departments%'
          and content like '%pgtap.log%'
     from public.export_jobs where id = :'exp'),
  'worker 生成 CSV（表头/调用明细落列）'
);

-- ===========================================================================
-- 12. RLS 与 pg_cron/登记处（6）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select ok(
  (select count(*) from public.integration_call_logs) > 0,
  'RLS：admin 可见调用明细'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select count(*) from public.integration_call_logs),
  0::bigint,
  'RLS：engineer 不可见调用明细'
);
reset role;

set local role anon;
select throws_ok(
  $$ select count(*) from public.integration_call_logs $$,
  '42501', null, 'anon 直读明细被拒（无授权）'
);
reset role;

select ok(
  exists (
    select 1 from cron.job
     where jobname = 'aggregate-integration-call-stats'
       and schedule = '10 0 * * *'
       and command like '%aggregate_integration_call_stats_daily%'
  ),
  'pg_cron 已注册每日聚合'
);
select ok(
  exists (
    select 1 from cron.job
     where jobname = 'cleanup-integration-call-logs'
       and schedule = '20 3 * * *'
       and command like '%cleanup_integration_call_logs%'
  ),
  'pg_cron 已注册每日清理'
);
select ok(
  (select count(*) from public.system_cron_registry
    where job_name in ('aggregate-integration-call-stats', 'cleanup-integration-call-logs')
      and module = 'integration'
      and owner_route = '/integration/logs'
      and status = 'active') = 2,
  'system 登记处已登记两个 job（integration / /integration/logs）'
);

select * from finish();
rollback;
