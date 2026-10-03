-- 系统管理 · 邮件服务配置页（工单 system/002）
-- 契约：docs/modules/system/services-mail.md（配置表单、草稿可存、测试验证状态机）；
--       docs/modules/INDEX.md 规则 4（凭据加密 + 界面掩码）、规则 10（内部 RPC 授权面）。
--
-- 组成：
--   1. app.upsert_service_config 契约补充（create or replace）——编辑保存时 p_credentials
--      为 NULL 表示「不修改凭据」，保留原密文；新建行 NULL 仍表示未配置凭据（system/001
--      契约不变）。原因：services-mail.md 要求密码仅掩码展示、不填=不修改，而 system/001
--      的 upsert 会把 NULL 直接写成空凭据——仅改 from_addr 等非敏感字段也会清空已存密码。
--   2. app.test_mail_config / public.test_mail_config：邮件「测试验证」RPC（admin 校验）——
--      本期不做真实 SMTP 发送（发信通道 Edge Function 投递器尚未上线），改为校验配置完整性
--      （host/port/username 非空）并经 app.mark_service_verified 回写验证状态：
--      完整 → verified；缺失 → failed；返回结果供页面 toast 与状态区展示。
--
-- 依赖：system/001（20261004151000_system_services.sql）。

-- ---------------------------------------------------------------------------
-- 1. app.upsert_service_config：补充「不传凭据 = 保留原凭据」语义
--    （其余逻辑与 system/001 完全一致：admin 校验、加密落库、验证状态机、审计）
-- ---------------------------------------------------------------------------
create or replace function app.upsert_service_config(
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
  v_cred_keep      boolean := false;
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

    -- system/002 契约补充：p_credentials IS NULL 且已有凭据 → 保留原密文（不填=不修改）。
    -- 需要清空凭据的场景本期无入口，后续若需要以显式参数引入，禁止再用 NULL 表达。
    v_cred_keep := p_credentials is null and v_prev.credentials is not null;
    v_cred_changed := not v_cred_keep
                      and app.decrypt_secret(v_prev.credentials) is distinct from p_credentials;

    v_status := v_prev.verify_status;
    -- 状态机（services-mail.md 功能需求 3）：已验证配置被修改 → 降级待复验，
    -- 旧 verified_at 同时清空（对当前配置不再成立）；failed 保持 failed（本就无效）。
    if v_prev.verify_status = 'verified' and (v_config_changed or v_cred_changed) then
      v_status := 'unverified';
    end if;

    update public.system_services
       set config        = v_config,
           credentials   = case
                             when v_cred_keep then v_prev.credentials
                             else app.encrypt_secret(p_credentials)
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
        'credentials_kept', v_cred_keep,
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
  '编辑保存时 p_credentials 为 NULL 表示「不修改凭据」（保留原密文），新建时 NULL 表示未配置；'
  '已验证配置内容有变更时 verify_status 降级 unverified 并清空 verified_at（草稿状态机）；'
  '审计仅记变更标记与 config 键名，不落凭据明文';

-- ---------------------------------------------------------------------------
-- 2. app.test_mail_config：邮件配置测试验证（admin，本期为配置校验非真实发送）
--    契约（services-mail.md 功能需求 3/4）：最近一次测试结果与时间常驻展示；
--    配置缺失时记 failed（可读失败），完整时记 verified。
-- ---------------------------------------------------------------------------
create function app.test_mail_config(p_to text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row      public.system_services;
  v_host     text;
  v_port     text;
  v_username text;
  v_ok       boolean;
  v_message  text;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_to is null or btrim(p_to) = '' then
    raise exception '测试收件邮箱不能为空' using errcode = '22023';
  end if;

  select * into v_row
  from public.system_services
  where service = 'mail';

  if not found then
    raise exception '邮件配置不存在，请先保存配置' using errcode = 'P0002';
  end if;

  v_host     := nullif(btrim(v_row.config ->> 'host'), '');
  v_port     := nullif(btrim(v_row.config ->> 'port'), '');
  v_username := nullif(btrim(v_row.config ->> 'username'), '');

  if v_host is null or v_port is null or v_username is null then
    v_ok      := false;
    v_message := '配置不完整：host / port / username 均为必填';
  else
    v_ok      := true;
    v_message := '配置校验通过（真实发送验证在 Edge Function 投递器上线后启用）';
  end if;

  return app.mark_service_verified(
           'mail',
           v_ok,
           format('测试收件邮箱：%s；%s', p_to, v_message)
         )
         || jsonb_build_object(
              'ok', v_ok,
              'message', v_message
            );
end;
$$;

comment on function app.test_mail_config(text) is
  '邮件配置测试验证 RPC（admin）：校验 host/port/username 完整性并经 app.mark_service_verified 回写；'
  '本期不做真实 SMTP 发送（发信通道 Edge Function 投递器尚未上线），p_to 仅记录于审计备注；'
  '配置完整 → verified，缺失 → failed；返回 {ok, message, verify_status, verified_at}';

-- ---------------------------------------------------------------------------
-- 3. public 薄包装（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.test_mail_config(p_to text)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.test_mail_config(p_to)
$$;

comment on function public.test_mail_config(text) is
  'test_mail_config Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 4. 授权：管理 RPC 仅 authenticated（函数内 admin 校验）；anon/service_role 无路径
--    （create or replace 已保留 app.upsert_service_config 原授权，无需重复 GRANT）
-- ---------------------------------------------------------------------------
revoke all on function app.test_mail_config(text) from public, anon, service_role;
revoke all on function public.test_mail_config(text) from public, anon, service_role;

grant execute on function app.test_mail_config(text) to authenticated;
grant execute on function public.test_mail_config(text) to authenticated;
