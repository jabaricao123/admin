-- pgTAP：message/007+008+009 — message_deliveries 分区表 + 渠道分发 + 重发 + 90 天清理 + RLS
-- 运行：supabase db reset && supabase test db
-- 覆盖：分区表结构（PARTITION BY RANGE + 202610/202611 分区 + 唯一 (idempotency_key, created_at)）；
--       ensure_message_partition 幂等；inbox 必达 success；无 mail 配置 email/push 降级不报错
--       （degraded 非 failed）；mail verified + relay_api_url → pg_net 入队 queued；
--       重发（admin、failed/queued 超时、attempts+1、幂等键不变）；90 天清理；RLS 本人/越权；cron 登记。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;
select plan(78);

-- ---------------------------------------------------------------------------
-- 夹具：u1 收件人 / u2 他人 / u3 admin；清空服务配置保证降级路径确定性
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-4000-a000-000000000051', 'msg-del-u1@example.com'),
  ('00000000-0000-4000-a000-000000000052', 'msg-del-u2@example.com'),
  ('00000000-0000-4000-a000-000000000053', 'msg-del-admin@example.com');

update public.profiles set role = 'admin'::public.user_role
 where id = '00000000-0000-4000-a000-000000000053';

delete from public.system_services;

insert into public.messages (id, recipient_id, event_key, title, body)
overriding system value
values
  (9800051, '00000000-0000-4000-a000-000000000051', 'approval.approved', '夹具消息一', '夹具正文一'),
  (9800052, '00000000-0000-4000-a000-000000000052', 'approval.approved', '夹具消息二', '夹具正文二');

-- ---------------------------------------------------------------------------
-- A. 结构：分区表 / 分区 / 列 / 约束 / 索引（18）
-- ---------------------------------------------------------------------------
select has_table('public', 'message_deliveries', 'message_deliveries 表存在');
select is(
  (select c.relkind
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'message_deliveries'),
  'p',
  '父表为分区表（relkind=p）'
);
select is(
  (select count(*)
     from pg_partitioned_table pt
    where pt.partrelid = 'public.message_deliveries'::regclass
      and pt.partstrat = 'r'),
  1::bigint,
  '分区策略 = RANGE'
);
select is(
  pg_get_partkeydef('public.message_deliveries'::regclass),
  'RANGE (created_at)',
  '分区键 = created_at'
);
select ok(
  to_regclass('public.message_deliveries_202610') is not null,
  '2026-10 月分区存在'
);
select ok(
  to_regclass('public.message_deliveries_202611') is not null,
  '2026-11 月分区存在'
);
select is(
  (select count(*)
     from pg_inherits
    where inhparent = 'public.message_deliveries'::regclass
      and inhrelid in (
        'public.message_deliveries_202610'::regclass,
        'public.message_deliveries_202611'::regclass
      )),
  2::bigint,
  '两个初始分区均挂载于父表'
);
select ok(
  not has_table_privilege('authenticated', 'public.message_deliveries_202610', 'SELECT')
  and not has_table_privilege('anon', 'public.message_deliveries_202611', 'SELECT')
  and not has_table_privilege('service_role', 'public.message_deliveries_202610', 'SELECT')
  and not has_table_privilege('service_role', 'public.message_deliveries_202611', 'SELECT')
  and (select relrowsecurity from pg_class where oid = 'public.message_deliveries_202610'::regclass)
  and (select relrowsecurity from pg_class where oid = 'public.message_deliveries_202611'::regclass),
  '初始分区撤权 + RLS 启用（防直读分区绕过父表策略）'
);
select ok(
  (select count(*) = 13
     from information_schema.columns
    where table_schema = 'public'
      and table_name = 'message_deliveries'
      and column_name in (
        'id', 'message_id', 'recipient_id', 'event_key', 'channel', 'status', 'error',
        'response', 'rendered_subject', 'rendered_body', 'idempotency_key', 'attempts', 'created_at'
      )),
  '核心 13 列齐全（含快照 / 幂等键 / attempts）'
);
select col_has_check('public', 'message_deliveries', 'channel', 'channel 取值 check');
select col_has_check('public', 'message_deliveries', 'status', 'status 取值 check');
select col_has_check('public', 'message_deliveries', 'attempts', 'attempts >= 1 check');
select has_index(
  'public', 'message_deliveries', 'message_deliveries_idempotency_key_created_at_uq',
  '唯一约束 (idempotency_key, created_at) 索引存在（含分区键）'
);
select col_is_pk(
  'public', 'message_deliveries', array['id', 'created_at'],
  '主键 (id, created_at)（分区表主键含分区键）'
);
select has_index(
  'public', 'message_deliveries', 'message_deliveries_recipient_created_idx',
  'recipient+created 索引存在'
);
select col_not_null('public', 'message_deliveries', 'idempotency_key', 'idempotency_key 非空');
select col_has_default('public', 'message_deliveries', 'created_at', 'created_at 默认 now()');
select col_has_default('public', 'message_deliveries', 'attempts', 'attempts 默认 1');

