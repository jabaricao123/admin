-- pgTAP：report/005 + report/006 —— 报表订阅（表 + 管理 RPC + 执行注入属主 + 页面数据面）
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构与约束/索引；RLS（owner/admin；runs 跟随订阅；无表级写）；授权面（规则 10）；
--       upsert 校验与频率预设映射；cron.job + system_cron_registry 登记；下次执行计算；
--       执行注入订阅属主（RLS 外数据不可见 / audit 报表行数收窄为 0）；失败记 error + 审计；
--       禁用后 cron 回调跳过；逻辑删注销 job/登记；手动触发 owner/admin；越权读写拒绝。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

-- 测试账号（seeds）：admin=1111... / engineer=2222...0001 / planner=2222...0002
create temporary table fixture_ids (label text primary key, id uuid, num bigint);
grant select on fixture_ids to authenticated;

-- 夹具报表定义（admin/engineer 经真实 RPC 创建，含 public / private 两类）
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
select (public.save_report_definition(
  null, '订阅夹具-部门分布', 'departments_v',
  '{"dimensions":["name"],"metrics":[],"filters":[],"chart":"table"}'::jsonb
)).id as def_public \gset
select public.publish_report_definition(:'def_public');
select (public.save_report_definition(
  null, '订阅夹具-私有报表', 'departments_v',
  '{"dimensions":["name"],"metrics":[],"filters":[],"chart":"table"}'::jsonb
)).id as def_private \gset
select (public.save_report_definition(
  null, '订阅夹具-操作日志', 'audit_operations_v',
  '{"dimensions":["module"],"metrics":[{"column":"module","agg":"count"}],"filters":[],"chart":"table"}'::jsonb
)).id as def_audit \gset
select public.publish_report_definition(:'def_audit');
reset role;

select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}', true);
set local role authenticated;
select (public.save_report_definition(
  null, '订阅夹具-Engineer 私有', 'departments_v',
  '{"dimensions":["name"],"metrics":[],"filters":[],"chart":"table"}'::jsonb
)).id as def_own \gset
reset role;

insert into fixture_ids (label, id) values
  ('def_public', :'def_public'),
  ('def_private', :'def_private'),
  ('def_audit', :'def_audit'),
  ('def_own', :'def_own');

select plan(108);

-- ===========================================================================
-- 1. 结构：表 / 列 / PK / check / FK / 索引 / RLS / 授权（27）
-- ===========================================================================
select has_table('public', 'report_subscriptions', 'report_subscriptions 表存在');
select has_table('public', 'report_subscription_runs', 'report_subscription_runs 表存在');

select has_column('public', 'report_subscriptions', 'report_def_id', 'subscriptions.report_def_id 存在');
select has_column('public', 'report_subscriptions', 'cron_expr', 'subscriptions.cron_expr 存在');
select has_column('public', 'report_subscriptions', 'channels', 'subscriptions.channels 存在');
select has_column('public', 'report_subscriptions', 'recipients', 'subscriptions.recipients 存在');
select has_column('public', 'report_subscriptions', 'status', 'subscriptions.status 存在');
select has_column('public', 'report_subscriptions', 'is_deleted', 'subscriptions.is_deleted 存在（逻辑删）');
select has_column('public', 'report_subscriptions', 'created_by', 'subscriptions.created_by 存在');
select has_column('public', 'report_subscription_runs', 'subscription_id', 'runs.subscription_id 存在');
select has_column('public', 'report_subscription_runs', 'status', 'runs.status 存在');
select has_column('public', 'report_subscription_runs', 'duration_ms', 'runs.duration_ms 存在');
select has_column('public', 'report_subscription_runs', 'error', 'runs.error 存在');

select col_is_pk('public', 'report_subscriptions', 'id', 'subscriptions.id 为主键');
select col_is_pk('public', 'report_subscription_runs', 'id', 'runs.id 为主键');

