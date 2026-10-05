-- 接口/集成中心 · API 失败调用留痕（integration 批次 2 修复项 1）
-- 契约：docs/modules/integration/logs.md（验收：每次失败调用可在详情看到完整错误）、
--       docs/modules/INDEX.md 规则 2（audit 只记摘要）。
-- 背景：PG 无自治事务，「同事务记日志 + raise」不可兼得（raise 会回滚日志）。
--   本迁移采用务实方案：
--   * 资源 RPC（api_departments 模板）守卫失败不再 raise，而是返回状态包
--     {ok:false, status:401/403, error}，同事务写集成调用日志后正常提交；
--     HTTP 状态语义由网关按包内 status 适配（网关留痕 v2 收敛）；
--   * public.record_api_failure 保留给网关/未来 Edge Function 的显式失败打点入口
--     （GRANT anon；函数内不验签仅提取 key_id，限流同 key 1 分钟 ≤30）。
--   * 成功路径不变（{ok:true, data}），资源 RPC 契约从 setof 改为 jsonb 状态包
--     （唯一破坏性变更，属批次 2 决策；OpenAPI v1.1 已同步，见 20261008030000）。
-- 内容：
--   1. app.record_api_failure + public 薄包装：失败调用写 integration_call_logs（401/403）
--      + audit_log('integration','denied',...)；
--   2. app.api_departments：返回 jsonb 状态包；失败分支写日志不 raise；
--      scope 守卫改用 app.require_scope（20261008010000）；
--   3. public.api_departments 薄包装重建（返回 jsonb）。
-- 依赖：20261004200000（api_keys）、20261004235000（verify_api_token）、
--       20261005121000（log_integration_call）、20261008010000（scope registry / require_scope）、
--       app.audit_log。