-- ---------------------------------------------------------------------------
-- B. RLS 与表级权限（6）
-- ---------------------------------------------------------------------------
select ok(
  (select relrowsecurity from pg_class where oid = 'public.message_deliveries'::regclass),
  'RLS 已启用'
);
select is(
  (select count(*) from pg_policies where schemaname = 'public' and tablename = 'message_deliveries'),
  2::bigint,
  '恰 2 条策略（admin 全量 + 本人）'
);
select is(
  (select count(*) from pg_policies
    where schemaname = 'public' and tablename = 'message_deliveries' and cmd = 'SELECT'),
  2::bigint,
  '策略均为 SELECT（无表级写策略）'
);
select ok(
  has_table_privilege('authenticated', 'public.message_deliveries', 'SELECT'),
  'authenticated 有 SELECT 权限'
);
select ok(
  not has_table_privilege('authenticated', 'public.message_deliveries', 'INSERT')
  and not has_table_privilege('authenticated', 'public.message_deliveries', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.message_deliveries', 'DELETE'),
  'authenticated 无表级写权限（写全经 SECURITY DEFINER）'
);
select ok(
  not has_table_privilege('anon', 'public.message_deliveries', 'SELECT')
  and not has_table_privilege('service_role', 'public.message_deliveries', 'SELECT'),
  'anon / service_role 无读权限'
);

-- ---------------------------------------------------------------------------
-- C. 函数存在 / 安全属性 / 授权面（10）
-- ---------------------------------------------------------------------------
select has_function(
  'app', 'ensure_message_partition', array['date'], 'app.ensure_message_partition 存在'
);
select has_function(
  'app', 'cleanup_message_deliveries', array['integer'], 'app.cleanup_message_deliveries 存在'
);
select has_function(
  'app', 'attempt_channel_delivery', array['text', 'uuid', 'text', 'text'],
  'app.attempt_channel_delivery 存在'
);
select has_function(
  'app', 'dispatch_message_channels', array['bigint', 'jsonb'],
  'app.dispatch_message_channels 存在'
);
select has_function('app', 'resend_delivery', array['bigint'], 'app.resend_delivery 存在');
select has_function('public', 'resend_delivery', array['bigint'], 'public.resend_delivery 薄包装存在');
select ok(
  (select count(*) = 4
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname in (
        'ensure_message_partition', 'attempt_channel_delivery',
        'dispatch_message_channels', 'resend_delivery'
      )
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '分区/分发/重发 4 函数 = SECURITY DEFINER + search_path 固定为空'
);
select ok(
  (select count(*) = 1
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = 'cleanup_message_deliveries'
      and not p.prosecdef
      and p.proconfig @> array['search_path=""']),
  'cleanup_message_deliveries = SECURITY INVOKER + search_path 固定为空（cron/owner 可达）'
);
select ok(
  has_function_privilege('authenticated', 'public.resend_delivery(bigint)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.resend_delivery(bigint)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.dispatch_message_channels(bigint,jsonb)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.attempt_channel_delivery(text,uuid,text,text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.ensure_message_partition(date)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.cleanup_message_deliveries(integer)', 'EXECUTE'),
  '重发仅 public 包装对 authenticated 开放；内部函数不 GRANT（INDEX 规则 10）'
);
select ok(
  not has_function_privilege('anon', 'public.resend_delivery(bigint)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.resend_delivery(bigint)', 'EXECUTE'),
  'anon / service_role 无重发执行权'
);

-- ---------------------------------------------------------------------------
-- D. ensure_message_partition：幂等建分区（4）
-- ---------------------------------------------------------------------------
select is(
  app.ensure_message_partition('2026-09-15'::date),
  'message_deliveries_202609',
  '指定月份返回分区名（YYYYMM）'
);
select ok(
  to_regclass('public.message_deliveries_202609') is not null,
  '指定月份分区已创建'
);
select is(
  app.ensure_message_partition('2026-09-01'::date),
  'message_deliveries_202609',
  '重复调用幂等返回同名（不重复建表）'
);
select ok(
  not has_table_privilege('authenticated', 'public.message_deliveries_202609', 'SELECT')
  and not has_table_privilege('service_role', 'public.message_deliveries_202609', 'SELECT')
  and (select relrowsecurity from pg_class where oid = 'public.message_deliveries_202609'::regclass),
  'ensure 新建分区同样撤权 + 启用 RLS'
);

-- ---------------------------------------------------------------------------
-- E. 唯一约束：同 (idempotency_key, created_at) 拒绝（1）
-- ---------------------------------------------------------------------------
insert into public.message_deliveries
  (message_id, recipient_id, event_key, channel, status, idempotency_key, created_at)
values
  (9800051, '00000000-0000-4000-a000-000000000051', 'approval.approved', 'inbox', 'success',
   'dup:key', '2026-10-15T00:00:00Z');

select throws_ok(
  $$ insert into public.message_deliveries
       (message_id, recipient_id, event_key, channel, status, idempotency_key, created_at)
     values (9800051, '00000000-0000-4000-a000-000000000051', 'approval.approved', 'inbox',
             'success', 'dup:key', '2026-10-15T00:00:00Z') $$,
  '23505', null,
  '同 (idempotency_key, created_at) 重复插入被唯一约束拒绝'
);

-- ---------------------------------------------------------------------------
-- F. 渠道分发：inbox 必达 + 无配置 email/push 降级（8）
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-000000000053","role":"authenticated"}',
  true
);
set local role authenticated;

select public.upsert_message_template(
  'approval.approved', 'email', '审批结果：{{title}}', '申请 {{title}}：{{comment}}'
);
select public.publish_message_template(
  (select id from public.message_templates
    where event_key = 'approval.approved' and channel = 'email' and status = 'draft'
    limit 1)
);
select public.upsert_message_template(
  'approval.approved', 'push', '推送：{{title}}', '推送正文 {{title}}'
);
select public.publish_message_template(
  (select id from public.message_templates
    where event_key = 'approval.approved' and channel = 'push' and status = 'draft'
    limit 1)
);

reset role;

select app.send_notification(
  '00000000-0000-4000-a000-000000000051',
  'approval.approved',
  '{"title":"请假","body":"已通过","comment":"同意"}'::jsonb
) as msg1 \gset

select is(
  (select status from public.message_deliveries where idempotency_key = :'msg1' || ':inbox'),
  'success',
  'inbox 渠道必达 success'
);
select is(
  (select count(*) from public.message_deliveries
    where idempotency_key = :'msg1' || ':inbox' and message_id = :msg1),
  1::bigint,
  'inbox delivery 幂等键 = message_id:inbox 且关联正确'
);
select is(
  (select rendered_subject || '|' || rendered_body from public.message_deliveries
    where idempotency_key = :'msg1' || ':inbox'),
  '请假|已通过',
  'inbox 快照 = 渲染后标题/正文'
);
select is(
  (select status from public.message_deliveries where idempotency_key = :'msg1' || ':email'),
  'degraded',
  '无 mail 配置：email 降级 degraded（不报错）'
);
select ok(
  (select error from public.message_deliveries where idempotency_key = :'msg1' || ':email')
    like '%邮件服务未配置%',
  'email 降级原因标注「服务未配置」'
);
select is(
  (select rendered_subject || '|' || rendered_body from public.message_deliveries
    where idempotency_key = :'msg1' || ':email'),
  '审批结果：请假|申请 请假：同意',
  'email 快照 = email 模板渲染结果（变量替换）'
);
select is(
  (select status from public.message_deliveries where idempotency_key = :'msg1' || ':push'),
  'degraded',
  '无 push 配置：push 降级 degraded（不报错）'
);
select is(
  (select count(*) from public.message_deliveries where message_id = :msg1),
  3::bigint,
  '渠道矩阵完整记录 inbox + email + push 三条'
);

-- ---------------------------------------------------------------------------
-- G. relay_api_url：mail verified 后 pg_net 入队 success（3）
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-000000000053","role":"authenticated"}',
  true
);
set local role authenticated;

