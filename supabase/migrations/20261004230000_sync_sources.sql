-- 第三方数据同步 · 数据源配置（工单 sync/001）
-- 契约：docs/modules/sync/sources.md（三类源 api/db/excel；凭据 pgcrypto 加密 + 界面掩码；
--       草稿可存 + 验证状态机；被启用中任务引用的数据源不可停用）、
--       docs/modules/INDEX.md 规则 4（凭据统一加密、分域持有）。
-- 组成：
--   1. public.sync_sources：数据源定义（config 非敏感 jsonb；credentials 密文 bytea）；
--   2. app.upsert_sync_source / public.upsert_sync_source：admin 新建/编辑；凭据 NULL/空串=保留；
--      已验证配置（config/credentials/type 任一变更）降级 unverified 并清空 last_verified_at；
--   3. app.test_sync_source / public.test_sync_source：按类型校验完整性 → verified/failed 回写 +
--      last_verified_at；excel 校验模板对象存在于 sync-templates bucket（有对象即过，免连通性测试）；
--      api/db 本期只做配置完整性校验（真实出网探测待 sync/005 执行器，出网白名单在部署层配置）；
--   4. app.disable_sync_source / public.disable_sync_source：停用；被 active 任务引用时拒绝
--      （sync_tasks 由 sync/003 迁移创建，函数体内晚绑定）；
--   5. app.get_sync_sources / public.get_sync_sources：admin 列表口（凭据仅 ''****'' + 明文尾 4 位，
--      不下发密文/明文）；
--   6. RLS：仅 admin SELECT；无表级写（写仅经 SECURITY DEFINER RPC）。
--
-- 依赖：app.current_role()、app.set_updated_at()（init_profiles）、app.audit_log()（audit/001）、
--       app.encrypt_secret / app.decrypt_secret（system/001）。
-- 下游：sync/002 页面、sync/003 任务引用该表。

-- ---------------------------------------------------------------------------
-- 1. sync_sources：数据源定义（config 非敏感 / credentials 密文）
-- ---------------------------------------------------------------------------
create table public.sync_sources (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  type             text not null
                   constraint sync_sources_type_check
                   check (type in ('api', 'db', 'excel')),
  config           jsonb not null default '{}'::jsonb,
  credentials      bytea,
  verify_status    text not null default 'unverified'
                   constraint sync_sources_verify_status_check
                   check (verify_status in ('unverified', 'verified', 'failed')),
  last_verified_at timestamptz,
  status           text not null default 'active'
                   constraint sync_sources_status_check
                   check (status in ('active', 'disabled')),
  created_by       uuid,
  updated_by       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint sync_sources_name_check check (btrim(name) <> ''),
  constraint sync_sources_config_object_check check (jsonb_typeof(config) = 'object')
);

comment on table public.sync_sources is
  '第三方数据源（admin 管理）：config 存非敏感连接信息，credentials 经 app.encrypt_secret 加密；'
  '草稿可存（unverified），启用任务前必须验证通过；被启用中任务引用时不可停用';
comment on column public.sync_sources.name is '数据源名称（展示用）';
comment on column public.sync_sources.type is '源类型：api（REST）/ db（外部库）/ excel（模板文件）';
comment on column public.sync_sources.config is
  '非敏感连接配置：api→base_url/auth_type/timeout_seconds；db→engine/host/port/database/username；'
  'excel→template_path（sync-templates bucket 内对象路径）';
comment on column public.sync_sources.credentials is
  '敏感凭据密文（app.encrypt_secret 写入；明文仅掩码计算在函数内解密，不下发）';
comment on column public.sync_sources.verify_status is
  '验证状态机：unverified 待验证 / verified 已验证 / failed 最近一次验证失败；已验证配置变更即降级';
comment on column public.sync_sources.last_verified_at is
  '最近一次验证尝试时间；配置变更降级 pending 时清空（旧验证对新配置失效）';
comment on column public.sync_sources.status is '状态机：active 启用 / disabled 停用（被 active 任务引用时不可停用）';
comment on column public.sync_sources.created_by is '创建人（弱关联 auth.users，不设外键以保留追溯）';

create trigger sync_sources_set_updated_at
before update on public.sync_sources
for each row
execute function app.set_updated_at();

alter table public.sync_sources enable row level security;

