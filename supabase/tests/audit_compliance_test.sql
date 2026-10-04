-- pgTAP：audit/008 —— 合规报告（compliance_reports 归档 + generate_compliance_report 聚合/HTML）
-- 运行：supabase db reset && supabase test db
-- 覆盖：表结构/约束/RLS/授权；html_escape；生成（admin 周期+范围聚合、HTML 内容要素、
--       数字与明细口径一致、审计摘要）；周期/范围校验；非 admin 拒绝；历史可见性（RLS）；
--       1 年清理；pg_cron 调度与 system 登记处登记。
-- 说明：夹具（audit_operations / audit_logins / audit_row_versions）在本事务内清空后重建，
--       finish 回滚，不影响其他测试文件；非 admin 账号用 seeds 的 engineer。
begin;

select plan(59);

-- ===========================================================================
-- 1. 结构：表 / 列 / 约束 / 索引 / RLS（12）
-- ===========================================================================
select has_table('public', 'compliance_reports', 'compliance_reports 表存在');
select col_is_pk('public', 'compliance_reports', 'id', 'id 为主键');
select col_type_is('public', 'compliance_reports', 'period', 'text', 'period 为 text');
select col_type_is('public', 'compliance_reports', 'range', 'text', '"range" 为 text');
select col_type_is('public', 'compliance_reports', 'file_content', 'text', 'file_content 为 text');
select col_type_is('public', 'compliance_reports', 'generated_by', 'uuid', 'generated_by 为 uuid');
select is(
  (select a.atttypid::regtype::text
     from pg_attribute a
    where a.attrelid = 'public.compliance_reports'::regclass
      and a.attname = 'created_at'),
  'timestamp with time zone',
  'created_at 为 timestamptz'
);
select col_not_null('public', 'compliance_reports', 'period', 'period 非空');
select col_not_null('public', 'compliance_reports', 'file_content', 'file_content 非空');
select ok(
  exists (
    select 1
    from pg_constraint c
    where c.conrelid = 'public.compliance_reports'::regclass
      and c.contype = 'c'
      and pg_get_constraintdef(c.oid) like '%period%'
      and pg_get_constraintdef(c.oid) like '%quarter%'
  ),
  'period 枚举 check（week/month/quarter）存在'
);
select is(
  (select relrowsecurity from pg_class where oid = 'public.compliance_reports'::regclass),
  true,
  'compliance_reports 已启用 RLS'
);
select has_index(
  'public', 'compliance_reports', 'compliance_reports_created_idx',
  '历史列表索引（created_at desc）存在'
);

-- ===========================================================================
-- 2. 函数与安全属性（9）
-- ===========================================================================
select has_function('app', 'html_escape', array['text'], 'app.html_escape(text) 存在');
select has_function('app', 'generate_compliance_report', array['text', 'text'],
  'app.generate_compliance_report(text,text) 存在');
select has_function('public', 'generate_compliance_report', array['text', 'text'],
  'public.generate_compliance_report 薄包装存在');
select has_function('app', 'cleanup_compliance_reports', array['integer'],
  'app.cleanup_compliance_reports(integer) 存在');
select is(
  app.html_escape('<b class="x">&"''</b>'),
  '&lt;b class=&quot;x&quot;&gt;&amp;&quot;&#39;&lt;/b&gt;',
  'html_escape 转义 & < > " ''（& 优先）'
);
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'generate_compliance_report'),
  'app.generate_compliance_report 为 SECURITY DEFINER + search_path 空'
);
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'generate_compliance_report'),
  'public.generate_compliance_report 为 SECURITY DEFINER + search_path 空'
);
select ok(
  (select not p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'cleanup_compliance_reports'),
  'app.cleanup_compliance_reports 为 SECURITY INVOKER + search_path 空'
);
select ok(
  (select p.provolatile = 'i'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'html_escape'),
  'html_escape 为 immutable'
);