select public.upsert_service_config(
  'mail',
  '{"host":"127.0.0.1","port":"54325","username":"dev","relay_api_url":"http://127.0.0.1:54324/api/v1/send"}'::jsonb,
  null
);
select public.mark_service_verified('mail', true, 'pgtap 配置校验通过');

reset role;

select app.send_notification(
  '00000000-0000-4000-a000-000000000052',
  'approval.approved',
  '{"title":"第二条","body":"正文二","comment":"OK"}'::jsonb
) as msg2 \gset

select is(
  (select status from public.message_deliveries where idempotency_key = :'msg2' || ':email'),
  'queued',
  'mail verified + relay_api_url：email 经 pg_net 入队 queued（真实结果待投递器回写）'
);
select ok(
  (select response from public.message_deliveries where idempotency_key = :'msg2' || ':email')
    like 'pg_net request #%',
  '渠道响应摘要记录 pg_net request id'
);
select is(
  (select attempts from public.message_deliveries where idempotency_key = :'msg2' || ':email'),
  1,
  '首投 attempts = 1'
);

-- ---------------------------------------------------------------------------
-- H. 重发：admin / 仅 failed / attempts+1 / 幂等键不变 / 审计（7）
-- ---------------------------------------------------------------------------
insert into public.message_deliveries
  (message_id, recipient_id, event_key, channel, status, error,
   rendered_subject, rendered_body, idempotency_key)
