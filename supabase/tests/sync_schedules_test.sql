-- pgTAP：sync/007 —— sync_schedules 调度：结构 / cron 解析与注册注销 / 启停 / webhook 验签限流
-- 运行：supabase db reset && supabase test db
-- 覆盖：表结构/约束/RLS/触发器；cron 数字语法解析与下次执行时间（含时区）；
--       cron 注册（cron.job 同名幂等更新）/停用注销/expression 校验；启用前置（任务启用 + 数据源已验证）；
--       「停用当次跑完再注销」disabled_pending_unschedule 流程（job 保留 → 执行收尾注销）；
--       webhook token 生成/哈希落库/轮换/旧 token 失效/限流 60 次每分钟/停用拒绝；
--       run_scheduled_sync cron 回调（active 才执行、更新 last/next_run_at）；
--       GRANT 面（anon 可调 webhook、不可调 run_scheduled_sync；无 API 直调注册函数）。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(139);

-- ===========================================================================
-- 1. 结构：sync_schedules
-- ===========================================================================
select has_table('public', 'sync_schedules', 'sync_schedules 表存在');
select col_is_pk('public', 'sync_schedules', 'id', 'id 为主键');
select col_is_fk('public', 'sync_schedules', 'task_id', 'task_id 外键 → sync_tasks');
select col_is_unique('public', 'sync_schedules', 'task_id', 'task_id 唯一（任务一对一调度）');

select col_type_is('public', 'sync_schedules', 'task_id', 'uuid', 'task_id 为 uuid');
select col_type_is('public', 'sync_schedules', 'trigger_type', 'text', 'trigger_type 为 text');
select col_type_is('public', 'sync_schedules', 'cron_expr', 'text', 'cron_expr 为 text');
select col_type_is('public', 'sync_schedules', 'timezone', 'text', 'timezone 为 text');
select col_type_is('public', 'sync_schedules', 'webhook_token_hash', 'text', 'webhook_token_hash 为 text');
select col_type_is('public', 'sync_schedules', 'status', 'text', 'status 为 text');
select col_type_is('public', 'sync_schedules', 'last_run_at', 'timestamp with time zone', 'last_run_at 为 timestamptz');
select col_type_is('public', 'sync_schedules', 'next_run_at', 'timestamp with time zone', 'next_run_at 为 timestamptz');

select col_not_null('public', 'sync_schedules', 'task_id', 'task_id 非空');
select col_not_null('public', 'sync_schedules', 'trigger_type', 'trigger_type 非空');
select col_not_null('public', 'sync_schedules', 'timezone', 'timezone 非空');
select col_not_null('public', 'sync_schedules', 'status', 'status 非空');
select col_has_default('public', 'sync_schedules', 'trigger_type', 'trigger_type 有默认值');
select col_has_default('public', 'sync_schedules', 'timezone', 'timezone 默认 Asia/Shanghai');
select col_has_default('public', 'sync_schedules', 'status', 'status 默认 active');
select col_has_check('public', 'sync_schedules', 'trigger_type', 'trigger_type 有取值 check');
select col_has_check('public', 'sync_schedules', 'status', 'status 有状态机 check');
select ok(
  exists (
    select 1 from pg_constraint
    where conrelid = 'public.sync_schedules'::regclass
      and conname = 'sync_schedules_cron_expr_check'
  ),
  'cron_expr 有 cron 型必填 check'
);
select ok(
  exists (
    select 1 from pg_constraint
    where conrelid = 'public.sync_schedules'::regclass
      and conname = 'sync_schedules_token_check'
  ),
  'token hash 有 webhook 型必填 check'
);

select has_trigger('public', 'sync_schedules', 'sync_schedules_set_updated_at', 'updated_at 触发器存在');
select is(
  (select relrowsecurity from pg_class where oid = 'public.sync_schedules'::regclass),
  true,
  'sync_schedules 已启用 RLS'
);
select ok(
  (select count(*) = 1 from pg_policies
    where schemaname = 'public' and tablename = 'sync_schedules'
      and policyname = 'sync_schedules_select_admin' and cmd = 'SELECT'),
  'sync_schedules 仅 1 条 admin SELECT 策略'
);
select has_index('public', 'sync_schedules', 'sync_schedules_status_idx', 'status 索引存在');

