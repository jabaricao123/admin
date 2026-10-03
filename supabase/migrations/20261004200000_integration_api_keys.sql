-- 接口/集成中心 · API 密钥（工单 integration/001）
-- 契约：docs/modules/integration/api-keys.md（key_prefix + key_hash sha256、scopes、一次性展示）、
--       docs/modules/INDEX.md 规则 2（审计统一入口）、规则 10（verify_api_key 不 GRANT authenticated）。
-- 组成：
--   1. public.api_keys：命名/前缀/哈希/范围/状态/有效期；明文 key 零落库（仅 sha256 hex 哈希）；
--   2. app.create_api_key：admin 签发（一次性返回完整 key）；app.revoke_api_key：admin 吊销；
--   3. app.verify_api_key：后端通道校验口（哈希 + status + 有效期；通过更新 last_used_at），
--      不 GRANT authenticated（规则 10），供 002 中间件 wrapper 调用；
--   4. RLS：仅 admin SELECT；无表级写（写仅经 SECURITY DEFINER RPC）。
--
-- 依赖：app.current_role() 与 app.set_updated_at()（init_profiles）、app.audit_log()（audit/001）、
--       extensions.pgcrypto（digest sha256；system/001 已建扩展）。

-- ---------------------------------------------------------------------------
-- 1. api_keys：对外 API 凭据（明文零落库）
-- ---------------------------------------------------------------------------
create table public.api_keys (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  key_prefix   text not null,
  key_hash     text not null unique,
  scopes       jsonb not null default '[]'::jsonb,
  status       text not null default 'active'
               constraint api_keys_status_check
               check (status in ('active', 'revoked')),
  expires_at   timestamptz,
  last_used_at timestamptz,
  created_by   uuid,
  updated_by   uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint api_keys_name_check check (btrim(name) <> ''),
  constraint api_keys_key_prefix_check check (key_prefix ~ '^ak_[0-9a-f]{8}$'),
  constraint api_keys_scopes_array_check check (jsonb_typeof(scopes) = 'array')
);

comment on table public.api_keys is
  '对外 API 凭据（admin 管理）；完整 key 明文仅在签发响应中出现一次，落库仅 sha256 hex 哈希';
comment on column public.api_keys.name is '密钥用途名称（展示用）';
comment on column public.api_keys.key_prefix is '密钥前缀（展示掩码用，''ak_'' + 8 位十六进制）';
comment on column public.api_keys.key_hash is '完整 key 的 sha256 hex（唯一索引供校验查找；明文零落库）';
comment on column public.api_keys.scopes is
  '范围白名单（jsonb 字符串数组，如 ["org:read","report:read"]；模块级只读/读写）';
comment on column public.api_keys.status is '状态机：active 生效 / revoked 已吊销（吊销即时失效）';
comment on column public.api_keys.expires_at is '有效期（NULL=不过期）；过期 key 校验一律拒绝';
comment on column public.api_keys.last_used_at is '最近一次 verify_api_key 成功时间（中间件用量排障）';
comment on column public.api_keys.created_by is '签发人（弱关联 auth.users，不设外键以保留追溯）';

create trigger api_keys_set_updated_at
before update on public.api_keys
for each row
execute function app.set_updated_at();

alter table public.api_keys enable row level security;

