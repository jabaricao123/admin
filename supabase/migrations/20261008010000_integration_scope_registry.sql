-- 接口/集成中心 · scope 白名单注册表 + 资源守卫 helper（integration 批次 2 修复项 3）
-- 契约：docs/modules/integration/api-keys.md（scopes 限到模块级只读/读写，最小授权）、
--       docs/modules/INDEX.md 规则 10（内部 helper 不 GRANT 业务角色，函数级最小例外）。
-- 内容：
--   1. public.api_scope_registry：scope 白名单（DB 单一事实来源；create_api_key 校验 ⊆ 本表）；
--   2. app.create_api_key 更新：拒绝注册表外的 scope（不再允许任意字符串）；
--   3. app.require_scope(p_claims, p_scope)：资源 RPC 守卫 helper（api_departments 模板必调项），
--      判定 claims.scopes 是否含所需 scope；helper 只读 claims，不含白名单查询。
-- 说明：require_scope 以 SECURITY INVOKER 使用（资源 RPC 在调用者身份下执行），
--   需要 EXECUTE 的最小例外（grant anon，与 log_integration_call 先例一致）；
--   白名单表本身仅 admin 可见（管理面数据，不开放普通登录用户）。
-- 依赖：integration/001（api_keys / create_api_key）、app.current_role。

-- ---------------------------------------------------------------------------
-- 1. api_scope_registry：scope 白名单（seed 四类只读）
-- ---------------------------------------------------------------------------
create table public.api_scope_registry (
  scope       text primary key,
  resource    text not null,
  description text,
  constraint api_scope_registry_scope_check check (scope ~ '^[a-z][a-z0-9_]*:[a-z][a-z0-9_]*$'),
  constraint api_scope_registry_resource_check check (btrim(resource) <> '')
);

comment on table public.api_scope_registry is
  '开放 API scope 白名单（DB 单一事实来源）：create_api_key 只接受本表登记的 scope；'
  'scope 形如 <模块>:<动作>（模块级只读/读写拆分），仅 admin 可见';
comment on column public.api_scope_registry.scope is 'scope 标识（如 org:read；主键）';
comment on column public.api_scope_registry.resource is 'scope 所属资源/模块标识（如 org/report/audit/integration）';
comment on column public.api_scope_registry.description is '权限说明（管理面展示用）';

insert into public.api_scope_registry (scope, resource, description) values
  ('org:read',         'org',         '组织：部门等公开视图只读'),
  ('report:read',      'report',      '报表：允许视图清单内只读'),
  ('audit:read',       'audit',       '审计：操作/登录明细只读'),
  ('integration:read', 'integration', '集成：调用日志与投递明细只读')
on conflict (scope) do nothing;

alter table public.api_scope_registry enable row level security;

create policy api_scope_registry_select_admin
on public.api_scope_registry
for select
to authenticated
using ((select app.current_role()) = 'admin');

-- ---------------------------------------------------------------------------
-- 2. app.create_api_key：scopes ⊆ 注册表（在原类型/空值校验之后补白名单校验）
-- ---------------------------------------------------------------------------
create or replace function app.create_api_key(
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
  v_unknown text;
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

  -- scope 白名单：注册表外一律拒绝（integration 批次 2；白名单在 api_scope_registry 维护）
  select string_agg(e #>> '{}', ', ' order by e #>> '{}')
    into v_unknown
  from jsonb_array_elements(v_scopes) as e
  where not exists (
    select 1
    from public.api_scope_registry r
    where r.scope = e #>> '{}'
  );

  if v_unknown is not null then
    raise exception 'scope 不在白名单内：%（可选：%）',
      v_unknown,
      (select string_agg(r.scope, ', ' order by r.scope) from public.api_scope_registry r)
      using errcode = '22023';
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
  'scopes 必须 ⊆ api_scope_registry 白名单（未知 scope 抛 22023）；'
  '落库仅 sha256 hex；审计只记前缀/范围/有效期，不落明文';

-- ---------------------------------------------------------------------------
-- 3. app.require_scope：资源 RPC 守卫 helper
-- ---------------------------------------------------------------------------
create function app.require_scope(p_claims jsonb, p_scope text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_scope is not null
     and btrim(p_scope) <> ''
     and jsonb_typeof(p_claims -> 'scopes') = 'array'
     and coalesce((p_claims -> 'scopes') ? p_scope, false)
$$;

comment on function app.require_scope(jsonb, text) is
  '资源 RPC 守卫 helper：claims.scopes 数组是否含所需 scope（缺省 false；只读 claims，不查白名单）；'
  '纯函数，不 GRANT authenticated；SECURITY INVOKER 资源函数以调用者身份运行时需 EXECUTE（grant anon）';

-- ---------------------------------------------------------------------------
-- 4. 授权：白名单表 admin 只读；require_scope 给 anon（资源 RPC invoker 链）
-- ---------------------------------------------------------------------------
revoke all on public.api_scope_registry from public, anon, authenticated, service_role;
grant select on public.api_scope_registry to authenticated;

revoke all on function app.require_scope(jsonb, text)
  from public, authenticated, service_role;
grant execute on function app.require_scope(jsonb, text) to anon;
