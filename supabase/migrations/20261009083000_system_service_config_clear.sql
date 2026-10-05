-- 系统管理 · 批次 1 安全修复 4：upsert_service_config 空串=保留 + 显式清空
-- 背景（system/002 遗留）：
--   1. 凭据仅以 NULL 表达「不修改」：空白串（'' / '   '）会被当成新凭据加密覆盖原值，
--      用户「留空不改」的语义被破坏；
--   2. 无显式清空凭据的入口（界面只能覆盖、不能清除）。
-- 方案（对齐 sync 20261009070000）：
--   * p_credentials 先 btrim 判空（NULL / 空串 / 纯空白 = 保留原值；新建=未配置）；
--   * 签名追加 p_clear_credentials boolean default false：true 时显式清空（credentials 置
--     NULL），与 p_credentials 同给时以清空为准；清空同样触发已验证配置降级 unverified
--     并清空 verified_at；
--   * 审计补充 credentials_kept / credentials_cleared 标记。
-- 签名变更：新增尾参（default false，旧 3 参调用保持可用）；create or replace 不能改参数
--   列表，故 drop 后重建 app/public 两级函数——原 ACL 需显式恢复（authenticated EXECUTE）。
-- 依赖：20261004161000（upsert_service_config 最新版）、system/001（encrypt helper）。

-- ---------------------------------------------------------------------------
-- 1. 重建 app.upsert_service_config（+ p_clear_credentials）
-- ---------------------------------------------------------------------------
drop function app.upsert_service_config(text, jsonb, text);
drop function public.upsert_service_config(text, jsonb, text);

create function app.upsert_service_config(
  p_service          text,
  p_config           jsonb,
  p_credentials      text,
  p_clear_credentials boolean default false
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
  v_credentials    text  := nullif(btrim(p_credentials), '');
  v_clear          boolean := coalesce(p_clear_credentials, false);
  v_config_changed boolean := false;
  v_cred_changed   boolean := false;
  v_cred_kept      boolean := false;
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
    -- 草稿可存：新建一律 unverified，待「测试连接」确认；
    -- 空凭据（NULL/空白）与显式清空均落 NULL（未配置）
    insert into public.system_services
      (service, config, credentials, verify_status, verified_at, updated_by)
    values
      (p_service, v_config,
       case when v_clear then null else app.encrypt_secret(v_credentials) end,
       'unverified', null, (select auth.uid()))
    returning * into v_row;

    perform app.audit_log(
      'system', 'upsert', 'service_config', p_service,
      jsonb_build_object(
        'created', true,
        'config_keys', (select jsonb_agg(k order by k) from jsonb_object_keys(v_config) as k),
        'credentials_set', v_row.credentials is not null,
        'credentials_cleared', v_clear,
        'verify_status', v_row.verify_status
      )
    );
  else
    v_config_changed := v_config is distinct from v_prev.config;
    -- 凭据三态（对齐 sync）：显式清空 > 非空白新值 > 保留（NULL/空串/纯空白）
    v_cred_kept := not v_clear and v_credentials is null;
    v_cred_changed := case
                        when v_clear then v_prev.credentials is not null
                        else v_credentials is not null
                             and app.decrypt_secret(v_prev.credentials) is distinct from v_credentials
                      end;

    v_status := v_prev.verify_status;
    -- 状态机（services-mail.md 功能需求 3）：已验证配置被修改（含清空）→ 降级待复验，
    -- 旧 verified_at 同时清空（对当前配置不再成立）；failed 保持 failed（本就无效）。
    if v_prev.verify_status = 'verified' and (v_config_changed or v_cred_changed) then
      v_status := 'unverified';
    end if;

    update public.system_services
       set config        = v_config,
           credentials   = case
                             when v_clear then null
                             when v_credentials is null then v_prev.credentials
                             else app.encrypt_secret(v_credentials)
                           end,
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
        'credentials_kept', v_cred_kept,
        'credentials_cleared', v_clear,
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

comment on function app.upsert_service_config(text, jsonb, text, boolean) is
  '服务配置新建/编辑 RPC（admin）：credentials NULL/空串/纯空白=保留原值（btrim 判空），'
  '非空经 app.encrypt_secret 加密；p_clear_credentials=true 显式清空（与 p_credentials '
  '同给时以清空为准）；config/credentials 有变更（含清空）且原为 verified 时降级 unverified '
  '并清空 verified_at；审计仅记变更标记与 config 键名，不落凭据明文';

-- ---------------------------------------------------------------------------
-- 2. public 薄包装（新签名）
-- ---------------------------------------------------------------------------
create function public.upsert_service_config(
  p_service          text,
  p_config           jsonb,
  p_credentials      text,
  p_clear_credentials boolean default false
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.upsert_service_config(p_service, p_config, p_credentials, p_clear_credentials)
$$;

comment on function public.upsert_service_config(text, jsonb, text, boolean) is
  'upsert_service_config Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 3. 授权：重建的 upsert（app/public）恢复 authenticated EXECUTE，清零其他角色
-- ---------------------------------------------------------------------------
revoke all on function app.upsert_service_config(text, jsonb, text, boolean)
  from public, anon, service_role;
grant execute on function app.upsert_service_config(text, jsonb, text, boolean)
  to authenticated;

revoke all on function public.upsert_service_config(text, jsonb, text, boolean)
  from public, anon, service_role;
grant execute on function public.upsert_service_config(text, jsonb, text, boolean)
  to authenticated;