-- ---------------------------------------------------------------------------
-- 2. app.create_api_key：admin 签发（一次性返回完整 key）
--    返回 jsonb：id/name/key_prefix/scopes/status/expires_at/created_at + key（明文，仅此一次）。
--    审计摘要只记前缀与范围，绝不落 key 明文/哈希。
-- ---------------------------------------------------------------------------
create function app.create_api_key(
  p_name       text,
  p_scopes     jsonb,
  p_expires_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plain  text;
  v_scopes jsonb := coalesce(p_scopes, '[]'::jsonb);
  v_row    public.api_keys;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_name is null or btrim(p_name) = '' then
    raise exception '密钥名称不能为空' using errcode = '22023';
  end if;

  if jsonb_typeof(v_scopes) <> 'array' then
    raise exception 'scopes 必须为 jsonb 数组' using errcode = '22023';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(v_scopes) as e
    where jsonb_typeof(e) <> 'string' or btrim(e #>> '{}') = ''
  ) then
    raise exception 'scopes 元素必须为非空字符串' using errcode = '22023';
  end if;

  if p_expires_at is not null and p_expires_at <= now() then
    raise exception '有效期必须晚于当前时间' using errcode = '22023';
  end if;

  -- 完整 key：'ak_' + 32 位十六进制（gen_random_uuid 去横线）；前缀取前 11 位（'ak_' + 8 位）
  v_plain := 'ak_' || replace(gen_random_uuid()::text, '-', '');

  insert into public.api_keys
    (name, key_prefix, key_hash, scopes, expires_at, created_by, updated_by)
  values
    (btrim(p_name),
     left(v_plain, 11),
     encode(extensions.digest(v_plain, 'sha256'), 'hex'),
     v_scopes,
     p_expires_at,
     (select auth.uid()),
     (select auth.uid()))
  returning * into v_row;

  perform app.audit_log(
    'integration', 'create', 'api_key', v_row.id::text,
    jsonb_build_object(
      'name', v_row.name,
      'key_prefix', v_row.key_prefix,
      'scopes', v_row.scopes,
      'expires_at', v_row.expires_at,
      'status', v_row.status
    )
  );

  return jsonb_build_object(
    'id', v_row.id,
    'name', v_row.name,
    'key', v_plain, -- 明文仅此一次；表中仅有 key_hash
    'key_prefix', v_row.key_prefix,
    'scopes', v_row.scopes,
    'status', v_row.status,
    'expires_at', v_row.expires_at,
    'created_at', v_row.created_at
  );
end;
$$;

comment on function app.create_api_key(text, jsonb, timestamptz) is
  'API 密钥签发 RPC（admin）：''ak_'' + 32 位十六进制；返回一次性完整 key 与前缀；'
  '落库仅 sha256 hex；审计只记前缀/范围/有效期，不落明文';

-- ---------------------------------------------------------------------------
-- 3. app.revoke_api_key：admin 吊销（即时失效）
-- ---------------------------------------------------------------------------
create function app.revoke_api_key(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev public.api_keys;
  v_row  public.api_keys;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_prev
  from public.api_keys
  where id = p_id
  for update;

  if not found then
    raise exception '密钥不存在：%', coalesce(p_id::text, '(null)') using errcode = 'P0002';
  end if;

  update public.api_keys
     set status     = 'revoked',
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  perform app.audit_log(
    'integration', 'revoke', 'api_key', v_row.id::text,
    jsonb_build_object(
      'key_prefix', v_row.key_prefix,
      'status_before', v_prev.status,
      'status_after', v_row.status
    )
  );

  return jsonb_build_object(
    'id', v_row.id,
    'name', v_row.name,
    'key_prefix', v_row.key_prefix,
    'status', v_row.status,
    'updated_at', v_row.updated_at
  );
end;
$$;

comment on function app.revoke_api_key(uuid) is
  'API 密钥吊销 RPC（admin）：status=revoked；吊销后 verify_api_key 立即返回 NULL（中间件 401）';

-- ---------------------------------------------------------------------------
-- 4. app.verify_api_key：后端校验口（规则 10，不 GRANT authenticated）
--    哈希匹配 + status=active + 未过期 → 更新 last_used_at 并返回 {key_id, scopes}；否则 NULL。
--    单条 UPDATE ... RETURNING 原子完成，避免校验与更新之间的竞态。
-- ---------------------------------------------------------------------------
create function app.verify_api_key(p_key text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id     uuid;
  v_scopes jsonb;
begin
  if p_key is null or btrim(p_key) = '' then
    return null;
  end if;

  update public.api_keys k
     set last_used_at = now()
   where k.key_hash = encode(extensions.digest(p_key, 'sha256'), 'hex')
     and k.status = 'active'
     and (k.expires_at is null or k.expires_at > now())
  returning k.id, k.scopes into v_id, v_scopes;

  if not found then
    return null;
  end if;

  return jsonb_build_object('key_id', v_id, 'scopes', v_scopes);
end;
$$;

comment on function app.verify_api_key(text) is
  'API 密钥校验口（后端中间件/wrapper）：sha256 哈希 + status + 有效期；'
  '通过则更新 last_used_at 并返回 {key_id, scopes}，失败（未知/吊销/过期）返回 NULL；'
  '不 GRANT authenticated（INDEX 规则 10）';

-- ---------------------------------------------------------------------------
-- 5. public 薄包装（PostgREST 仅暴露 public schema；admin 校验在 app 实现内）
-- ---------------------------------------------------------------------------
create function public.create_api_key(
  p_name       text,
  p_scopes     jsonb,
  p_expires_at timestamptz
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.create_api_key(p_name, p_scopes, p_expires_at)
$$;

create function public.revoke_api_key(p_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.revoke_api_key(p_id)
$$;

comment on function public.create_api_key(text, jsonb, timestamptz) is
  'create_api_key Data API 薄包装（admin 校验在 app 实现内；返回一次性完整 key）';
comment on function public.revoke_api_key(uuid) is
  'revoke_api_key Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 6. 授权：敏感表无表级写；管理 RPC 仅 authenticated（函数内 admin 校验）；
--    verify_api_key 不 GRANT authenticated（规则 10）
-- ---------------------------------------------------------------------------
revoke all on public.api_keys from public, anon, authenticated, service_role;
grant select on public.api_keys to authenticated;

revoke all on function app.create_api_key(text, jsonb, timestamptz) from public, anon;
grant execute on function app.create_api_key(text, jsonb, timestamptz) to authenticated;

revoke all on function app.revoke_api_key(uuid) from public, anon;
grant execute on function app.revoke_api_key(uuid) to authenticated;

revoke all on function app.verify_api_key(text) from public, anon, authenticated, service_role;

revoke all on function public.create_api_key(text, jsonb, timestamptz) from public, anon;
grant execute on function public.create_api_key(text, jsonb, timestamptz) to authenticated;

revoke all on function public.revoke_api_key(uuid) from public, anon;
grant execute on function public.revoke_api_key(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. RLS：仅 admin SELECT；无 INSERT/UPDATE/DELETE 策略（写仅经 RPC，无策略=拒绝）
-- ---------------------------------------------------------------------------
create policy api_keys_select_admin
on public.api_keys
for select
to authenticated
using ((select app.current_role()) = 'admin');
