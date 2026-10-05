-- 接口/集成中心 · 批次 1 安全修复：吊销/过期 key 的存量 JWT 即时失效
-- 背景：API key 换取的短期 JWT（role=api_client_role、TTL 1 小时，integration/002）此前仅
--       验签 + exp；key 被吊销/过期后，已签发 token 最长仍有 1 小时窗口。本迁移补齐存量
--       token 的即时失效，并收敛签发有效期与 last_used_at 写入节流。
-- 契约：docs/modules/integration/api-keys.md（吊销即时失效）、
--       docs/adr/001-job-runner.md（禁 service_role，本迁移不改 GRANT 面）。
-- 组成（均为 create or replace，函数签名/所有权/GRANT 面不变）：
--   1. app.verify_api_token：验签 + exp/nbf + role 校验后，查 claims.key_id 对应 api_keys：
--      status='active' 且未过期才返回 claims，否则 NULL（资源守据据此 42501，即时失效）。
--   2. app.issue_api_token：exp = min(now()+1h, key.expires_at)，避免签发超出 key 有效期的
--      token；expires_in 返回实际秒数（key 剩余不足 1 小时时 < 3600）。
--      key 有效性仍复用 app.verify_api_key（哈希 + status + 有效期）。
--   3. app.verify_api_key（顺带节流）：last_used_at 仅当为空或距上次更新 > 1 分钟才 UPDATE；
--      命中节流时走只读查询，仍正常返回 {key_id, scopes}（不影响签发/中间件调用方）。
-- 残留风险披露：即时失效依赖 verify 时查询 api_keys（无 token 吊销列表快照/黑名单）；
--       key 删除后同 id 不复用（uuid 主键），无重放旧 key_id 风险。
-- 依赖：integration/001（api_keys / verify_api_key）、integration/002（issue/verify_api_token）、
--       system/001（app.encryption_key）、extensions.pgjwt。

-- ---------------------------------------------------------------------------
-- 1. app.verify_api_key：校验成功路径不变；last_used_at 更新节流（1 分钟）
--    - 快路径仍为单条 UPDATE ... RETURNING（原子完成校验 + 用量时间）；
--    - 节流命中（1 分钟内已记录）时返回只读查询结果，不更新 last_used_at。
-- ---------------------------------------------------------------------------
create or replace function app.verify_api_key(p_key text)
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
     -- 节流：1 分钟内已记录用量则不重复写（last_used_at 为空或更早才更新）
     and (k.last_used_at is null or k.last_used_at < now() - interval '1 minute')
  returning k.id, k.scopes into v_id, v_scopes;

  if found then
    return jsonb_build_object('key_id', v_id, 'scopes', v_scopes);
  end if;

  -- 节流命中：只读校验（key 有效但 last_used_at 较新），不更新用量时间
  select k.id, k.scopes into v_id, v_scopes
  from public.api_keys k
  where k.key_hash = encode(extensions.digest(p_key, 'sha256'), 'hex')
    and k.status = 'active'
    and (k.expires_at is null or k.expires_at > now());

  if not found then
    return null;
  end if;

  return jsonb_build_object('key_id', v_id, 'scopes', v_scopes);
end;
$$;

comment on function app.verify_api_key(text) is
  'API 密钥校验口（后端中间件/wrapper）：sha256 哈希 + status + 有效期；'
  '通过则返回 {key_id, scopes}（last_used_at 仅在为空或距上次 >1 分钟时更新；节流不影响校验结果），'
  '失败（未知/吊销/过期）返回 NULL；不 GRANT authenticated（INDEX 规则 10）';

-- ---------------------------------------------------------------------------
-- 2. app.issue_api_token：exp = min(now()+1h, key.expires_at)（key 有效期是硬上界）
-- ---------------------------------------------------------------------------
create or replace function app.issue_api_token(p_key text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_verified   jsonb;
  v_secret     text;
  v_key_id     uuid;
  v_expires_at timestamptz;
  v_now_epoch  bigint := floor(extract(epoch from now()))::bigint;
  v_exp_epoch  bigint;
  v_token      text;
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

  v_key_id := (v_verified ->> 'key_id')::uuid;

  select k.expires_at into v_expires_at
  from public.api_keys k
  where k.id = v_key_id;

  -- 硬上界：token 不得晚于 key 自身有效期；key 无有效期时取 1 小时
  v_exp_epoch := floor(extract(epoch from
    least(now() + interval '1 hour', coalesce(v_expires_at, now() + interval '1 hour'))
  ))::bigint;

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
    'expires_in', greatest(v_exp_epoch - v_now_epoch, 0),
    'expires_at', to_timestamp(v_exp_epoch),
    'key_id', v_verified ->> 'key_id',
    'scopes', v_verified -> 'scopes'
  );
end;
$$;

comment on function app.issue_api_token(text) is
  'API key 换短期 JWT（HS256、role=api_client_role、claims 带 key_id/scopes）；'
  'exp = min(now()+1 小时, key.expires_at)，expires_in 为实际秒数（key 不足 1 小时时小于 3600）；'
  '签名密钥取 app.encryption_key.key_id=1（独立于 Supabase JWT_SECRET）；'
  '成功返回 {token,token_type,expires_in,expires_at,key_id,scopes}，无效 key 抛 42501；'
  'SECURITY DEFINER + search_path 空；GRANT anon（API 网关匿名入口），限流由调用方控制';

-- ---------------------------------------------------------------------------
-- 3. app.verify_api_token：验签后回查 key 状态（吊销/过期即时失效）
--    返回 claims（jsonb）或 NULL；不区分失败原因（防探测）；损坏 token 不抛错。
-- ---------------------------------------------------------------------------
create or replace function app.verify_api_token(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_secret     text;
  v_claims     jsonb;
  v_valid      boolean;
  v_key_id_txt text;
  v_key_active boolean;
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

  -- 存量 token 即时失效：回查 claims.key_id 对应 key 仍 active 且未过期
  v_key_id_txt := v_claims ->> 'key_id';

  if v_key_id_txt is null
     or v_key_id_txt !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    return null; -- 本系统签发必带合法 key_id；缺失/畸形一律拒绝（防伪造 claims）
  end if;

  select exists (
    select 1
    from public.api_keys k
    where k.id = v_key_id_txt::uuid
      and k.status = 'active'
      and (k.expires_at is null or k.expires_at > now())
  ) into v_key_active;

  if not v_key_active then
    return null; -- key 已吊销/过期/被删：已签发 token 立即失效
  end if;

  return v_claims;
end;
$$;

comment on function app.verify_api_token(text) is
  'API JWT 校验：签名（HS256，app.encryption_key.key_id=1）+ exp/nbf + role=api_client_role + '
  'claims.key_id 对应 api_keys 仍 active 且未过期（吊销/过期 key 的存量 token 立即失效）；'
  '有效返回 claims（含 key_id/scopes/exp），无效/篡改/过期/损坏/key 失效一律 NULL；'
  'SECURITY DEFINER + search_path 空；GRANT anon（守卫 RPC 以调用者身份执行，需自行验 token）';
