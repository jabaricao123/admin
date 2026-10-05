-- pgTAP：system/003 —— 对象存储初始化（buckets + storage.objects RLS）+ 测试验证/用量统计 RPC
-- 运行：supabase db reset && supabase test db
-- 覆盖：buckets 存在/私有；storage.objects admin 策略（4 条，仅 authenticated）；函数存在性 +
--       SECURITY DEFINER + search_path=''；GRANT 面；非 admin 越权拒绝；未配置 P0002；
--       配置不完整 / 未知 provider / supabase-storage bucket 不存在 → failed；
--       s3 完整配置（endpoint/region/access_key/secret_key）→ verified（bucket 归属外部对象存储）；
--       supabase-storage 配置完整且 bucket 存在 → verified；
--       掩码不泄明文、审计摘要不落凭据明文；get_storage_usage 聚合（空 bucket 0 / 多对象求和 /
--       非数字 size 按 0）；RLS 行为（admin 可见可写、engineer 不可见且写被拒、anon 不可见）。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(62);

-- ===========================================================================
-- 1. buckets：存在 / 私有（5）
-- ===========================================================================
select has_table('storage', 'buckets', 'storage.buckets 表存在');

select ok(
  (select count(*) = 1 from storage.buckets where id = 'exports' and name = 'exports' and public = false),
  'exports bucket 存在且为 private'
);
select ok(
  (select count(*) = 1 from storage.buckets where id = 'sync-templates' and name = 'sync-templates' and public = false),
  'sync-templates bucket 存在且为 private'
);
select ok(
  (select count(*) = 1 from storage.buckets where id = 'attachments' and name = 'attachments' and public = false),
  'attachments bucket 存在且为 private'
);
select ok(
  not exists (
    select 1 from storage.buckets
    where id in ('exports', 'sync-templates', 'attachments') and public
  ),
  '三个托管 bucket 无一公开（访问一律经签名 URL）'
);

-- ===========================================================================
-- 2. storage.objects RLS 策略（4）
-- ===========================================================================
select is(
  (select relrowsecurity from pg_class where oid = 'storage.objects'::regclass),
  true,
  'storage.objects 已启用 RLS'
);
select is(
  (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'),
  4::bigint,
  'storage.objects 上恰有 4 条 admin 策略'
);
select ok(
  (select bool_and(roles = '{authenticated}'::name[])
     from pg_policies where schemaname = 'storage' and tablename = 'objects'),
  '4 条策略均仅绑定 authenticated 角色'
);
select is(
  (select count(distinct cmd) from pg_policies
    where schemaname = 'storage' and tablename = 'objects'),
  4::bigint,
  '策略覆盖 select / insert / update / delete'
);

-- ===========================================================================
-- 3. 函数存在性 + SECURITY DEFINER + search_path + GRANT 面（10）
-- ===========================================================================
select has_function('app', 'test_storage_config', array[]::text[], 'app.test_storage_config() 存在');
select has_function('public', 'test_storage_config', array[]::text[], 'public.test_storage_config() 薄包装存在');
select has_function('app', 'get_storage_usage', array[]::text[], 'app.get_storage_usage() 存在');
select has_function('public', 'get_storage_usage', array[]::text[], 'public.get_storage_usage() 薄包装存在');

select ok(
  (select count(*) = 4
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
      ('app', 'test_storage_config'),
      ('public', 'test_storage_config'),
      ('app', 'get_storage_usage'),
      ('public', 'get_storage_usage')
    )
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '4 个函数均 security definer + search_path 固定为空'
);

select ok(
  has_function_privilege('authenticated', 'app.test_storage_config()', 'EXECUTE'),
  'authenticated 可执行 app.test_storage_config'
);
select ok(
  has_function_privilege('authenticated', 'public.test_storage_config()', 'EXECUTE'),
  'authenticated 可执行 public.test_storage_config'
);
select ok(
  has_function_privilege('authenticated', 'public.get_storage_usage()', 'EXECUTE'),
  'authenticated 可执行 public.get_storage_usage'
);
select ok(
  not has_function_privilege('anon', 'public.test_storage_config()', 'EXECUTE'),
  'anon 无 public.test_storage_config 执行权'
);
select ok(
  not has_function_privilege('anon', 'public.get_storage_usage()', 'EXECUTE'),
  'anon 无 public.get_storage_usage 执行权'
);

-- ===========================================================================
-- 4. 越权与前置校验（4）
-- ===========================================================================
-- engineer 调两个 RPC：admin 校验先于业务逻辑
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.test_storage_config() $$,
  '42501', null, 'engineer 调 test_storage_config 被 admin 校验拒绝'
);
select throws_ok(
  $$ select public.get_storage_usage() $$,
  '42501', null, 'engineer 调 get_storage_usage 被 admin 校验拒绝'
);
reset role;

-- anon 无 GRANT（先于函数体）
set local role anon;
select throws_ok(
  $$ select public.test_storage_config() $$,
  '42501', null, 'anon 调 test_storage_config 被拒（无 GRANT）'
);
reset role;

