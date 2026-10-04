-- pgTAP：audit 批次 2 修复 ——
--   修复项 1：audit.logins 导出源（seed / admin 独占 / worker CSV 表头与行）
--             + audit.operations config.start/end 筛选（含非法日期失败路径）
--   修复项 2：upsert_row_version_whitelist 幂等（enabled 未变化不重复写审计）
--   修复项 3：generate_compliance_report 模块分布中文化 + dashboard/demo 范围映射
-- 运行：supabase db reset && supabase test db
-- 说明：夹具仅在本事务内生效，finish 后 rollback，不污染其他测试文件；
--       非 admin 账号用 seeds 的 engineer（2222...0001）。

begin;

select plan(26);

-- ===========================================================================
-- 1. export_sources：audit.logins 登记（admin 独占）+ operations 筛选描述（3）
-- ===========================================================================
select ok(
  exists (
    select 1 from public.export_sources
    where source = 'audit.logins' and enabled and owner_module = 'audit'
  ),
  'seed：audit.logins 已注册且启用（owner_module=audit）'
);
select is(
  (select config_schema ->> 'access' from public.export_sources where source = 'audit.logins'),
  'admin',
  'audit.logins 标记 config_schema.access=admin（admin 独占）'
);
select is(
  (select config_schema #>> '{properties,start,format}' from public.export_sources
    where source = 'audit.operations'),
  'date',
  'audit.operations config_schema 登记 start/end 日期筛选'
);

-- ===========================================================================
-- 2. worker：audit.logins CSV（表头 + 行）+ audit.operations 日期筛选（12）
-- ===========================================================================
-- 非 admin 发起 audit.logins 被拒（发起时拦截）
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.request_export('audit.logins') $$,
  '42501', null, '非 admin 发起 audit.logins 被拒（admin 独占源）'
);
reset role;

-- 登录日志夹具：1 失败（含 IP/UA）+ 1 成功
insert into public.audit_logins (email, success, fail_reason, ip, ua)
values
  ('login-export-pgtap@example.com', false, 'invalid_credentials', '203.0.113.77', 'pgTAP-UA'),
  ('login-export-ok-pgtap@example.com', true, null, '198.51.100.8', 'pgTAP-UA-OK');

-- 操作日志夹具：今日（Asia/Shanghai）窗口内 + 窗口外各一条
insert into public.audit_operations (module, action, object_type, object_id, created_at)
values
  ('audit', 'update', 'export_filter_fixture', 'export-filter-in-pgtap', now()),
  ('audit', 'update', 'export_filter_fixture', 'export-filter-out-pgtap', now() - interval '3 days');

-- admin 发起两个导出：audit.logins（无筛选）+ audit.operations（今日筛选）
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.request_export('audit.logins') $$,
  'admin 发起 audit.logins 导出'
);
select lives_ok(
  format(
    $$ select public.request_export('audit.operations', %L::jsonb) $$,
    jsonb_build_object(
      'start', to_char(now() at time zone 'Asia/Shanghai', 'YYYY-MM-DD'),
      'end',   to_char(now() at time zone 'Asia/Shanghai', 'YYYY-MM-DD')
    )::text
  ),
  'admin 带 start/end 发起 audit.operations 导出'
);
reset role;

select is(
  app.process_export_jobs(),
  2,
  'worker 一轮处理两个导出任务（logins + 带筛选 operations）'
);
select ok(
  (select content like 'created_at,email,success,fail_reason,ip,ua%'
     from public.export_jobs
    where source = 'audit.logins'
      and requested_by = '11111111-1111-1111-1111-111111111111'),
  'audit.logins CSV 以表头开头（时间/邮箱/结果/原因/IP/UA）'
);
select ok(
  (select content like '%login-export-pgtap@example.com,false,invalid_credentials,203.0.113.77,pgTAP-UA%'
     from public.export_jobs
    where source = 'audit.logins'
      and requested_by = '11111111-1111-1111-1111-111111111111'),
  '登录失败行落列（邮箱/结果/原因/IP/UA）'
);
select ok(
  (select content like '%login-export-ok-pgtap@example.com,true,,198.51.100.8,pgTAP-UA-OK%'
     from public.export_jobs
    where source = 'audit.logins'
      and requested_by = '11111111-1111-1111-1111-111111111111'),
  '登录成功行落列（fail_reason 空字段）'
);
select ok(
  (select content like '%export-filter-in-pgtap%'
     from public.export_jobs
    where source = 'audit.operations'
      and requested_by = '11111111-1111-1111-1111-111111111111'
      and config ? 'start'),
  'audit.operations 筛选导出含窗口内记录'
);
select ok(
  (select content not like '%export-filter-out-pgtap%'
     from public.export_jobs
    where source = 'audit.operations'
      and requested_by = '11111111-1111-1111-1111-111111111111'
      and config ? 'start'),
  'audit.operations config.start/end 过滤掉窗口外记录'
);