-- ===========================================================================
-- 2. cron 解析 helper：cron_field_values / cron_expr_valid / next_cron_run
-- ===========================================================================
select is(
  app.cron_field_values('*', 0, 59),
  (select array_agg(g order by g) from generate_series(0, 59) g),
  'cron_field_values：* 展开全量'
);
select is(
  app.cron_field_values('*/15', 0, 59),
  array[0, 15, 30, 45],
  'cron_field_values：*/n 步长'
);
select is(
  app.cron_field_values('1-5', 0, 59),
  array[1, 2, 3, 4, 5],
  'cron_field_values：a-b 范围'
);
select is(
  app.cron_field_values('0,30', 0, 59),
  array[0, 30],
  'cron_field_values：列表'
);
select is(
  app.cron_field_values('10-20/5', 0, 59),
  array[10, 15, 20],
  'cron_field_values：a-b/n 范围步长'
);
select is(app.cron_field_values('60', 0, 59), null::int[], 'cron_field_values：越界返回 NULL');
select is(app.cron_field_values('abc', 0, 59), null::int[], 'cron_field_values：非数字返回 NULL');
select is(app.cron_field_values('*/0', 0, 59), null::int[], 'cron_field_values：步长 0 返回 NULL');
select is(app.cron_field_values('', 0, 59), null::int[], 'cron_field_values：空串返回 NULL');

select ok(app.cron_expr_valid('0 9 * * 1-5'), 'cron_expr_valid：五段数字语法合法');
select ok(app.cron_expr_valid('*/5 * * * *'), 'cron_expr_valid：*/n 合法');
select ok(not app.cron_expr_valid('0 9 * *'), 'cron_expr_valid：四段非法');
select ok(not app.cron_expr_valid('60 9 * * *'), 'cron_expr_valid：分钟越界非法');
select ok(not app.cron_expr_valid('a b c d e'), 'cron_expr_valid：字母非法');

select is(
  app.next_cron_run('0 * * * *', 'UTC', '2026-01-01 10:30:15+00'::timestamptz),
  '2026-01-01 11:00:00+00'::timestamptz,
  'next_cron_run：每小时整点（UTC）'
);
select is(
  app.next_cron_run('30 9 * * *', 'Asia/Shanghai', '2026-01-01 01:00:00+00'::timestamptz),
  '2026-01-01 01:30:00+00'::timestamptz,
  'next_cron_run：每日 09:30 Asia/Shanghai 时区换算'
);
select is(
  app.next_cron_run('0 9 * * 1', 'Asia/Shanghai', '2026-01-01 00:00:00+00'::timestamptz),
  '2026-01-05 01:00:00+00'::timestamptz,
  'next_cron_run：每周一 09:00（跨周计算）'
);
select is(
  app.next_cron_run('5 0 * * *', 'Asia/Shanghai', '2026-01-01 16:04:00+00'::timestamptz),
  '2026-01-01 16:05:00+00'::timestamptz,
  'next_cron_run：跨日边界取下一分钟'
);
select ok(
  app.next_cron_run('0 0 1 * 1', 'UTC', '2026-01-01 00:00:00+00'::timestamptz) is not null,
  'next_cron_run：dom 与 dow 同时受限可计算（OR 语义）'
);
select is(
  app.next_cron_run('0 0 31 2 *', 'UTC', '2026-01-01 00:00:00+00'::timestamptz),
  null::timestamptz,
  'next_cron_run：窗口内无匹配返回 NULL'
);
select is(
  app.next_cron_run('0 0 * * *', 'Not/AZone', '2026-01-01 00:00:00+00'::timestamptz),
  null::timestamptz,
  'next_cron_run：非法时区返回 NULL'
);
select is(
  app.next_cron_run('bad', 'UTC', '2026-01-01 00:00:00+00'::timestamptz),
  null::timestamptz,
  'next_cron_run：非法表达式返回 NULL'
);