values
  (9800052, '00000000-0000-4000-a000-000000000052', 'approval.approved', 'email', 'failed',
   '投递请求失败：连接超时', '审批结果：重发', '申请 重发：正文', 'pgtap:failed')
returning id as failed_id \gset

select id as degraded_id
from public.message_deliveries
where idempotency_key = :'msg1' || ':email' \gset

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-000000000051","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  format('select public.resend_delivery(%s)', :failed_id),
  '42501', '仅管理员可执行此操作',
  '非 admin 重发被拒（42501）'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-000000000053","role":"authenticated"}',
  true
);
select r.status as status, r.attempts as attempts
from public.resend_delivery(:failed_id) r \gset resend_

select is(:'resend_status'::text, 'queued', 'admin 重发失败记录入队 queued（relay 可达）');
select is(:resend_attempts::integer, 2, '重发后 attempts +1');

select throws_ok(
  format('select public.resend_delivery(%s)', :failed_id),
  '22023', null,
  'queued 未超 10 分钟不可重复重发（避免重复入队）'
);
select throws_ok(
  format('select public.resend_delivery(%s)', :degraded_id),
  '22023', '仅失败或排队超时记录可重发（当前状态：degraded）',
  '降级记录不可重发（渠道不可用，非失败）'
);
select throws_ok(
  'select public.resend_delivery(999999991)',
  'P0002', '投递记录不存在',
  '重发不存在的记录报 P0002'
);

