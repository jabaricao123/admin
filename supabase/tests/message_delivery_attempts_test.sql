-- pgTAP：message 批次 2 修复项 3 + 批次 4 并入项 1 —
--        queued 异步出站语义 + queued 卡死重发 + message_delivery_attempts 明细（append-only）
-- 运行：supabase db reset && supabase test db
-- 覆盖：明细表结构/约束/RLS/权限；relay 渠道入队 queued、inbox 仍 success；
--       queued 未超 10 分钟拒绝重发、超时视为卡死可重发；failed 重发；明细逐次留痕
--       （append-only 不被覆盖）；本人/越权/admin 读面。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(25);

-- ---------------------------------------------------------------------------
-- 夹具：u1 收件人 / u2 他人 / adm（admin）
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-4000-a000-000000000081', 'msg-att-u1@example.com'),
  ('00000000-0000-4000-a000-000000000082', 'msg-att-u2@example.com'),
  ('00000000-0000-4000-a000-000000000083', 'msg-att-admin@example.com');

update public.profiles set role = 'admin'::public.user_role
 where id = '00000000-0000-4000-a000-000000000083';

delete from public.system_services;

-- ---------------------------------------------------------------------------
-- A. 明细表结构 / 权限 / RLS（9）
-- ---------------------------------------------------------------------------
select has_table('public', 'message_delivery_attempts', 'message_delivery_attempts 表存在');
select ok(
  (select count(*) = 7
     from information_schema.columns
    where table_schema = 'public'
      and table_name = 'message_delivery_attempts'
      and column_name in (
        'id', 'delivery_id', 'attempt_no', 'status', 'response', 'error', 'attempted_at'
      )),
  '核心 7 列齐全（delivery_id / attempt_no / status / response / error / attempted_at）'
);
select col_has_check('public', 'message_delivery_attempts', 'status', 'status 取值 check（含 queued）');
select col_has_check('public', 'message_delivery_attempts', 'attempt_no', 'attempt_no >= 1 check');
select ok(
  (select relrowsecurity from pg_class where oid = 'public.message_delivery_attempts'::regclass)
  and (select count(*) from pg_policies
        where schemaname = 'public' and tablename = 'message_delivery_attempts') = 2,
  'RLS 启用且恰 2 条策略（admin + 本人关联）'
);
select ok(
  has_table_privilege('authenticated', 'public.message_delivery_attempts', 'SELECT')
  and not has_table_privilege('authenticated', 'public.message_delivery_attempts', 'INSERT')
  and not has_table_privilege('authenticated', 'public.message_delivery_attempts', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.message_delivery_attempts', 'DELETE'),
  'authenticated 仅 SELECT（写全经 resend_delivery）'
);
select ok(
  not has_table_privilege('anon', 'public.message_delivery_attempts', 'SELECT')
  and not has_table_privilege('service_role', 'public.message_delivery_attempts', 'SELECT'),
  'anon / service_role 无读权限'
);
select has_index(
  'public', 'message_delivery_attempts', 'message_delivery_attempts_delivery_idx',
  'delivery_id + attempted_at 索引存在（详情页查询）'
);
select ok(
  not has_sequence_privilege('authenticated', 'public.message_delivery_attempts_id_seq', 'USAGE')
  and not has_sequence_privilege('anon', 'public.message_delivery_attempts_id_seq', 'USAGE')
  and not has_sequence_privilege('service_role', 'public.message_delivery_attempts_id_seq', 'USAGE'),
  'identity 序列不暴露给 API 角色'
);

-- ---------------------------------------------------------------------------
-- B. 出站语义：relay email 入队 queued / inbox 仍 success（4）
-- ---------------------------------------------------------------------------
select app.register_message_event('attempt.test', 'message', '投递明细 pgtap', '["title"]'::jsonb);

-- 模板夹具直接落库（published 冻结触发器只拦 UPDATE；本测试聚焦投递语义，避开模板管理 RPC）
insert into public.message_templates (event_key, channel, subject_tpl, body_tpl, version, status)
values ('attempt.test', 'email', '投递 {{title}}', '正文 {{title}}', 1, 'published');

insert into public.message_template_current (event_key, channel, template_id)
select 'attempt.test', 'email', t.id
from public.message_templates t
where t.event_key = 'attempt.test' and t.channel = 'email' and t.version = 1;

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-000000000083","role":"authenticated"}',
  true
);
set local role authenticated;

select public.upsert_service_config(
  'mail',
  '{"host":"127.0.0.1","port":"54325","username":"dev","relay_api_url":"http://127.0.0.1:54324/api/v1/send"}'::jsonb,
  null
);
select public.mark_service_verified('mail', true, 'pgtap attempts');

reset role;

select app.send_notification(
  '00000000-0000-4000-a000-000000000081',
  'attempt.test',
  '{"title":"入队测试"}'::jsonb
) as msg1 \gset