select throws_ok(
  $$ insert into public.report_subscriptions
       (report_def_id, cron_expr, created_by, status)
     select id, '0 9 * * *', '11111111-1111-1111-1111-111111111111', 'bogus'
       from public.report_definitions limit 1 $$,
  '23514', null, 'status 非法取值被 check 拒绝'
);
select throws_ok(
  $$ insert into public.report_subscriptions
       (report_def_id, cron_expr, channels, created_by)
     select id, '0 9 * * *', '{}'::text[], '11111111-1111-1111-1111-111111111111'
       from public.report_definitions limit 1 $$,
  '23514', null, 'channels 空数组被 check 拒绝'
);
select throws_ok(
  $$ insert into public.report_subscriptions
       (report_def_id, cron_expr, channels, created_by)
     select id, '0 9 * * *', array['sms'], '11111111-1111-1111-1111-111111111111'
       from public.report_definitions limit 1 $$,
  '23514', null, 'channels 非 inbox/email 被 check 拒绝'
);
select throws_ok(
  $$ insert into public.report_subscriptions
       (report_def_id, cron_expr, recipients, created_by)
     select id, '0 9 * * *', 'team:x', '11111111-1111-1111-1111-111111111111'
       from public.report_definitions limit 1 $$,
  '23514', null, 'recipients 非法格式被 check 拒绝'
);
select throws_ok(
  $$ insert into public.report_subscriptions
       (report_def_id, cron_expr, created_by)
     select id, '   ', '11111111-1111-1111-1111-111111111111'
       from public.report_definitions limit 1 $$,
  '23514', null, 'cron_expr 空白被 check 拒绝'
);
select throws_ok(
  $$ insert into public.report_subscriptions
       (report_def_id, cron_expr, created_by)
     values ('00000000-0000-0000-0000-0000000000ff', '0 9 * * *',
             '11111111-1111-1111-1111-111111111111') $$,
  '23503', null, '未知 report_def_id 被外键拒绝'
);
select throws_ok(
  $$ insert into public.report_subscriptions
       (report_def_id, cron_expr, created_by)
     select id, '0 9 * * *', '00000000-0000-0000-0000-0000000000ff'
       from public.report_definitions limit 1 $$,
  '23503', null, '未知 created_by 被外键拒绝'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.report_subscriptions'::regclass)
  and (select relrowsecurity from pg_class where oid = 'public.report_subscription_runs'::regclass),
  'report_subscriptions / report_subscription_runs 均启用 RLS'
);
select is(
  (select count(*) from pg_policies
    where schemaname = 'public' and tablename = 'report_subscriptions'),
  2::bigint,
  'subscriptions 恰 2 条策略（owner + admin）'
);
select is(
  (select count(*) from pg_policies
    where schemaname = 'public' and tablename = 'report_subscription_runs'),
  2::bigint,
  'runs 恰 2 条策略（owner + admin）'
);
select ok(
  (select count(*) = 3 from pg_indexes
    where schemaname = 'public'
      and indexname in ('report_subscriptions_owner_idx',
                        'report_subscriptions_active_idx',
                        'report_subscription_runs_subscription_idx')),
  '订阅属主/活跃部分索引与执行历史索引存在'
);
select ok(
  not has_table_privilege('authenticated', 'public.report_subscriptions', 'insert')
  and not has_table_privilege('authenticated', 'public.report_subscriptions', 'update')
  and not has_table_privilege('authenticated', 'public.report_subscriptions', 'delete')
  and not has_table_privilege('authenticated', 'public.report_subscription_runs', 'insert')
  and not has_table_privilege('authenticated', 'public.report_subscription_runs', 'update')
  and not has_table_privilege('authenticated', 'public.report_subscription_runs', 'delete'),
  '目标表无 API 写权限（写全经 RPC/内部函数）'
);
select ok(
  not has_table_privilege('anon', 'public.report_subscriptions', 'select')
  and not has_table_privilege('anon', 'public.report_subscription_runs', 'select'),
  'anon 无订阅/执行历史读权限'
);

