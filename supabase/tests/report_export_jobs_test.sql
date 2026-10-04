-- pgTAP：report/007 —— 统一导出管道（export_sources + export_jobs + worker + RPC + pg_cron）
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构与 seed；RLS（属主/admin；源 enabled）；列级授权（content 不暴露）；授权面（规则 10）；
--       request_export 校验（未登录/未知源/停用源/config/audit 源非 admin）与限额 ≤3；
--       worker 属主身份注入（外部用户 CSV 仅含本人）、queued→done、失败路径、单轮 ≤5；
--       download 属主/admin/他人/过期/未完成；retry 重置与权限；pg_cron 注册。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(96);

-- 测试账号（seeds）：admin=1111... / engineer=2222...0001 / planner=2222...0002；
-- supplier 在夹具中构造（验证外部用户经 RLS 收窄的属主身份注入）。
-- 夹具任务 id 汇总表（postgres 写入后 grant 给 authenticated 供 RPC 参数引用）
create temporary table fixture_ids (label text primary key, id uuid);
grant select on fixture_ids to authenticated;

-- ===========================================================================
-- 1. 结构：表 / 列 / PK / check / FK / seed / RLS / 授权（23）
-- ===========================================================================
select has_table('public', 'export_sources', 'export_sources 表存在');
select has_table('public', 'export_jobs', 'export_jobs 表存在');

select has_column('public', 'export_sources', 'config_schema', 'export_sources.config_schema 存在');
select has_column('public', 'export_jobs', 'content', 'export_jobs.content 存在（v1 行内 CSV）');
select has_column('public', 'export_jobs', 'size_bytes', 'export_jobs.size_bytes 存在');
select has_column('public', 'export_jobs', 'file_path', 'export_jobs.file_path 存在（v2 预留）');

select col_is_pk('public', 'export_sources', 'source', 'export_sources.source 为主键');
select col_is_pk('public', 'export_jobs', 'id', 'export_jobs.id 为主键');

select is(
  (select count(*) from public.export_sources
    where source in ('org.users', 'audit.operations') and enabled),
  2::bigint,
  'seed：org.users / audit.operations 已注册且启用'
);
select is(
  (select string_agg(source || '=' || owner_module, ',' order by source)
     from public.export_sources),
  'audit.operations=audit,integration.logs=integration,org.users=org',
  'seed 源 owner_module 归属正确（含 integration/007 登记的 integration.logs）'
);
select is(
  (select config_schema ->> 'access' from public.export_sources where source = 'audit.operations'),
  'admin',
  'audit.operations 标记 config_schema.access=admin（admin 独占）'
);

select throws_ok(
  $$ insert into public.export_jobs (source, requested_by, status)
     values ('org.users', '11111111-1111-1111-1111-111111111111', 'bogus') $$,
  '23514', null, 'status 非法取值被 check 约束拒绝'
);
select throws_ok(
  $$ insert into public.export_jobs (source, requested_by)
     values ('no.such_source', '11111111-1111-1111-1111-111111111111') $$,
  '23503', null, '未注册导出源被外键拒绝'
);
select throws_ok(
  $$ insert into public.export_jobs (source, requested_by)
     values ('org.users', '00000000-0000-0000-0000-0000000000ff') $$,
  '23503', null, 'requested_by 必须指向 profiles'
);
select throws_ok(
  $$ insert into public.export_sources (source, owner_module) values ('Bad Source', 'x') $$,
  '23514', null, 'source 命名不符合 <module>.<entity> 被拒绝'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.export_sources'::regclass)
  and (select relrowsecurity from pg_class where oid = 'public.export_jobs'::regclass),
  'export_sources / export_jobs 均启用 RLS'
);
select is(
  (select count(*) from pg_policies where schemaname = 'public' and tablename = 'export_jobs'),
  2::bigint,
  'export_jobs 恰 2 条策略（属主 + admin）'
);
select is(
  (select count(*) from pg_policies where schemaname = 'public' and tablename = 'export_sources'),
  1::bigint,
  'export_sources 恰 1 条策略（enabled/admin）'
);

