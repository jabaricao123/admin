-- 接口/集成中心 · API 认证：key 校验 → 短期 JWT 签发与资源守卫（工单 integration/002）
-- 契约：docs/modules/integration/api-keys.md（校验后签发短期 JWT role=api_client_role、
--       RLS 按该角色策略过滤、白名单最小授权）、docs/modules/INDEX.md 规则 10（内部 RPC
--       不 GRANT authenticated；issue/verify 为 API 网关匿名入口的显式例外：仅 GRANT anon +
--       函数内全参数校验，限流由网关/调用方控制）、ADR-001（全局禁 service_role）。
--
-- 组成：
--   1. 数据库角色 api_client_role：nologin；public schema usage + 白名单只读
--      （departments_v / positions；security_invoker 视图另需底层表 SELECT）；无写权限。
--   2. app.issue_api_token：API key（复用 integration/001 app.verify_api_key）→ 短期 JWT
--      （HS256、1 小时）。签名密钥取 app.encryption_key.key_id=1——与 Supabase auth 的
--      JWT_SECRET 相互独立：api_client JWT 仅本系统的资源守卫（app.verify_api_token）校验，
--      PostgREST/auth 不认；密钥轮换后旧 token 立即失效（TTL 1 小时可接受）。
--   3. app.verify_api_token：验签 + exp + role 校验，返回 claims；供资源 RPC 守卫生成
--      set local role api_client_role 的身份依据。
--   4. app.api_departments：端到端演示资源 RPC——token 校验 + scopes 含 org:read →
--      set local role api_client_role → 读 departments_v（RLS 按 api_client_role 策略过滤）。
--      作为后续开放 API 资源 RPC 的模板：守卫（verify + scope）→ 切角色 → 查询公开视图。
--      注：守卫 RPC 必须 SECURITY INVOKER——PostgreSQL 禁止 SECURITY DEFINER 内 SET ROLE
--      （PG17「cannot set parameter "role" within security-definer function」；同 report/007
--      worker 的落地方式），角色注入前不读取任何业务数据，函数内无 definer 权限可用。
--   5. 白名单 RLS 策略：departments / positions 对 api_client_role 的最小只读策略
--      （本批为演示同批落地；后续按 scopes 扩展时在各自模块迁移追加）。
--   6. public 薄包装（PostgREST 仅暴露 public；config.toml schemas=public/graphql_public）
--      与角色成员：api_client_role GRANT authenticator（PostgREST 会话用户；SET ROLE 需
--      成员资格，与继承无关）。
--
-- 依赖：integration/001（app.verify_api_key / api_keys）、system/001（app.encryption_key）、
--       org/001（departments / departments_v）、org/003（positions）、extensions.pgjwt。

-- ---------------------------------------------------------------------------
-- 1. 数据库角色 api_client_role（幂等；nologin + 最小属性）
-- ---------------------------------------------------------------------------
do $do$
begin
  if not exists (
    select 1 from pg_catalog.pg_roles where rolname = 'api_client_role'
  ) then
    create role api_client_role nologin;
  end if;
end
$do$;

comment on role api_client_role is
  '开放 API 访问身份（API key 换取的短期 JWT role claim）：nologin、非 superuser、非 bypassrls；'
  '仅 public schema usage + 白名单只读对象 SELECT；守卫 RPC set local role 后按该角色 RLS 策略过滤；'
  '低权限读角色（不持有任何业务写权限）；全局禁 service_role（ADR-001）';

-- PostgREST 会话用户为 authenticator；SET ROLE api_client_role 需要成员资格（显式 SET，
-- 与 rolINHERIT 无关）。裸 Postgres 环境无 authenticator 时跳过。
do $do$
begin
  if exists (
    select 1 from pg_catalog.pg_roles where rolname = 'authenticator'
  ) then
    grant api_client_role to authenticator;
  end if;
end
$do$;

-- ---------------------------------------------------------------------------
-- 2. 白名单只读授权 + RLS 策略（最小面；无写策略=拒绝）
-- ---------------------------------------------------------------------------
grant usage on schema public to api_client_role;

-- 白名单：部门公开视图与岗位（roles_v/profiles 等待后续 scopes 扩展时追加，不在本期开口）
grant select on public.departments_v, public.positions to api_client_role;
-- departments_v 为 security_invoker 视图：底层表同样需要 SELECT，RLS 由策略收口
grant select on public.departments to api_client_role;