-- ===========================================================================
-- 2. 函数存在性 / security 属性 / 授权面（18）
-- ===========================================================================
select has_function('app', 'upsert_report_subscription',
  array['uuid', 'uuid', 'text', 'text', 'integer', 'text[]', 'text'],
  'app.upsert_report_subscription 存在');
select has_function('public', 'upsert_report_subscription',
  array['uuid', 'uuid', 'text', 'text', 'integer', 'text[]', 'text'],
  'public.upsert_report_subscription 薄包装存在');
select has_function('app', 'delete_report_subscription', array['uuid'],
  'app.delete_report_subscription 存在');
select has_function('app', 'set_report_subscription_status', array['uuid', 'text'],
  'app.set_report_subscription_status 存在');
select has_function('app', 'get_report_subscriptions', array[]::text[],
  'app.get_report_subscriptions 存在');
select has_function('app', 'run_report_subscription', array['uuid'],
  'app.run_report_subscription（cron 回调）存在');
select has_function('app', 'execute_report_subscription', array['uuid', 'text'],
  'app.execute_report_subscription（执行核心）存在');
select has_function('app', 'run_report_subscription_now', array['uuid'],
  'app.run_report_subscription_now 存在');
select has_function('public', 'run_report_subscription_now', array['uuid'],
  'public.run_report_subscription_now 薄包装存在');

select ok(
  (select not p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'run_report_subscription'),
  'cron 回调为 security invoker + search_path 固定为空（PG 禁止 definer 内 SET ROLE）'
);
select ok(
  (select count(*) = 3
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
        ('app', 'execute_report_subscription'),
        ('app', 'run_report_subscription_now'),
        ('public', 'run_report_subscription_now'))
      and not p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '执行核心与手动触发链路均 security invoker + search_path 固定为空'
);
select ok(
  (select count(*) = 4
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
        ('app', 'upsert_report_subscription'), ('public', 'upsert_report_subscription'),
        ('app', 'delete_report_subscription'), ('app', 'set_report_subscription_status'))
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '管理 RPC 均 security definer + search_path 固定为空'
);
select ok(
  (select count(*) = 5
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
        ('app', 'report_subscription_register_cron'),
        ('app', 'report_subscription_unregister_cron'),
        ('app', 'report_subscription_run_begin'),
        ('app', 'report_subscription_run_notify'),
        ('app', 'report_subscription_run_finish'))
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '执行/调度 helper 均 security definer + search_path 固定为空'
);

