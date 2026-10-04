-- pgTAP：report 批次 2 修复 —— 订阅时区换算 / 失败通知 / 导出清理 / 事件契约
-- 运行：supabase db reset && supabase test db
-- 覆盖：
--   * upsert_report_subscription 本地（Asia/Shanghai）→ UTC 换算：daily / weekly 跨日回绕；
--     cron.job 同步；next_run_at 按 UTC 解释后本地展示；
--   * 失败收尾通知属主：report.subscription_failed（订阅）/ report.export_failed（导出）；
--   * app.cleanup_export_jobs：超期内容置空、近 7 天保留、download 两条过期路径拒绝；
--   * 事件注册表 available_vars 与实际发送键一致（export_ready / 两失败事件）。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

create temporary table fixture_ids (label text primary key, id uuid, num bigint);
grant select on fixture_ids to authenticated;

-- ===========================================================================
-- 夹具：admin 创建并发布公共报表定义（engineer 订阅；失败路径共用）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select (public.save_report_definition(
  null, '批次2-时区夹具', 'departments_v',
  '{"dimensions":["name"],"metrics":[],"filters":[],"chart":"table"}'::jsonb
)).id as def_tz \gset
select public.publish_report_definition(:'def_tz');
reset role;
insert into fixture_ids (label, id) values ('def_tz', :'def_tz');

select plan(24);

-- ===========================================================================
-- 1. 订阅时区换算：本地 HH:mm → UTC cron（5）
-- ===========================================================================
-- 09:00 CST daily → 01:00 UTC
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select (public.upsert_report_subscription(
  null, (select id from fixture_ids where label = 'def_tz'),
  'daily', '09:00', null, array['inbox'], 'self')).id as sub_tz \gset
reset role;
insert into fixture_ids (label, id) values ('sub_tz', :'sub_tz');

select is(
  (select cron_expr from public.report_subscriptions
    where id = (select id from fixture_ids where label = 'sub_tz')),
  '0 1 * * *',
  '09:00 CST daily → cron 0 1 * * *（UTC）'
);
select is(
  (select schedule from cron.job
    where jobname = 'report-sub-' || (select id::text from fixture_ids where label = 'sub_tz')),
  '0 1 * * *',
  'pg_cron job 注册为 UTC 表达式'
);

-- 01:00 CST daily → 17:00 UTC（前一日小时）
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select public.upsert_report_subscription(
  (select id from fixture_ids where label = 'sub_tz'),
  (select id from fixture_ids where label = 'def_tz'),
  'daily', '01:00', null, array['inbox'], 'self');
reset role;
select is(
  (select cron_expr from public.report_subscriptions
    where id = (select id from fixture_ids where label = 'sub_tz')),
  '0 17 * * *',
  '01:00 CST daily → cron 0 17 * * *（UTC 前一日小时，回绕）'
);

-- 周一 09:00 CST weekly → 01:00 UTC 周一（无星期偏移）
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select public.upsert_report_subscription(
  (select id from fixture_ids where label = 'sub_tz'),
  (select id from fixture_ids where label = 'def_tz'),
  'weekly', '09:00', 1, array['inbox'], 'self');
reset role;
select is(
  (select cron_expr from public.report_subscriptions
    where id = (select id from fixture_ids where label = 'sub_tz')),
  '0 1 * * 1',
  '周一 09:00 CST weekly → cron 0 1 * * 1（UTC）'
);

-- 周一 01:00 CST weekly → 17:00 UTC 周日（星期回退一天）
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select public.upsert_report_subscription(
  (select id from fixture_ids where label = 'sub_tz'),
  (select id from fixture_ids where label = 'def_tz'),
  'weekly', '01:00', 1, array['inbox'], 'self');
reset role;
select is(
  (select cron_expr from public.report_subscriptions
    where id = (select id from fixture_ids where label = 'sub_tz')),
  '0 17 * * 0',
  '周一 01:00 CST weekly → cron 0 17 * * 0（UTC 周日，跨日星期回退）'
);

-- next_run_at：按 UTC 解释 cron 后返回 timestamptz，本地展示为周一 01:00
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select ok(
  (select extract(hour from (next_run_at at time zone 'Asia/Shanghai'))::integer = 1
          and extract(isodow from (next_run_at at time zone 'Asia/Shanghai'))::integer = 1
     from public.get_report_subscriptions()
    where id = (select id from fixture_ids where label = 'sub_tz')),
  'next_run_at 按 UTC 解释 cron（本地展示周一 01:00）'
);
reset role;

-- ===========================================================================
-- 2. 失败订阅 → 属主收到 report.subscription_failed（3）
-- ===========================================================================
update public.report_definitions
   set config = '{"dimensions":["hacked"],"metrics":[],"filters":[],"chart":"table"}'::jsonb
 where id = (select id from fixture_ids where label = 'def_tz');

select coalesce(max(id), 0) as msg_before from public.messages \gset

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select public.run_report_subscription_now(
  (select id from fixture_ids where label = 'sub_tz')) as fail_run \gset
reset role;
insert into fixture_ids (label, num) values ('run_fail', :'fail_run');

select ok(
  (select status = 'failed' and error like '%白名单%'
     from public.report_subscription_runs
    where id = (select num from fixture_ids where label = 'run_fail')),
  '订阅执行失败记录 failed + error'
);
select ok(
  exists (
    select 1 from public.messages
     where id > :msg_before
       and recipient_id = '22222222-2222-2222-2222-222222220001'
       and event_key = 'report.subscription_failed'
  ),
  '失败订阅通知属主（report.subscription_failed）'
);
select ok(
  (select title like '报表订阅「批次2-时区夹具」执行失败'
     from public.messages
    where id > :msg_before
      and event_key = 'report.subscription_failed'
    order by id desc
    limit 1),
  '失败通知标题包含报表名'
);

