-- pgTAP：system 批次 1 安全四件套 + 批次 4 并入
-- 运行：supabase db reset && supabase test db
-- 覆盖：
--   A 公告通知：role:<code> 只发角色内 active（admin/supplier 无）；all 发全部 active；
--     单用户投递异常不阻断发布（failed 计数 + 其余照发 + 前序站内信不被回滚波及）；
--   B 掩码：mail/push 凭据 4/8 位 → '****'；10 位 → '****' + 尾 4；
--   C 敏感设置：is_sensitive 列/默认；存量敏感键标记；engineer 读敏感键 null + denied 审计；
--     admin 正常值；upsert_setting 标记/取消标记（三态）；
--   D 凭据空串/纯空白 = 保留；p_clear_credentials=true 显式清空 + verified 降级；
--   E service_role 序列零权限；cron register/disable 写审计。
-- 说明：夹具只在本事务内生效，finish 后 rollback。

begin;

select plan(53);

-- ===========================================================================
-- 0. 夹具：外部 supplier 用户（用于公告受众排除断言）
-- ===========================================================================
insert into auth.users (id, email, raw_app_meta_data)
values ('99999999-9999-4999-8999-999999990001', 'batch1-supplier@example.com', '{}'::jsonb);

update public.profiles
   set role = 'supplier'
 where id = '99999999-9999-4999-8999-999999990001';

select is(
  (select role::text from public.profiles where id = '99999999-9999-4999-8999-999999990001'),
  'supplier',
  '夹具：supplier 用户建档且角色正确'
);

-- ===========================================================================
-- A. 公告 notify 按 audience 过滤 + 单用户失败不阻断（14）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.upsert_announcement(
  '工程师通知', '仅工程师收到本通知。',
  now() - interval '1 hour', now() + interval '7 days', 'role:engineer', false
) as ann_e \gset
select public.publish_announcement((:'ann_e'::jsonb ->> 'id')::uuid, true) as pub_e \gset

select is((:'pub_e'::jsonb ->> 'notified')::integer, 1, 'role:engineer 通知只发角色内 active（1 人）');
select is((:'pub_e'::jsonb ->> 'failed')::integer, 0, 'role:engineer 通知无失败');

reset role;

select is(
  (select count(*) from public.messages
    where ref_type = 'announcement' and ref_id = (:'ann_e'::jsonb ->> 'id')),
  1::bigint,
  'role:engineer 公告站内信恰 1 条'
);
select is(
  (select recipient_id::text from public.messages
    where ref_type = 'announcement' and ref_id = (:'ann_e'::jsonb ->> 'id')),
  '22222222-2222-2222-2222-222222220001',
  '收件人为 engineer'
);
select ok(
  not exists (
    select 1 from public.messages
    where ref_type = 'announcement' and ref_id = (:'ann_e'::jsonb ->> 'id')
      and recipient_id in (
        '11111111-1111-1111-1111-111111111111',
        '99999999-9999-4999-8999-999999990001'
      )
  ),
  'admin 与 supplier 均未收到 role:engineer 公告'
);

-- 全员公告：全部 active 收到
set local role authenticated;
select public.upsert_announcement(
  '全员通知', '全员收到本通知。',
  now() - interval '1 hour', now() + interval '7 days', 'all', false
) as ann_all \gset
select public.publish_announcement((:'ann_all'::jsonb ->> 'id')::uuid, true) as pub_all \gset
reset role;

select is(
  (:'pub_all'::jsonb ->> 'notified')::integer,
  (select count(*)::integer from public.profiles where status = 'active'),
  'all 公告 notified=全部 active 用户数（含 supplier）'
);
select is(
  (select count(*) from public.messages
    where ref_type = 'announcement' and ref_id = (:'ann_all'::jsonb ->> 'id')),
  (select count(*) from public.profiles where status = 'active'),
  'all 公告站内信条数=active 用户数'
);

-- 单用户投递异常注入：engineer 的 messages 插入失败
create function public.batch1_fail_engineer_notification()
returns trigger
language plpgsql
as $$
begin
  if new.recipient_id = '22222222-2222-2222-2222-222222220001' then
    raise exception '注入失败：engineer 通知通道异常';
  end if;
  return new;
end;
$$;

create trigger batch1_fail_engineer_notification
before insert on public.messages
for each row
execute function public.batch1_fail_engineer_notification();

set local role authenticated;
select public.upsert_announcement(
  '尽力投递通知', 'engineer 投递失败，其余照发。',
  now() - interval '1 hour', now() + interval '7 days', 'all', false
) as ann_fail \gset
select public.publish_announcement((:'ann_fail'::jsonb ->> 'id')::uuid, true) as pub_fail \gset
reset role;

drop trigger batch1_fail_engineer_notification on public.messages;
drop function public.batch1_fail_engineer_notification();

