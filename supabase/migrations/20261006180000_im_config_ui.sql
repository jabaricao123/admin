-- 系统管理 · IM 配置页数据面（工单 im/006）
-- 契约：docs/adr/003-im-login.md §1（全局单选启用）/§4（凭据读写审计）/§5（切换=配置热更新 +
--       全局签出，不自动清空绑定；清空绑定为独立手动操作）、
--       docs/modules/INDEX.md 规则 4（凭据统一加密 + 界面掩码）/ 规则 10（内部入口不 GRANT API 角色）、
--       docs/modules/system/services-auth.md（身份认证配置页）。
--
-- 组成：
--   1. system_settings 新增三键：管理员联系方式（im_not_bound 时登录页展示）/ 密码登录全局开关 /
--      密码登录应急管理员邮箱（关闭后仅名单内且 role=admin/status=active 的账号可密码登录）；
--   2. public.im_get_config：admin 查看某厂商配置状态与**掩码后的已存凭据**（明文不出函数；
--      查看动作写 audit view_credentials——谁、何时、看了哪家）；
--   3. public.im_test_config：admin 测试连接（可先测界面上未保存的凭据；出站统一走
--      extensions.http + 既有 8s 超时收紧；写 audit test_connection）；
--   4. public.im_switch_provider：admin 启用 / 停用厂商（三选一原子切换，启用前校验凭据已保存），
--      并执行「全局签出」：删除 auth.sessions（GoTrue 对 access token 的 session_id claim 做存在性
--      校验，本地栈实测删除后 GET /auth/v1/user 立即 403 session_not_found，SSR 下一请求即跳登录页）。
--      说明：Supabase Auth Admin API 没有「全部用户签出」端点（admin.signOut 仅接受单个用户 JWT），
--      删除会话表即 GoTrue 自身登出的等价实现；本函数为 SECURITY DEFINER（属主 postgres，BYPASSRLS）。
--      写 audit switch_provider + force_logout（分两条，均可在 /audit 查到）；
--   5. public.im_clear_all_bindings：admin 一键清空 profiles 三列全部绑定（独立按钮，二次确认在 UI），
--      写 audit clear_bindings（含三家清空计数）；
--   6. public.im_get_login_options：登录页匿名读取（启用厂商 / 密码登录开关 / 管理员联系方式）；
--   7. public.im_password_login_allowed：密码登录提交后校验（关闭开关时仅应急管理员放行），
--      仅 GRANT authenticated（不在匿名阶段构成"某邮箱是否管理员"的探测口）。
--
-- 依赖：app.current_role()（init_profiles）、app.audit_log()（audit/001）、app.encrypt_secret /
--       app.decrypt_secret（system/001）、app.im_http_timeout()（im/002，飞书迁移 §4.6）。

-- ---------------------------------------------------------------------------
-- 1. system_settings 三键（幂等 seed；语义归 system，读写经既有 get_setting / upsert_setting）
-- ---------------------------------------------------------------------------
insert into public.system_settings (key, group_name, value, value_type, description)
values
  ('im_admin_contact', '通用', to_jsonb(''::text), 'string',
   'IM 未绑定（im_not_bound）时登录页展示的管理员联系方式，可填邮箱 / 电话 / 其他'),
  ('password_login_enabled', '安全', to_jsonb(true), 'bool',
   '密码登录全局开关：关闭后 /login 隐藏密码 Tab；应急管理员经 /login?admin=1 使用密码登录'),
  ('password_login_admin_emails', '安全', '[]'::jsonb, 'json',
   '密码登录应急管理员邮箱（json 数组，小写）；关闭开关后仅名单内且 role=admin / status=active 的账号可密码登录')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 2. app 内部 helper（零授权，仅经 PUBLIC SECURITY DEFINER 包装调用）
-- ---------------------------------------------------------------------------