-- ---------------------------------------------------------------------------
-- 2. 内部 helper：停用前置校验（sync_tasks 由 sync/003 创建，晚绑定）
-- ---------------------------------------------------------------------------
create function app.ensure_sync_source_disableable(p_source_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_refs integer;
begin
  -- 单独部署 sync/001 时 sync_tasks 尚不存在：直接放行（部署顺序由迁移编号保证）
  if to_regclass('public.sync_tasks') is null then
    return;
  end if;

  select count(*) into v_refs
  from public.sync_tasks t
  where t.source_id = p_source_id
    and t.status = 'active';

  if v_refs > 0 then
    raise exception '数据源被 % 个启用中任务引用，无法停用', v_refs using errcode = '22023';
  end if;
end;
$$;

comment on function app.ensure_sync_source_disableable(uuid) is
  '数据源停用前置校验（admin RPC 内部调用）：存在 active 任务引用时 raise 22023；'
  '不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 3. app.upsert_sync_source：admin 新建/编辑（凭据 null/空串=保留）
-- ---------------------------------------------------------------------------
create function app.upsert_sync_source(
  p_id          uuid,
  p_name        text,
  p_type        text,
  p_config      jsonb,
  p_credentials text,
  p_status      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev           public.sync_sources;
  v_row            public.sync_sources;
  v_config         jsonb := coalesce(p_config, '{}'::jsonb);
  v_credentials    text  := nullif(p_credentials, '');
  v_config_changed boolean := false;
  v_cred_changed   boolean := false;
  v_type_changed   boolean := false;
  v_status         text;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_name is null or btrim(p_name) = '' then
    raise exception '数据源名称不能为空' using errcode = '22023';
  end if;

  if p_type is null or p_type not in ('api', 'db', 'excel') then
    raise exception '数据源类型不合法：%', coalesce(p_type, '(null)') using errcode = '22023';
  end if;

  if jsonb_typeof(v_config) <> 'object' then
    raise exception 'config 必须为 jsonb 对象' using errcode = '22023';
  end if;

  if p_status is not null and p_status not in ('active', 'disabled') then
    raise exception '数据源状态不合法：%', p_status using errcode = '22023';
  end if;

  select * into v_prev
  from public.sync_sources
  where id = p_id
  for update;

  if not found then
    insert into public.sync_sources
      (name, type, config, credentials, verify_status, last_verified_at,
       status, created_by, updated_by)
    values
      (btrim(p_name), p_type, v_config, app.encrypt_secret(v_credentials),
       'unverified', null, coalesce(p_status, 'active'),
       (select auth.uid()), (select auth.uid()))
    returning * into v_row;

    perform app.audit_log(
      'sync', 'upsert', 'sync_source', v_row.id::text,
      jsonb_build_object(
        'created', true,
        'type', v_row.type,
        'config_keys', (select jsonb_agg(k order by k) from jsonb_object_keys(v_config) as k),
        'credentials_set', v_row.credentials is not null,
        'status', v_row.status,
        'verify_status', v_row.verify_status
      )
    );
  else
    v_config_changed := v_config is distinct from v_prev.config;
    v_type_changed   := p_type is distinct from v_prev.type;
    v_cred_changed   := v_credentials is not null
                        and app.decrypt_secret(v_prev.credentials) is distinct from v_credentials;

    v_status := coalesce(p_status, v_prev.status);
    if v_status = 'disabled' and v_prev.status = 'active' then
      perform app.ensure_sync_source_disableable(v_prev.id);
    end if;

    -- 状态机：已验证配置被修改 → 降级待复验并清空 last_verified_at（状态沿用，不自动停用）
    update public.sync_sources
       set name        = btrim(p_name),
           type        = p_type,
           config      = v_config,
           credentials = case
                           when v_credentials is null then v_prev.credentials
                           else app.encrypt_secret(v_credentials)
                         end,
           verify_status = case
                             when v_prev.verify_status = 'verified'
                                  and (v_config_changed or v_cred_changed or v_type_changed)
                             then 'unverified'
                             else v_prev.verify_status
                           end,
           last_verified_at = case
                                when v_prev.verify_status = 'verified'
                                     and (v_config_changed or v_cred_changed or v_type_changed)
                                then null
                                else v_prev.last_verified_at
                              end,
           status      = v_status,
           updated_by  = (select auth.uid())
     where id = v_prev.id
    returning * into v_row;

    perform app.audit_log(
      'sync', 'upsert', 'sync_source', v_row.id::text,
      jsonb_build_object(
        'created', false,
        'config_changed', v_config_changed,
        'credentials_changed', v_cred_changed,
        'type_changed', v_type_changed,
        'status_before', v_prev.status,
        'status_after', v_row.status,
        'verify_status_before', v_prev.verify_status,
        'verify_status_after', v_row.verify_status
      )
    );
  end if;

  return jsonb_build_object(
    'id', v_row.id,
    'name', v_row.name,
    'type', v_row.type,
    'config', v_row.config,
    'credentials_set', v_row.credentials is not null,
    'verify_status', v_row.verify_status,
    'last_verified_at', v_row.last_verified_at,
    'status', v_row.status,
    'updated_at', v_row.updated_at
  );
end;
$$;

comment on function app.upsert_sync_source(uuid, text, text, jsonb, text, text) is
  '数据源新建/编辑 RPC（admin）：credentials NULL/空串=保留原值，非空经 app.encrypt_secret 加密；'
  'config/credentials/type 有变更且原为 verified 时降级 unverified 并清空 last_verified_at；'
  'p_status=disabled 且存在 active 任务引用时拒绝；审计不落凭据明文';

-- ---------------------------------------------------------------------------
-- 4. app.test_sync_source：类型化验证 + 状态回写
-- ---------------------------------------------------------------------------
create function app.test_sync_source(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row            public.sync_sources;
  v_ok             boolean := true;
  v_message        text;
  v_missing        text[] := array[]::text[];
  v_template_path  text;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.sync_sources
  where id = p_id
  for update;

  if not found then
    raise exception '数据源不存在：%', coalesce(p_id::text, '(null)') using errcode = 'P0002';
  end if;

  if v_row.type = 'api' then
    if coalesce(btrim(v_row.config ->> 'base_url'), '') = '' then
      v_missing := array['base_url'];
    end if;
    if array_length(v_missing, 1) is null then
      v_message := 'API 配置完整（base_url 已填写）；真实连通性探测待 sync/005 执行器上线后启用';
    else
      v_ok := false;
      v_message := '缺少必填配置：' || array_to_string(v_missing, ' / ');
    end if;
  elsif v_row.type = 'db' then
    if coalesce(btrim(v_row.config ->> 'host'), '') = '' then
      v_missing := array_append(v_missing, 'host');
    end if;
    if coalesce(btrim(v_row.config ->> 'port'), '') = '' then
      v_missing := array_append(v_missing, 'port');
    end if;
    if coalesce(btrim(v_row.config ->> 'database'), '') = '' then
      v_missing := array_append(v_missing, 'database');
    end if;
    if array_length(v_missing, 1) is null
       and (v_row.config ->> 'port') !~ '^[0-9]+$' then
      v_ok := false;
      v_message := '端口必须为数字：' || (v_row.config ->> 'port');
    elsif array_length(v_missing, 1) is null then
      v_message := '数据库配置完整（host / port / database 已填写）；真实连通性探测待 sync/005 执行器上线后启用';
    else
      v_ok := false;
      v_message := '缺少必填配置：' || array_to_string(v_missing, ' / ');
    end if;
  elsif v_row.type = 'excel' then
    v_template_path := btrim(coalesce(v_row.config ->> 'template_path', ''));
    if v_template_path = '' then
      v_ok := false;
      v_message := '缺少必填配置：template_path（请先上传 Excel 模板）';
    elsif not exists (
      select 1
      from storage.objects o
      where o.bucket_id = 'sync-templates'
        and o.name = v_template_path
    ) then
      v_ok := false;
      v_message := '模板文件不存在：' || v_template_path;
    else
      v_message := '模板文件已存在：' || v_template_path;
    end if;
  else
    v_ok := false;
    v_message := '未知数据源类型：' || v_row.type;
  end if;

  update public.sync_sources
     set verify_status    = case when v_ok then 'verified' else 'failed' end,
         last_verified_at = now(),
         updated_by       = (select auth.uid())
   where id = v_row.id
  returning * into v_row;

  perform app.audit_log(
    'sync', 'verify', 'sync_source', v_row.id::text,
    jsonb_build_object(
      'ok', v_ok,
      'type', v_row.type,
      'message', v_message,
      'verify_status', v_row.verify_status
    )
  );

  return jsonb_build_object(
    'id', v_row.id,
    'ok', v_ok,
    'message', v_message,
    'verify_status', v_row.verify_status,
    'last_verified_at', v_row.last_verified_at
  );
end;
$$;

comment on function app.test_sync_source(uuid) is
  '数据源测试验证 RPC（admin）：api 校验 base_url；db 校验 host/port/database；'
  'excel 校验 config.template_path 对象存在于 sync-templates bucket；'
  '结果回写 verify_status（verified/failed）与 last_verified_at；返回可读 message';

-- ---------------------------------------------------------------------------
-- 5. app.disable_sync_source：停用（被 active 任务引用时拒绝）
-- ---------------------------------------------------------------------------
create function app.disable_sync_source(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.sync_sources;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.sync_sources
  where id = p_id
  for update;

  if not found then
    raise exception '数据源不存在：%', coalesce(p_id::text, '(null)') using errcode = 'P0002';
  end if;

  if v_row.status = 'active' then
    perform app.ensure_sync_source_disableable(v_row.id);

    update public.sync_sources
       set status     = 'disabled',
           updated_by = (select auth.uid())
     where id = v_row.id
    returning * into v_row;

    perform app.audit_log(
      'sync', 'disable', 'sync_source', v_row.id::text,
      jsonb_build_object('status', v_row.status)
    );
  end if;

  return jsonb_build_object(
    'id', v_row.id,
    'name', v_row.name,
    'status', v_row.status,
    'updated_at', v_row.updated_at
  );
end;
$$;

comment on function app.disable_sync_source(uuid) is
  '数据源停用 RPC（admin）：存在 active 任务引用时 raise 22023 拒绝；幂等（已停用直接返回）';

-- ---------------------------------------------------------------------------
-- 6. app.get_sync_sources：admin 列表口（凭据仅掩码）
-- ---------------------------------------------------------------------------
create function app.get_sync_sources()
returns table (
  id                 uuid,
  name               text,
  type               text,
  config             jsonb,
  credentials_masked text,
  verify_status      text,
  last_verified_at   timestamptz,
  status             text,
  created_by         uuid,
  updated_by         uuid,
  created_at         timestamptz,
  updated_at         timestamptz
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
    s.id,
    s.name,
    s.type,
    s.config,
    case
      when s.credentials is null then null
      else '****' || right(app.decrypt_secret(s.credentials), 4)
    end as credentials_masked,
    s.verify_status,
    s.last_verified_at,
    s.status,
    s.created_by,
    s.updated_by,
    s.created_at,
    s.updated_at
  from public.sync_sources s
  order by s.created_at desc, s.id;
end;
$$;

comment on function app.get_sync_sources() is
  '数据源列表 RPC（admin）：凭据掩码在函数内计算（''****'' + 明文尾 4 位），不下发密文/明文；'
  'config 为非敏感字段原样返回';

-- ---------------------------------------------------------------------------
-- 7. public 薄包装（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.upsert_sync_source(
  p_id          uuid,
  p_name        text,
  p_type        text,
  p_config      jsonb,
  p_credentials text,
  p_status      text default null
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.upsert_sync_source(p_id, p_name, p_type, p_config, p_credentials, p_status)
$$;

create function public.test_sync_source(p_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.test_sync_source(p_id)
$$;

create function public.disable_sync_source(p_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.disable_sync_source(p_id)
$$;

create function public.get_sync_sources()
returns table (
  id                 uuid,
  name               text,
  type               text,
  config             jsonb,
  credentials_masked text,
  verify_status      text,
  last_verified_at   timestamptz,
  status             text,
  created_by         uuid,
  updated_by         uuid,
  created_at         timestamptz,
  updated_at         timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.get_sync_sources()
$$;

comment on function public.upsert_sync_source(uuid, text, text, jsonb, text, text) is
  'upsert_sync_source Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.test_sync_source(uuid) is
  'test_sync_source Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.disable_sync_source(uuid) is
  'disable_sync_source Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.get_sync_sources() is
  'get_sync_sources Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 8. 授权：表仅 admin SELECT（RLS 再收口）；无表级写；管理 RPC 仅 authenticated
-- ---------------------------------------------------------------------------
revoke all on public.sync_sources from public, anon, authenticated, service_role;
grant select on public.sync_sources to authenticated;

-- 内部 helper 不 GRANT API 角色
revoke all on function app.ensure_sync_source_disableable(uuid)
  from public, anon, authenticated, service_role;

revoke all on function app.upsert_sync_source(uuid, text, text, jsonb, text, text)
  from public, anon, authenticated, service_role;
revoke all on function app.test_sync_source(uuid) from public, anon, authenticated, service_role;
revoke all on function app.disable_sync_source(uuid) from public, anon, authenticated, service_role;
revoke all on function app.get_sync_sources() from public, anon, authenticated, service_role;

grant execute on function app.upsert_sync_source(uuid, text, text, jsonb, text, text)
  to authenticated;
grant execute on function app.test_sync_source(uuid) to authenticated;
grant execute on function app.disable_sync_source(uuid) to authenticated;
grant execute on function app.get_sync_sources() to authenticated;

revoke all on function public.upsert_sync_source(uuid, text, text, jsonb, text, text)
  from public, anon, authenticated, service_role;
revoke all on function public.test_sync_source(uuid) from public, anon, authenticated, service_role;
revoke all on function public.disable_sync_source(uuid) from public, anon, authenticated, service_role;
revoke all on function public.get_sync_sources() from public, anon, authenticated, service_role;

grant execute on function public.upsert_sync_source(uuid, text, text, jsonb, text, text)
  to authenticated;
grant execute on function public.test_sync_source(uuid) to authenticated;
grant execute on function public.disable_sync_source(uuid) to authenticated;
grant execute on function public.get_sync_sources() to authenticated;

-- ---------------------------------------------------------------------------
-- 9. RLS：仅 admin SELECT；无 INSERT/UPDATE/DELETE 策略（写仅经 RPC，无策略=拒绝）
-- ---------------------------------------------------------------------------
create policy sync_sources_select_admin
on public.sync_sources
for select
to authenticated
using ((select app.current_role()) = 'admin');