reset role;

select is(
  (select count(*) from public.audit_operations
    where module = 'message' and action = 'resend'
      and object_type = 'message_delivery' and object_id = :'failed_id'),
  1::bigint,
  '重发写审计摘要（message/resend/message_delivery）'
);

-- ---------------------------------------------------------------------------
-- I. 90 天保留清理（4）
-- ---------------------------------------------------------------------------
select app.ensure_message_partition((now() - interval '91 days')::date);

insert into public.message_deliveries
  (message_id, recipient_id, event_key, channel, status,
   rendered_subject, rendered_body, idempotency_key, created_at)
values
  (9800051, '00000000-0000-4000-a000-000000000051', 'approval.approved', 'inbox', 'success',
   't', 'b', 'cleanup:old', now() - interval '91 days'),
  (9800051, '00000000-0000-4000-a000-000000000051', 'approval.approved', 'inbox', 'success',
   't', 'b', 'cleanup:fresh', now() - interval '89 days');

select is(app.cleanup_message_deliveries(), 1, '清理恰好删除 1 条（91 天前）');
select is(
  (select count(*) from public.message_deliveries where idempotency_key = 'cleanup:old'),
  0::bigint,
  '91 天前记录已删除'
);
select is(
  (select count(*) from public.message_deliveries where idempotency_key = 'cleanup:fresh'),
  1::bigint,
  '89 天前记录保留（未到 90 天）'
);
select throws_ok(
  'select app.cleanup_message_deliveries(0)',
  '22023', '保留天数必须 >= 1：0',
  '保留天数 < 1 被拒'
);

-- ---------------------------------------------------------------------------
-- L. 无外部渠道模板的事件：仅站内信，不产生渠道记录（2）
-- ---------------------------------------------------------------------------
select lives_ok(
  $$ select app.send_notification(
       '00000000-0000-4000-a000-000000000052', 'sync.run_finished',
       '{"title":"同步完成","body":"3 行"}'::jsonb) $$,
  '无 email/push 模板的事件不报错'
);

select max(id) as msg3
from public.messages
where recipient_id = '00000000-0000-4000-a000-000000000052' \gset

select is(
  (select count(*) from public.message_deliveries where message_id = :msg3),
  1::bigint,
  '无外部渠道模板：仅 inbox delivery，无降级噪音'
);

-- ---------------------------------------------------------------------------
-- J. RLS：本人可见 / 越权不可见 / admin 全量 / 直写拒绝（4）
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-000000000051","role":"authenticated"}',
  true
);
set local role authenticated;

select ok(
  (select count(*) from public.message_deliveries) >= 1,
  'u1 可见本人投递记录'
);
select is(
  (select count(*) from public.message_deliveries
    where recipient_id = '00000000-0000-4000-a000-000000000052'),
  0::bigint,
  'u1 不可见他人投递记录（RLS 收口）'
);
select throws_ok(
  $$ insert into public.message_deliveries
       (message_id, recipient_id, event_key, channel, status, idempotency_key)
     values (9800051, '00000000-0000-4000-a000-000000000051', 'approval.approved',
             'inbox', 'success', 'rls:write') $$,
  '42501', null,
  'authenticated 直写 deliveries 被拒（无 INSERT 权限）'
);

reset role;

select count(*) as total_deliveries from public.message_deliveries \gset

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-000000000053","role":"authenticated"}',
  true
);
set local role authenticated;