-- admin：未配置 storage 时报 P0002
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  $$ select public.test_storage_config() $$,
  'P0002', null, '未保存对象存储配置时报 P0002'
);

-- ===========================================================================
-- 5. 草稿可存 + 配置不完整 → failed（6）
-- ===========================================================================
select lives_ok(
  $$ select public.upsert_service_config('storage', '{"provider":"supabase-storage"}'::jsonb, null) $$,
  'admin 保存不完整对象存储配置（草稿态）'
);
select is(
  (select (public.test_storage_config()) ->> 'ok'),
  'false',
  '配置不完整：test_storage_config 返回 ok=false'
);
select is(
  (select (public.test_storage_config()) ->> 'message'),
  '配置不完整：provider / endpoint / bucket 均为必填',
  '配置不完整：message 提示必填字段'
);
select is(
  (select (public.test_storage_config()) ->> 'verify_status'),
  'failed',
  '配置不完整：返回 verify_status=failed'
);
reset role;

select is(
  (select verify_status from public.system_services where service = 'storage'),
  'failed',
  '配置不完整：库内 verify_status=failed'
);
select ok(
  (select verified_at is not null from public.system_services where service = 'storage'),
  '配置不完整：verified_at 记录最近一次尝试时间'
);

-- ===========================================================================
-- 6. 未知 provider → failed（2）
-- ===========================================================================
set local role authenticated;
select lives_ok(
  $$ select public.upsert_service_config(
       'storage',
       '{"provider":"oss","endpoint":"https://oss.example.com","bucket":"exports"}'::jsonb,
       null
     ) $$,
  'admin 保存未知 provider 配置'
);
select is(
  (select (public.test_storage_config()) ->> 'message'),
  '未知 provider：oss（支持 supabase-storage / s3）',
  '未知 provider：message 说明支持的取值'
);
reset role;

-- ===========================================================================
-- 7. provider 语义分派：s3 校验 endpoint/region/access_key/secret_key（10）
--    s3 目标 bucket 由外部对象存储持有，本地不校验 bucket 存在性（原实现必然 failed 的缺陷）；
--    supabase-storage 保持 storage.buckets 存在性校验。
-- ===========================================================================
set local role authenticated;
select lives_ok(
  $$ select public.upsert_service_config(
       'storage',
       '{"provider":"s3","endpoint":"https://s3.example.com","region":"cn-north-1","bucket":"no-such-bucket"}'::jsonb,
       '{"access_key":"minio-access","secret_key":"testStorageSecret9876"}'
     ) $$,
  'admin 保存完整 s3 配置（bucket 不在本地 storage.buckets 中）'
);
select is(
  (select (public.test_storage_config()) ->> 'ok'),
  'true',
  's3 完整配置：test_storage_config 返回 ok=true（不再永远 failed）'
);
select is(
  (select (public.test_storage_config()) ->> 'verify_status'),
  'verified',
  's3 完整配置：verify_status=verified'
);
select ok(
  (select (public.test_storage_config()) ->> 'message') like '配置校验通过：S3 端点 %',
  's3 完整配置：message 标注 S3 端点（连通性实测待出站 ADR）'
);

select lives_ok(
  $$ select public.upsert_service_config(
       'storage',
       '{"provider":"s3","endpoint":"https://s3.example.com","region":"cn-north-1","bucket":"exports"}'::jsonb,
       '{"access_key":"minio-access"}'
     ) $$,
  'admin 保存缺 secret_key 的 s3 配置'
);
select is(
  (select (public.test_storage_config()) ->> 'ok'),
  'false',
  's3 缺 secret_key：test_storage_config 返回 ok=false'
);
select is(
  (select (public.test_storage_config()) ->> 'message'),
  '配置不完整：S3 需 endpoint / region / access_key / secret_key',
  's3 缺 secret_key：message 指明必填键'
);

-- supabase-storage 通道：bucket 存在性校验保持原语义
select lives_ok(
  $$ select public.upsert_service_config(
       'storage',
       '{"provider":"supabase-storage","endpoint":"https://storage.example.com","bucket":"no-such-bucket"}'::jsonb,
       null
     ) $$,
  'admin 保存 bucket 不存在的 supabase-storage 配置'
);
select is(
  (select (public.test_storage_config()) ->> 'ok'),
  'false',
  'supabase-storage bucket 不存在：返回 ok=false'
);
select is(
  (select (public.test_storage_config()) ->> 'message'),
  'bucket 不存在或不可访问：no-such-bucket',
  'supabase-storage bucket 不存在：message 指明目标 bucket'
);
reset role;

