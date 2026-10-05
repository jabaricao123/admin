-- pgTAP：integration 批次 4 —— API key 近 30 天用量统计 RPC get_api_key_usage
-- 运行：supabase db reset && supabase test db
-- 覆盖：函数存在/SECURITY 属性/授权（仅 authenticated；函数内 admin 校验）；
--       越权 42501、参数校验（NULL 22023、未知 key P0002）；
--       明细 + stats_daily 合并口径（天级去重、明细优先、窗口 30 天、加权均值）；
--       无数据 key 返回空 days 与 0 值。
-- 说明：夹具只在本事务内生效，finish 后 rollback。

begin;

select plan(21);

-- ===========================================================================
-- 1. 函数存在 / 属性 / 授权（4）
-- ===========================================================================
select has_function('app', 'get_api_key_usage', array['uuid'],
  'app.get_api_key_usage(uuid) 存在');
select has_function('public', 'get_api_key_usage', array['uuid'],
  'public.get_api_key_usage(uuid) 薄包装存在');
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'get_api_key_usage'),
  'app 实现为 SECURITY DEFINER + search_path 空（函数内 admin 校验）'
);
select ok(
  has_function_privilege('authenticated', 'public.get_api_key_usage(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.get_api_key_usage(uuid)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.get_api_key_usage(uuid)', 'EXECUTE'),
  '仅 authenticated 可执行包装（anon/service_role 无）'
);

-- ===========================================================================
-- 2. 夹具：密钥 + 明细 + 历史聚合（admin 身份）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.create_api_key('用量统计密钥', '["org:read"]'::jsonb, null) as uk \gset
select public.create_api_key('空用量密钥', '["org:read"]'::jsonb, null) as ek \gset

reset role;

-- 当天明细 3 条（2 成功 + 1 失败）
select app.log_integration_call('api', (:'uk'::jsonb ->> 'id')::uuid, null,
  'api_usage.test', 200, 100, null, null, null);
select app.log_integration_call('api', (:'uk'::jsonb ->> 'id')::uuid, null,
  'api_usage.test', 500, 300, null, null, 'boom');
select app.log_integration_call('api', (:'uk'::jsonb ->> 'id')::uuid, null,
  'api_usage.test', 401, 50, null, null, 'denied');

-- 历史聚合：20 天前（窗口内）+ 35 天前（窗口外）
insert into public.integration_call_stats_daily
  (day, kind, ref_id, ref_name, total, failed, avg_duration_ms)
values
  (current_date - 20, 'api', (:'uk'::jsonb ->> 'id')::uuid, '用量统计密钥', 10, 2, 123.4),
  (current_date - 35, 'api', (:'uk'::jsonb ->> 'id')::uuid, '用量统计密钥', 77, 0, 5.0);

-- ===========================================================================
-- 3. 越权 / 参数校验（3）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  format('select public.get_api_key_usage(%L::uuid)', (:'uk'::jsonb ->> 'id')),
  '42501', null, 'engineer 查询用量被 admin 校验拒绝'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
select throws_ok(
  $$ select public.get_api_key_usage(null) $$,
  '22023', null, 'NULL key_id 报 22023'
);
select throws_ok(
  $$ select public.get_api_key_usage('00000000-0000-0000-0000-000000000000'::uuid) $$,
  'P0002', null, '未知 key 报 P0002'
);

-- ===========================================================================
-- 4. 聚合口径（10）
-- ===========================================================================
select public.get_api_key_usage((:'uk'::jsonb ->> 'id')::uuid) as usage \gset

select is((:'usage'::jsonb ->> 'total')::bigint, 13::bigint,
  'total = 当天明细 3 + 20 天前聚合 10');
select is((:'usage'::jsonb ->> 'failed')::bigint, 4::bigint,
  'failed = 明细 500/401 + 聚合 2');
select is((:'usage'::jsonb ->> 'success')::bigint, 9::bigint,
  'success = total - failed');
select is((:'usage'::jsonb ->> 'avg_duration_ms')::numeric, 129.5::numeric,
  'avg 为按天 total 加权（(150*3 + 123.4*10) / 13）');
select is((:'usage'::jsonb ->> 'name'), '用量统计密钥', '返回密钥名称');
select is(
  (:'usage'::jsonb ->> 'key_prefix'),
  (:'uk'::jsonb ->> 'key_prefix'),
  '返回 key_prefix'
);
select is(
  (:'usage'::jsonb ->> 'since')::date,
  current_date - 29,
  'since = 近 30 天窗口起点（current_date - 29）'
);
select is(
  jsonb_array_length(:'usage'::jsonb -> 'days'),
  2,
  'days 仅含窗口内 2 天（当天明细 + 20 天前聚合）'
);
select ok(
  (select count(*) = 1
     from jsonb_array_elements(:'usage'::jsonb -> 'days') d
    where (d ->> 'day')::date = current_date - 20
      and (d ->> 'total')::bigint = 10),
  '20 天前聚合日补齐进 days'
);
select ok(
  not exists (
    select 1
    from jsonb_array_elements(:'usage'::jsonb -> 'days') d
    where (d ->> 'day')::date = current_date - 35
  ),
  '35 天前数据在 30 天窗口外（不计入）'
);

-- 同日 stats 行不覆盖明细（明细优先）
insert into public.integration_call_stats_daily
  (day, kind, ref_id, ref_name, total, failed, avg_duration_ms)
values (current_date, 'api', (:'uk'::jsonb ->> 'id')::uuid, '用量统计密钥', 99, 9, 999.9);

select public.get_api_key_usage((:'uk'::jsonb ->> 'id')::uuid) as usage2 \gset

select is(
  (select (d ->> 'total')::bigint
     from jsonb_array_elements(:'usage2'::jsonb -> 'days') d
    where (d ->> 'day')::date = current_date),
  3::bigint,
  '同日明细优先于 stats_daily（当天仍为 3）'
);

-- ===========================================================================
-- 5. 无数据密钥：空 days 与 0 值（3）
-- ===========================================================================
select public.get_api_key_usage((:'ek'::jsonb ->> 'id')::uuid) as empty_usage \gset

select is((:'empty_usage'::jsonb ->> 'total')::bigint, 0::bigint, '无调用 key total=0');
select is((:'empty_usage'::jsonb ->> 'failed')::bigint, 0::bigint, '无调用 key failed=0');
select is(
  jsonb_array_length(:'empty_usage'::jsonb -> 'days'),
  0,
  '无调用 key days=[]'
);

select * from finish();
rollback;