select ok(
  not has_table_privilege('authenticated', 'public.export_jobs', 'insert')
  and not has_table_privilege('authenticated', 'public.export_jobs', 'update')
  and not has_table_privilege('authenticated', 'public.export_jobs', 'delete')
  and not has_table_privilege('authenticated', 'public.export_sources', 'insert'),
  '目标表无 API 写权限（写全经 SECURITY DEFINER RPC）'
);
select ok(
  has_column_privilege('authenticated', 'public.export_jobs', 'status', 'select')
  and not has_column_privilege('authenticated', 'public.export_jobs', 'content', 'select')
  and not has_column_privilege('authenticated', 'public.export_jobs', 'file_path', 'select'),
  '列级 SELECT：元数据可读，content/file_path 不经表级通道暴露'
);
select ok(
  not has_table_privilege('anon', 'public.export_jobs', 'select')
  and not has_table_privilege('anon', 'public.export_sources', 'select'),
  'anon 无两张表的读权限'
);

select has_index('public', 'export_jobs', 'export_jobs_queue_idx', 'queued 队列部分索引存在');
select has_index('public', 'export_jobs', 'export_jobs_owner_created_idx', '属主时间索引存在');

-- ===========================================================================
-- 2. 函数存在性 / security definer / 授权面（16）
-- ===========================================================================
select has_function('app', 'request_export', array['text', 'jsonb'], 'app.request_export 存在');
select has_function('public', 'request_export', array['text', 'jsonb'], 'public.request_export 薄包装存在');
select has_function('app', 'process_export_jobs', array[]::text[], 'app.process_export_jobs 存在');
select has_function('app', 'download_export', array['uuid'], 'app.download_export 存在');
select has_function('public', 'download_export', array['uuid'], 'public.download_export 薄包装存在');
select has_function('app', 'retry_export', array['uuid'], 'app.retry_export 存在');
select has_function('public', 'retry_export', array['uuid'], 'public.retry_export 薄包装存在');

select ok(
  (select count(*) = 3
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname in ('csv_field', 'csv_line', 'csv_encode')),
  'CSV helper 三个函数存在'
);
select ok(
  (select count(*) = 6
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
      ('app', 'request_export'), ('public', 'request_export'),
      ('app', 'download_export'), ('public', 'download_export'),
      ('app', 'retry_export'), ('public', 'retry_export'))
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '6 个用户 RPC 均 security definer + search_path 固定为空'
);
select ok(
  (select not p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'process_export_jobs'),
  'worker 为 security invoker + search_path 固定为空（PG 禁止 definer 内 SET ROLE，见迁移注释）'
);