select is((:'pub_fail'::jsonb ->> 'status'), 'published', '单用户投递异常不阻断发布（仍 published）');
select is((:'pub_fail'::jsonb ->> 'failed')::integer, 1, '发布结果 failed=1');
select is(
  (:'pub_fail'::jsonb ->> 'notified')::integer,
  (select count(*)::integer from public.profiles where status = 'active') - 1,
  'notified=其余 active 用户数'
);
select is(
  (select count(*) from public.messages
    where ref_type = 'announcement' and ref_id = (:'ann_fail'::jsonb ->> 'id')),
  (select count(*) from public.profiles where status = 'active') - 1,
  '失败用户无站内信，其余全部收到'
);
select ok(
  not exists (
    select 1 from public.messages
    where ref_type = 'announcement' and ref_id = (:'ann_fail'::jsonb ->> 'id')
      and recipient_id = '22222222-2222-2222-2222-222222220001'
  ),
  'engineer 收件箱无本条失败公告'
);
select ok(
  exists (
    select 1 from public.messages
    where ref_type = 'announcement' and ref_id = (:'ann_e'::jsonb ->> 'id')
      and recipient_id = '22222222-2222-2222-2222-222222220001'
  ),
  '前序公告的 engineer 站内信未被失败子事务回滚波及'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'publish' and object_type = 'announcement'
      and object_id = (:'ann_fail'::jsonb ->> 'id')
      and (diff ->> 'failed')::integer = 1
  ),
  '发布审计记 failed=1'
);

-- ===========================================================================
-- B. 掩码：≤8 全掩 / >8 尾 4（mail + push，14）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

-- mail：4 位 → '****'；10 位 → '****ghij'
select public.upsert_service_config(
  'mail',
  '{"host":"smtp.batch1.example.com","port":"587","username":"batch1@example.com"}'::jsonb,
  'abcd'
) as m_a \gset
select is(
  (select credentials_masked from public.get_service_status() where service = 'mail'),
  '****',
  'mail 4 位凭据掩码仅 ****（不泄露尾段）'
);

select public.upsert_service_config(
  'mail',
  '{"host":"smtp.batch1.example.com","port":"587","username":"batch1@example.com"}'::jsonb,
  'abcdefghij'
) as m_b \gset
select is(
  (select credentials_masked from public.get_service_status() where service = 'mail'),
  '****ghij',
  'mail 10 位凭据掩码 **** + 尾 4'
);

reset role;

select is(
  (select app.decrypt_secret(credentials) from public.system_services where service = 'mail'),
  'abcdefghij',
  'mail 凭据加密往返（明文可解）'
);

-- 空串 / 纯空白 = 保留
set local role authenticated;
select public.upsert_service_config(
  'mail',
  '{"host":"smtp.batch1.example.com","port":"587","username":"batch1@example.com"}'::jsonb,
  ''
) as m_c \gset
reset role;
select is(
  (select app.decrypt_secret(credentials) from public.system_services where service = 'mail'),
  'abcdefghij',
  '空串凭据 = 保留原值'
);

set local role authenticated;
select public.upsert_service_config(
  'mail',
  '{"host":"smtp.batch1.example.com","port":"587","username":"batch1@example.com"}'::jsonb,
  '   '
) as m_d \gset
reset role;
select is(
  (select app.decrypt_secret(credentials) from public.system_services where service = 'mail'),
  'abcdefghij',
  '纯空白凭据 = 保留原值'
);

-- 测试验证 → verified 后显式清空：清空优先 + 降级
set local role authenticated;
select public.test_mail_config('batch1@example.com') as m_t \gset
select is((:'m_t'::jsonb ->> 'verify_status'), 'verified', '前置：mail 测试通过为 verified');

select public.upsert_service_config(
  'mail',
  '{"host":"smtp.batch1.example.com","port":"587","username":"batch1@example.com"}'::jsonb,
  'zzz', true
) as m_clear \gset
select is((:'m_clear'::jsonb ->> 'credentials_set'), 'false', '显式清空后 credentials_set=false');
select is((:'m_clear'::jsonb ->> 'verify_status'), 'unverified', '清空凭据触发已验证降级');
select is((:'m_clear'::jsonb ->> 'verified_at'), null::text, '清空降级同时清空 verified_at');
reset role;
select is(
  (select credentials from public.system_services where service = 'mail'),
  null::bytea,
  '显式清空后 credentials 为 NULL（与 p_credentials 同给以清空为准）'
);
select is(
  (select credentials_masked from public.get_service_status() where service = 'mail'),
  null::text,
  '清空后展示掩码为 NULL'
);

-- push：4/8/10 位掩码
set local role authenticated;
select public.upsert_push_channel(
  'wecom', 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=batch1', '1234', true
) as p_a \gset
select is(
  (select secret_masked from public.get_push_status() where channel = 'wecom'),
  '****',
  'push 4 位 secret 掩码仅 ****'
);

select public.upsert_push_channel(
  'wecom', 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=batch1', 'abcdefgh', true
) as p_b \gset
select is(
  (select secret_masked from public.get_push_status() where channel = 'wecom'),
  '****',
  'push 8 位 secret 掩码仅 ****'
);

select public.upsert_push_channel(
  'wecom', 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=batch1', 'abcdefghij', true
) as p_c \gset
select is(
  (select secret_masked from public.get_push_status() where channel = 'wecom'),
  '****ghij',
  'push 10 位 secret 掩码 **** + 尾 4'
);
reset role;