select ok(
  has_function_privilege('authenticated', 'public.upsert_report_subscription(uuid,uuid,text,text,integer,text[],text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.delete_report_subscription(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.set_report_subscription_status(uuid,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.get_report_subscriptions()', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.run_report_subscription_now(uuid)', 'EXECUTE'),
  'authenticated 可执行 5 个 public 用户入口'
);
select ok(
  has_function_privilege('authenticated', 'app.run_report_subscription_now(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'app.execute_report_subscription(uuid,text)', 'EXECUTE')
  and has_function_privilege('authenticated', 'app.report_subscription_run_begin(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'app.report_subscription_run_notify(uuid,bigint,jsonb)', 'EXECUTE')
  and has_function_privilege('authenticated', 'app.report_subscription_run_finish(bigint,text,integer,text)', 'EXECUTE'),
  '手动触发 INVOKER 链路 app 函数对 authenticated 可见（app schema 不在 Data API 面）'
);
select ok(
  not has_function_privilege('authenticated', 'app.run_report_subscription(uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.report_subscription_register_cron(uuid,text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.report_subscription_unregister_cron(uuid)', 'EXECUTE'),
  'cron 回调与调度 helper 不对 authenticated 开放（INDEX 规则 10）'
);
select ok(
  not has_function_privilege('anon', 'public.upsert_report_subscription(uuid,uuid,text,text,integer,text[],text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.run_report_subscription_now(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.get_report_subscriptions()', 'EXECUTE'),
  'anon 无订阅 RPC 执行权'
);
select ok(
  not has_function_privilege('service_role', 'public.upsert_report_subscription(uuid,uuid,text,text,integer,text[],text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'app.execute_report_subscription(uuid,text)', 'EXECUTE'),
  'service_role 无订阅 RPC 执行权（ADR-001 全局禁令）'
);

-- ===========================================================================
-- 3. upsert：校验 / 频率映射 / cron 注册与登记 / 编辑（20）
-- ===========================================================================
-- 非法参数（engineer 视角）
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}', true);
set local role authenticated;
select throws_ok(
  $$ select public.upsert_report_subscription(
       null, (select id from fixture_ids where label = 'def_public'),
       'monthly', '09:00', null, array['inbox'], 'self') $$,
  '22023', null, '未知频率预设被拒'
);
select throws_ok(
  $$ select public.upsert_report_subscription(
       null, (select id from fixture_ids where label = 'def_public'),
       'daily', '9:5', null, array['inbox'], 'self') $$,
  '22023', null, 'HH:mm 时间格式非法被拒'
);
select throws_ok(
  $$ select public.upsert_report_subscription(
       null, (select id from fixture_ids where label = 'def_public'),
       'weekly', '09:00', 7, array['inbox'], 'self') $$,
  '22023', null, '星期越界被拒'
);
select throws_ok(
  $$ select public.upsert_report_subscription(
       null, (select id from fixture_ids where label = 'def_public'),
       'daily', '09:00', null, '{}'::text[], 'self') $$,
  '22023', null, '空渠道被拒'
);
select throws_ok(
  $$ select public.upsert_report_subscription(
       null, (select id from fixture_ids where label = 'def_public'),
       'daily', '09:00', null, array['sms'], 'self') $$,
  '22023', null, '非 inbox/email 渠道被拒'
);
select throws_ok(
  $$ select public.upsert_report_subscription(
       null, (select id from fixture_ids where label = 'def_public'),
       'daily', '09:00', null, array['inbox', null], 'self') $$,
  '22023', null, '渠道数组含空值被拒'
);
select throws_ok(
  $$ select public.upsert_report_subscription(
       null, (select id from fixture_ids where label = 'def_public'),
       'daily', '09:00', null, array['inbox'], 'team:x') $$,
  '22023', null, '非法接收范围被拒'
);
select throws_ok(
  $$ select public.upsert_report_subscription(
       null, (select id from fixture_ids where label = 'def_public'),
       'daily', '09:00', null, array['inbox'], 'role:nope') $$,
  'P0002', null, '不存在的角色被拒'
);
select throws_ok(
  $$ select public.upsert_report_subscription(
       null, (select id from fixture_ids where label = 'def_private'),
       'daily', '09:00', null, array['inbox'], 'self') $$,
  '42501', null, '订阅他人私有报表被拒'
);
select throws_ok(
  $$ select public.upsert_report_subscription(
       null, '00000000-0000-0000-0000-0000000000ff',
       'daily', '09:00', null, array['inbox'], 'self') $$,
  'P0002', null, '未知报表定义被拒'
);

-- engineer 新建：每天 09:30，self，inbox+email（去重排序）
select lives_ok(
  $$ select public.upsert_report_subscription(
       null, (select id from fixture_ids where label = 'def_public'),
       'daily', '09:30', null, array['inbox', 'email', 'inbox'], 'self') $$,
  'engineer 新建订阅'
);
reset role;

insert into fixture_ids (label, id)
select 'sub_main', id from public.report_subscriptions
 where created_by = '22222222-2222-2222-2222-222222220001'
 order by created_at, id
 limit 1;

select is(
  (select cron_expr || '|' || status || '|' || recipients || '|' || channels::text
     from public.report_subscriptions
    where id = (select id from fixture_ids where label = 'sub_main')),
  '30 9 * * *|active|self|{email,inbox}',
  '新建落库：cron 映射 / active / self / 渠道去重排序'
);
select is(
  (select count(*) from cron.job
    where jobname = 'report-sub-' || (select id::text from fixture_ids where label = 'sub_main')),
  1::bigint,
  'pg_cron 已注册 report-sub-<id> job'
);
select ok(
  (select schedule = '30 9 * * *'
          and command like '%app.run_report_subscription(''%'
     from cron.job
    where jobname = 'report-sub-' || (select id::text from fixture_ids where label = 'sub_main')),
  'cron 表达式与回调命令正确'
);
select ok(
  exists (
    select 1 from public.system_cron_registry
     where job_name = 'report-sub-' || (select id::text from fixture_ids where label = 'sub_main')
       and module = 'report'
       and cron_expr = '30 9 * * *'
       and owner_route = '/report/subscriptions'
       and status = 'active'
  ),
  'system 平台登记处已登记（INDEX 规则 5）'
);
select ok(
  exists (
    select 1 from public.audit_operations
     where module = 'report' and action = 'upsert' and object_type = 'report_subscription'
       and object_id = (select id::text from fixture_ids where label = 'sub_main')
  ),
  '新建写审计摘要'
);

-- 编辑：每周五 08:05 → role:planner；再改回每小时/self
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}', true);
set local role authenticated;
select lives_ok(
  $$ select public.upsert_report_subscription(
       (select id from fixture_ids where label = 'sub_main'),
       (select id from fixture_ids where label = 'def_public'),
       'weekly', '08:05', 5, array['inbox'], 'role:planner') $$,
  '编辑为每周五 08:05 / role:planner'
);
reset role;
select is(
  (select cron_expr || '|' || recipients from public.report_subscriptions
    where id = (select id from fixture_ids where label = 'sub_main')),
  '5 8 * * 5|role:planner',
  '编辑后 cron/recipients 落库正确'
);
select is(
  (select schedule from cron.job
    where jobname = 'report-sub-' || (select id::text from fixture_ids where label = 'sub_main')),
  '5 8 * * 5',
  '编辑后 pg_cron job 同步更新（同名幂等）'
);

select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}', true);
set local role authenticated;
select lives_ok(
  $$ select public.upsert_report_subscription(
       (select id from fixture_ids where label = 'sub_main'),
       (select id from fixture_ids where label = 'def_public'),
       'hourly', null, null, array['inbox'], 'self') $$,
  '编辑为每小时 / self'
);
reset role;
select is(
  (select cron_expr || '|' || recipients from public.report_subscriptions
    where id = (select id from fixture_ids where label = 'sub_main')),
  '0 * * * *|self',
  '每小时预设映射 0 * * * *'
);
select is(
  (select schedule from cron.job
    where jobname = 'report-sub-' || (select id::text from fixture_ids where label = 'sub_main')),
  '0 * * * *',
  '每小时 job 更新生效'
);

-- ===========================================================================
-- 4. 列表 RPC：owner/admin 可见性 / 下次执行（5）
-- ===========================================================================
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}', true);
set local role authenticated;
select is(
  (select count(*) from public.get_report_subscriptions()),
  1::bigint,
  '列表：engineer 仅见自己的订阅'
);
select is(
  (select report_name from public.get_report_subscriptions()
    where id = (select id from fixture_ids where label = 'sub_main')),
  '订阅夹具-部门分布',
  '列表返回报表名'
);
select ok(
  (select next_run_at is not null and last_run_status is null
     from public.get_report_subscriptions()
    where id = (select id from fixture_ids where label = 'sub_main')),
  '列表：active 订阅算出下次执行；未执行时无最近状态'
);
reset role;