select ok(
  has_function_privilege('authenticated', 'public.request_export(text,jsonb)', 'EXECUTE'),
  'authenticated 可执行 public.request_export'
);
select ok(
  has_function_privilege('authenticated', 'public.download_export(uuid)', 'EXECUTE'),
  'authenticated 可执行 public.download_export'
);
select ok(
  has_function_privilege('authenticated', 'public.retry_export(uuid)', 'EXECUTE'),
  'authenticated 可执行 public.retry_export'
);
select ok(
  not has_function_privilege('authenticated', 'app.request_export(text,jsonb)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.process_export_jobs()', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.download_export(uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.retry_export(uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.csv_field(text)', 'EXECUTE'),
  '内部实现 / worker / helper 不对 authenticated 开放（INDEX 规则 10）'
);
select ok(
  not has_function_privilege('anon', 'public.request_export(text,jsonb)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.download_export(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.retry_export(uuid)', 'EXECUTE'),
  'anon 无三个用户 RPC 执行权'
);
select ok(
  not has_function_privilege('service_role', 'public.request_export(text,jsonb)', 'EXECUTE')
  and not has_function_privilege('service_role', 'app.process_export_jobs()', 'EXECUTE'),
  'service_role 无导出 RPC/worker 执行权（ADR-001 全局禁令）'
);

-- ===========================================================================
-- 3. request_export：校验、权限、限额（16）
-- ===========================================================================
-- 夹具：外部用户 supplier（profiles 由 handle_new_user 建档后回写角色）
insert into auth.users (id, email, raw_app_meta_data)
values ('77777777-7777-4777-8777-777777770001', 'report-export-supplier@example.com', '{}'::jsonb);
update public.profiles
   set role = 'supplier'
 where id = '77777777-7777-4777-8777-777777770001';

select is(
  (select role::text from public.profiles where id = '77777777-7777-4777-8777-777777770001'),
  'supplier',
  '夹具：supplier 用户建档且角色正确'
);

-- 未登录（claims 为空）拒绝
select set_config('request.jwt.claims', '{}', true);
set local role authenticated;
select throws_ok(
  $$ select public.request_export('org.users') $$,
  '42501', '未登录，无法发起导出', '未登录发起被拒'
);
reset role;

-- engineer：audit 源（admin 独占）被拒
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.request_export('audit.operations') $$,
  '42501', null, '非 admin 发起 audit.operations 被拒（发起时拦截）'
);
select throws_ok(
  $$ select public.request_export('report.unknown') $$,
  'P0002', null, '未注册导出源被拒'
);
select throws_ok(
  $$ select public.request_export('org.users', '[]'::jsonb) $$,
  '22023', null, 'config 非 jsonb 对象被拒'
);
reset role;

-- 停用源拒绝（admin 视角同样被 enabled 拦截）
update public.export_sources set enabled = false where source = 'org.users';
set local role authenticated;
select throws_ok(
  $$ select public.request_export('org.users') $$,
  'P0001', null, '停用源发起被拒'
);
reset role;
update public.export_sources set enabled = true where source = 'org.users';

-- engineer 发起 org.users 成功
set local role authenticated;
select lives_ok(
  $$ select public.request_export('org.users') $$,
  'engineer 发起 org.users 导出'
);
reset role;
select is(
  (select status || '/' || source from public.export_jobs
    where requested_by = '22222222-2222-2222-2222-222222220001'),
  'queued/org.users',
  '任务入库为 queued 且属主/来源正确'
);
select ok(
  (select diff ->> 'source' = 'org.users'
     from public.audit_operations
    where module = 'report' and action = 'request' and object_type = 'export_job'
    order by id desc
    limit 1),
  '发起写审计摘要（report / request / export_job）'
);

-- admin 发起 audit.operations 成功
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.request_export('audit.operations') $$,
  'admin 发起 audit.operations 导出'
);
reset role;

-- supplier 发起 org.users 成功（外部用户允许，执行时按属主 RLS 收窄）
select set_config(
  'request.jwt.claims',
  '{"sub":"77777777-7777-4777-8777-777777770001","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.request_export('org.users') $$,
  'supplier 发起 org.users 导出'
);
reset role;

-- planner 限额：3 条 queued 后第 4 条被拒
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220002","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok($$ select public.request_export('org.users') $$, 'planner 第 1 条导出发起成功');
select lives_ok($$ select public.request_export('org.users') $$, 'planner 第 2 条导出发起成功');
select lives_ok($$ select public.request_export('org.users') $$, 'planner 第 3 条导出发起成功');
select throws_ok(
  $$ select public.request_export('org.users') $$,
  'P0001', '进行中的导出任务已达上限（3），请等待完成后再试',
  '第 4 条并发任务被限额拒绝（queued + running ≤ 3）'
);
reset role;

-- 终态任务不计入限额：把 planner 最新 queued 置 done 后可再发起
update public.export_jobs
   set status = 'done', finished_at = now(), content = '', size_bytes = 0
 where id = (
   select id from public.export_jobs
    where requested_by = '22222222-2222-2222-2222-222222220002'
      and status = 'queued'
    order by created_at desc
    limit 1
 );
set local role authenticated;
select lives_ok(
  $$ select public.request_export('org.users') $$,
  '终态任务不计入限额：腾出名额后发起成功'
);
reset role;

-- ===========================================================================
-- 4. worker：属主身份注入、queued→done、失败路径、单轮 ≤5（16）
--    待处理队列：engineer 1 + admin 1 + supplier 1 + planner 3 = 6
-- ===========================================================================
select is(
  app.process_export_jobs(),
  5,
  '单轮最多处理 5 条（limit 5 / for update skip locked）'
);
select is(
  (select count(*) from public.export_jobs where status = 'queued'),
  1::bigint,
  '第一轮后仅剩 1 条 queued'
);
select is(
  app.process_export_jobs(),
  1,
  '第二轮处理剩余 1 条'
);
select is(
  (select count(*) from public.export_jobs where status in ('queued', 'running', 'failed')),
  0::bigint,
  '全部任务收敛到终态 done'
);

select ok(
  (select content like 'id,full_name,department,role,status,created_at%'
     from public.export_jobs
    where requested_by = '22222222-2222-2222-2222-222222220001'),
  'org.users CSV 以表头开头'
);
select ok(
  (select content like '%系统管理员%'
     from public.export_jobs
    where requested_by = '22222222-2222-2222-2222-222222220001'),
  '内部用户导出含通讯录成员（RLS：内部可见）'
);
select ok(
  (select content like 'id,created_at,actor_id,actor_name,module,action,object_type,object_id,ip%'
     from public.export_jobs
    where requested_by = '11111111-1111-1111-1111-111111111111'
      and source = 'audit.operations'),
  'audit.operations CSV 以表头开头'
);
select ok(
  (select content like '%report,request,export_job%'
     from public.export_jobs
    where requested_by = '11111111-1111-1111-1111-111111111111'
      and source = 'audit.operations'),
  '操作日志导出含发起审计行（admin 全量）'
);
select ok(
  (select content like '%report-export-supplier%'
     from public.export_jobs
    where requested_by = '77777777-7777-4777-8777-777777770001'),
  '外部用户导出含本人行'
);
select ok(
  (select content not like '%系统管理员%' and content not like '%Engineer 测试%'
     from public.export_jobs
    where requested_by = '77777777-7777-4777-8777-777777770001'),
  '属主身份注入：外部用户 CSV 不含他人（RLS 按属主收窄，ADR-001）'
);
select ok(
  (select size_bytes = octet_length(content) and size_bytes > 0
     from public.export_jobs
    where requested_by = '22222222-2222-2222-2222-222222220001'),
  'size_bytes = octet_length(content)'
);
select ok(
  (select status = 'done'
          and started_at is not null and finished_at >= started_at
          and error is null
     from public.export_jobs
    where requested_by = '22222222-2222-2222-2222-222222220001'),
  '完成任务的 started_at / finished_at / error 状态正确'
);

-- 失败路径：源在排队期间被停用 → worker 置 failed 并记原因
update public.export_sources set enabled = false where source = 'org.users';
insert into public.export_jobs (source, requested_by, status)
values ('org.users', '22222222-2222-2222-2222-222222220001', 'queued');
select is(
  app.process_export_jobs(),
  1,
  '停用源任务进入本轮处理'
);
select is(
  (select status from public.export_jobs
    where requested_by = '22222222-2222-2222-2222-222222220001'
      and status = 'failed'),
  'failed',
  '停用源任务置 failed'
);
select ok(
  (select error like '导出源已停用%'
     from public.export_jobs
    where requested_by = '22222222-2222-2222-2222-222222220001'
      and status = 'failed'),
  '失败原因记录「导出源已停用」'
);
select ok(
  exists (
    select 1 from public.audit_operations
     where module = 'report' and action = 'fail' and object_type = 'export_job'
       and diff ->> 'source' = 'org.users'
  ),
  '终态失败写审计摘要（ADR-001 第 3 节）'
);
update public.export_sources set enabled = true where source = 'org.users';

-- ===========================================================================
-- 5. download / retry / RLS / pg_cron（24）
-- ===========================================================================
-- 夹具任务 id（postgres 汇总，供 RPC 参数引用）
insert into fixture_ids (label, id)
select 'eng_user', id from public.export_jobs
 where requested_by = '22222222-2222-2222-2222-222222220001'
   and status = 'done'
 order by created_at
 limit 1;
insert into fixture_ids (label, id)
select 'admin_audit', id from public.export_jobs
 where requested_by = '11111111-1111-1111-1111-111111111111'
   and source = 'audit.operations';
insert into fixture_ids (label, id)
select 'supplier_user', id from public.export_jobs
 where requested_by = '77777777-7777-4777-8777-777777770001'
   and status = 'done';
insert into fixture_ids (label, id)
select 'eng_failed', id from public.export_jobs
 where requested_by = '22222222-2222-2222-2222-222222220001'
   and status = 'failed';

-- download：非属主（planner）被拒
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220002","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.download_export((select id from fixture_ids where label = 'eng_user')) $$,
  '42501', null, '非属主下载被拒'
);
reset role;

