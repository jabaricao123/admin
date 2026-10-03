-- 系统管理 · 对象存储初始化（工单 system/003）
-- 契约：docs/modules/system/services-storage.md（配置字段、bucket 约定、RLS「仅 admin 可管理」、
--       bucket 不公开、签名 URL 约束）；docs/modules/INDEX.md 规则 4（凭据 pgcrypto 加密 + 界面掩码）、
--       规则 10（内部 RPC 授权面）；验证状态机沿用 services-mail.md 同款（system/001 + system/002）。
--
-- 组成：
--   1. storage.buckets：exports / sync-templates / attachments 三个私有 bucket（幂等 seed）；
--   2. storage.objects RLS：首期仅 admin 全权；service 通道 = storage 服务以表属主身份访问
--      （supabase_storage_admin 为 storage.objects 属主，不经 RLS，无需策略）；
--      属主路径前缀隔离留给 report/007（注释 TODO）；
--   3. app.test_storage_config / public.test_storage_config：存储「测试验证」RPC（admin）——
--      校验 provider/endpoint/bucket 完整性 + 目标 bucket 存在性，经 app.mark_service_verified 回写；
--   4. app.get_storage_usage / public.get_storage_usage：bucket 用量统计（admin，storage.objects 聚合）。
--
-- 依赖：system/001（20261004151000，system_services + current_role + mark_service_verified）、
--       Supabase Storage schema（storage.buckets / storage.objects，服务预置）。

-- ---------------------------------------------------------------------------
-- 0. 前置校验：storage schema 必须存在（裸 Postgres 环境尽早报清晰错误）
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('storage.buckets') is null then
    raise exception 'storage.buckets 不存在：对象存储初始化依赖 Supabase Storage schema'
      using errcode = 'P0001';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 1. buckets：三个私有 bucket（幂等；公开访问一律经签名 URL）
--    services-storage.md：exports 导出文件 / sync-templates Excel 模板 / attachments 附件（预留）。
--    file_size_limit / allowed_mime_types 不在 bucket 上固化——配置存 system_services.config，
--    由消费方在签名 URL/上传校验时执行（enforcement 在 report/007 导出管道与 sync 导入落地）。
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values
  ('exports',        'exports',        false),
  ('sync-templates', 'sync-templates', false),
  ('attachments',    'attachments',    false)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 2. storage.objects RLS：首期 admin 全权（仅本三 bucket）
--    说明（services-storage.md 依赖与契约）：
--    - 所有 bucket 不公开；登录用户访问经签名 URL（签名 URL 由 storage 服务校验，不经 RLS 策略）；
--    - 本策略覆盖 Data API / storage API 中用户态直连的读写路径；
--    - 属主隔离（exports 按 user_id/ 路径前缀，属主可读自前缀）在 report/007 交付导出管道时
--      追加 permissive 策略细化——RLS 策略间为 OR 关系，不会回改本策略。
--    TODO(report/007)：为 exports 追加属主策略，形如
--      bucket_id = 'exports' and (storage.foldername(name))[1] = (select auth.uid())::text
--      （读自前缀；写路径由导出管道以服务端通道落盘，用户直写是否开放届时评审）。
-- ---------------------------------------------------------------------------
create policy system_storage_admin_select
on storage.objects
for select
to authenticated
using (
  (select app.current_role()) = 'admin'
  and bucket_id in ('exports', 'sync-templates', 'attachments')
);

create policy system_storage_admin_insert
on storage.objects
for insert
to authenticated
with check (
  (select app.current_role()) = 'admin'
  and bucket_id in ('exports', 'sync-templates', 'attachments')
);

create policy system_storage_admin_update
on storage.objects
for update
to authenticated
using (
  (select app.current_role()) = 'admin'
  and bucket_id in ('exports', 'sync-templates', 'attachments')
)
with check (
  (select app.current_role()) = 'admin'
  and bucket_id in ('exports', 'sync-templates', 'attachments')
);

create policy system_storage_admin_delete
on storage.objects
for delete
to authenticated
using (
  (select app.current_role()) = 'admin'
  and bucket_id in ('exports', 'sync-templates', 'attachments')
);