select id as msg1_email_id
from public.message_deliveries
where idempotency_key = :'msg1' || ':email' \gset

select is(
  (select status from public.message_deliveries where id = :msg1_email_id),
  'queued',
  'relay 渠道新投递 status=queued（pg_net 入队 ≠ 送达）'
);
select ok(
  (select response from public.message_deliveries where id = :msg1_email_id)
    like '%真实结果待投递器回写%',
  'queued 响应摘要注明真实结果待投递器回写'
);
select is(
  (select status from public.message_deliveries where idempotency_key = :'msg1' || ':inbox'),
  'success',
  'inbox 站内信仍为 success（写库即送达）'
);
select is(
  (select attempts from public.message_deliveries where id = :msg1_email_id),
  1,
  '首投入队 attempts = 1'
);

-- ---------------------------------------------------------------------------
-- C. queued 重发：未超时拒绝 / 超 10 分钟视为卡死可重发（3）
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-000000000083","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  format('select public.resend_delivery(%s)', :msg1_email_id),
  '22023', null,
  'queued 未满 10 分钟拒绝重发（避免重复入队）'
);

reset role;

update public.message_deliveries
   set created_at = now() - interval '11 minutes'
 where id = :msg1_email_id;

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-000000000083","role":"authenticated"}',
  true
);
set local role authenticated;

select r.status as resend_status, r.attempts as resend_attempts
from public.resend_delivery(:msg1_email_id) r \gset c_
select is(
  :'c_resend_status'::text || '/' || :c_resend_attempts,
  'queued/2',
  'queued 超 10 分钟重发成功（重新入队，attempts+1）'
);
select is(
  (select status || '/' || attempt_no
     from public.message_delivery_attempts
    where delivery_id = :msg1_email_id),
  'queued/2',
  '重发写入明细（attempt_no 与 attempts 对齐）'
);

-- ---------------------------------------------------------------------------
-- D. failed 重发与 append-only 留痕（5）
-- ---------------------------------------------------------------------------
reset role;

insert into public.message_deliveries
  (message_id, recipient_id, event_key, channel, status, error,
   rendered_subject, rendered_body, idempotency_key)
values
  (:'msg1'::bigint, '00000000-0000-4000-a000-000000000081', 'attempt.test', 'email', 'failed',
   '投递请求失败：连接超时', '投递 失败夹具', '正文 失败夹具', 'attempts:failed')
returning id as failed_id \gset

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-000000000083","role":"authenticated"}',
  true
);
set local role authenticated;

select r.status as failed_status, r.attempts as failed_attempts
from public.resend_delivery(:failed_id) r \gset f_
select is(
  :'f_failed_status'::text || '/' || :f_failed_attempts,
  'queued/2',
  'failed 记录重发成功入队（attempts+1）'
);

reset role;

update public.message_deliveries
   set created_at = now() - interval '11 minutes'
 where id = :failed_id;

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-000000000083","role":"authenticated"}',
  true
);
set local role authenticated;

select r.attempts as failed_attempts3
from public.resend_delivery(:failed_id) r \gset g_
select is(:g_failed_attempts3::integer, 3, '卡死再次重发 attempts=3');

reset role;

select is(
  (select count(*) from public.message_delivery_attempts where delivery_id = :failed_id),
  2::bigint,
  '两次重发逐条留痕（append-only，共 2 条）'
);
select is(
  (select string_agg(attempt_no || ':' || status, ',' order by attempt_no)
     from public.message_delivery_attempts
    where delivery_id = :failed_id),
  '2:queued,3:queued',
  '明细保留每次尝试（旧行不被覆盖）'
);
select ok(
  (select response from public.message_delivery_attempts
    where delivery_id = :failed_id and attempt_no = 3)
    like 'pg_net request #%',
  '明细记录本次渠道响应摘要（排障原文）'
);

-- ---------------------------------------------------------------------------
-- E. RLS 读面：本人 / 越权 / admin（4）
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-000000000081","role":"authenticated"}',
  true
);
set local role authenticated;

select is(
  (select count(*) from public.message_delivery_attempts),
  3::bigint,
  'u1 可见本人 delivery 的全部尝试明细（1 + 2）'
);
select is(
  (select count(*) from public.message_delivery_attempts a
    where a.delivery_id not in (
      select d.id from public.message_deliveries d
      where d.recipient_id = '00000000-0000-4000-a000-000000000081'
    )),
  0::bigint,
  'u1 不可见他人类明细（RLS 关联收口）'
);

reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-000000000082","role":"authenticated"}',
  true
);
set local role authenticated;

select is(
  (select count(*) from public.message_delivery_attempts),
  0::bigint,
  'u2 不可见他人（u1）尝试明细'
);

reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-000000000083","role":"authenticated"}',
  true
);
set local role authenticated;

select is(
  (select count(*) from public.message_delivery_attempts),
  3::bigint,
  'admin 全量可见尝试明细（排查重发链）'
);

reset role;

select * from finish();
rollback;