-- 非法日期格式：任务置 failed 留中文原因（不阻断其他任务）
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.request_export('audit.operations', '{"start":"2026/01/01"}'::jsonb) $$,
  '非法日期格式的导出请求可入队（校验延迟到 worker）'
);
reset role;
select is(
  app.process_export_jobs(),
  1,
  'worker 处理非法日期任务'
);
select ok(
  (select status = 'failed' and error like '筛选起始日期不合法%'
     from public.export_jobs
    where config ->> 'start' = '2026/01/01'),
  '非法日期任务置 failed 且原因中文化'
);

-- ===========================================================================
-- 3. upsert_row_version_whitelist：幂等（enabled 未变化不重复写审计）（6）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  public.upsert_row_version_whitelist('audit_pgtap_idem', true) ->> 'enabled',
  'true',
  '首次 upsert 新表白名单（create）'
);
reset role;
select is(
  (select count(*)::int from public.audit_operations
    where module = 'audit' and object_type = 'row_version_whitelist'
      and object_id = 'audit_pgtap_idem'),
  1,
  '首次 upsert 写 1 条审计'
);

set local role authenticated;
select is(
  public.upsert_row_version_whitelist('audit_pgtap_idem', true) ->> 'enabled',
  'true',
  '重复相同 upsert（before=after）返回成功'
);
reset role;
select is(
  (select count(*)::int from public.audit_operations
    where module = 'audit' and object_type = 'row_version_whitelist'
      and object_id = 'audit_pgtap_idem'),
  1,
  'enabled 未变化的重复 upsert 不再写审计（幂等）'
);

set local role authenticated;
select lives_ok(
  $$ select public.upsert_row_version_whitelist('audit_pgtap_idem', false) $$,
  'enabled 变化（true→false）的 upsert 仍执行'
);
reset role;
select is(
  (select count(*)::int from public.audit_operations
    where module = 'audit' and object_type = 'row_version_whitelist'
      and object_id = 'audit_pgtap_idem'),
  2,
  'enabled 变化时照常写审计（第 2 条）'
);

-- ===========================================================================
-- 4. generate_compliance_report：模块分布中文化 + dashboard/demo 范围映射（5）
-- ===========================================================================
insert into public.audit_operations (module, action, object_type, object_id, created_at)
values
  ('audit', 'create', 'compliance_i18n_fixture', 'i18n-audit', now()),
  ('dashboard', 'update', 'compliance_i18n_fixture', 'i18n-dashboard', now()),
  ('demo', 'update', 'compliance_i18n_fixture', 'i18n-demo', now());

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select public.generate_compliance_report('month', 'all') as r1 \gset
select public.generate_compliance_report('month', 'dashboard') as r2 \gset
select public.generate_compliance_report('month', 'demo') as r3 \gset
reset role;

select ok(
  (select file_content like '%<td>审计中心</td>%'
     from public.compliance_reports where id = :'r1'),
  '按模块分布输出中文（audit → 审计中心）'
);
select ok(
  (select file_content like '%<td>工作台</td>%'
     from public.compliance_reports where id = :'r1'),
  '按模块分布输出中文（dashboard → 工作台）'
);
select ok(
  (select file_content like '%<td>演示</td>%'
     from public.compliance_reports where id = :'r1'),
  '按模块分布输出中文（demo → 演示）'
);
select ok(
  (select file_content like '%范围：工作台%'
     from public.compliance_reports where id = :'r2'),
  '范围 dashboard 映射中文（工作台）'
);
select ok(
  (select file_content like '%范围：演示%'
     from public.compliance_reports where id = :'r3'),
  '范围 demo 映射中文（演示）'
);

select * from finish();
rollback;