-- ---------------------------------------------------------------------------
-- 3. app.test_storage_config：存储配置测试验证（admin）
--    契约（services-storage.md 功能需求 3）：列出 bucket 可访问性验证。
--    本期简化：校验 provider/endpoint/bucket 完整性（provider ∈ supabase-storage|s3）+
--    storage.buckets 存在目标 bucket；不做出站连通性探测（出站运行时选型尚未上线）。
--    结果经 app.mark_service_verified 回写验证状态机（配置完整且 bucket 可用 → verified）。
-- ---------------------------------------------------------------------------
create function app.test_storage_config()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row      public.system_services;
  v_provider text;
  v_endpoint text;
  v_bucket   text;
  v_ok       boolean;
  v_message  text;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.system_services
  where service = 'storage';

  if not found then
    raise exception '对象存储配置不存在，请先保存配置' using errcode = 'P0002';
  end if;

  v_provider := nullif(btrim(v_row.config ->> 'provider'), '');
  v_endpoint := nullif(btrim(v_row.config ->> 'endpoint'), '');
  v_bucket   := nullif(btrim(v_row.config ->> 'bucket'), '');

  if v_provider is null or v_endpoint is null or v_bucket is null then
    v_ok      := false;
    v_message := '配置不完整：provider / endpoint / bucket 均为必填';
  elsif v_provider not in ('supabase-storage', 's3') then
    v_ok      := false;
    v_message := format('未知 provider：%s（支持 supabase-storage / s3）', v_provider);
  elsif exists (select 1 from storage.buckets b where b.id = v_bucket) then
    v_ok      := true;
    v_message := format('配置校验通过：bucket「%s」可访问（连通性实测待出站运行时上线后启用）', v_bucket);
  else
    v_ok      := false;
    v_message := format('bucket 不存在或不可访问：%s', v_bucket);
  end if;

  return app.mark_service_verified('storage', v_ok, v_message)
         || jsonb_build_object(
              'ok', v_ok,
              'message', v_message,
              'provider', v_provider,
              'bucket', v_bucket
            );
end;
$$;

comment on function app.test_storage_config() is
  '对象存储配置测试验证 RPC（admin）：校验 provider/endpoint/bucket 完整性 + storage.buckets 存在目标 bucket，'
  '经 app.mark_service_verified 回写；本期不做出站连通性实测（出站运行时选型未定），'
  '完整且 bucket 可用 → verified，否则 failed；返回 {ok, message, provider, bucket, verify_status, verified_at}';

-- ---------------------------------------------------------------------------
-- 4. app.get_storage_usage：bucket 用量统计（admin；storage.objects 聚合）
--    返回所有 bucket（含 0 用量行），文件数与 metadata.size 总字节；
--    metadata.size 非数字（异常/手工写入）按 0 计，避免 cast 报错。
-- ---------------------------------------------------------------------------
create function app.get_storage_usage()
returns table (
  bucket_id    text,
  object_count bigint,
  total_bytes  bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  return query
  select
    b.id,
    count(o.id)::bigint,
    coalesce(
      sum(
        case
          when (o.metadata ->> 'size') ~ '^[0-9]+$' then (o.metadata ->> 'size')::bigint
          else 0
        end
      ),
      0
    )::bigint
  from storage.buckets b
  left join storage.objects o on o.bucket_id = b.id
  group by b.id
  order by b.id;
end;
$$;

comment on function app.get_storage_usage() is
  'bucket 用量统计 RPC（admin）：storage.objects 按 bucket 聚合文件数与 metadata.size 总字节；'
  '空 bucket 返回 0；metadata.size 非数字按 0 计';

-- ---------------------------------------------------------------------------
-- 5. public 薄包装（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.test_storage_config()
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.test_storage_config()
$$;

comment on function public.test_storage_config() is
  'test_storage_config Data API 薄包装（admin 校验在 app 实现内）';

create function public.get_storage_usage()
returns table (
  bucket_id    text,
  object_count bigint,
  total_bytes  bigint
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.get_storage_usage()
$$;

comment on function public.get_storage_usage() is
  'get_storage_usage Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 6. 授权：管理 RPC 仅 authenticated（函数内 admin 校验）；anon/service_role 无路径
-- ---------------------------------------------------------------------------
revoke all on function app.test_storage_config() from public, anon, service_role;
revoke all on function public.test_storage_config() from public, anon, service_role;
revoke all on function app.get_storage_usage() from public, anon, service_role;
revoke all on function public.get_storage_usage() from public, anon, service_role;

grant execute on function app.test_storage_config() to authenticated;
grant execute on function public.test_storage_config() to authenticated;
grant execute on function app.get_storage_usage() to authenticated;
grant execute on function public.get_storage_usage() to authenticated;