-- ===========================================================================
-- C. get_setting 敏感键准入（16）
-- ===========================================================================
select has_column('public', 'system_settings', 'is_sensitive', 'is_sensitive 列存在');
select col_not_null('public', 'system_settings', 'is_sensitive', 'is_sensitive 非空');
select col_has_default('public', 'system_settings', 'is_sensitive', 'is_sensitive 有默认值');
select col_type_is('public', 'system_settings', 'is_sensitive', 'boolean', 'is_sensitive 为 boolean');
select is(
  (select is_sensitive from public.system_settings where key = 'password_login_admin_emails'),
  true,
  '存量敏感键 password_login_admin_emails 标记 sensitive'
);
select is(
  (select is_sensitive from public.system_settings where key = 'im_admin_contact'),
  true,
  '存量敏感键 im_admin_contact 标记 sensitive'
);

-- engineer：敏感键 null（与缺 key 同形）+ denied 审计；普通键正常
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  public.get_setting('password_login_admin_emails'),
  null::jsonb,
  'engineer 读敏感键返回 NULL'
);
select is(
  public.get_setting('site_name'),
  '"企业管理系统"'::jsonb,
  'engineer 读普通键正常返回值'
);
reset role;
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'denied' and object_type = 'setting'
      and object_id = 'password_login_admin_emails'
      and actor_id = '22222222-2222-2222-2222-222222220001'
  ),
  '非 admin 读敏感键写 denied 审计'
);

-- admin：敏感键正常值 + 可标记新敏感键
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  public.get_setting('im_admin_contact'),
  '""'::jsonb,
  'admin 读敏感键返回正常值'
);
select public.upsert_setting(
  'batch1_secret_key', '"s3cr3t"'::jsonb, '安全', 'string', '批次1敏感键测试', true
) as s_sens \gset
select is((:'s_sens'::jsonb ->> 'is_sensitive'), 'true', 'upsert_setting 支持标记 is_sensitive=true');
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  public.get_setting('batch1_secret_key'),
  null::jsonb,
  'engineer 读新建敏感键返回 NULL'
);
reset role;

-- 新键默认 false（旧 5 参调用）；取消标记（显式 false）
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select public.upsert_setting(
  'batch1_plain_key', '"v"'::jsonb, '通用', 'string', '批次1普通键测试'
) as s_plain \gset
select is((:'s_plain'::jsonb ->> 'is_sensitive'), 'false', '5 参调用新键 is_sensitive 默认 false');
select public.upsert_setting(
  'batch1_secret_key', '"s3cr3t"'::jsonb, '安全', 'string', '批次1敏感键测试', false
) as s_unmark \gset
select is((:'s_unmark'::jsonb ->> 'is_sensitive'), 'false', '显式 p_is_sensitive=false 取消标记');
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  public.get_setting('batch1_plain_key'),
  '"v"'::jsonb,
  'engineer 读新建普通键正常返回值'
);
select is(
  public.get_setting('batch1_secret_key'),
  '"s3cr3t"'::jsonb,
  '取消标记后 engineer 可读原敏感键'
);
reset role;

-- ===========================================================================
-- E. service_role 序列零权限 + cron 登记审计（8）
-- ===========================================================================
select is(
  (
    with seqs as materialized (
      select c.oid
      from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      where c.relkind = 'S'
        and n.nspname = 'public'
    )
    select count(*)
    from seqs
    where pg_catalog.has_sequence_privilege('service_role', oid, 'USAGE')
  ),
  0::bigint,
  'service_role 对 public 全部序列无 USAGE'
);
select ok(
  not pg_catalog.has_sequence_privilege(
    'service_role', 'public.system_cron_registry_id_seq', 'USAGE'
  ),
  'service_role 无 system_cron_registry_id_seq 权限（抽查）'
);
select ok(
  not pg_catalog.has_sequence_privilege(
    'service_role', 'public.system_setting_history_id_seq', 'USAGE'
  ),
  'service_role 无 system_setting_history_id_seq 权限（抽查）'
);

select app.register_cron_job(
  'batch1-audit-job', 'system', '*/5 * * * *', 'Asia/Shanghai', '/system/jobs'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'register' and object_type = 'cron_job'
      and object_id = 'batch1-audit-job'
      and diff ->> 'module' = 'system'
  ),
  'register_cron_job 写审计（system/register/cron_job）'
);
select is(app.unregister_cron_job('batch1-audit-job'), true, 'unregister_cron_job 注销已登记 job 返回 true');
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'disable' and object_type = 'cron_job'
      and object_id = 'batch1-audit-job'
  ),
  'unregister_cron_job 写审计（system/disable/cron_job）'
);
select is(
  app.unregister_cron_job('batch1-no-such-job'),
  false,
  '注销不存在 job 幂等返回 false'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'disable' and object_type = 'cron_job'
      and object_id = 'batch1-no-such-job'
      and diff ->> 'found' = 'false'
  ),
  '注销不存在 job 也留痕（found=false）'
);

select * from finish();
rollback;