-- ===========================================================================
-- 3. 函数存在性 + SECURITY/GRANT 面
-- ===========================================================================
select has_function('app', 'cron_field_values', array['text', 'integer', 'integer'], 'app.cron_field_values 存在');
select has_function('app', 'cron_expr_valid', array['text'], 'app.cron_expr_valid 存在');
select has_function('app', 'next_cron_run', array['text', 'text', 'timestamptz'], 'app.next_cron_run 存在');
select has_function(
  'app', 'sync_schedule_register_cron', array['uuid', 'text', 'text'],
  'app.sync_schedule_register_cron 存在（含时区参数）'
);
select has_function('app', 'sync_schedule_unregister_cron', array['uuid'], 'app.sync_schedule_unregister_cron 存在');
select has_function(
  'app', 'upsert_sync_schedule',
  array['uuid', 'text', 'text', 'text', 'text', 'boolean'],
  'app.upsert_sync_schedule 存在'
);
select has_function('app', 'set_sync_schedule_status', array['uuid', 'text'], 'app.set_sync_schedule_status 存在');
select has_function('app', 'get_sync_schedules', array[]::text[], 'app.get_sync_schedules 存在');
select has_function(
  'public', 'upsert_sync_schedule',
  array['uuid', 'text', 'text', 'text', 'text', 'boolean'],
  'public.upsert_sync_schedule 薄包装存在'
);
select has_function('public', 'set_sync_schedule_status', array['uuid', 'text'], 'public.set_sync_schedule_status 薄包装存在');
select has_function('public', 'get_sync_schedules', array[]::text[], 'public.get_sync_schedules 薄包装存在');
select has_function('public', 'trigger_sync_webhook', array['text'], 'public.trigger_sync_webhook 存在');
select has_function('public', 'run_scheduled_sync', array['uuid'], 'public.run_scheduled_sync 存在');

select ok(
  (select count(*) = 10
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
      ('app', 'sync_schedule_register_cron'), ('app', 'sync_schedule_unregister_cron'),
      ('app', 'upsert_sync_schedule'), ('app', 'set_sync_schedule_status'),
      ('app', 'get_sync_schedules'),
      ('public', 'upsert_sync_schedule'), ('public', 'set_sync_schedule_status'),
      ('public', 'get_sync_schedules'), ('public', 'trigger_sync_webhook'),
      ('public', 'run_scheduled_sync')
    )
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '10 个调度函数 SECURITY DEFINER + search_path 固定为空'
);
select ok(
  (select count(*) = 3
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in
      (('app', 'cron_field_values'), ('app', 'cron_expr_valid'), ('app', 'next_cron_run'))
      and p.proconfig @> array['search_path=""']
      and not p.prosecdef),
  'cron 解析 helper 为 SECURITY INVOKER + search_path 固定为空'
);

