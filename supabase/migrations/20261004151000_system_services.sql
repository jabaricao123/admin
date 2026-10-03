-- 系统管理 · 通用服务配置（工单 system/001）
-- 契约：docs/modules/system/services-mail.md（system_services 数据模型 + get_service_config 读取口）；
--       docs/modules/INDEX.md 规则 4（凭据 pgcrypto 加密 + 界面掩码）、规则 10（get_service_config
--       不得 GRANT authenticated，仅白名单后端通道）；敏感表授权模式参考 audit/001
--       （20261003205349_audit_operations.sql）。
--
-- 组成：
--   1. app.encryption_key：加密密钥表（key_id=1 单行；本地迁移 seed 随机密钥，生产走密钥轮换流程）；
--   2. public.system_services：通用服务配置表（service 主键；config 非敏感 jsonb；credentials 密文 bytea）；
--   3. app.encrypt_secret / app.decrypt_secret：跨模块共享加密 helper（sync/integration 复用；
--      SECURITY DEFINER + search_path=''，不 GRANT API 角色，供各模块 SECURITY DEFINER wrapper 调用）；
--   4. app.get_service_config：白名单后端读取口（不 GRANT anon/authenticated，见规则 10）；
--   5. 管理 RPC（admin 专用，GRANT authenticated + 函数内 app.current_role() 校验）：
--      upsert_service_config（加密落库 + 已验证配置修改后降级待复验）、mark_service_verified；
--   6. app.get_service_status：脱敏展示 RPC（admin 可读；凭据仅 '****' + 尾 4 位，不解出明文）；
--   7. RLS：system_services 与 app.encryption_key 均为敏感表——全 revoke（含 SELECT），
--      无任何角色表级访问，所有读写经 SECURITY DEFINER RPC；无策略即为拒绝。
--
-- 依赖：app.current_role()（init_profiles / access 阶段 2）、app.audit_log()（audit/001）、
--       extensions.pgcrypto（Supabase 预装于 extensions schema）。

-- ---------------------------------------------------------------------------
-- 0. pgcrypto
-- ---------------------------------------------------------------------------
-- Supabase 本地/云均预装于 extensions schema；显式声明保证裸 Postgres 环境可迁移。
create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- 1. app.encryption_key：凭据加密密钥（专用表，不暴露 API）
-- ---------------------------------------------------------------------------
create table app.encryption_key (
  key_id     integer primary key,
  key        text not null,
  created_at timestamptz not null default now(),
  rotated_at timestamptz
);

comment on table app.encryption_key is
  '凭据加密密钥（key_id=1 为当前密钥）；仅 app.encrypt_secret/app.decrypt_secret 读取。'
  '本地迁移 seed 随机密钥（gen_random_uuid）仅供开发；生产密钥经密钥轮换流程注入并重加密存量 '
  'credentials（轮换工单另行落地，禁止把生产密钥写进迁移文件）';
comment on column app.encryption_key.key_id is '密钥编号；当前固定 1（轮换后保留旧行以解密存量数据）';
comment on column app.encryption_key.rotated_at is '该密钥被轮换时间；NULL=当前使用中';

-- 本地开发密钥：随机、不落版本库（迁移文件本身不含密钥值）；生产用轮换流程写入。
insert into app.encryption_key (key_id, key)
values (1, gen_random_uuid()::text)
on conflict (key_id) do nothing;

alter table app.encryption_key enable row level security;

-- ---------------------------------------------------------------------------
-- 2. public.system_services：通用服务配置表（service 域分区）
-- ---------------------------------------------------------------------------
create table public.system_services (
  service       text primary key,
  config        jsonb not null default '{}'::jsonb,
  credentials   bytea,
  verified_at   timestamptz,
  verify_status text not null default 'unverified'
                constraint system_services_verify_status_check
                check (verify_status in ('unverified', 'verified', 'failed')),
  updated_by    uuid,
  updated_at    timestamptz not null default now(),
  constraint system_services_service_check
    check (service in ('mail', 'storage', 'sms', 'push', 'auth'))
);

