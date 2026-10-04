-- 系统管理 · IM 登录数据底座（工单 im/001）
-- 契约：docs/adr/003-im-login.md（§1 全局单选启用、§2 预绑定三元组、§4 凭据 pgcrypto 加密）、
--       GLOSSARY.md「IM 登录 / IM userid / IM 账号绑定 / 当前 IM 厂商」、
--       docs/modules/INDEX.md 规则 4（凭据统一加密 + 掩码）、规则 10（内部入口不 GRANT）。
--
-- 组成：
--   1. profiles 三列（wecom/feishu/dingtalk_userid）：nullable + UNIQUE + 格式 CHECK，
--      多槽位保存历史绑定，切换厂商不清空；
--   2. public.im_auth_configs：三家厂商配置各至多一行；partial unique index 保证
--      任一时刻至多一行 enabled=true；credentials 经 app.encrypt_secret 加密存 bytea；
--   3. 5 个 SECURITY DEFINER RPC（search_path='' + 全限定名）：
--      im_bind_self（自助绑定）/ im_unbind（admin）/ im_admin_set_userid（admin）/
--      im_upsert_config（admin）/ im_get_enabled_provider（所有人，含 anon）；
--   4. RLS：im_auth_configs 表级无直接写；admin 仅 SELECT 非凭据列；写一律走 RPC。
--
-- 依赖：app.current_role()（init_profiles）、app.audit_log()（audit/001）、
--       app.encrypt_secret / app.decrypt_secret（system/001）。

-- ---------------------------------------------------------------------------
-- 1. profiles 三列：IM userid 预绑定（多槽位，切换厂商不清空）
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists wecom_userid text,
  add column if not exists feishu_userid text,
  add column if not exists dingtalk_userid text;

alter table public.profiles
  add constraint profiles_wecom_userid_unique unique (wecom_userid),
  add constraint profiles_feishu_userid_unique unique (feishu_userid),
  add constraint profiles_dingtalk_userid_unique unique (dingtalk_userid),
  add constraint profiles_wecom_userid_format
    check (wecom_userid ~ '^[A-Za-z0-9_-]+$'),
  add constraint profiles_feishu_userid_format
    check (feishu_userid ~ '^[A-Za-z0-9_-]+$'),
  add constraint profiles_dingtalk_userid_format
    check (dingtalk_userid ~ '^[A-Za-z0-9_-]+$');

comment on column public.profiles.wecom_userid is
  '企业微信 userid（IM 预绑定，ADR-003 §2）：全局唯一，NULL=未绑定；写入仅经 im_bind_self / im_admin_set_userid / im_unbind';
comment on column public.profiles.feishu_userid is
  '飞书 userid（IM 预绑定）：全局唯一，NULL=未绑定；写入仅经 im_bind_self / im_admin_set_userid / im_unbind';
comment on column public.profiles.dingtalk_userid is
  '钉钉 userid（IM 预绑定）：全局唯一，NULL=未绑定；写入仅经 im_bind_self / im_admin_set_userid / im_unbind';

-- ---------------------------------------------------------------------------
-- 2. public.im_auth_configs：IM 登录厂商配置（三家至多一家启用）
-- ---------------------------------------------------------------------------
create table public.im_auth_configs (
  provider    text primary key
              constraint im_auth_configs_provider_check
              check (provider in ('wecom', 'feishu', 'dingtalk')),
  enabled     boolean not null default false,
  credentials bytea,
  updated_by  uuid references auth.users (id) on delete set null,
  updated_at  timestamptz not null default now()
);

comment on table public.im_auth_configs is
  'IM 登录厂商配置（wecom/feishu/dingtalk）：任一时刻至多一行 enabled=true；'
  'credentials 经 app.encrypt_secret 加密存储；表级无直接写，写仅经 RPC；'
  'admin 仅可 SELECT 非凭据列（provider/enabled/updated_by/updated_at）';
comment on column public.im_auth_configs.provider is '厂商（PK）：wecom/feishu/dingtalk（ADR-003 §1 全局单选）';
comment on column public.im_auth_configs.enabled is '是否当前启用厂商；全局至多一行为 true（partial unique index 保证）';
comment on column public.im_auth_configs.credentials is
  '厂商凭据密文（appid/secret/agentid 等 jsonb 的 app.encrypt_secret 密文）；明文仅 RPC 函数内解密';
comment on column public.im_auth_configs.updated_by is '最近修改人（弱追溯；auth 用户删除时置 NULL，不阻断删除）';
comment on column public.im_auth_configs.updated_at is '最近修改时间（触发器维护）';