-- download：属主通过 + 内容为 CSV
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.download_export((select id from fixture_ids where label = 'eng_user')) $$,
  '属主 download_export 通过'
);
select ok(
  (public.download_export((select id from fixture_ids where label = 'eng_user'))
     like 'id,full_name,department,role,status,created_at%'),
  '下载内容为 CSV（RPC 返回表头）'
);
reset role;

-- download：admin 可下载他人任务
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.download_export((select id from fixture_ids where label = 'eng_user')) $$,
  'admin 可下载他人导出任务'
);
select throws_ok(
  $$ select public.download_export('00000000-0000-0000-0000-0000000000ee') $$,
  'P0002', null, '任务不存在报 P0002'
);
reset role;

-- download：E-2 基准修正——创建 8 天前、完成 1 天前的任务仍可下载（以 finished_at 计）
insert into public.export_jobs (source, requested_by, status, content, size_bytes, created_at, finished_at)
values ('org.users', '11111111-1111-1111-1111-111111111111', 'done', 'id,full_name', 12,
        now() - interval '8 days', now() - interval '1 day');
insert into fixture_ids (label, id)
select 'admin_old_created', id from public.export_jobs
 where requested_by = '11111111-1111-1111-1111-111111111111'
   and status = 'done'
   and created_at < now() - interval '7 days'
   and content is not null
 order by created_at desc
 limit 1;
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.download_export((select id from fixture_ids where label = 'admin_old_created')) $$,
  'E-2：创建 8 天前但完成 1 天前的任务仍可下载（基准 finished_at）'
);
reset role;