comment on table public.system_services is
  '基础设施服务配置（mail/storage/sms/push/auth）；凭据 pgcrypto 加密存储；'
  '无任何角色表级访问，管理经 upsert_service_config、展示经 get_service_status、'
  '白名单消费经 app.get_service_config';
comment on column public.system_services.service is '服务域：mail/storage/sms/push/auth（PK）';
comment on column public.system_services.config is '非敏感配置（host/port/bucket/provider 等），jsonb 对象';
comment on column public.system_services.credentials is
  '敏感凭据密文（app.encrypt_secret 写入；明文仅 app.get_service_config 与掩码计算在函数内解密）';
comment on column public.system_services.verify_status is
  '验证状态机：unverified 待复验 / verified 已验证 / failed 最近一次验证失败';
comment on column public.system_services.verified_at is
  '最近一次验证尝试时间；已验证配置被修改而降级时置 NULL（旧验证对新配置失效）';
comment on column public.system_services.updated_by is '最近修改人（弱关联 auth.users，不设外键以保留追溯）';

create trigger system_services_set_updated_at
before update on public.system_services
for each row
execute function app.set_updated_at();

alter table public.system_services enable row level security;

-- ---------------------------------------------------------------------------
-- 3. 共享加密 helper（规则 4：凭据统一规范、分域持有）
-- ---------------------------------------------------------------------------
create function app.encrypt_secret(p_plain text)
returns bytea
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text;
begin
  if p_plain is null then
    return null;
  end if;

  select k.key into v_key
  from app.encryption_key k
  where k.key_id = 1;

  if v_key is null then
    raise exception '加密密钥未初始化（app.encryption_key.key_id=1 缺失）' using errcode = 'P0001';
  end if;

  -- 随机盐：同一明文两次加密产生不同密文
  return extensions.pgp_sym_encrypt(p_plain, v_key);
end;
$$;

comment on function app.encrypt_secret(text) is
  '凭据加密共享 helper（INDEX 规则 4）；密钥取 app.encryption_key.key_id=1；'
  'SECURITY DEFINER + search_path 固定；不 GRANT anon/authenticated（规则 10），供各模块 wrapper 调用';

create function app.decrypt_secret(p_cipher bytea)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_key text;
begin
  if p_cipher is null then
    return null;
  end if;

  select k.key into v_key
  from app.encryption_key k
  where k.key_id = 1;

  if v_key is null then
    raise exception '加密密钥未初始化（app.encryption_key.key_id=1 缺失）' using errcode = 'P0001';
  end if;

  return extensions.pgp_sym_decrypt(p_cipher, v_key);
end;
$$;

comment on function app.decrypt_secret(bytea) is
  '凭据解密共享 helper；密钥不匹配/数据损坏时 pgcrypto 报错；不 GRANT anon/authenticated';