-- 任一时刻至多一行 enabled=true：partial unique index（enabled=true 的行键相同）
create unique index im_auth_configs_one_enabled_idx
  on public.im_auth_configs (enabled)
  where enabled;

create trigger im_auth_configs_set_updated_at
before update on public.im_auth_configs
for each row
execute function app.set_updated_at();

alter table public.im_auth_configs enable row level security;

-- admin 可读（列级授权见 §6，credentials 不在授权列内）；无写策略 = 写入仅经 RPC
create policy im_auth_configs_select_admin
on public.im_auth_configs
for select
to authenticated
using (app.current_role() = 'admin');

-- ---------------------------------------------------------------------------
-- 3. im_bind_self：当前登录用户扫码回调后绑定本人（ADR-003 §2 自助通道）
--    信任边界：userid 由服务端回调路由（持用户 session）从厂商 API 取得后传入；
--    函数只写 auth.uid() 本人行，UNIQUE 冲突（他人已绑定同一 userid）直接拒绝。
-- ---------------------------------------------------------------------------
create function public.im_bind_self(
  p_provider text,
  p_userid   text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_provider text := lower(btrim(p_provider));
  v_userid   text := nullif(btrim(p_userid), '');
  v_before   text;
begin
  -- 仅在职（active）用户可自助绑定；anon / 停用账号拒绝
  if (select app.current_role()) is null then
    raise exception '当前账号不可用' using errcode = '42501';
  end if;

  if v_provider is null or v_provider not in ('wecom', 'feishu', 'dingtalk') then
    raise exception '未知 IM 厂商：%', coalesce(p_provider, '(null)') using errcode = '22023';
  end if;

  if v_userid is null or v_userid !~ '^[A-Za-z0-9_-]+$' then
    raise exception 'IM userid 格式不正确：%', coalesce(p_userid, '(null)') using errcode = '22023';
  end if;

  -- 冲突预检（约束仍兜底并发）：同一 userid 已绑定他人时给出稳定 23505
  if exists (
    select 1
    from public.profiles p
    where case v_provider
            when 'wecom' then p.wecom_userid
            when 'feishu' then p.feishu_userid
            else p.dingtalk_userid
          end = v_userid
      and p.id <> v_uid
  ) then
    raise exception 'IM userid 已被其他账号绑定：%', v_userid using errcode = '23505';
  end if;

  select case v_provider
           when 'wecom' then p.wecom_userid
           when 'feishu' then p.feishu_userid
           else p.dingtalk_userid
         end
    into v_before
    from public.profiles p
   where p.id = v_uid
     for update;

  if not found then
    raise exception '用户档案不存在：%', v_uid using errcode = 'P0002';
  end if;

  update public.profiles p
     set wecom_userid    = case when v_provider = 'wecom'    then v_userid else p.wecom_userid end,
         feishu_userid   = case when v_provider = 'feishu'   then v_userid else p.feishu_userid end,
         dingtalk_userid = case when v_provider = 'dingtalk' then v_userid else p.dingtalk_userid end,
         updated_by      = v_uid
   where p.id = v_uid;

  perform app.audit_log(
    'system', 'bind', 'im_binding', v_uid::text,
    jsonb_build_object(
      'provider', v_provider,
      'userid', v_userid,
      'userid_before', v_before
    )
  );

  return jsonb_build_object('provider', v_provider, 'userid', v_userid);
end;
$$;

comment on function public.im_bind_self(text, text) is
  '自助绑定 RPC：当前登录用户（system/authenticated）扫码回调后绑定本人 profiles.<provider>_userid；'
  '只写 auth.uid() 本人行，payload 由服务端回调路由传入；格式校验 + UNIQUE 冲突 23505；写 audit';

-- ---------------------------------------------------------------------------
-- 4. im_unbind / im_admin_set_userid：admin 管理绑定
-- ---------------------------------------------------------------------------
create function public.im_unbind(
  p_user_id uuid,
  p_provider text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_provider text := lower(btrim(p_provider));
  v_before   text;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_user_id is null then
    raise exception '用户 ID 不能为空' using errcode = '22023';
  end if;

  if v_provider is null or v_provider not in ('wecom', 'feishu', 'dingtalk') then
    raise exception '未知 IM 厂商：%', coalesce(p_provider, '(null)') using errcode = '22023';
  end if;

  select case v_provider
           when 'wecom' then p.wecom_userid
           when 'feishu' then p.feishu_userid
           else p.dingtalk_userid
         end
    into v_before
    from public.profiles p
   where p.id = p_user_id
     for update;

  if not found then
    raise exception '用户不存在：%', p_user_id using errcode = 'P0002';
  end if;

  update public.profiles p
     set wecom_userid    = case when v_provider = 'wecom'    then null else p.wecom_userid end,
         feishu_userid   = case when v_provider = 'feishu'   then null else p.feishu_userid end,
         dingtalk_userid = case when v_provider = 'dingtalk' then null else p.dingtalk_userid end,
         updated_by      = (select auth.uid())
   where p.id = p_user_id;

  perform app.audit_log(
    'system', 'unbind', 'im_binding', p_user_id::text,
    jsonb_build_object(
      'provider', v_provider,
      'userid_before', v_before
    )
  );

  return jsonb_build_object(
    'user_id', p_user_id,
    'provider', v_provider,
    'userid_before', v_before
  );
end;
$$;

comment on function public.im_unbind(uuid, text) is
  '解绑 RPC（仅 admin，ADR-003 §2 用户不可自助解绑）：置空 profiles.<provider>_userid 并写 audit；'
  '幂等：未绑定时也成功返回（userid_before=null）；用户不存在报 P0002';

create function public.im_admin_set_userid(
  p_user_id uuid,
  p_provider text,
  p_userid   text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_provider text := lower(btrim(p_provider));
  v_userid   text := nullif(btrim(p_userid), '');
  v_before   text;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_user_id is null then
    raise exception '用户 ID 不能为空' using errcode = '22023';
  end if;

  if v_provider is null or v_provider not in ('wecom', 'feishu', 'dingtalk') then
    raise exception '未知 IM 厂商：%', coalesce(p_provider, '(null)') using errcode = '22023';
  end if;

  if v_userid is null or v_userid !~ '^[A-Za-z0-9_-]+$' then
    raise exception 'IM userid 格式不正确：%', coalesce(p_userid, '(null)') using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.profiles p
    where case v_provider
            when 'wecom' then p.wecom_userid
            when 'feishu' then p.feishu_userid
            else p.dingtalk_userid
          end = v_userid
      and p.id <> p_user_id
  ) then
    raise exception 'IM userid 已被其他账号绑定：%', v_userid using errcode = '23505';
  end if;

  select case v_provider
           when 'wecom' then p.wecom_userid
           when 'feishu' then p.feishu_userid
           else p.dingtalk_userid
         end
    into v_before
    from public.profiles p
   where p.id = p_user_id
     for update;

  if not found then
    raise exception '用户不存在：%', p_user_id using errcode = 'P0002';
  end if;

  update public.profiles p
     set wecom_userid    = case when v_provider = 'wecom'    then v_userid else p.wecom_userid end,
         feishu_userid   = case when v_provider = 'feishu'   then v_userid else p.feishu_userid end,
         dingtalk_userid = case when v_provider = 'dingtalk' then v_userid else p.dingtalk_userid end,
         updated_by      = (select auth.uid())
   where p.id = p_user_id;

  perform app.audit_log(
    'system', 'set_userid', 'im_binding', p_user_id::text,
    jsonb_build_object(
      'provider', v_provider,
      'userid', v_userid,
      'userid_before', v_before
    )
  );

  return jsonb_build_object(
    'user_id', p_user_id,
    'provider', v_provider,
    'userid', v_userid
  );
end;
$$;

comment on function public.im_admin_set_userid(uuid, text, text) is
  'admin 手工录入绑定 RPC：写入指定用户的 profiles.<provider>_userid；'
  '清空请走 im_unbind；格式校验 + UNIQUE 冲突 23505；写 audit（含前值）';

-- ---------------------------------------------------------------------------
-- 5. im_upsert_config（admin）/ im_get_enabled_provider（全员）
-- ---------------------------------------------------------------------------
create function public.im_upsert_config(
  p_provider    text,
  p_credentials jsonb,
  p_enabled     boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_provider      text := lower(btrim(p_provider));
  v_prev          public.im_auth_configs;
  v_row           public.im_auth_configs;
  v_cipher        bytea;
  v_enabled       boolean;
  v_creds_changed boolean := false;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if v_provider is null or v_provider not in ('wecom', 'feishu', 'dingtalk') then
    raise exception '未知 IM 厂商：%', coalesce(p_provider, '(null)') using errcode = '22023';
  end if;

  if p_credentials is not null and jsonb_typeof(p_credentials) <> 'object' then
    raise exception 'credentials 必须为 jsonb 对象' using errcode = '22023';
  end if;

  -- 配置切换串行化（至多 3 行）：advisory lock 防并发启停交错与死锁
  perform pg_advisory_xact_lock(hashtextextended('public.im_auth_configs', 0));

  select * into v_prev
  from public.im_auth_configs c
  where c.provider = v_provider
  for update;

  -- p_credentials IS NULL = 保留原凭据；非空对象 = 整体替换（加密存储）
  v_cipher := case
                when p_credentials is null then v_prev.credentials
                else app.encrypt_secret(p_credentials::text)
              end;

  -- p_enabled IS NULL = 保持现状（新行默认 false）
  v_enabled := coalesce(p_enabled, v_prev.enabled, false);

  if v_prev.provider is not null and p_credentials is not null then
    v_creds_changed := app.decrypt_secret(v_prev.credentials) is distinct from p_credentials::text;
  elsif v_prev.provider is null and p_credentials is not null then
    v_creds_changed := true;
  end if;

  -- 启用当前厂商 = 原子停用其他家（ADR-003 §1 全局单选；partial unique index 兜底）
  if v_enabled then
    update public.im_auth_configs c
       set enabled    = false,
           updated_by = (select auth.uid())
     where c.enabled
       and c.provider <> v_provider;
  end if;

  insert into public.im_auth_configs (provider, enabled, credentials, updated_by)
  values (v_provider, v_enabled, v_cipher, (select auth.uid()))
  on conflict (provider) do update
     set enabled     = excluded.enabled,
         credentials = excluded.credentials,
         updated_by  = excluded.updated_by
  returning * into v_row;

  perform app.audit_log(
    'system', 'upsert', 'im_auth_config', v_provider,
    jsonb_build_object(
      'created', v_prev.provider is null,
      'enabled_before', v_prev.enabled,
      'enabled_after', v_row.enabled,
      'credentials_set', v_row.credentials is not null,
      'credentials_changed', v_creds_changed
    )
  );

  return jsonb_build_object(
    'provider', v_row.provider,
    'enabled', v_row.enabled,
    'credentials_set', v_row.credentials is not null,
    'updated_at', v_row.updated_at
  );
end;
$$;

comment on function public.im_upsert_config(text, jsonb, boolean) is
  '厂商配置保存 RPC（admin）：credentials 为 jsonb 对象经 app.encrypt_secret 加密；'
  'p_credentials IS NULL = 保留原凭据；p_enabled=true 时原子停用其他两家（全局单选）；'
  '审计仅记变更标记，不落凭据明文';

create function public.im_get_enabled_provider()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select c.provider
  from public.im_auth_configs c
  where c.enabled
  limit 1
$$;

comment on function public.im_get_enabled_provider() is
  '当前启用 IM 厂商（登录页判断用，ADR-003 §1）；无启用返回 NULL；'
  '只读 provider 文本，不触 credentials；GRANT anon + authenticated';

-- ---------------------------------------------------------------------------
-- 6. 授权
-- ---------------------------------------------------------------------------
-- 表：无直接写；admin 列级 SELECT 非凭据列（credentials 不授权）；anon/service_role 无路径。
-- RLS 策略（§2）再按 admin 行过滤；无策略 = 拒绝。
revoke all on public.im_auth_configs from public, anon, authenticated, service_role;
grant select (provider, enabled, updated_by, updated_at)
  on public.im_auth_configs to authenticated;

-- RPC：敏感管理/自助入口仅 authenticated（函数内 admin 校验）；
-- im_get_enabled_provider 为登录页公开读取（anon + authenticated）。
revoke all on function public.im_bind_self(text, text) from public, anon, service_role;
revoke all on function public.im_unbind(uuid, text) from public, anon, service_role;
revoke all on function public.im_admin_set_userid(uuid, text, text) from public, anon, service_role;
revoke all on function public.im_upsert_config(text, jsonb, boolean) from public, anon, service_role;
revoke all on function public.im_get_enabled_provider() from public, service_role;

grant execute on function public.im_bind_self(text, text) to authenticated;
grant execute on function public.im_unbind(uuid, text) to authenticated;
grant execute on function public.im_admin_set_userid(uuid, text, text) to authenticated;
grant execute on function public.im_upsert_config(text, jsonb, boolean) to authenticated;
grant execute on function public.im_get_enabled_provider() to anon, authenticated;
