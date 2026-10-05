-- 第三方数据同步 · 批次 4 并入 2：凭据掩码修复 + 显式清空（sync_sources）
-- 背景：
--   1. get_sync_sources 掩码固定 '****' || 明文尾 4 位：长度 ≤8 的凭据被「尾 4 位」暴露
--      一半以上（如 8 位凭据泄露 4 位），薄弱凭据等于半公开；
--   2. upsert_sync_source 仅 nullif(p_credentials,'') 判空：空白串（'   '）会被当成新凭据
--      加密覆盖原值（用户「留空不改」的语义被破坏）；
--   3. 无显式清空凭据的入口（界面只能覆盖、不能清除）。
-- 方案：
--   * get_sync_sources：明文长度 ≤8 只显示 '****'；>8 仍 '****' + 尾 4 位（sources.md 掩码约定）；
--   * app.upsert_sync_source 签名追加 p_clear_credentials boolean default false：
--       - 凭据 btrim 判空（NULL / 空串 / 纯空白 = 保留原值）；
--       - p_clear_credentials=true：显式清空（credentials 置 NULL；与已验证降级联动——
--         凭据变更含清空，原 verified 降级 unverified 并清空 last_verified_at）；
--       - p_clear_credentials=true 与 p_credentials 同时给值时以显式清空为准（接口文档注释）。
-- 签名变更：新增尾参（default false，旧 6 参调用保持可用）；create or replace 不能改参数列表，
--   故 drop 后重建 app/public 两级函数——原 ACL 需显式恢复（authenticated EXECUTE）。
-- pgTAP：sync_batch2_test.sql（≤8 全掩码 / 9 位尾 4 位 / 空白串保留 / 显式清空 + 降级）。
-- 依赖：20261004230000（sync_sources 现状）、system/001（encrypt/decrypt helper）。

-- ---------------------------------------------------------------------------
-- 1. 重建 app.upsert_sync_source（+ p_clear_credentials）
-- ---------------------------------------------------------------------------
drop function app.upsert_sync_source(uuid, text, text, jsonb, text, text);
drop function public.upsert_sync_source(uuid, text, text, jsonb, text, text);

create function app.upsert_sync_source(
  p_id                uuid,
  p_name              text,
  p_type              text,
  p_config            jsonb,
  p_credentials       text,
  p_status            text default null,
  p_clear_credentials boolean default false
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
  v_credentials    text  := nullif(btrim(p_credentials), '');
  v_clear          boolean := coalesce(p_clear_credentials, false);
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
      (btrim(p_name), p_type, v_config,
       case when v_clear then null else app.encrypt_secret(v_credentials) end,
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
    -- 凭据变更：显式清空视为变更（有旧值才降级）；否则仅非空白新值参与比较
    v_cred_changed   := case
                          when v_clear then v_prev.credentials is not null
                          else v_credentials is not null
                               and app.decrypt_secret(v_prev.credentials) is distinct from v_credentials
                        end;

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
                           when v_clear then null
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
        'credentials_cleared', v_clear,
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

comment on function app.upsert_sync_source(uuid, text, text, jsonb, text, text, boolean) is
  '数据源新建/编辑 RPC（admin）：credentials NULL/空串/纯空白=保留原值（btrim 判空），'
  '非空经 app.encrypt_secret 加密；p_clear_credentials=true 显式清空（与 p_credentials 同给时'
  '以清空为准）；config/credentials/type 有变更（含清空）且原为 verified 时降级 unverified 并'
  '清空 last_verified_at；p_status=disabled 且存在 active 任务引用时拒绝；审计不落凭据明文';

-- ---------------------------------------------------------------------------
-- 2. public 薄包装（新签名）
-- ---------------------------------------------------------------------------
create function public.upsert_sync_source(
  p_id                uuid,
  p_name              text,
  p_type              text,
  p_config            jsonb,
  p_credentials       text,
  p_status            text default null,
  p_clear_credentials boolean default false
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.upsert_sync_source(
    p_id, p_name, p_type, p_config, p_credentials, p_status, p_clear_credentials
  )
$$;

comment on function public.upsert_sync_source(uuid, text, text, jsonb, text, text, boolean) is
  'upsert_sync_source Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 3. app.get_sync_sources：掩码修复（长度 ≤8 仅 '****'）
-- ---------------------------------------------------------------------------
create or replace function app.get_sync_sources()
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
      when length(d.plain) <= 8 then '****'
      else '****' || right(d.plain, 4)
    end as credentials_masked,
    s.verify_status,
    s.last_verified_at,
    s.status,
    s.created_by,
    s.updated_by,
    s.created_at,
    s.updated_at
  from public.sync_sources s
  left join lateral (
    select app.decrypt_secret(s.credentials) as plain
  ) d on true
  order by s.created_at desc, s.id;
end;
$$;

comment on function app.get_sync_sources() is
  '数据源列表 RPC（admin）：凭据掩码在函数内计算——明文长度 ≤8 仅 ''****''（不泄露尾段），'
  '>8 为 ''****'' + 明文尾 4 位；不下发密文/明文；config 为非敏感字段原样返回';

-- ---------------------------------------------------------------------------
-- 4. 授权：重建的 upsert（app/public）恢复 authenticated EXECUTE，清零其他角色；
--    get_sync_sources 同签名 replace 保留原 ACL（仍显式再收口）
-- ---------------------------------------------------------------------------
revoke all on function app.upsert_sync_source(uuid, text, text, jsonb, text, text, boolean)
  from public, anon, authenticated, service_role;
grant execute on function app.upsert_sync_source(uuid, text, text, jsonb, text, text, boolean)
  to authenticated;

revoke all on function public.upsert_sync_source(uuid, text, text, jsonb, text, text, boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.upsert_sync_source(uuid, text, text, jsonb, text, text, boolean)
  to authenticated;

revoke all on function app.get_sync_sources() from public, anon, service_role;
grant execute on function app.get_sync_sources() to authenticated;