-- ---------------------------------------------------------------------------
-- 4. app.get_service_config：白名单后端读取口（规则 10，不 GRANT authenticated）
--    返回：config 字段 + credentials（明文，未配置时为 null）。
--    消费方（如 message 发送器）只能经各自模块的 SECURITY DEFINER wrapper 调用；
--    函数无法识别调用模块，禁止以模块标记做安全依据。
-- ---------------------------------------------------------------------------
create function app.get_service_config(p_service text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select s.config || jsonb_build_object('credentials', app.decrypt_secret(s.credentials))
  from public.system_services s
  where s.service = p_service
$$;

comment on function app.get_service_config(text) is
  '服务配置白名单读取口（INDEX 规则 10）：config 字段合并 credentials 明文；'
  'service 不存在返回 NULL；不 GRANT anon/authenticated，仅后端 wrapper/专用角色可调';

-- ---------------------------------------------------------------------------
-- 5. 管理 RPC（admin 专用；公开面为 public 同名薄包装）
-- ---------------------------------------------------------------------------
create function app.upsert_service_config(
  p_service     text,
  p_config      jsonb,
  p_credentials text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev           public.system_services;
  v_row            public.system_services;
  v_config         jsonb := coalesce(p_config, '{}'::jsonb);
  v_config_changed boolean := false;
  v_cred_changed   boolean := false;
  v_status         text;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_service is null or p_service not in ('mail', 'storage', 'sms', 'push', 'auth') then
    raise exception '未知服务：%', coalesce(p_service, '(null)') using errcode = '22023';
  end if;

  if jsonb_typeof(v_config) <> 'object' then
    raise exception 'config 必须为 jsonb 对象' using errcode = '22023';
  end if;

  select * into v_prev
  from public.system_services
  where service = p_service
  for update;

  if not found then
    -- 草稿可存：新建一律 unverified，待「测试连接」确认
    insert into public.system_services
      (service, config, credentials, verify_status, verified_at, updated_by)
    values
      (p_service, v_config, app.encrypt_secret(p_credentials), 'unverified', null,
       (select auth.uid()))
    returning * into v_row;

    perform app.audit_log(
      'system', 'upsert', 'service_config', p_service,
      jsonb_build_object(
        'created', true,
        'config_keys', (select jsonb_agg(k order by k) from jsonb_object_keys(v_config) as k),
        'credentials_set', p_credentials is not null,
        'verify_status', v_row.verify_status
      )
    );
  else
    v_config_changed := v_config is distinct from v_prev.config;
    v_cred_changed   := app.decrypt_secret(v_prev.credentials) is distinct from p_credentials;

    v_status := v_prev.verify_status;
    -- 状态机（services-mail.md 功能需求 3）：已验证配置被修改 → 降级待复验，
    -- 旧 verified_at 同时清空（对当前配置不再成立）；failed 保持 failed（本就无效）。
    if v_prev.verify_status = 'verified' and (v_config_changed or v_cred_changed) then
      v_status := 'unverified';
    end if;

    update public.system_services
       set config        = v_config,
           credentials   = app.encrypt_secret(p_credentials),
           verify_status = v_status,
           verified_at   = case
                             when v_status = 'unverified' and v_prev.verify_status = 'verified'
                             then null
                             else verified_at
                           end,
           updated_by    = (select auth.uid())
     where service = p_service
    returning * into v_row;

    perform app.audit_log(
      'system', 'upsert', 'service_config', p_service,
      jsonb_build_object(
        'created', false,
        'config_changed', v_config_changed,
        'credentials_changed', v_cred_changed,
        'verify_status_before', v_prev.verify_status,
        'verify_status_after', v_row.verify_status
      )
    );
  end if;

  return jsonb_build_object(
    'service', v_row.service,
    'config', v_row.config,
    'credentials_set', v_row.credentials is not null,
    'verify_status', v_row.verify_status,
    'verified_at', v_row.verified_at,
    'updated_at', v_row.updated_at
  );
end;
$$;

comment on function app.upsert_service_config(text, jsonb, text) is
  '服务配置新建/编辑 RPC（admin）：credentials 经 app.encrypt_secret 加密；'
  '已验证配置内容有变更时 verify_status 降级 unverified 并清空 verified_at（草稿状态机）；'
  '审计仅记变更标记与 config 键名，不落凭据明文';

create function app.mark_service_verified(
  p_service text,
  p_ok      boolean,
  p_note    text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.system_services;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_ok is null then
    raise exception 'p_ok 不能为空' using errcode = '22023';
  end if;

  update public.system_services
     set verify_status = case when p_ok then 'verified' else 'failed' end,
         verified_at   = now(),
         updated_by    = (select auth.uid())
   where service = p_service
  returning * into v_row;

  if not found then
    raise exception '服务配置不存在：%', coalesce(p_service, '(null)') using errcode = 'P0002';
  end if;

  perform app.audit_log(
    'system', 'verify', 'service_config', p_service,
    jsonb_build_object('ok', p_ok, 'note', p_note, 'verify_status', v_row.verify_status)
  );

  return jsonb_build_object(
    'service', v_row.service,
    'verify_status', v_row.verify_status,
    'verified_at', v_row.verified_at,
    'note', p_note
  );
end;
$$;

comment on function app.mark_service_verified(text, boolean, text) is
  '测试连接结果回写 RPC（admin）：p_ok=true → verified，false → failed；'
  'verified_at 记录最近一次验证尝试时间；p_note 进审计摘要（表不存备注列）';

-- ---------------------------------------------------------------------------
-- 6. app.get_service_status：脱敏展示（admin；凭据仅尾 4 位）
-- ---------------------------------------------------------------------------
create function app.get_service_status()
returns table (
  service            text,
  config             jsonb,
  credentials_masked text,
  verify_status      text,
  verified_at        timestamptz,
  updated_by         uuid,
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
    s.service,
    s.config,
    case
      when s.credentials is null then null
      else '****' || right(app.decrypt_secret(s.credentials), 4)
    end as credentials_masked,
    s.verify_status,
    s.verified_at,
    s.updated_by,
    s.updated_at
  from public.system_services s
  order by s.service;
end;
$$;

comment on function app.get_service_status() is
  '服务配置脱敏展示 RPC（admin）：凭据掩码在函数内计算（''****'' + 明文尾 4 位），'
  '不下发明文/密文；所有 service 行按 service 升序返回';

-- ---------------------------------------------------------------------------
-- 7. public 薄包装（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.upsert_service_config(
  p_service     text,
  p_config      jsonb,
  p_credentials text
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.upsert_service_config(p_service, p_config, p_credentials)
$$;

create function public.mark_service_verified(
  p_service text,
  p_ok      boolean,
  p_note    text
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.mark_service_verified(p_service, p_ok, p_note)
$$;

create function public.get_service_status()
returns table (
  service            text,
  config             jsonb,
  credentials_masked text,
  verify_status      text,
  verified_at        timestamptz,
  updated_by         uuid,
  updated_at         timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.get_service_status()
$$;

comment on function public.upsert_service_config(text, jsonb, text) is
  'upsert_service_config Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.mark_service_verified(text, boolean, text) is
  'mark_service_verified Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.get_service_status() is
  'get_service_status Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 8. 授权：敏感表全 revoke；内部 helper 不 GRANT；管理/展示 RPC 仅 authenticated
-- ---------------------------------------------------------------------------
-- 表级：连 SELECT 也不给（展示全经 get_service_status）；RLS 已启用，无策略 = 拒绝。
revoke all on public.system_services from public, anon, authenticated, service_role;
revoke all on app.encryption_key from public, anon, authenticated, service_role;

-- 内部 helper / 白名单读取口：仅函数属主（postgres）与 SECURITY DEFINER wrapper 可调（规则 10）。
revoke all on function app.encrypt_secret(text) from public, anon, authenticated, service_role;
revoke all on function app.decrypt_secret(bytea) from public, anon, authenticated, service_role;
revoke all on function app.get_service_config(text) from public, anon, authenticated, service_role;

-- 管理与展示 RPC：登录用户可执行，函数内再做 admin 校验。
revoke all on function app.upsert_service_config(text, jsonb, text) from public, anon;
revoke all on function app.mark_service_verified(text, boolean, text) from public, anon;
revoke all on function app.get_service_status() from public, anon;

grant execute on function app.upsert_service_config(text, jsonb, text) to authenticated;
grant execute on function app.mark_service_verified(text, boolean, text) to authenticated;
grant execute on function app.get_service_status() to authenticated;

revoke all on function public.upsert_service_config(text, jsonb, text) from public, anon;
revoke all on function public.mark_service_verified(text, boolean, text) from public, anon;
revoke all on function public.get_service_status() from public, anon;

grant execute on function public.upsert_service_config(text, jsonb, text) to authenticated;
grant execute on function public.mark_service_verified(text, boolean, text) to authenticated;
grant execute on function public.get_service_status() to authenticated;