create policy departments_select_api_client
on public.departments
for select
to api_client_role
using (status <> 'deleted');

create policy positions_select_api_client
on public.positions
for select
to api_client_role
using (status = 'active');

-- ---------------------------------------------------------------------------
-- 3. pgjwt 扩展（签名/验签；安装到 extensions schema，复用同 schema 的 pgcrypto.hmac）
-- ---------------------------------------------------------------------------
create extension if not exists pgjwt with schema extensions;

-- ---------------------------------------------------------------------------
-- 4. app.issue_api_token：API key → 短期 JWT（1 小时；claims 带 key_id/scopes）
--    校验失败（未知/吊销/过期 key）抛 42501（不返回半成品）；空 key 抛 22023。
-- ---------------------------------------------------------------------------
create function app.issue_api_token(p_key text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_verified  jsonb;
  v_secret    text;
  v_now_epoch bigint := floor(extract(epoch from now()))::bigint;
  v_exp_epoch bigint;
  v_token     text;
begin
  if p_key is null or btrim(p_key) = '' then
    raise exception 'API key 不能为空' using errcode = '22023';
  end if;

  -- key 校验复用 integration/001：sha256 哈希 + status + 有效期；失败一律 NULL
  v_verified := app.verify_api_key(p_key);

  if v_verified is null then
    raise exception 'API key 无效、已吊销或已过期' using errcode = '42501';
  end if;

  select k.key into v_secret
  from app.encryption_key k
  where k.key_id = 1;

  if v_secret is null then
    raise exception 'JWT 签名密钥未初始化（app.encryption_key.key_id=1 缺失）' using errcode = 'P0001';
  end if;

  v_exp_epoch := floor(extract(epoch from now() + interval '1 hour'))::bigint;

  v_token := extensions.sign(
    json_build_object(
      'iss', 'admin-api',
      'role', 'api_client_role',
      'key_id', v_verified ->> 'key_id',
      'scopes', v_verified -> 'scopes',
      'iat', v_now_epoch,
      'nbf', v_now_epoch,
      'exp', v_exp_epoch
    ),
    v_secret
  );

  return jsonb_build_object(
    'token', v_token,
    'token_type', 'Bearer',
    'expires_in', 3600,
    'expires_at', to_timestamp(v_exp_epoch),
    'key_id', v_verified ->> 'key_id',
    'scopes', v_verified -> 'scopes'
  );
end;
$$;

comment on function app.issue_api_token(text) is
  'API key 换短期 JWT（HS256、1 小时、role=api_client_role、claims 带 key_id/scopes）；'
  '签名密钥取 app.encryption_key.key_id=1（独立于 Supabase JWT_SECRET）；'
  '成功返回 {token,token_type,expires_in,expires_at,key_id,scopes}，无效 key 抛 42501；'
  'SECURITY DEFINER + search_path 空；GRANT anon（API 网关匿名入口），限流由调用方控制';

-- ---------------------------------------------------------------------------
-- 5. app.verify_api_token：验签 + exp + role（供资源守卫）
--    返回 claims（jsonb）或 NULL；不区分失败原因（防探测）；损坏 token 不抛错。
-- ---------------------------------------------------------------------------
create function app.verify_api_token(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_secret text;
  v_claims jsonb;
  v_valid  boolean;
begin
  if p_token is null or btrim(p_token) = '' then
    return null;
  end if;

  select k.key into v_secret
  from app.encryption_key k
  where k.key_id = 1;

  if v_secret is null then
    raise exception 'JWT 签名密钥未初始化（app.encryption_key.key_id=1 缺失）' using errcode = 'P0001';
  end if;

  begin
    select v.payload, v.valid
      into v_claims, v_valid
      from extensions.verify(p_token, v_secret) as v;
  exception when others then
    -- 非 JWT 结构 / base64 损坏：一律视为无效凭证
    return null;
  end;

  if v_valid is not true then
    return null;
  end if;

  -- 防串用：仅接受本系统签发的 api_client_role，且必须带 exp（缺失时 pgjwt 视为无上界）
  if v_claims is null
     or v_claims ->> 'role' is distinct from 'api_client_role'
     or not (v_claims ? 'exp') then
    return null;
  end if;

  return v_claims;
end;
$$;

comment on function app.verify_api_token(text) is
  'API JWT 校验：签名（HS256，app.encryption_key.key_id=1）+ exp/nbf + role=api_client_role；'
  '有效返回 claims（含 key_id/scopes/exp），无效/篡改/过期/损坏一律 NULL；'
  'SECURITY DEFINER + search_path 空；GRANT anon（守卫 RPC 以调用者身份执行，需自行验 token）';

-- ---------------------------------------------------------------------------
-- 6. app.api_departments：端到端演示资源 RPC（后续开放 API 模板）
--    守卫：verify token + scopes 含 org:read；查询：set local role api_client_role 后读
--    departments_v（RLS 按该角色策略过滤）；结束/异常均还原角色。
-- ---------------------------------------------------------------------------
create function app.api_departments(p_token text)
returns setof public.departments_v
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_claims    jsonb;
  v_prev_role text := pg_catalog.current_setting('role');
begin
  -- 守卫：验 token（无效直接 401 语义）
  v_claims := app.verify_api_token(p_token);

  if v_claims is null then
    raise exception 'API token 无效或已过期' using errcode = '42501';
  end if;

  -- 范围守卫：本资源要求 org:read（scopes 为签发时 API key 上声明的白名单）
  if not coalesce((v_claims -> 'scopes') ? 'org:read', false) then
    raise exception 'API token 缺少所需范围：org:read' using errcode = '42501';
  end if;

  begin
    -- 资源查询身份：api_client_role（不绕过 RLS；无写策略=拒绝）
    set local role api_client_role;

    return query
    select dv.*
    from public.departments_v dv
    order by dv.depth, dv.sort_order, dv.name;

    -- 查询完成：还原入口身份，避免影响同一事务中的后续语句
    if v_prev_role is null or v_prev_role = 'none' then
      reset role;
    else
      execute format('set local role %I', v_prev_role);
    end if;
  exception when others then
    if v_prev_role is null or v_prev_role = 'none' then
      reset role;
    else
      execute format('set local role %I', v_prev_role);
    end if;
    raise;
  end;

  return;
end;
$$;

comment on function app.api_departments(text) is
  '开放 API 资源 RPC 模板（演示端到端闭环）：验 token + scopes 含 org:read → '
  'set local role api_client_role → 返回 departments_v（RLS 按该角色策略过滤）；'
  'SECURITY INVOKER（PG17 禁 definer 内 SET ROLE），查询前无业务数据访问；'
  '后续资源 RPC 按此模板扩展（scopes 按模块只读/读写拆分）';

-- ---------------------------------------------------------------------------
-- 7. public 薄包装（PostgREST 仅暴露 public schema；实现与守卫在 app）
-- ---------------------------------------------------------------------------
create function public.issue_api_token(p_key text)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.issue_api_token(p_key)
$$;

create function public.api_departments(p_token text)
returns setof public.departments_v
language sql
security invoker
set search_path = ''
as $$
  select * from app.api_departments(p_token)
$$;

comment on function public.issue_api_token(text) is
  'issue_api_token Data API 薄包装（校验/签发票在 app 实现内；匿名入口）';
comment on function public.api_departments(text) is
  'api_departments Data API 薄包装（token/scope 守卫在 app 实现内；必须 invoker 以支持 SET ROLE）';

-- ---------------------------------------------------------------------------
-- 8. 授权：匿名网关入口（规则 10 的显式例外）
--    - 不 GRANT authenticated（任务契约）：后台 wrapper 走 anon 或直连数据库；
--    - 不 GRANT service_role（ADR-001）；verify_api_token 不暴露 public 包装（仅守卫内部用）。
--    - anon 需要 schema app USAGE 才能调用 app 下函数（init_profiles 已 revoke 默认面；
--      此处显式开一个仅函数级的最小入口，app 内其余函数均无 anon/authenticated 执行权）。
-- ---------------------------------------------------------------------------
grant usage on schema app to anon;

revoke all on function app.issue_api_token(text) from public, authenticated, service_role;
grant execute on function app.issue_api_token(text) to anon;

revoke all on function app.verify_api_token(text) from public, authenticated, service_role;
grant execute on function app.verify_api_token(text) to anon;

revoke all on function app.api_departments(text) from public, authenticated, service_role;
grant execute on function app.api_departments(text) to anon;

revoke all on function public.issue_api_token(text) from public, authenticated, service_role;
grant execute on function public.issue_api_token(text) to anon;

revoke all on function public.api_departments(text) from public, authenticated, service_role;
grant execute on function public.api_departments(text) to anon;