-- download：过期（完成时间 8 天前）拒绝
update public.export_jobs
   set created_at = now() - interval '8 days',
       finished_at = now() - interval '8 days'
 where id = (select id from fixture_ids where label = 'eng_user');
set local role authenticated;
select throws_ok(
  $$ select public.download_export((select id from fixture_ids where label = 'eng_user')) $$,
  'P0001', '导出文件已过期（完成后 7 天内可下载）',
  '过期任务下载被拒（完成 7 天有效期）'
);
reset role;

-- download：未完成（running）拒绝
insert into public.export_jobs (source, requested_by, status, started_at)
values ('org.users', '77777777-7777-4777-8777-777777770001', 'running', now());
select set_config(
  'request.jwt.claims',
  '{"sub":"77777777-7777-4777-8777-777777770001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.download_export((
       select id from public.export_jobs
        where requested_by = '77777777-7777-4777-8777-777777770001'
          and status = 'running')) $$,
  'P0001', null, '未完成任务下载被拒'
);
reset role;

-- retry：done 任务不可重试
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.retry_export((select id from fixture_ids where label = 'eng_user')) $$,
  'P0001', null, '仅失败任务可重试（done 被拒）'
);
reset role;

-- retry：属主重试失败任务 → queued 重置
set local role authenticated;
select lives_ok(
  $$ select public.retry_export((select id from fixture_ids where label = 'eng_failed')) $$,
  '属主重试失败任务'
);
reset role;
select ok(
  (select status = 'queued' and error is null and content is null
          and size_bytes is null and started_at is null and finished_at is null
     from public.export_jobs
    where id = (select id from fixture_ids where label = 'eng_failed')),
  '重试重置为 queued 并清空失败信息与产物'
);