select ok(
  has_function_privilege('authenticated', 'public.upsert_sync_schedule(uuid,text,text,text,text,boolean)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.set_sync_schedule_status(uuid,text)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.get_sync_schedules()', 'EXECUTE'),
  'authenticated 可执行调度管理 RPC'
);
select ok(
  has_function_privilege('anon', 'public.trigger_sync_webhook(text)', 'EXECUTE'),
  'anon 可执行 webhook 触发端点（公开 URL）'
);
select ok(
  not has_function_privilege('anon', 'public.run_scheduled_sync(uuid)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.run_scheduled_sync(uuid)', 'EXECUTE'),
  'cron 回调 run_scheduled_sync 无 API 角色执行权（仅 pg_cron 可达）'
);
select ok(
  not has_function_privilege('authenticated', 'app.sync_schedule_register_cron(uuid,text,text)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'app.cron_field_values(text,integer,integer)', 'EXECUTE'),
  'authenticated 无注册/解析内部函数执行权'
);
select ok(
  not has_function_privilege('service_role', 'public.trigger_sync_webhook(text)', 'EXECUTE')
    and not has_function_privilege('service_role', 'public.upsert_sync_schedule(uuid,text,text,text,text,boolean)', 'EXECUTE'),
  'service_role 零执行权（全局禁 service_role）'
);
select ok(
  has_table_privilege('authenticated', 'public.sync_schedules', 'SELECT')
    and not has_table_privilege('authenticated', 'public.sync_schedules', 'INSERT')
    and not has_table_privilege('authenticated', 'public.sync_schedules', 'UPDATE'),
  'authenticated 对 sync_schedules 仅 SELECT'
);

-- ===========================================================================
-- 4. 夹具：源 + 任务 + cron 注册/更新/注销
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.upsert_sync_source(
  null, '调度测试源', 'api', '{"base_url":"https://sched.example.com"}'::jsonb, 'tok-sched', null
) as ss \gset
select public.test_sync_source((:'ss'::jsonb ->> 'id')::uuid) as ssv \gset

select public.upsert_sync_task(
  null, '定时任务', (:'ss'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"dept","target_field":"name"}]'::jsonb, 'skip', null
) as tc \gset
select public.upsert_sync_task(
  null, 'Webhook 任务', (:'ss'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"dept","target_field":"name"}]'::jsonb, 'skip', null
) as tw \gset
select public.upsert_sync_task(
  null, '待注销任务', (:'ss'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"dept","target_field":"name"}]'::jsonb, 'skip', null
) as tr \gset
select public.upsert_sync_task(
  null, '无调度任务', (:'ss'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"dept","target_field":"name"}]'::jsonb, 'skip', null
) as tn \gset
select public.upsert_sync_task(
  null, '停用调度任务', (:'ss'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"dept","target_field":"name"}]'::jsonb, 'skip', 'disabled'
) as td \gset

select public.upsert_sync_schedule(
  (:'tc'::jsonb ->> 'id')::uuid, 'cron', '0 9 * * *', 'Asia/Shanghai', 'active', false
) as sc \gset
reset role;

select is((:'ssv'::jsonb) ->> 'verify_status', 'verified', '夹具：数据源已验证');
select is((:'sc'::jsonb) ->> 'trigger_type', 'cron', 'upsert 返回 cron 型');
select is((:'sc'::jsonb) ->> 'status', 'active', 'upsert 返回 active');
select is((:'sc'::jsonb) ->> 'timezone', 'Asia/Shanghai', 'upsert 返回时区');
select is((:'sc'::jsonb) ->> 'webhook_token', null::text, 'cron 型不返回 token');
select ok((:'sc'::jsonb) ->> 'next_run_at' is not null, 'cron 型计算 next_run_at');