select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220002","role":"authenticated"}', true);
set local role authenticated;
select is(
  (select count(*) from public.get_report_subscriptions()),
  0::bigint,
  '列表：planner 不可见他人订阅'
);
reset role;

select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
select is(
  (select count(*) from public.get_report_subscriptions()),
  1::bigint,
  '列表：admin 全量可见'
);
reset role;

-- ===========================================================================
-- 5. 执行：属主注入 / 摘要投递 / 失败 / 启停 / 逻辑删（29）
-- ===========================================================================
-- 5.1 cron 回调执行（engineer self 订阅 departments_v → 有权限，行数 > 0）
select app.run_report_subscription((select id from fixture_ids where label = 'sub_main'))
  as main_run \gset
insert into fixture_ids (label, num) values ('run_main', :'main_run');

select ok(
  (select status = 'success' and error is null and duration_ms >= 0
     from public.report_subscription_runs
    where id = (select num from fixture_ids where label = 'run_main')),
  'cron 回调：执行记录 success + 耗时'
);
select ok(
  exists (
    select 1 from public.messages
     where recipient_id = '22222222-2222-2222-2222-222222220001'
       and event_key = 'report.export_ready'
       and source_module = 'report'
       and ref_type = 'report_subscription_run'
       and ref_id = (select num::text from fixture_ids where label = 'run_main')
  ),
  '结果摘要经 send_notification 投递（report.export_ready）'
);
select ok(
  (select body like '共 % 行。%' and body like '%name=%'
     from public.messages
    where ref_id = (select num::text from fixture_ids where label = 'run_main')
    order by id desc limit 1),
  '摘要含行数与前 10 行（属主可见数据非空）'
);