select is(
  (select count(*) from public.message_deliveries),
  :total_deliveries::bigint,
  'admin 可见全量投递记录'
);

reset role;

-- ---------------------------------------------------------------------------
-- K. pg_cron 登记：分区维护 + 清理（3）
-- ---------------------------------------------------------------------------
select is(
  (select count(*) from public.system_cron_registry
    where job_name in ('message-ensure-partitions', 'message-cleanup-deliveries')
      and module = 'message'),
  2::bigint,
  '分区维护 + 90 天清理已登记（module=message）'
);
select ok(
  (select bool_and(owner_route = '/message/history')
     from public.system_cron_registry
    where job_name in ('message-ensure-partitions', 'message-cleanup-deliveries')),
  '登记 owner_route 均指向 /message/history'
);
select is(
  (select count(*) from cron.job
    where jobname in ('message-ensure-partitions', 'message-cleanup-deliveries')),
  2::bigint,
  'pg_cron 调度已注册（cron.job 同名 job）'
);

-- ---------------------------------------------------------------------------
-- M. 幂等重放：deliveries.created_at 取 messages.created_at 确定值（批次 1 修复；4）
-- ---------------------------------------------------------------------------
insert into public.messages (id, recipient_id, event_key, title, body, created_at)
overriding system value
values (
  9800061, '00000000-0000-4000-a000-000000000052', 'approval.approved',
  '幂等重放', '正文', '2026-10-15T00:00:00Z'
);

select is(
  app.dispatch_message_channels(9800061),
  2,
  '首轮分发 2 个外部渠道尝试（email/push 模板）'
);
select is(
  (select count(*) from public.message_deliveries where message_id = 9800061),
  3::bigint,
  '首轮写入 inbox + email + push 三条'
);

-- 模拟跨时间戳重放：再次 dispatch 同 message（旧实现 created_at=now() 必新增重复行）
select app.dispatch_message_channels(9800061);

select is(
  (select count(*) from public.message_deliveries where message_id = 9800061),
  3::bigint,
  '重放同 message 同渠道命中唯一约束 do nothing，不重复插入'
);
select ok(
  (select bool_and(d.created_at = m.created_at)
     from public.message_deliveries d
     join public.messages m on m.id = d.message_id
    where d.message_id = 9800061),
  'deliveries.created_at 取 messages.created_at 确定值'
);

-- ---------------------------------------------------------------------------
-- N. send_notification dispatch 异常隔离：messages 必达（批次 1 修复；4）
-- ---------------------------------------------------------------------------
-- 模拟结构型异常：messages.created_at 默认值临时改到无分区的 2020-01，
-- dispatch 写 deliveries 触发「no partition of relation」→ 被捕获降级（audit + warning）。
alter table public.messages alter column created_at set default '2020-01-15T00:00:00Z'::timestamptz;

select lives_ok(
  $$ select app.send_notification(
       '00000000-0000-4000-a000-000000000051', 'approval.approved',
       '{"title":"隔离测试","body":"dispatch 异常"}'::jsonb) $$,
  'dispatch 结构型异常被隔离：send_notification 不抛错'
);

alter table public.messages alter column created_at set default now();

select max(id) as iso_msg
from public.messages
where event_key = 'approval.approved' and title = '隔离测试' \gset

select is(
  (select count(*) from public.messages where id = :iso_msg),
  1::bigint,
  'dispatch 抛错仍落库 messages（站内信必达）'
);
select is(
  (select count(*) from public.audit_operations
    where module = 'message' and action = 'dispatch_degraded' and object_id = :'iso_msg'),
  1::bigint,
  '结构型异常降级写 audit（message/dispatch_degraded）'
);
select is(
  (select count(*) from public.message_deliveries where message_id = :iso_msg),
  0::bigint,
  '分发失败无 deliveries 行（降级不产生噪音记录）'
);

select * from finish();
rollback;