-- ===========================================================================
-- 3. 失败导出 → 属主收到 report.export_failed（3）
-- ===========================================================================
select coalesce(max(id), 0) as msg_before2 from public.messages \gset

insert into public.export_jobs (source, requested_by, status)
values ('org.users', '22222222-2222-2222-2222-222222220001', 'queued');
update public.export_sources set enabled = false where source = 'org.users';

select is(
  app.process_export_jobs(),
  1,
  '停用源任务进入本轮处理'
);
update public.export_sources set enabled = true where source = 'org.users';

select ok(
  (select status = 'failed' and content is null
     from public.export_jobs
    where requested_by = '22222222-2222-2222-2222-222222220001'
      and status = 'failed'),
  '失败导出任务置 failed（content 清空）'
);
select ok(
  exists (
    select 1 from public.messages
     where id > :msg_before2
       and recipient_id = '22222222-2222-2222-2222-222222220001'
       and event_key = 'report.export_failed'
  ),
  '失败导出通知任务属主（report.export_failed）'
);

-- ===========================================================================
-- 4. 导出过期清理：cleanup + download 两条拒绝路径（6）
-- ===========================================================================
insert into public.export_jobs (source, requested_by, status, content, size_bytes, created_at, finished_at)
values
  ('org.users', '22222222-2222-2222-2222-222222220001', 'done',
   'id,full_name', 12, now() - interval '9 days', now() - interval '8 days'),
  ('org.users', '22222222-2222-2222-2222-222222220001', 'done',
   'id,full_name', 12, now() - interval '2 days', now() - interval '2 days');

insert into fixture_ids (label, id)
select 'job_old', id from public.export_jobs
 where requested_by = '22222222-2222-2222-2222-222222220001'
   and status = 'done'
   and finished_at < now() - interval '7 days'
 order by finished_at desc
 limit 1;
insert into fixture_ids (label, id)
select 'job_new', id from public.export_jobs
 where requested_by = '22222222-2222-2222-2222-222222220001'
   and status = 'done'
   and finished_at >= now() - interval '7 days'
 order by finished_at desc
 limit 1;

-- cleanup 前：超期但内容仍在 → 时间路径拒绝
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.download_export((select id from fixture_ids where label = 'job_old')) $$,
  'P0001', '导出文件已过期（完成后 7 天内可下载）',
  '超期任务（完成 8 天前）下载被拒'
);
reset role;

select is(
  app.cleanup_export_jobs(),
  1,
  'cleanup 清理 1 条超期任务内容'
);
select ok(
  (select content is null and size_bytes = 12 and status = 'done'
     from public.export_jobs
    where id = (select id from fixture_ids where label = 'job_old')),
  '超期任务：content 置空、size_bytes 保留、status 保持 done'
);
select ok(
  (select content = 'id,full_name' from public.export_jobs
    where id = (select id from fixture_ids where label = 'job_new')),
  '7 天内任务内容不受 cleanup 影响'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.download_export((select id from fixture_ids where label = 'job_old')) $$,
  'P0001', '导出文件已过期（完成后 7 天内可下载）',
  '内容已清理的任务下载被拒（content=null 路径）'
);
select lives_ok(
  $$ select public.download_export((select id from fixture_ids where label = 'job_new')) $$,
  '7 天内任务仍可下载'
);
reset role;

-- pg_cron / 平台登记
select ok(
  exists (
    select 1 from cron.job
     where jobname = 'cleanup-export-jobs'
       and schedule = '30 3 * * *'
       and command like '%app.cleanup_export_jobs()%'
  ),
  'pg_cron 已注册 cleanup-export-jobs（每日 03:30）'
);
select ok(
  exists (
    select 1 from public.system_cron_registry
     where job_name = 'cleanup-export-jobs'
       and module = 'report'
       and cron_expr = '30 3 * * *'
       and owner_route = '/report/exports'
       and status = 'active'
  ),
  'system 平台登记处已登记（INDEX 规则 5）'
);

-- ===========================================================================
-- 5. 事件注册表 available_vars 与实际发送键一致（3）
-- ===========================================================================
select is(
  (select available_vars from public.message_event_registry where event_key = 'report.export_ready'),
  '["title","body","report_name","row_count","summary"]'::jsonb,
  'export_ready 变量清单 = 订阅摘要实际发送键（无 download_url）'
);
select is(
  (select available_vars from public.message_event_registry where event_key = 'report.subscription_failed'),
  '["title","report_name","error"]'::jsonb,
  'subscription_failed 变量清单 = 失败通知实际发送键'
);
select is(
  (select available_vars from public.message_event_registry where event_key = 'report.export_failed'),
  '["source","error"]'::jsonb,
  'export_failed 变量清单 = 失败通知实际发送键'
);

-- monthly 预设映射（UTC 换算）
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select (public.upsert_report_subscription(
  null,
  (select id from fixture_ids where label = 'def_tz'),
  'monthly', '09:00', null, array['inbox'], 'self')).id as sub_monthly \gset
reset role;
insert into fixture_ids (label, id) values ('sub_monthly', :'sub_monthly');
select is(
  (select cron_expr from public.report_subscriptions
    where id = (select id from fixture_ids where label = 'sub_monthly')),
  '0 1 1 * *',
  'monthly 09:00 CST → cron 0 1 1 * *（UTC 当月 1 日）'
);

select * from finish();
rollback;