-- retry：worker 再次处理，产物生成
select is(
  app.process_export_jobs(),
  1,
  '重试任务被 worker 再次处理'
);
select ok(
  (select status = 'done' and content like 'id,full_name%'
     from public.export_jobs
    where id = (select id from fixture_ids where label = 'eng_failed')),
  '重试后 CSV 产物生成'
);

-- retry：非属主拒绝 / admin 可代重试
insert into public.export_jobs (source, requested_by, status, error, started_at, finished_at)
values ('org.users', '22222222-2222-2222-2222-222222220002', 'failed', '构造失败', now(), now());
insert into fixture_ids (label, id)
select 'planner_failed', id from public.export_jobs
 where requested_by = '22222222-2222-2222-2222-222222220002'
   and status = 'failed';

set local role authenticated;
select throws_ok(
  $$ select public.retry_export((select id from fixture_ids where label = 'planner_failed')) $$,
  '42501', null, '非属主重试被拒'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.retry_export((select id from fixture_ids where label = 'planner_failed')) $$,
  'admin 可代属主重试'
);
reset role;

-- RLS：属主只见自己 / admin 全量 / 无表级写
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select ok(
  (select count(id) = 2 from public.export_jobs)
  and not exists (
    select 1 from public.export_jobs
     where requested_by = '77777777-7777-4777-8777-777777770001'
  ),
  'RLS：engineer 仅见本人任务（他人不可见）'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select ok(
  exists (
    select 1 from public.export_jobs
     where requested_by = '77777777-7777-4777-8777-777777770001'
  )
  and (select count(id) > 2 from public.export_jobs),
  'RLS：admin 全量可见'
);
select throws_ok(
  $$ insert into public.export_jobs (source, requested_by)
     values ('org.users', '11111111-1111-1111-1111-111111111111') $$,
  '42501', null, 'admin 也走 RPC（表级无写授权）'
);
reset role;

set local role anon;
select throws_ok(
  $$ select count(*) from public.export_jobs $$,
  '42501', null, 'anon 直读任务表被拒（无任何授权）'
);
reset role;

-- RLS：export_sources 非 admin 仅见 enabled 源；admin 可见停用源
-- 启用源：org.users / integration.logs（admin 可见 3 源，其中 audit.operations 停用）
update public.export_sources set enabled = false where source = 'audit.operations';
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select count(*) from public.export_sources),
  2::bigint,
  'RLS：非 admin 仅见 enabled 源'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select count(*) from public.export_sources),
  3::bigint,
  'RLS：admin 可见停用源'
);
reset role;
update public.export_sources set enabled = true where source = 'audit.operations';

-- pg_cron：扩展启用 + job 注册（TODO system/011 登记处后续补登记）
select ok(
  exists (select 1 from pg_extension where extname = 'pg_cron'),
  'pg_cron 扩展已启用'
);
select is(
  (select count(*) from cron.job where jobname = 'process-export-jobs'),
  1::bigint,
  'pg_cron 已注册 process-export-jobs'
);
select ok(
  (select schedule = '* * * * *' and command like '%app.process_export_jobs()%'
     from cron.job
    where jobname = 'process-export-jobs'),
  'cron 表达式每分钟且命令指向 worker'
);
select is(
  (select active from cron.job where jobname = 'process-export-jobs'),
  true,
  'cron job 处于启用状态'
);

select * from finish();
rollback;
