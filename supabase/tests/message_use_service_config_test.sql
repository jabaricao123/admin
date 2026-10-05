-- pgTAP：system 批次 2 修复项 2 —— 渠道分发改走 get_service_config（message_use_service_config）
-- 覆盖：attempt_channel_delivery 不再直读 system_services（prosrc 断言）、经白名单读取口；
--       服务未配置 → degraded（行为不变）；verified + relay → pg_net 入队 queued；
--       凭据解密失败 → degraded 且 error 标注可读原因、站内信必达不受影响；
--       未知渠道 → failed；GRANT 面不变（内部函数不授 API 角色）。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(18);

-- ---------------------------------------------------------------------------
-- 1. 实现口径与授权（5）
-- ---------------------------------------------------------------------------
select has_function(
  'app', 'attempt_channel_delivery', array['text', 'uuid', 'text', 'text'],
  'app.attempt_channel_delivery(text,uuid,text,text) 存在'
);
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'attempt_channel_delivery'),
  'attempt_channel_delivery = SECURITY DEFINER + search_path 固定为空'
);
select ok(
  not has_function_privilege(
    'authenticated', 'app.attempt_channel_delivery(text,uuid,text,text)', 'EXECUTE'
  ),
  'authenticated 无 attempt_channel_delivery 执行权（INDEX 规则 10）'
);
select ok(
  (select p.prosrc not like '%from public.system_services%'
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'attempt_channel_delivery'),
  '函数体无「from public.system_services」直读（改走白名单读取口）'
);
select ok(
  (select p.prosrc like '%app.get_service_config%'
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'attempt_channel_delivery'),
  '函数体经 app.get_service_config 取配置与凭据'
);

-- ---------------------------------------------------------------------------
-- 夹具：收件人 + email 模板（admin 发布），清空服务配置保证降级路径确定性
-- ---------------------------------------------------------------------------
insert into auth.users (id, email)
values ('00000000-0000-4000-a000-000000000061', 'batch2-msg@example.com');

delete from public.system_services;

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select public.upsert_message_template(
  'approval.approved', 'email', '主题 {{title}}', '正文 {{title}}'
);
select public.publish_message_template(
  (select id from public.message_templates
    where event_key = 'approval.approved' and channel = 'email' and status = 'draft'
    limit 1)
);
reset role;

-- ---------------------------------------------------------------------------
-- 2. 无 mail 配置 → email 降级（4）
-- ---------------------------------------------------------------------------
select app.send_notification(
  '00000000-0000-4000-a000-000000000061',
  'approval.approved',
  '{"title":"批次二","body":"正文"}'::jsonb
) as msg1 \gset

select is(
  (select status from public.message_deliveries where idempotency_key = :'msg1' || ':email'),
  'degraded',
  '无 mail 配置：email 降级 degraded（行为不变）'
);
select ok(
  (select error from public.message_deliveries where idempotency_key = :'msg1' || ':email')
    like '%邮件服务未配置%',
  '降级原因仍标注「服务未配置」'
);
select is(
  (select status from public.message_deliveries where idempotency_key = :'msg1' || ':inbox'),
  'success',
  '站内信必达 success（分发降级不影响主渠道）'
);
select is(
  (select count(*) from public.message_deliveries where message_id = :msg1),
  2::bigint,
  '渠道矩阵记录 inbox + email 两条'
);

-- ---------------------------------------------------------------------------
-- 3. verified + relay_api_url → 经白名单读取口取配置后 pg_net 入队（3）
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select public.upsert_service_config(
  'mail',
  '{"host":"127.0.0.1","port":"54325","username":"dev","relay_api_url":"http://127.0.0.1:54324/api/v1/send"}'::jsonb,
  null
);
select public.mark_service_verified('mail', true, 'pgtap 批次 2 校验');
reset role;

select app.send_notification(
  '00000000-0000-4000-a000-000000000061',
  'approval.approved',
  '{"title":"批次二2","body":"正文2"}'::jsonb
) as msg2 \gset

select is(
  (select status from public.message_deliveries where idempotency_key = :'msg2' || ':email'),
  'queued',
  'mail verified + relay：email 经 pg_net 入队 queued（批次 2 语义：真实结果待投递器回写）'
);
select ok(
  (select response from public.message_deliveries where idempotency_key = :'msg2' || ':email')
    like 'pg_net request #%',
  '响应摘要记录 pg_net request id'
);
select is(
  (select error from public.message_deliveries where idempotency_key = :'msg2' || ':email'),
  null::text,
  '成功路径 error 为 NULL'
);

-- ---------------------------------------------------------------------------
-- 4. 凭据解密失败 → degraded（可读原因、不阻断站内信）（4）
-- ---------------------------------------------------------------------------
update public.system_services
   set credentials = '\xdeadbeef'::bytea
 where service = 'mail';

select lives_ok(
  $$ select app.send_notification(
       '00000000-0000-4000-a000-000000000061',
       'approval.approved',
       '{"title":"批次二3","body":"正文3"}'::jsonb
     ) $$,
  '凭据损坏：send_notification 不抛错（best-effort）'
);

select max(id) as msg3
from public.messages
where recipient_id = '00000000-0000-4000-a000-000000000061' \gset

select is(
  (select status from public.message_deliveries where idempotency_key = :'msg3' || ':email'),
  'degraded',
  '凭据解密失败：email 降级 degraded（渠道不可用非投递失败）'
);
select ok(
  (select error from public.message_deliveries where idempotency_key = :'msg3' || ':email')
    like '%凭据解密失败，可能密钥已轮换%',
  '降级原因标注可读解密错误（不静默）'
);
select is(
  (select status from public.message_deliveries where idempotency_key = :'msg3' || ':inbox'),
  'success',
  '凭据解密失败：站内信仍必达 success'
);

-- ---------------------------------------------------------------------------
-- 5. 直接调用边界：未知渠道 failed / 无配置 degraded（2）
-- ---------------------------------------------------------------------------
delete from public.system_services where service = 'mail';

select is(
  (app.attempt_channel_delivery('weird', gen_random_uuid(), 's', 'b')) ->> 'status',
  'failed',
  '未知渠道：attempt 返回 failed'
);
select is(
  (app.attempt_channel_delivery('email', '00000000-0000-4000-a000-000000000061', 's', 'b')) ->> 'status',
  'degraded',
  'mail 未配置：attempt 直接调用返回 degraded'
);

select * from finish();
rollback;