-- 5.2 属主注入：非 admin 订阅 audit 报表（audit_operations_v 仅 admin 可见）→ 行数为 0
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}', true);
set local role authenticated;
select lives_ok(
  $$ select public.upsert_report_subscription(
       null, (select id from fixture_ids where label = 'def_audit'),
       'daily', '07:00', null, array['inbox'], 'self') $$,
  'engineer 订阅公共 audit 报表'
);
reset role;
insert into fixture_ids (label, id)
select 'sub_audit', id from public.report_subscriptions
 where created_by = '22222222-2222-2222-2222-222222220001'
   and report_def_id = (select id from fixture_ids where label = 'def_audit')
 order by created_at desc limit 1;

select app.run_report_subscription((select id from fixture_ids where label = 'sub_audit'))
  as audit_run \gset
insert into fixture_ids (label, num) values ('run_audit', :'audit_run');

select ok(
  (select status = 'success' and error is null
     from public.report_subscription_runs
    where id = (select num from fixture_ids where label = 'run_audit'))
  and exists (
    select 1 from public.messages
     where ref_id = (select num::text from fixture_ids where label = 'run_audit')
       and body like '共 0 行。%'
  ),
  '属主身份注入：非 admin 订阅 audit 报表受 RLS 限制为 0 行（success + 摘要 0 行）'
);

-- 5.3 失败路径：篡改 config 直改库（绕过保存校验）→ 手动执行 failed + error + 审计
update public.report_definitions
   set config = '{"dimensions":["hacked"],"metrics":[],"filters":[],"chart":"table"}'::jsonb
 where id = (select id from fixture_ids where label = 'def_public');

select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}', true);
set local role authenticated;
select public.run_report_subscription_now((select id from fixture_ids where label = 'sub_main'))
  as fail_run \gset
reset role;
insert into fixture_ids (label, num) values ('run_fail', :'fail_run');

select ok(
  (select status = 'failed' and error like '%白名单%'
     from public.report_subscription_runs
    where id = (select num from fixture_ids where label = 'run_fail')),
  '失败执行：失败不中断，记录 failed + 合理 error（白名单校验）'
);
select ok(
  exists (
    select 1 from public.audit_operations
     where module = 'report' and action = 'fail'
       and object_type = 'report_subscription_run'
       and object_id = (select num::text from fixture_ids where label = 'run_fail')
  ),
  '终态失败写审计摘要（ADR-001 §3）'
);