-- 2.1 凭据解密读取（不要求 enabled=true —— 配置页需在启用前查看/测试凭据）
create function app.im_config_credentials(p_provider text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
           when c.credentials is not null
           then app.decrypt_secret(c.credentials)::jsonb
         end
  from public.im_auth_configs c
  where c.provider = lower(btrim(coalesce(p_provider, '')))
$$;

comment on function app.im_config_credentials(text) is
  '厂商凭据解密读取（配置页内部 helper，不 GRANT 任何角色）：与 app.im_provider_credentials 的差异是'
  '不要求 enabled=true（配置页要在启用前查看掩码 / 测试连接）；明文只存在于函数作用域';

-- 2.2 掩码：secret 类字段全掩码（不回显任何字符）；标识类字段保留首 4 尾 2 供识别
create function app.im_mask_credential_value(p_key text, p_value text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_len integer := char_length(coalesce(p_value, ''));
begin
  if p_value is null or v_len = 0 then
    return null;
  end if;

  -- 含 secret 的字段（app_secret / secret）一律全掩码，不泄露任何字符
  if coalesce(p_key, '') ilike '%secret%' then
    return repeat('•', 8);
  end if;

  if v_len <= 4 then
    return repeat('•', 8);
  elsif v_len <= 10 then
    return substr(p_value, 1, 2) || repeat('•', 6);
  end if;

  return substr(p_value, 1, 4) || repeat('•', 6) || right(p_value, 2);
end;
$$;

comment on function app.im_mask_credential_value(text, text) is
  '凭据展示掩码（纯函数）：secret 类字段固定 ••••••••；其余字段 >10 位保留首 4 尾 2、'
  '4-10 位保留首 2、<=4 位全掩码；空值返回 NULL；不 GRANT API 角色';

-- 2.3 三家测试连接响应解析（纯函数，pgTAP 覆盖；出站异常由调用方捕获）
create function app.im_test_parse_feishu(p_http_status integer, p_content text)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_body jsonb;
begin
  if p_http_status is distinct from 200 then
    return jsonb_build_object('ok', false, 'message', format('飞书返回 HTTP %s', p_http_status));
  end if;

  begin
    v_body := p_content::jsonb;
  exception when others then
    return jsonb_build_object('ok', false, 'message', '飞书响应不是合法 JSON');
  end;

  if coalesce(v_body ->> 'code', '') <> '0' then
    return jsonb_build_object(
      'ok', false,
      'message', format(
        '飞书校验失败（code=%s）：%s',
        coalesce(v_body ->> 'code', '?'),
        coalesce(v_body ->> 'msg', '未知错误')
      )
    );
  end if;

  if coalesce(v_body ->> 'tenant_access_token', '') = '' then
    return jsonb_build_object('ok', false, 'message', '飞书响应缺少 tenant_access_token');
  end if;

  return jsonb_build_object('ok', true, 'message', '飞书凭据有效');
end;
$$;

create function app.im_test_parse_wecom(p_http_status integer, p_content text)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_body jsonb;
begin
  if p_http_status is distinct from 200 then
    return jsonb_build_object('ok', false, 'message', format('企业微信返回 HTTP %s', p_http_status));
  end if;

  begin
    v_body := p_content::jsonb;
  exception when others then
    return jsonb_build_object('ok', false, 'message', '企业微信响应不是合法 JSON');
  end;

  if coalesce(v_body ->> 'errcode', '') <> '0' then
    return jsonb_build_object(
      'ok', false,
      'message', format(
        '企业微信校验失败（errcode=%s）：%s',
        coalesce(v_body ->> 'errcode', '?'),
        coalesce(v_body ->> 'errmsg', '未知错误')
      )
    );
  end if;

  if coalesce(v_body ->> 'access_token', '') = '' then
    return jsonb_build_object('ok', false, 'message', '企业微信响应缺少 access_token');
  end if;

  return jsonb_build_object('ok', true, 'message', '企业微信凭据有效');
end;
$$;

create function app.im_test_parse_dingtalk(p_http_status integer, p_content text)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_body jsonb;
begin
  if p_http_status is distinct from 200 then
    return jsonb_build_object('ok', false, 'message', format('钉钉返回 HTTP %s', p_http_status));
  end if;

  begin
    v_body := p_content::jsonb;
  exception when others then
    return jsonb_build_object('ok', false, 'message', '钉钉响应不是合法 JSON');
  end;

  if coalesce(v_body ->> 'accessToken', '') = '' then
    return jsonb_build_object(
      'ok', false,
      'message', format(
        '钉钉校验失败（code=%s）：%s',
        coalesce(v_body ->> 'code', '?'),
        coalesce(v_body ->> 'message', '缺少 accessToken')
      )
    );
  end if;

  return jsonb_build_object('ok', true, 'message', '钉钉凭据有效');
end;
$$;

comment on function app.im_test_parse_feishu(integer, text) is
  '飞书 tenant_access_token 校验响应解析（纯函数）：HTTP 非 200 / 非法 JSON / code<>0 / 缺 token 均 {ok:false,message}；不 GRANT API 角色';
comment on function app.im_test_parse_wecom(integer, text) is
  '企业微信 gettoken 校验响应解析（纯函数）：HTTP 非 200 / 非法 JSON / errcode<>0 / 缺 token 均 {ok:false,message}；不 GRANT API 角色';
comment on function app.im_test_parse_dingtalk(integer, text) is
  '钉钉 accessToken 校验响应解析（纯函数）：HTTP 非 200 / 非法 JSON / 缺 accessToken 均 {ok:false,message}；不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 3. public.im_get_config：admin 查看厂商配置（凭据仅返回掩码；查看写 audit）
-- ---------------------------------------------------------------------------
create function public.im_get_config(p_provider text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_provider text := lower(btrim(coalesce(p_provider, '')));
  v_row      public.im_auth_configs;
  v_creds    jsonb;
  v_masked   jsonb := '{}'::jsonb;
  v_key      text;
  v_value    text;
  v_updated_by_name text;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if v_provider not in ('wecom', 'feishu', 'dingtalk') then
    raise exception '未知 IM 厂商：%', coalesce(p_provider, '(null)') using errcode = '22023';
  end if;

  select * into v_row
  from public.im_auth_configs c
  where c.provider = v_provider;

  if v_row.provider is null then
    return jsonb_build_object(
      'provider', v_provider,
      'exists', false,
      'enabled', false,
      'credentials_set', false,
      'credentials_masked', '{}'::jsonb,
      'updated_by_name', null,
      'updated_at', null
    );
  end if;

  if v_row.credentials is not null then
    v_creds := app.decrypt_secret(v_row.credentials)::jsonb;
    for v_key, v_value in
      select key, value from jsonb_each_text(v_creds)
    loop
      v_masked := v_masked || jsonb_build_object(
        v_key, app.im_mask_credential_value(v_key, v_value)
      );
    end loop;
  end if;

  select p.full_name into v_updated_by_name
  from public.profiles p
  where p.id = v_row.updated_by;

  -- 敏感操作留痕：谁、何时、看了哪家（diff 只记"是否已配置"，不落任何凭据字符）
  perform app.audit_log(
    'system', 'view_credentials', 'im_auth_config', v_provider,
    jsonb_build_object(
      'provider', v_provider,
      'credentials_set', v_row.credentials is not null
    )
  );

  return jsonb_build_object(
    'provider', v_provider,
    'exists', true,
    'enabled', v_row.enabled,
    'credentials_set', v_row.credentials is not null,
    'credentials_masked', v_masked,
    'updated_by_name', v_updated_by_name,
    'updated_at', v_row.updated_at
  );
end;
$$;

comment on function public.im_get_config(text) is
  '厂商配置查看 RPC（admin）：返回 enabled / credentials_set / 掩码凭据（secret 全掩码）'
  '与最近修改人；写 audit view_credentials；明文凭据不出函数';

-- ---------------------------------------------------------------------------
-- 4. public.im_test_config：admin 测试连接（可带界面上未保存的凭据）
-- ---------------------------------------------------------------------------
create function public.im_test_config(p_provider text, p_credentials jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_provider  text := lower(btrim(coalesce(p_provider, '')));
  v_creds     jsonb;
  v_used_saved boolean;
  v_response  extensions.http_response;
  v_parsed    jsonb;
  v_app_id    text;
  v_app_secret text;
  v_corp_id   text;
  v_agent_id  text;
  v_wecom_secret text;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if v_provider not in ('wecom', 'feishu', 'dingtalk') then
    raise exception '未知 IM 厂商：%', coalesce(p_provider, '(null)') using errcode = '22023';
  end if;

  if p_credentials is not null and jsonb_typeof(p_credentials) <> 'object' then
    raise exception 'credentials 必须为 jsonb 对象' using errcode = '22023';
  end if;

  -- 未传凭据 → 用已保存的（不要求 enabled，配置页可在启用前测试）
  v_used_saved := p_credentials is null;
  v_creds := coalesce(p_credentials, app.im_config_credentials(v_provider));

  if v_creds is null or v_creds = '{}'::jsonb then
    v_parsed := jsonb_build_object(
      'ok', false,
      'message', '尚未保存凭据：请先填写并保存，或直接填入本次要测试的凭据'
    );
  elsif v_provider = 'feishu' then
    v_app_id := nullif(btrim(coalesce(v_creds ->> 'app_id', '')), '');
    v_app_secret := nullif(btrim(coalesce(v_creds ->> 'app_secret', '')), '');
    if v_app_id is null or v_app_secret is null then
      v_parsed := jsonb_build_object('ok', false, 'message', '飞书凭据不完整：需要 App ID 与 App Secret');
    else
      perform app.im_http_timeout();
      begin
        v_response := extensions.http_post(
          'https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal',
          jsonb_build_object('app_id', v_app_id, 'app_secret', v_app_secret)::text,
          'application/json'
        );
      exception when others then
        v_parsed := jsonb_build_object('ok', false, 'message', '飞书出站请求失败（连接 / 超时 / DNS）');
      end;

      if v_parsed is null then
        v_parsed := app.im_test_parse_feishu(v_response.status, v_response.content);
      end if;
    end if;

  elsif v_provider = 'wecom' then
    v_corp_id := nullif(btrim(coalesce(v_creds ->> 'corp_id', '')), '');
    v_agent_id := nullif(btrim(coalesce(v_creds ->> 'agent_id', '')), '');
    v_wecom_secret := nullif(btrim(coalesce(v_creds ->> 'secret', '')), '');
    if v_corp_id is null or v_agent_id is null or v_wecom_secret is null then
      v_parsed := jsonb_build_object(
        'ok', false, 'message', '企业微信凭据不完整：需要企业 ID、应用 AgentId 与应用 Secret'
      );
    else
      perform app.im_http_timeout();
      begin
        v_response := extensions.http_get(
          'https://qyapi.weixin.qq.com/cgi-bin/gettoken'
            || '?corpid=' || app.urlencode(v_corp_id)
            || '&corpsecret=' || app.urlencode(v_wecom_secret)
        );
      exception when others then
        v_parsed := jsonb_build_object('ok', false, 'message', '企业微信出站请求失败（连接 / 超时 / DNS）');
      end;

      if v_parsed is null then
        v_parsed := app.im_test_parse_wecom(v_response.status, v_response.content);
      end if;
    end if;

  else  -- dingtalk
    v_app_id := nullif(btrim(coalesce(v_creds ->> 'app_key', '')), '');
    v_app_secret := nullif(btrim(coalesce(v_creds ->> 'app_secret', '')), '');
    if v_app_id is null or v_app_secret is null then
      v_parsed := jsonb_build_object('ok', false, 'message', '钉钉凭据不完整：需要 AppKey 与 AppSecret');
    else
      perform app.im_http_timeout();
      begin
        v_response := extensions.http_post(
          'https://api.dingtalk.com/v1.0/oauth2/accessToken',
          jsonb_build_object('appKey', v_app_id, 'appSecret', v_app_secret)::text,
          'application/json'
        );
      exception when others then
        v_parsed := jsonb_build_object('ok', false, 'message', '钉钉出站请求失败（连接 / 超时 / DNS）');
      end;

      if v_parsed is null then
        v_parsed := app.im_test_parse_dingtalk(v_response.status, v_response.content);
      end if;
    end if;
  end if;

  perform app.audit_log(
    'system', 'test_connection', 'im_auth_config', v_provider,
    jsonb_build_object(
      'provider', v_provider,
      'used_saved_credentials', v_used_saved,
      'ok', coalesce((v_parsed ->> 'ok')::boolean, false)
      -- 只记结果标记；厂商返回文案可能含凭据指纹，不入 audit
    )
  );

  return v_parsed;
end;
$$;

comment on function public.im_test_config(text, jsonb) is
  '厂商连接测试 RPC（admin）：p_credentials 为空用已保存凭据（不要求 enabled），非空用本次传入的'
  '完整凭据；飞书 tenant_access_token / 企业微信 gettoken / 钉钉 accessToken 出站校验（8s 超时）；'
  '写 audit test_connection（仅结果标记，不落凭据）；凭据明文不出函数作用域';

-- ---------------------------------------------------------------------------
-- 5. public.im_switch_provider：启用 / 停用厂商 + 全局签出（ADR-003 §5）
-- ---------------------------------------------------------------------------
create function public.im_switch_provider(p_provider text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_provider      text := nullif(lower(btrim(coalesce(p_provider, ''))), '');
  v_prev_enabled  text;
  v_sessions      integer := 0;
  v_audit_target  text;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if v_provider is not null and v_provider not in ('wecom', 'feishu', 'dingtalk') then
    raise exception '未知 IM 厂商：%', coalesce(p_provider, '(null)') using errcode = '22023';
  end if;

  -- 与 im_upsert_config 共用同一把配置锁，防并发启停交错
  perform pg_advisory_xact_lock(hashtextextended('public.im_auth_configs', 0));

  select c.provider into v_prev_enabled
  from public.im_auth_configs c
  where c.enabled
  limit 1;

  -- 幂等：目标即现状 → 不变更、不签出、不写审计噪声
  if v_prev_enabled is not distinct from v_provider then
    return jsonb_build_object(
      'provider', v_provider,
      'enabled', v_provider is not null,
      'changed', false,
      'sessions_revoked', 0
    );
  end if;

  if v_provider is not null then
    -- 启用前必须已有凭据，避免启用空厂商导致登录页扫码入口不可用
    if not exists (
      select 1
      from public.im_auth_configs c
      where c.provider = v_provider
        and c.credentials is not null
    ) then
      raise exception '厂商「%」尚未保存凭据，请先保存凭据再启用', v_provider using errcode = '22023';
    end if;

    update public.im_auth_configs c
       set enabled    = false,
           updated_by = (select auth.uid())
     where c.enabled
       and c.provider <> v_provider;

    insert into public.im_auth_configs (provider, enabled, updated_by)
    values (v_provider, true, (select auth.uid()))
    on conflict (provider) do update
       set enabled    = true,
           updated_by = excluded.updated_by;
  else
    -- p_provider = NULL：停用当前厂商（无任何扫码登录）
    update public.im_auth_configs c
       set enabled    = false,
           updated_by = (select auth.uid())
     where c.enabled;
  end if;

  v_audit_target := coalesce(v_provider, '(none)');

  perform app.audit_log(
    'system', 'switch_provider', 'im_auth_config', v_audit_target,
    jsonb_build_object(
      'enabled_before', v_prev_enabled,
      'enabled_after', v_provider
    )
  );

  -- 全局签出（ADR-003 §5）：删除全部 Supabase 会话，在线 access token 下一请求即失效。
  -- 仅删会话，不动任何绑定（清空绑定是显式独立操作，im_clear_all_bindings）。
  -- WHERE true 显式条件：Supabase 预置 pg_safeupdate 扩展拒绝无 WHERE 的 DELETE。
  delete from auth.sessions where true;
  get diagnostics v_sessions = row_count;

  perform app.audit_log(
    'system', 'force_logout', 'im_auth_config', v_audit_target,
    jsonb_build_object(
      'scope', 'all_users',
      'sessions_revoked', v_sessions,
      'trigger', 'switch_provider'
    )
  );

  return jsonb_build_object(
    'provider', v_provider,
    'enabled', v_provider is not null,
    'changed', true,
    'sessions_revoked', v_sessions
  );
end;
$$;

comment on function public.im_switch_provider(text) is
  '厂商启用 / 停用 RPC（admin）：p_provider 为空 = 停用当前厂商；启用前校验凭据已保存；'
  '三选一原子切换（advisory lock + partial unique index 兜底）；随后删除 auth.sessions 执行全局签出'
  '（GoTrue session_id 校验使在线 token 立即失效），写 audit switch_provider + force_logout；'
  '不自动清空任何绑定（ADR-003 §5）';

-- ---------------------------------------------------------------------------
-- 6. public.im_clear_all_bindings：清空全部 IM 绑定（独立操作，写 audit）
-- ---------------------------------------------------------------------------
create function public.im_clear_all_bindings()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wecom    integer;
  v_feishu   integer;
  v_dingtalk integer;
  v_total    integer;
  v_profiles integer;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select
    count(*) filter (where p.wecom_userid is not null)::integer,
    count(*) filter (where p.feishu_userid is not null)::integer,
    count(*) filter (where p.dingtalk_userid is not null)::integer,
    count(*) filter (
      where p.wecom_userid is not null
         or p.feishu_userid is not null
         or p.dingtalk_userid is not null
    )::integer
  into v_wecom, v_feishu, v_dingtalk, v_profiles
  from public.profiles p;

  -- 被清空的「绑定条目」总数（一个用户三家都绑 = 3 条）
  v_total := v_wecom + v_feishu + v_dingtalk;

  if v_total > 0 then
    update public.profiles p
       set wecom_userid    = null,
           feishu_userid   = null,
           dingtalk_userid = null,
           updated_by      = (select auth.uid())
     where p.wecom_userid is not null
        or p.feishu_userid is not null
        or p.dingtalk_userid is not null;
  end if;

  perform app.audit_log(
    'system', 'clear_bindings', 'im_binding', 'all',
    jsonb_build_object(
      'wecom_cleared', v_wecom,
      'feishu_cleared', v_feishu,
      'dingtalk_cleared', v_dingtalk,
      'total_cleared', v_total,
      'profiles_affected', v_profiles
    )
  );

  return jsonb_build_object(
    'wecom_cleared', v_wecom,
    'feishu_cleared', v_feishu,
    'dingtalk_cleared', v_dingtalk,
    'total_cleared', v_total,
    'profiles_affected', v_profiles
  );
end;
$$;

comment on function public.im_clear_all_bindings() is
  '清空全部 IM 绑定 RPC（admin）：三家 userid 全置空并写 updated_by；返回各厂商 / 总绑定条目 /'
  '受影响用户数；写 audit clear_bindings；不触碰会话（是否需要下线由管理员另用切换流程决定）';

-- ---------------------------------------------------------------------------
-- 7. 登录页公开读取 / 密码登录校验
-- ---------------------------------------------------------------------------
create function public.im_get_login_options()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'enabled_provider', (
      select c.provider
      from public.im_auth_configs c
      where c.enabled
      limit 1
    ),
    'password_login_enabled', coalesce(
      (
        select (s.value)::boolean
        from public.system_settings s
        where s.key = 'password_login_enabled'
      ),
      true
    ),
    'admin_contact', coalesce(
      (
        select nullif(btrim(s.value #>> '{}'), '')
        from public.system_settings s
        where s.key = 'im_admin_contact'
      ),
      ''
    )
  )
$$;

comment on function public.im_get_login_options() is
  '登录页读取口（anon + authenticated）：启用厂商 / 密码登录开关 / 管理员联系方式；'
  '只读三个标量，不触凭据；GRANT anon + authenticated';

create function public.im_password_login_allowed(p_email text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    coalesce(
      (
        select (s.value)::boolean
        from public.system_settings s
        where s.key = 'password_login_enabled'
      ),
      true
    )
    or (
      lower(btrim(coalesce(p_email, ''))) <> ''
      -- 应急名单命中（json 数组按字符串元素匹配）
      and exists (
        select 1
        from public.system_settings s
        where s.key = 'password_login_admin_emails'
          and s.value ? lower(btrim(p_email))
      )
      -- 名单只是过滤条件：账号本身仍须是 active admin，防止把非管理员写进名单绕过开关
      and exists (
        select 1
        from public.profiles p
        where lower(p.email) = lower(btrim(p_email))
          and p.role = 'admin'
          and p.status = 'active'
      )
    )
$$;

comment on function public.im_password_login_allowed(text) is
  '密码登录放行校验（仅 authenticated）：开关开启恒 true；关闭时仅应急名单内且 role=admin / '
  'status=active 的邮箱 true；仅 GRANT authenticated（不在匿名阶段暴露"某邮箱是否在应急名单"）';

-- ---------------------------------------------------------------------------
-- 8. 授权：admin RPC 仅 authenticated（函数内校验）；登录读取口 anon；内部 helper 零授权
-- ---------------------------------------------------------------------------
revoke all on function public.im_get_config(text) from public, anon, service_role;
revoke all on function public.im_test_config(text, jsonb) from public, anon, service_role;
revoke all on function public.im_switch_provider(text) from public, anon, service_role;
revoke all on function public.im_clear_all_bindings() from public, anon, service_role;
revoke all on function public.im_password_login_allowed(text) from public, anon, service_role;
revoke all on function public.im_get_login_options() from public, service_role;

grant execute on function public.im_get_config(text) to authenticated;
grant execute on function public.im_test_config(text, jsonb) to authenticated;
grant execute on function public.im_switch_provider(text) to authenticated;
grant execute on function public.im_clear_all_bindings() to authenticated;
grant execute on function public.im_password_login_allowed(text) to authenticated;
grant execute on function public.im_get_login_options() to anon, authenticated;

revoke all on function app.im_config_credentials(text)
  from public, anon, authenticated, service_role;
revoke all on function app.im_mask_credential_value(text, text)
  from public, anon, authenticated, service_role;
revoke all on function app.im_test_parse_feishu(integer, text)
  from public, anon, authenticated, service_role;
revoke all on function app.im_test_parse_wecom(integer, text)
  from public, anon, authenticated, service_role;
revoke all on function app.im_test_parse_dingtalk(integer, text)
  from public, anon, authenticated, service_role;