-- ===========================================================================
-- 8. supabase-storage 配置完整且 bucket 存在 → verified + 掩码/审计（8）
-- ===========================================================================
set local role authenticated;
select lives_ok(
  $$ select public.upsert_service_config(
       'storage',
       '{"provider":"supabase-storage","endpoint":"https://storage.example.com","bucket":"exports","signed_url_ttl_minutes":60,"max_file_size_mb":50,"mime_whitelist":["text/csv","application/pdf"]}'::jsonb,
       '{"access_key":"minio-access","secret_key":"testStorageSecret9876"}'
     ) $$,
  'admin 保存完整的 supabase-storage 配置'
);
select is(
  (select (public.test_storage_config()) ->> 'ok'),
  'true',
  '配置完整：test_storage_config 返回 ok=true'
);
select ok(
  (select (public.test_storage_config()) ->> 'message') like '配置校验通过：bucket「exports」%',
  '配置完整：message 指明 bucket 可访问'
);
select is(
  (select (public.test_storage_config()) ->> 'verify_status'),
  'verified',
  '配置完整：返回 verify_status=verified'
);
reset role;

select is(
  (select verify_status from public.system_services where service = 'storage'),
  'verified',
  '配置完整：库内 verify_status=verified'
);
select ok(
  (select verified_at is not null from public.system_services where service = 'storage'),
  '配置完整：verified_at 记录最近一次尝试时间'
);
select ok(
  (select (diff ->> 'note') like '%exports%'
     from public.audit_operations
    where module = 'system' and action = 'verify'
      and object_type = 'service_config' and object_id = 'storage'
    order by id desc limit 1),
  'verify 审计备注含目标 bucket（不含凭据）'
);
select ok(
  not exists (
    select 1 from public.audit_operations
    where module = 'system' and diff::text like '%testStorageSecret9876%'
  ),
  '审计摘要不落凭据明文'
);

-- ===========================================================================
-- 9. get_storage_usage：空 bucket / 聚合 / 非数字 size（7）
-- ===========================================================================
set local role authenticated;
select is(
  (select count(*) from public.get_storage_usage()),
  3::bigint,
  '用量统计返回全部 3 个 bucket（空 bucket 也在列）'
);
select is(
  (select object_count from public.get_storage_usage() where bucket_id = 'exports'),
  0::bigint,
  '空 bucket：object_count=0'
);
select is(
  (select total_bytes from public.get_storage_usage() where bucket_id = 'exports'),
  0::bigint,
  '空 bucket：total_bytes=0'
);
select is(
  (select array_agg(bucket_id order by bucket_id) from public.get_storage_usage()),
  array['attachments', 'exports', 'sync-templates']::text[],
  '用量统计按 bucket_id 升序返回'
);
reset role;

-- 夹具：storage.objects 写入（本事务 rollback）
insert into storage.objects (bucket_id, name, metadata)
values
  ('exports', '11111111-1111-1111-1111-111111111111/report-a.csv', '{"size":"2048","mimetype":"text/csv"}'::jsonb),
  ('exports', '11111111-1111-1111-1111-111111111111/report-b.pdf', '{"size":"1024","mimetype":"application/pdf"}'::jsonb),
  ('sync-templates', 'templates/import.xlsx', '{"size":"500","mimetype":"application/vnd.ms-excel"}'::jsonb),
  ('attachments', 'misc/note.bin', '{"size":"abc"}'::jsonb);

set local role authenticated;
select is(
  (select object_count from public.get_storage_usage() where bucket_id = 'exports'),
  2::bigint,
  'exports：object_count 聚合为 2'
);
select is(
  (select total_bytes from public.get_storage_usage() where bucket_id = 'exports'),
  3072::bigint,
  'exports：total_bytes 聚合为 2048+1024'
);
select is(
  (select total_bytes from public.get_storage_usage() where bucket_id = 'attachments'),
  0::bigint,
  'metadata.size 非数字按 0 计（不报错）'
);
reset role;

-- ===========================================================================
-- 10. storage.objects RLS 行为：admin 可见可写 / engineer 不可见且写拒（6）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select count(*) from storage.objects),
  4::bigint,
  'RLS：admin 可见全部 4 个夹具对象'
);
select lives_ok(
  $$ insert into storage.objects (bucket_id, name, metadata)
     values ('exports', 'admin/extra.txt', '{"size":"10"}'::jsonb) $$,
  'RLS：admin 可直写 storage.objects'
);
reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select count(*) from storage.objects),
  0::bigint,
  'RLS：engineer 不可见任何对象（rls 过滤）'
);
select throws_ok(
  $$ insert into storage.objects (bucket_id, name, metadata)
     values ('exports', 'eng/evil.txt', '{"size":"10"}'::jsonb) $$,
  '42501', null, 'RLS：engineer 直写被拒'
);
set local storage.allow_delete_query = 'true';
delete from storage.objects where bucket_id = 'exports';
reset role;

select is(
  (select count(*) from storage.objects),
  5::bigint,
  'RLS：engineer 删除不命中任何对象（5 行仍在）'
);

set local role anon;
select is(
  (select count(*) from storage.objects),
  0::bigint,
  'RLS：anon 不可见任何对象'
);
reset role;

select * from finish();
rollback;