-- 恢复定义 + 失败重发（手动执行成功）
update public.report_definitions
   set config = '{"dimensions":["name"],"metrics":[],"filters":[],"chart":"table"}'::jsonb
 where id = (select id from fixture_ids where label = 'def_public');

select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}', true);
set local role authenticated;
select public.run_report_subscription_now((select id from fixture_ids where label = 'sub_main'))
  as resend_run \gset
reset role;
insert into fixture_ids (label, num) values ('resend_run', :'resend_run');
select ok(
  (select status = 'success' from public.report_subscription_runs
    where id = (select num from fixture_ids where label = 'resend_run')),
  '失败重发（手动执行）成功并新增记录'
);

-- 5.4 admin 代他人手动触发
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
select ok(
  public.run_report_subscription_now((select id from fixture_ids where label = 'sub_main')) is not null,
  'admin 可代属主手动触发'
);
reset role;

-- 5.5 role:<code> 接收范围：admin 订阅，role:planner 命中 planner
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
select (public.upsert_report_subscription(
  null, (select id from fixture_ids where label = 'def_public'),
  'daily', '10:00', null, array['inbox'], 'role:planner')).id as role_sub \gset
reset role;
insert into fixture_ids (label, id) values ('sub_role', :'role_sub');

select app.run_report_subscription((select id from fixture_ids where label = 'sub_role'))
  as role_run \gset
select ok(
  exists (
    select 1 from public.messages
     where recipient_id = '22222222-2222-2222-2222-222222220002'
       and event_key = 'report.export_ready'
       and ref_id = :'role_run'
  ),
  'role:<code> 接收范围：planner 收到站内信'
);

-- 5.6 停用：注销 job；cron 回调跳过；手动仍可重发
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}', true);
set local role authenticated;
select is(
  (public.set_report_subscription_status(
     (select id from fixture_ids where label = 'sub_main'), 'disabled')).status,
  'disabled',
  '停用订阅'
);
reset role;
select is(
  (select count(*) from cron.job
    where jobname = 'report-sub-' || (select id::text from fixture_ids where label = 'sub_main')),
  0::bigint,
  '停用后 pg_cron job 注销'
);
select is(
  app.run_report_subscription((select id from fixture_ids where label = 'sub_main')),
  null,
  '停用后 cron 回调跳过（返回 NULL）'
);
select is(
  (select count(*) from public.report_subscription_runs
    where subscription_id = (select id from fixture_ids where label = 'sub_main')),
  4::bigint,
  '跳过不产生新执行记录'
);
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}', true);
set local role authenticated;
select ok(
  public.run_report_subscription_now((select id from fixture_ids where label = 'sub_main')) is not null,
  '停用订阅仍可手动执行（失败重发场景）'
);
reset role;

-- 5.7 启用：重新注册 job
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}', true);
set local role authenticated;
select is(
  (public.set_report_subscription_status(
     (select id from fixture_ids where label = 'sub_main'), 'active')).status,
  'active',
  '重新启用订阅'
);
reset role;
select is(
  (select count(*) from cron.job
    where jobname = 'report-sub-' || (select id::text from fixture_ids where label = 'sub_main')),
  1::bigint,
  '启用后 job 重新注册'
);

-- 5.8 逻辑删：is_deleted + job 注销 + 登记 disabled + 拒绝再操作
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}', true);
set local role authenticated;
select lives_ok(
  $$ select public.delete_report_subscription(
       (select id from fixture_ids where label = 'sub_main')) $$,
  '删除订阅（逻辑删）'
);
reset role;
select is(
  (select is_deleted and status = 'disabled' from public.report_subscriptions
    where id = (select id from fixture_ids where label = 'sub_main')),
  true,
  '删除后 is_deleted=true 且 status=disabled'
);
select is(
  (select count(*) from cron.job
    where jobname = 'report-sub-' || (select id::text from fixture_ids where label = 'sub_main')),
  0::bigint,
  '删除后 pg_cron job 注销'
);
select is(
  (select status from public.system_cron_registry
    where job_name = 'report-sub-' || (select id::text from fixture_ids where label = 'sub_main')),
  'disabled',
  '删除后平台登记置 disabled（历史保留）'
);
select is(
  (select count(*) from public.get_report_subscriptions()
    where id = (select id from fixture_ids where label = 'sub_main')),
  0::bigint,
  '删除行不出现在订阅列表'
);