select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'tc'::jsonb ->> 'id')),
  1::bigint,
  'cron 型注册 pg_cron job'
);
select is(
  (select schedule from cron.job where jobname = 'sync-task-' || (:'tc'::jsonb ->> 'id')),
  '0 9 * * *',
  'pg_cron job 表达式正确'
);
select is(
  (select command from cron.job where jobname = 'sync-task-' || (:'tc'::jsonb ->> 'id')),
  'select public.run_scheduled_sync(''' || (:'tc'::jsonb ->> 'id') || ''')',
  'pg_cron job 命令指向 run_scheduled_sync'
);
select is(
  (select active from cron.job where jobname = 'sync-task-' || (:'tc'::jsonb ->> 'id')),
  true,
  'pg_cron job 处于启用状态'
);

-- 同名更新（表达式变更、jobid 不变）
select jobid as cron_jobid_before from cron.job
 where jobname = 'sync-task-' || (:'tc'::jsonb ->> 'id') \gset
set local role authenticated;
select public.upsert_sync_schedule(
  (:'tc'::jsonb ->> 'id')::uuid, 'cron', '0 10 * * 1-5', 'Asia/Shanghai', 'active', false
) as sc2 \gset
reset role;
select is(
  (select jobid from cron.job where jobname = 'sync-task-' || (:'tc'::jsonb ->> 'id')),
  :'cron_jobid_before'::bigint,
  'cron 编辑同名更新 job（jobid 不变）'
);
select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'tc'::jsonb ->> 'id')),
  1::bigint,
  'cron 编辑不产生重复 job'
);
select is(
  (select schedule from cron.job where jobname = 'sync-task-' || (:'tc'::jsonb ->> 'id')),
  '0 10 * * 1-5',
  'cron 编辑更新 job 表达式'
);
select is((:'sc2'::jsonb) ->> 'cron_expr', '0 10 * * 1-5', 'upsert 返回新表达式');

-- 非法表达式 / 缺表达式 / 非法时区
set local role authenticated;
select throws_ok(
  format(
    $q$ select public.upsert_sync_schedule(%L::uuid, 'cron', '99 * * * *', 'UTC', 'active', false) $q$,
    (:'tc'::jsonb ->> 'id')
  ),
  '22023', null, 'cron 表达式越界被拒'
);
select throws_ok(
  format(
    $q$ select public.upsert_sync_schedule(%L::uuid, 'cron', null, 'UTC', 'active', false) $q$,
    (:'tn'::jsonb ->> 'id')
  ),
  '22023', null, 'cron 型缺少表达式被拒（新建）'
);
select throws_ok(
  format(
    $q$ select public.upsert_sync_schedule(%L::uuid, 'cron', '0 9 * * *', 'Nowhere/Zone', 'active', false) $q$,
    (:'tc'::jsonb ->> 'id')
  ),
  '22023', null, '非法时区被拒'
);
select throws_ok(
  format(
    $q$ select public.upsert_sync_schedule(%L::uuid, 'bogus', null, 'UTC', null, false) $q$,
    (:'tc'::jsonb ->> 'id')
  ),
  '22023', null, '非法触发方式被拒'
);
reset role;

-- 切换 manual：注销 job 且清空表达式
set local role authenticated;
select public.upsert_sync_schedule(
  (:'tc'::jsonb ->> 'id')::uuid, 'manual', null, 'Asia/Shanghai', null, false
) as sc3 \gset
select public.upsert_sync_schedule(
  (:'tc'::jsonb ->> 'id')::uuid, 'cron', '0 9 * * *', 'Asia/Shanghai', 'active', false
) as sc4 \gset
select public.upsert_sync_schedule(
  (:'tc'::jsonb ->> 'id')::uuid, 'manual', null, 'Asia/Shanghai', null, false
) as sc5 \gset
reset role;
select is((:'sc5'::jsonb) ->> 'cron_expr', null::text, 'manual 型清空 cron_expr');
select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'tc'::jsonb ->> 'id')),
  0::bigint,
  '切换 manual 注销 pg_cron job'
);

-- ===========================================================================
-- 5. 启停：disable 立即注销 / enable 要求任务启用且数据源已验证
-- ===========================================================================
-- 恢复 cron active
set local role authenticated;
select public.upsert_sync_schedule(
  (:'tc'::jsonb ->> 'id')::uuid, 'cron', '0 9 * * *', 'Asia/Shanghai', 'active', false
) as sc6 \gset
select public.set_sync_schedule_status((:'tc'::jsonb ->> 'id')::uuid, 'disabled') as sc_dis \gset
reset role;
select is((:'sc_dis'::jsonb) ->> 'status', 'disabled', '停用立即置 disabled');
select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'tc'::jsonb ->> 'id')),
  0::bigint,
  '停用（无运行中 run）立即注销 job'
);
select is(
  (select next_run_at from public.sync_schedules where task_id = (:'tc'::jsonb ->> 'id')::uuid),
  null::timestamptz,
  '停用清空 next_run_at'
);

set local role authenticated;
select public.set_sync_schedule_status((:'tc'::jsonb ->> 'id')::uuid, 'active') as sc_en \gset
reset role;
select is((:'sc_en'::jsonb) ->> 'status', 'active', '重新启用');
select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'tc'::jsonb ->> 'id')),
  1::bigint,
  '启用重新注册 job'
);
select ok((:'sc_en'::jsonb) ->> 'next_run_at' is not null, '启用重算 next_run_at');

-- 启用前置：任务停用 / 调度不存在 / 非法状态
set local role authenticated;
select throws_ok(
  format(
    $q$ select public.upsert_sync_schedule(%L::uuid, 'cron', '0 9 * * *', 'UTC', 'active', false) $q$,
    (:'td'::jsonb ->> 'id')
  ),
  '22023', null, '停用任务不能启用调度'
);
select throws_ok(
  format(
    $q$ select public.set_sync_schedule_status(%L::uuid, 'active') $q$,
    (:'td'::jsonb ->> 'id')
  ),
  'P0002', null, '无调度行的任务启停被拒'
);
select throws_ok(
  format(
    $q$ select public.set_sync_schedule_status(%L::uuid, 'bogus') $q$,
    (:'tc'::jsonb ->> 'id')
  ),
  '22023', null, '非法状态被拒'
);
reset role;

-- 停用任务 + 不带状态 upsert → 自动落 disabled（不注册 job）
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select public.upsert_sync_schedule(
  (:'td'::jsonb ->> 'id')::uuid, 'cron', '0 9 * * *', 'UTC', null, false
) as sc_td \gset
reset role;
select is((:'sc_td'::jsonb) ->> 'status', 'disabled', '停用任务的新调度自动落 disabled');
select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'td'::jsonb ->> 'id')),
  0::bigint,
  '停用任务不注册 job'
);

-- ===========================================================================
-- 6. 「停用当次跑完再注销」：disabled_pending_unschedule 流程
-- ===========================================================================
set local role authenticated;
select public.upsert_sync_schedule(
  (:'tr'::jsonb ->> 'id')::uuid, 'cron', '*/5 * * * *', 'UTC', 'active', false
) as sr \gset
reset role;
select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'tr'::jsonb ->> 'id')),
  1::bigint,
  '待注销任务：job 已注册'
);

insert into public.sync_runs (task_id, trigger_type, status)
values ((:'tr'::jsonb ->> 'id')::uuid, 'cron', 'running');

set local role authenticated;
select public.set_sync_schedule_status((:'tr'::jsonb ->> 'id')::uuid, 'disabled') as sr_dis \gset
reset role;
select is(
  (:'sr_dis'::jsonb) ->> 'status',
  'disabled_pending_unschedule',
  '有运行中 run 时停用 → disabled_pending_unschedule'
);
select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'tr'::jsonb ->> 'id')),
  1::bigint,
  '待注销期间 job 保留（当次跑完再注销）'
);
select is(
  public.run_scheduled_sync((:'tr'::jsonb ->> 'id')::uuid),
  null::uuid,
  '待注销调度不再产生新 run（cron 回调跳过）'
);

-- 模拟当次 run 完成 → 再执行一次，收尾注销 job
update public.sync_runs
   set status = 'success', finished_at = now()
 where task_id = (:'tr'::jsonb ->> 'id')::uuid and status = 'running';
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
select app.execute_sync_task((:'tr'::jsonb ->> 'id')::uuid, 'manual', '[]'::jsonb) as sr_fin \gset
select is(
  (select count(*) from cron.job where jobname = 'sync-task-' || (:'tr'::jsonb ->> 'id')),
  0::bigint,
  '执行收尾注销 pending job'
);
select is(
  (select status from public.sync_schedules where task_id = (:'tr'::jsonb ->> 'id')::uuid),
  'disabled',
  '收尾后收敛为 disabled'
);
select ok(
  (select last_run_at is not null from public.sync_schedules where task_id = (:'tr'::jsonb ->> 'id')::uuid),
  '执行后写入 last_run_at'
);

-- ===========================================================================
-- 7. webhook：token 生成/验签/轮换/停用/限流
-- ===========================================================================
set local role authenticated;
select public.upsert_sync_schedule(
  (:'tw'::jsonb ->> 'id')::uuid, 'webhook', null, 'Asia/Shanghai', 'active', false
) as sw \gset
reset role;

select ok(
  (:'sw'::jsonb) ->> 'webhook_token' like 'st_%',
  'webhook 型返回 st_ 前缀明文 token（一次性）'
);
select is(
  (select webhook_token_hash from public.sync_schedules where task_id = (:'tw'::jsonb ->> 'id')::uuid),
  encode(extensions.digest((:'sw'::jsonb) ->> 'webhook_token', 'sha256'), 'hex'),
  '落库为 token 的 sha256（不存明文）'
);
select is(
  (select count(*) from public.sync_schedules where task_id = (:'tw'::jsonb ->> 'id')::uuid
    and webhook_token_hash = (:'sw'::jsonb) ->> 'webhook_token'),
  0::bigint,
  '库中不存在明文 token'
);

set local role anon;
select public.trigger_sync_webhook((:'sw'::jsonb) ->> 'webhook_token') as wh_run \gset
reset role;
select is(
  (select trigger_type from public.sync_runs where id = :'wh_run'),
  'webhook',
  'anon 携有效 token 触发创建 webhook run'
);
select is(
  (select executed_by from public.sync_runs where id = :'wh_run'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'webhook 执行身份 = 任务 created_by（属主）'
);

set local role anon;
select throws_ok(
  $$ select public.trigger_sync_webhook('st_wrong-token') $$,
  '42501', null, '错误 token 被拒'
);
select throws_ok(
  $$ select public.trigger_sync_webhook(null) $$,
  '42501', null, '空 token 被拒'
);
select throws_ok(
  $$ select public.trigger_sync_webhook('') $$,
  '42501', null, '空串 token 被拒'
);
reset role;

-- token 轮换：旧 token 失效，新 token 有效
set local role authenticated;
select public.upsert_sync_schedule(
  (:'tw'::jsonb ->> 'id')::uuid, 'webhook', null, 'Asia/Shanghai', 'active', true
) as sw2 \gset
reset role;
select ok(
  (:'sw2'::jsonb) ->> 'webhook_token' is not null
    and (:'sw2'::jsonb) ->> 'webhook_token' <> (:'sw'::jsonb) ->> 'webhook_token',
  'token 重置返回新明文'
);
set local role anon;
select throws_ok(
  format($q$ select public.trigger_sync_webhook(%L) $q$, (:'sw'::jsonb) ->> 'webhook_token'),
  '42501', null, '轮换后旧 token 失效（401 语义）'
);
reset role;

-- 停用后拒触发
set local role authenticated;
select public.set_sync_schedule_status((:'tw'::jsonb ->> 'id')::uuid, 'disabled') as sw_dis \gset
reset role;
set local role anon;
select throws_ok(
  format($q$ select public.trigger_sync_webhook(%L) $q$, (:'sw2'::jsonb) ->> 'webhook_token'),
  '22023', null, '停用调度 webhook 触发被拒'
);
reset role;
select is((:'sw_dis'::jsonb) ->> 'status', 'disabled', 'webhook 调度停用生效');

-- 重新启用不轮换 token
set local role authenticated;
select public.set_sync_schedule_status((:'tw'::jsonb ->> 'id')::uuid, 'active') as sw_en \gset
reset role;
select is((:'sw_en'::jsonb) ->> 'webhook_token', null::text, '重新启用不返回新 token（沿用原 token）');

-- 限流：同任务近 1 分钟已有 ≥60 次 webhook run → 拒绝
insert into public.sync_runs (task_id, trigger_type, status, stats)
select (:'tw'::jsonb ->> 'id')::uuid, 'webhook', 'success',
       '{"insert":0,"update":0,"conflict":0,"skip":0,"failed":0}'::jsonb
from generate_series(1, 60);
set local role anon;
select throws_ok(
  format($q$ select public.trigger_sync_webhook(%L) $q$, (:'sw2'::jsonb) ->> 'webhook_token'),
  '53400', null, 'webhook 超过 60 次/分钟被限流'
);
reset role;

-- ===========================================================================
-- 8. run_scheduled_sync：cron 回调
-- ===========================================================================
select is(
  public.run_scheduled_sync((:'tn'::jsonb ->> 'id')::uuid),
  null::uuid,
  '无调度任务 cron 回调返回 NULL'
);
select public.run_scheduled_sync((:'tc'::jsonb ->> 'id')::uuid) as cron_run \gset
select is(
  (select trigger_type from public.sync_runs where id = :'cron_run'),
  'cron',
  'active cron 调度回调执行并创建 cron run'
);
select is(
  (select executed_by from public.sync_runs where id = :'cron_run'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'cron 执行身份 = 任务 created_by（属主注入）'
);
select ok(
  (select last_run_at is not null and next_run_at is not null
     from public.sync_schedules where task_id = (:'tc'::jsonb ->> 'id')::uuid),
  'cron 回调后 last_run_at/next_run_at 已更新'
);
select is(
  (select status from public.sync_schedules where task_id = (:'tc'::jsonb ->> 'id')::uuid),
  'active',
  'cron 回调不改变调度状态'
);

-- 停用任务（含 disabled 调度）回调返回 NULL
select is(
  public.run_scheduled_sync((:'td'::jsonb ->> 'id')::uuid),
  null::uuid,
  '停用调度的回调返回 NULL'
);

-- cron 回调无 API 角色执行权
set local role anon;
select throws_ok(
  format($q$ select public.run_scheduled_sync(%L::uuid) $q$, (:'tc'::jsonb ->> 'id')),
  '42501', null, 'anon 调 cron 回调被拒（REVOKE API 角色）'
);
reset role;
set local role authenticated;
select throws_ok(
  format($q$ select public.run_scheduled_sync(%L::uuid) $q$, (:'tc'::jsonb ->> 'id')),
  '42501', null, 'authenticated 调 cron 回调被拒（仅 pg_cron 可达）'
);
reset role;

-- ===========================================================================
-- 9. get_sync_schedules / RLS
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select count(*) from public.get_sync_schedules() s
    where s.task_id = (:'tc'::jsonb ->> 'id')::uuid),
  1::bigint,
  'get_sync_schedules 返回调度行'
);
select is(
  (select s.task_name from public.get_sync_schedules() s
    where s.task_id = (:'tc'::jsonb ->> 'id')::uuid),
  '定时任务',
  '列表联表返回任务名'
);
select is(
  (select s.source_name from public.get_sync_schedules() s
    where s.task_id = (:'tc'::jsonb ->> 'id')::uuid),
  '调度测试源',
  '列表联表返回数据源名'
);
select is(
  (select s.has_token from public.get_sync_schedules() s
    where s.task_id = (:'tc'::jsonb ->> 'id')::uuid),
  false,
  'cron 行 has_token=false（不下发哈希）'
);
select is(
  (select s.has_token from public.get_sync_schedules() s
    where s.task_id = (:'tw'::jsonb ->> 'id')::uuid),
  true,
  'webhook 行 has_token=true'
);
select is(
  (select s.last_run_status from public.get_sync_schedules() s
    where s.task_id = (:'tc'::jsonb ->> 'id')::uuid),
  'success',
  'last_run_status 反映最近执行'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.get_sync_schedules() $$,
  '42501', null, 'engineer 读调度列表被拒（admin 专属）'
);
select is(
  (select count(*) from public.sync_schedules),
  0::bigint,
  'engineer 直查 sync_schedules RLS 收窄为 0 行'
);
reset role;

set local role anon;
select throws_ok(
  $$ select public.get_sync_schedules() $$,
  '42501', null, 'anon 读调度列表被拒（无 GRANT）'
);
reset role;

select * from finish();
rollback;