-- ===========================================================================
-- 3. 授权面（7）
-- ===========================================================================
select ok(
  has_function_privilege('authenticated', 'public.generate_compliance_report(text,text)', 'EXECUTE'),
  'authenticated 可执行生成 RPC（函数内 admin 校验）'
);
select ok(
  not has_function_privilege('authenticated', 'app.generate_compliance_report(text,text)', 'EXECUTE'),
  'authenticated 无 app 实现执行权（规则 10）'
);
select ok(
  not has_function_privilege('anon', 'public.generate_compliance_report(text,text)', 'EXECUTE'),
  'anon 无生成执行权'
);
select ok(
  has_table_privilege('authenticated', 'public.compliance_reports', 'SELECT'),
  'authenticated 有报告表 SELECT（RLS 再收口 admin）'
);
select ok(
  not has_table_privilege('authenticated', 'public.compliance_reports', 'INSERT')
  and not has_table_privilege('authenticated', 'public.compliance_reports', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.compliance_reports', 'DELETE'),
  'authenticated 无报告表级写（写仅经 RPC）'
);
select ok(
  not has_table_privilege('anon', 'public.compliance_reports', 'SELECT'),
  'anon 无报告表 SELECT'
);
select ok(
  not has_function_privilege('service_role', 'app.generate_compliance_report(text,text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'app.cleanup_compliance_reports(integer)', 'EXECUTE'),
  'service_role 无生成/清理执行权（ADR-001）'
);

-- ===========================================================================
-- 4. 夹具：操作/登录/版本快照（事务内清空重建，口径可控）
-- ===========================================================================
delete from public.audit_logins;
delete from public.audit_row_versions;
delete from public.audit_operations;
-- 共享本地库可能已有手工生成/其他会话留下的报告，清空保证计数口径可控
delete from public.compliance_reports;

-- 操作：范围 compliance_test 内 3 条（含权限摘要无关），窗口外 1 条
insert into public.audit_operations
  (actor_id, module, action, object_type, object_id, created_at)
values
  ('22222222-2222-2222-2222-222222220001', 'compliance_test', 'create', 'demo', '1',
   date_trunc('month', now())),
  ('22222222-2222-2222-2222-222222220001', 'compliance_test', 'update', 'demo', '2',
   date_trunc('month', now()) + interval '1 second'),
  ('11111111-1111-1111-1111-111111111111', 'compliance_test', 'update', 'demo', '3',
   date_trunc('month', now()) + interval '2 seconds'),
  ('22222222-2222-2222-2222-222222220001', 'compliance_test', 'delete', 'demo', '4',
   date_trunc('month', now()) - interval '1 day');

-- 权限类变更（range=all 的报告里计入「权限与角色变更摘要」）
insert into public.audit_operations
  (actor_id, module, action, object_type, object_id, created_at)
values
  ('11111111-1111-1111-1111-111111111111', 'access', 'assign', 'role', 'r1',
   date_trunc('month', now())),
  ('11111111-1111-1111-1111-111111111111', 'access', 'assign', 'role', 'r2',
   date_trunc('month', now()) + interval '1 second'),
  ('11111111-1111-1111-1111-111111111111', 'access', 'create', 'role', 'r3',
   date_trunc('month', now()) + interval '2 seconds');

-- 登录：2 失败（归类）+ 1 成功，均在窗口内
insert into public.audit_logins (email, success, fail_reason, created_at)
values
  ('fail-a@example.com', false, 'invalid_credentials', date_trunc('month', now())),
  ('fail-b@example.com', false, 'user_banned', date_trunc('month', now()) + interval '1 second'),
  ('ok@example.com', true, null, date_trunc('month', now()) + interval '2 seconds');

-- 版本快照：org 白名单表 2 条在窗口内，1 条在窗口外
insert into public.audit_row_versions (table_name, record_id, version, data, changed_at)
values
  ('profiles', 'p-1', 1, '{}'::jsonb, date_trunc('month', now())),
  ('departments', 'd-1', 1, '{}'::jsonb, date_trunc('month', now()) + interval '1 second'),
  ('positions', 'z-1', 1, '{}'::jsonb, date_trunc('month', now()) - interval '1 day');

-- ===========================================================================
-- 5. 生成：range=compliance_test 月报（HTML 内容与口径）（14）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select public.generate_compliance_report('month', 'compliance_test') as r1 \gset
reset role;

select isnt(:'r1', null::uuid, '生成返回报告 id');
select is(
  (select period from public.compliance_reports where id = :'r1'),
  'month',
  '报告周期落库为 month'
);
select is(
  (select "range" from public.compliance_reports where id = :'r1'),
  'compliance_test',
  '报告范围落库为指定模块'
);
select is(
  (select generated_by from public.compliance_reports where id = :'r1'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  '生成人落库为当前 admin'
);
select ok(
  (select file_content like '%操作总量</span><b>3</b>%'
     from public.compliance_reports where id = :'r1'),
  '操作总量=3（窗口内 3 条，窗口外不计）'
);
select ok(
  (select position('Engineer 测试' in file_content) > 0
     from public.compliance_reports where id = :'r1'),
  'Top 活跃用户含操作人姓名'
);
select ok(
  (select file_content like '%compliance_test%'
     from public.compliance_reports where id = :'r1'),
  '按模块分布含目标模块'
);
select ok(
  (select file_content like '%本周期内无权限/角色变更%'
     from public.compliance_reports where id = :'r1'),
  '范围=compliance_test 时权限摘要为空（范围过滤生效）'
);
select ok(
  (select file_content like '%失败次数</span><b>2</b>%'
     from public.compliance_reports where id = :'r1'),
  '登录失败摘要=2（全系统口径）'
);
select ok(
  (select file_content like '%邮箱或密码错误%' and file_content like '%账号已禁用%'
     from public.compliance_reports where id = :'r1'),
  '登录失败原因归类展示'
);
select ok(
  (select file_content like '%登录总次数</span><b>3</b>%'
     from public.compliance_reports where id = :'r1'),
  '登录总次数=3'
);
select ok(
  (select file_content like '<!doctype html>%'
     from public.compliance_reports where id = :'r1'),
  '归档内容为完整 HTML 文档'
);
select ok(
  (select file_content like '%@media print%' and file_content like '%size:A4%'
     from public.compliance_reports where id = :'r1'),
  'HTML 含 @media print A4 打印样式'
);
select ok(
  (select file_content like '%本周期内无数据变更快照%'
     from public.compliance_reports where id = :'r1'),
  '范围=compliance_test 时变更趋势为空（映射见 range=org）'
);

-- ===========================================================================
-- 6. 生成：range=all 月报（权限摘要）+ range=org（趋势）（6）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select public.generate_compliance_report('month', 'all') as r2 \gset
select public.generate_compliance_report('quarter', 'org') as r3 \gset
reset role;

select ok(
  (select file_content like '%权限类变更</span><b>3</b>%'
     from public.compliance_reports where id = :'r2'),
  '权限与角色变更摘要=3（access 授权类动作）'
);
select ok(
  (select file_content like '%分配角色%'
     from public.compliance_reports where id = :'r2'),
  '权限变更按动作归类（分配角色）'
);
select is(
  (select period from public.compliance_reports where id = :'r3'),
  'quarter',
  '季度报告周期落库为 quarter'
);
select ok(
  (select file_content like '%合计</td><td class="num">2</td>%'
     from public.compliance_reports where id = :'r3'),
  '趋势合计=2（org 白名单表窗口内 2 条）'
);
select ok(
  (select position(to_char(date_trunc('month', now()) at time zone 'Asia/Shanghai', 'YYYY-MM-DD')
                   in file_content) > 0
     from public.compliance_reports where id = :'r3'),
  '趋势表含窗口内日期'
);
select ok(
  (select file_content like '%数据变更量</span><b>2</b>%'
     from public.compliance_reports where id = :'r3'),
  '数变变更量 KPI=2'
);

-- ===========================================================================
-- 7. 校验与越权（5）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.generate_compliance_report('year', 'all') $$,
  '22023', null, '周期非法（year）拒绝'
);
select throws_ok(
  $$ select public.generate_compliance_report('month', 'Bad Range') $$,
  '22023', null, '范围非法（含空格）拒绝'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.generate_compliance_report('month', 'all') $$,
  '42501', null, '非 admin 生成被拒（42501）'
);
select is(
  (select count(*) from public.compliance_reports),
  0::bigint,
  'RLS：engineer 不可见任何报告'
);
reset role;

select ok(
  exists (
    select 1 from public.audit_operations
     where module = 'audit' and action = 'create'
       and object_type = 'compliance_report' and object_id = :'r1'
  ),
  '生成写审计摘要（audit/create/compliance_report）'
);

-- ===========================================================================
-- 8. 历史可见性（admin 全量）+ 清理（5）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select count(*) from public.compliance_reports),
  3::bigint,
  'RLS：admin 可见全部报告'
);
reset role;

-- 回填 r1 为 400 天前 → 清理 365 天前的归档
update public.compliance_reports
   set created_at = now() - interval '400 days'
 where id = :'r1';
select ok(
  app.cleanup_compliance_reports(365) >= 1,
  '清理函数删除过期的报告（返回删除数 ≥1）'
);
select ok(
  not exists (select 1 from public.compliance_reports where id = :'r1'),
  '过期报告（400 天前）已删除'
);
select is(
  (select count(*) from public.compliance_reports),
  2::bigint,
  '保留期内报告不删除'
);

-- ===========================================================================
-- 9. pg_cron 与登记处（2）
-- ===========================================================================
select ok(
  exists (
    select 1 from cron.job
     where jobname = 'cleanup-compliance-reports'
       and schedule = '40 3 * * *'
       and command like '%app.cleanup_compliance_reports()%'
  ),
  'pg_cron 已注册 cleanup-compliance-reports（每日 03:40）'
);
select ok(
  exists (
    select 1 from public.system_cron_registry
     where job_name = 'cleanup-compliance-reports'
       and module = 'audit'
       and owner_route = '/audit/compliance'
       and status = 'active'
  ),
  'system 登记处已登记 cleanup-compliance-reports'
);

select * from finish();
rollback;