-- ---------------------------------------------------------------------------
-- 1. app.record_api_failure：失败调用留痕（网关/资源 RPC 显式打点）
--    - 不验签、仅提取 key_id：payload base64url 解码 → api_keys 存在性校验；
--    - status_code：凭证有效但被拒 = 403；无效/无法解析 = 401；
--    - 限流：同 key（无法解析时共享 unknown 桶）1 分钟 ≤30 条，超限静默丢弃（返回 false）；
--    - audit：integration/denied（object_type='api_request'，diff 不含 token 明文）。
-- ---------------------------------------------------------------------------
create function app.record_api_failure(
  p_token  text,
  p_method text,
  p_reason text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_max_per_minute constant integer := 30;
  v_method text := left(btrim(coalesce(p_method, '')), 120);
  v_reason text := left(btrim(coalesce(p_reason, '')), 500);
  v_key_id uuid;
  v_prefix text;
  v_payload text;
  v_claims jsonb;
  v_status integer;
  v_recent integer;
begin
  if v_method = '' then
    raise exception '方法名不能为空' using errcode = '22023';
  end if;

  if v_reason = '' then
    raise exception '失败原因不能为空' using errcode = '22023';
  end if;

  -- 仅提取（不验签）：JWT payload 段 base64url 解码取 key_id；任何解析失败按未知凭证
  begin
    if p_token ~ '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$' then
      v_payload := translate(split_part(p_token, '.', 2), '-_', '+/');
      v_payload := v_payload || repeat('=', (4 - length(v_payload) % 4) % 4);
      v_claims := convert_from(decode(v_payload, 'base64'), 'utf8')::jsonb;
      v_key_id := nullif(v_claims ->> 'key_id', '')::uuid;
    end if;
  exception when others then
    v_key_id := null;
  end;

  -- 防伪造：key_id 必须真实存在（否则归入未知桶）
  if v_key_id is not null then
    select k.key_prefix into v_prefix
    from public.api_keys k
    where k.id = v_key_id;

    if v_prefix is null then
      v_key_id := null;
    end if;
  end if;

  -- 401（凭证无效/无法解析）或 403（凭证有效但被拒）
  v_status := case
    when app.verify_api_token(p_token) is not null then 403
    else 401
  end;

  -- 防刷：同 key 1 分钟 ≤30 条；超限静默丢弃（不报错以免成为探测信号）
  select count(*)::integer into v_recent
  from public.integration_call_logs l
  where l.kind = 'api'
    and l.status_code in (401, 403)
    and l.created_at > now() - interval '1 minute'
    and l.key_id is not distinct from v_key_id;

  if v_recent >= c_max_per_minute then
    return false;
  end if;

  perform app.log_integration_call(
    'api',
    v_key_id,
    null,
    v_method,
    v_status,
    null,
    jsonb_build_object('reason', v_reason)::text,
    null,
    v_reason
  );

  perform app.audit_log(
    'integration', 'denied', 'api_request', v_method,
    jsonb_build_object(
      'reason', v_reason,
      'status_code', v_status,
      'key_prefix', v_prefix
    )
  );

  return true;
end;
$$;

comment on function app.record_api_failure(text, text, text) is
  'API 失败调用留痕（网关/资源 RPC）：仅提取 token 中 key_id（不验签），'
  '凭证有效=403 / 无效=401，写 integration_call_logs（kind=api，error=reason）'
  '+ audit(integration/denied)；同 key 1 分钟 ≤30 限流（超限静默返回 false）；不落 token 明文';

-- ---------------------------------------------------------------------------
-- 2. public.record_api_failure：网关匿名入口薄包装
-- ---------------------------------------------------------------------------
create function public.record_api_failure(
  p_token  text,
  p_method text,
  p_reason text
)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select app.record_api_failure(p_token, p_method, p_reason)
$$;

comment on function public.record_api_failure(text, text, text) is
  'record_api_failure Data API 薄包装（网关匿名场景；限流/提取/落库在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 3. api_departments：jsonb 状态包（成功 {ok:true,data}；失败 {ok:false,status,error}）
--    返回类型变化，需重建函数（drop 包装 → drop 实现 → 重建）。
-- ---------------------------------------------------------------------------
drop function public.api_departments(text);
drop function app.api_departments(text);

create function app.api_departments(p_token text)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_claims    jsonb;
  v_prev_role text := pg_catalog.current_setting('role');
  v_key_id    uuid;
  v_started   timestamptz := clock_timestamp();
  v_rows      jsonb;
  v_duration  integer;
begin
  -- 守卫：验 token（无效 → 401 状态包 + 失败留痕，不再 raise）
  v_claims := app.verify_api_token(p_token);

  if v_claims is null then
    perform public.record_api_failure(p_token, 'api_departments', 'API token 无效或已过期');
    return jsonb_build_object('ok', false, 'status', 401, 'error', 'API token 无效或已过期');
  end if;

  -- 范围守卫：本资源要求 org:read（模板必调 app.require_scope）
  if not app.require_scope(v_claims, 'org:read') then
    perform public.record_api_failure(p_token, 'api_departments', 'API token 缺少所需范围：org:read');
    return jsonb_build_object(
      'ok', false, 'status', 403, 'error', 'API token 缺少所需范围：org:read'
    );
  end if;

  v_key_id := nullif(v_claims ->> 'key_id', '')::uuid;

  begin
    -- 资源查询身份：api_client_role（不绕过 RLS；无写策略=拒绝）
    set local role api_client_role;

    -- 结果聚合为 jsonb：既用于返回，也作为调用日志的响应摘要
    select jsonb_agg(to_jsonb(dv) order by dv.depth, dv.sort_order, dv.name)
      into v_rows
    from public.departments_v dv;

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

  v_duration := greatest(
    0,
    floor(extract(epoch from (clock_timestamp() - v_started)) * 1000)::integer
  );

  -- 调用日志（kind='api'）：状态码语义 200；响应摘要截断由 log 函数收口
  perform app.log_integration_call(
    'api',
    v_key_id,
    null,
    'api_departments',
    200,
    v_duration,
    jsonb_build_object('scope', 'org:read')::text,
    jsonb_build_object('ok', true, 'data', coalesce(v_rows, '[]'::jsonb))::text,
    null
  );

  return jsonb_build_object('ok', true, 'data', coalesce(v_rows, '[]'::jsonb));
end;
$$;

comment on function app.api_departments(text) is
  '开放 API 资源 RPC 模板：验 token（无效 → {ok:false,status:401} 并留痕）'
  '+ require_scope org:read（缺范围 → {ok:false,status:403} 并留痕）'
  '→ set local role api_client_role → 返回 {ok:true,data:[departments_v]}；'
  '失败不 raise（同事务写 integration_call_logs 后正常提交，HTTP 语义由网关适配）；'
  'SECURITY INVOKER（PG17 禁 definer 内 SET ROLE），查询前无业务数据访问';

create function public.api_departments(p_token text)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select app.api_departments(p_token)
$$;

comment on function public.api_departments(text) is
  'api_departments Data API 薄包装（token/scope 守卫与错误包在 app 实现内；必须 invoker 以支持 SET ROLE）';

-- ---------------------------------------------------------------------------
-- 4. 授权：record_api_failure 两个入口都开 anon（网关显式调用 + invoker 链）；
--    api_departments 同旧（仅 anon）；authenticated/service_role 不给。
-- ---------------------------------------------------------------------------
revoke all on function app.record_api_failure(text, text, text)
  from public, authenticated, service_role;
grant execute on function app.record_api_failure(text, text, text) to anon;

revoke all on function public.record_api_failure(text, text, text)
  from public, authenticated, service_role;
grant execute on function public.record_api_failure(text, text, text) to anon;

revoke all on function app.api_departments(text) from public, authenticated, service_role;
grant execute on function app.api_departments(text) to anon;

revoke all on function public.api_departments(text) from public, authenticated, service_role;
grant execute on function public.api_departments(text) to anon;