select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}', true);
set local role authenticated;
select throws_ok(
  $$ select public.run_report_subscription_now(
       (select id from fixture_ids where label = 'sub_main')) $$,
  'P0001', '订阅已删除，无法执行', '已删订阅手动执行被拒'
);
select throws_ok(
  $$ select public.upsert_report_subscription(
       (select id from fixture_ids where label = 'sub_main'),
       (select id from fixture_ids where label = 'def_public'),
       'daily', '09:00', null, array['inbox'], 'self') $$,
  'P0001', null, '已删订阅不可编辑'
);
select lives_ok(
  $$ select public.delete_report_subscription(
       (select id from fixture_ids where label = 'sub_main')) $$,
  '重复删除幂等'
);
reset role;

-- ===========================================================================
-- 6. 越权：他人订阅不可见 / 不可改 / runs 跟随订阅（9）
-- ===========================================================================
-- planner：表级不可见 engineer 的订阅与执行历史
select set_config('request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220002","role":"authenticated"}', true);
set local role authenticated;
select is(
  (select count(*) from public.report_subscriptions),
  0::bigint,
  'RLS：planner 不可见 engineer 订阅'
);
select is(
  (select count(*) from public.report_subscription_runs),
  0::bigint,
  'RLS：planner 不可见他人执行历史'
);
select throws_ok(
  $$ select public.upsert_report_subscription(
       (select id from fixture_ids where label = 'sub_audit'),
       (select id from fixture_ids where label = 'def_public'),
       'daily', '09:00', null, array['inbox'], 'self') $$,
  '42501', null, '越权编辑他人订阅被拒'
);
select throws_ok(
  $$ select public.delete_report_subscription(
       (select id from fixture_ids where label = 'sub_audit')) $$,
  '42501', null, '越权删除他人订阅被拒'
);
select throws_ok(
  $$ select public.set_report_subscription_status(
       (select id from fixture_ids where label = 'sub_audit'), 'disabled') $$,
  '42501', null, '越权启停他人订阅被拒'
);
select throws_ok(
  $$ select public.run_report_subscription_now(
       (select id from fixture_ids where label = 'sub_audit')) $$,
  'P0002', null, '越权手动触发被拒（RLS 视为不存在）'
);
reset role;

-- admin：表级全量可见
select set_config('request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}', true);
set local role authenticated;
select ok(
  (select count(*) > 0 from public.report_subscriptions)
  and (select count(*) > 0 from public.report_subscription_runs),
  'RLS：admin 全量可见订阅与执行历史'
);
select throws_ok(
  $$ insert into public.report_subscriptions (report_def_id, cron_expr, created_by)
     values ((select id from fixture_ids where label = 'def_public'), '0 9 * * *',
             '11111111-1111-1111-1111-111111111111') $$,
  '42501', null, 'admin 也走 RPC（表级无写授权）'
);
select throws_ok(
  $$ insert into public.report_subscription_runs (subscription_id)
     values ((select id from fixture_ids where label = 'sub_audit')) $$,
  '42501', null, '执行历史表级无写授权'
);
reset role;

select is(
  (select count(*) from public.report_subscription_runs
    where subscription_id = (select id from fixture_ids where label = 'sub_audit')
      and status = 'success'),
  1::bigint,
  '执行历史收尾：sub_audit 恰 1 条 success'
);

select * from finish();
rollback;
