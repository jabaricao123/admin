-- 系统管理 · 凭据加密密钥容错与轮换（system 批次 2 修复项 1）
-- 背景：app.encrypt_secret/decrypt_secret 共用 app.encryption_key.key_id=1；密钥轮换/密钥缺失/
--   密文损坏时，原实现会让整页读取（get_service_status）直接抛错锁死，或把解密失败静默吞为
--   「未配置」；本迁移做逐行容错 + 提供原子轮换预案。
-- 组成：
--   1. app.get_service_config：解密失败 raise 可读错误「凭据解密失败，可能密钥已轮换」；
--      返回值追加 verify_status（message 分发消费，见 20261011020000_message_use_service_config）。
--   2. app.get_service_status：逐行 exception 守卫——单行凭据解密失败仅该行显示
--      verify_status='failed' + config._decrypt_error 标注，其他行照常展示（不锁死整页）。
--   3. app.get_push_status：解密失败不再静默吞为「未配置」，secret_masked 标「解密失败」；
--      服务级状态由 get_service_status 同款守卫显示 failed。
--   4. app.rotate_encryption_key / public.rotate_encryption_key：admin 密钥轮换 RPC——
--      事务内旧 key 解密 + 新 key 重加密全部凭据，任一行失败整体回滚（原子）。
-- 掩码口径：合并批 1（20261009081000_system_mask_fix）——明文长度 <= 8 一律 '****'，
--   否则 '****' + 末 4 位；本迁移晚于批 1 落地，保持同一口径。
-- 轮换范围：system_services.credentials、webhooks.secret_enc/headers_enc、sync_sources.credentials，
--   并额外覆盖 im_auth_configs.credentials（同用 key_id=1；若不重加密，轮换后 IM 登录将失效）
--   与 app.im_wecom_token_cache（临时 access_token 缓存，轮换时直接清空，避免脏密文阻断轮换）。
-- 依赖：system/001（app.encryption_key / encrypt_secret / decrypt_secret）、sync/001（sync_sources）、
--       integration（webhooks）、im/001+003（im_auth_configs / im_wecom_token_cache）。

-- ---------------------------------------------------------------------------
-- 1. app.get_service_config：白名单读取口 + 可读解密错误 + verify_status
-- ---------------------------------------------------------------------------
create or replace function app.get_service_config(p_service text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row   public.system_services;
  v_plain text;
begin
  select * into v_row
  from public.system_services s
  where s.service = p_service;

  -- service 不存在返回 NULL（既有契约）
  if not found then
    return null;
  end if;

  begin
    v_plain := app.decrypt_secret(v_row.credentials);
  exception when others then
    -- 保持中断语义（配置不可用必须让消费方感知），但错误信息可读、指明可能原因
    raise exception '凭据解密失败，可能密钥已轮换（service=%）：请重新保存该服务凭据',
      p_service using errcode = 'P0001';
  end;

  -- config + 明文 credentials（未配置为 null）+ verify_status（供分发侧降级判定；
  -- 'verify_status' 为本次追加键，原消费方按 config 字段读取不受影响）
  return v_row.config || jsonb_build_object(
    'credentials',   v_plain,
    'verify_status', v_row.verify_status
  );
end;
$$;

comment on function app.get_service_config(text) is
  '服务配置白名单读取口（INDEX 规则 10）：config 字段合并 credentials 明文与 verify_status；'
  'service 不存在返回 NULL；凭据解密失败 raise 可读错误（可能密钥已轮换）；'
  '不 GRANT anon/authenticated，仅后端 wrapper/专用角色可调';

-- ---------------------------------------------------------------------------
-- 2. app.get_service_status：逐行容错脱敏展示（admin）
-- ---------------------------------------------------------------------------
create or replace function app.get_service_status()
returns table (
  service            text,
  config             jsonb,
  credentials_masked text,
  verify_status      text,
  verified_at        timestamptz,
  updated_by         uuid,
  updated_at         timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row   public.system_services;
  v_plain text;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  -- 逐行处理：单行解密失败只影响该行（不再让整页 500）
  for v_row in
    select * from public.system_services s order by s.service
  loop
    service       := v_row.service;
    config        := v_row.config;
    verify_status := v_row.verify_status;
    verified_at   := v_row.verified_at;
    updated_by    := v_row.updated_by;
    updated_at    := v_row.updated_at;

    if v_row.credentials is null then
      credentials_masked := null;
    else
      begin
        v_plain := app.decrypt_secret(v_row.credentials);
        -- 掩码口径（批 1 system_mask_fix）：<= 8 位一律 '****'，否则 '****' + 末 4 位
        credentials_masked := case
          when length(v_plain) <= 8 then '****'
          else '****' || right(v_plain, 4)
        end;
      exception when others then
        -- 容错展示：该行标 failed + config 内错误标注；不写库（读取口不得产生副作用）
        credentials_masked := '解密失败';
        verify_status      := 'failed';
        config             := coalesce(v_row.config, '{}'::jsonb)
                              || jsonb_build_object(
                                   '_decrypt_error',
                                   '凭据解密失败，可能密钥已轮换；请重新保存该服务凭据'
                                 );
      end;
    end if;

    return next;
  end loop;
end;
$$;

comment on function app.get_service_status() is
  '服务配置脱敏展示 RPC（admin）：逐行容错——单行凭据解密失败仅该行 verify_status 显示 failed'
  '并附 config._decrypt_error 标注，其他行照常返回（不锁死整页）；'
  '掩码口径与批 1 对齐（<=8 位一律 ''****''，否则 ''****''+末 4 位）；所有 service 行按 service 升序';

-- ---------------------------------------------------------------------------
-- 3. app.get_push_status：解密失败显式标注（admin）
-- ---------------------------------------------------------------------------
create or replace function app.get_push_status()
returns table (
  channel       text,
  webhook_url   text,
  enabled       boolean,
  secret_masked text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_row        public.system_services;
  v_secrets    jsonb := '{}'::jsonb;
  v_channel    text;
  v_items      text[] := array['wecom', 'dingtalk'];
  v_decrypt_ok boolean := true;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.system_services s
  where s.service = 'push';

  if found and v_row.credentials is not null then
    begin
      v_secrets := coalesce(
        nullif(app.decrypt_secret(v_row.credentials), '')::jsonb,
        '{}'::jsonb
      );
    exception when others then
      -- 批次 2 修复：解密/解析失败不再静默吞为「未配置」；两渠道显式标注，
      -- 服务级 verify_status 由 get_service_status 同款守卫显示 failed + _decrypt_error
      v_secrets    := '{}'::jsonb;
      v_decrypt_ok := false;
    end;
  end if;

  foreach v_channel in array v_items loop
    channel     := v_channel;
    webhook_url := nullif(btrim(v_row.config -> v_channel ->> 'webhook_url'), '');
    enabled     := coalesce(
                     (v_row.config -> v_channel -> 'enabled') = 'true'::jsonb,
                     false
                   );

    if not v_decrypt_ok then
      secret_masked := '解密失败';
    else
      secret_masked := case
                         when v_secrets ->> v_channel is null
                              or btrim(v_secrets ->> v_channel) = ''
                         then null
                         -- 掩码口径（批 1 system_mask_fix）：<= 8 位一律 '****'
                         when length(v_secrets ->> v_channel) <= 8 then '****'
                         else '****' || right(v_secrets ->> v_channel, 4)
                       end;
    end if;
    return next;
  end loop;
end;
$$;

comment on function app.get_push_status() is
  '推送配置脱敏读取 RPC（admin）：返回 wecom/dingtalk 双渠道 webhook_url、enabled 与 '
  'secret 掩码（<=8 位一律 ''****''，否则 ''****''+末 4 位）；密文在函数内解密、明文不出函数；'
  '解密/解析失败时两渠道 secret_masked 标「解密失败」（不再伪装未配置）；行不存在返回两行空配置';

-- ---------------------------------------------------------------------------
-- 4. app.rotate_encryption_key：原子密钥轮换（admin）
--    实现：读出旧 key → 生成新 key（256-bit 随机）→ 事务内逐表用旧 key 解密 + 新 key 重加密
--    → 全部成功后更新 key_id=1 的值（helpers 读取点）→ 写审计。
--   任一行解密/重加密失败 → raise，整个 RPC 事务回滚（旧 key 与旧密文原样保留）。
--   MVCC 下并发读会话在提交前始终看到旧 key + 旧密文，无中间态。
-- ---------------------------------------------------------------------------
create function app.rotate_encryption_key()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old_key   text;
  v_new_key   text;
  v_system    integer := 0;
  v_wh_secret integer := 0;
  v_wh_header integer := 0;
  v_sync      integer := 0;
  v_im_cfg    integer := 0;
  v_im_cache  integer := 0;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  -- 单实例锁：防两个轮换并发交错（xact 级，随本次 RPC 事务释放）
  perform pg_advisory_xact_lock(hashtext('app.rotate_encryption_key'));

  select k.key into v_old_key
  from app.encryption_key k
  where k.key_id = 1;

  if v_old_key is null then
    raise exception '加密密钥未初始化（app.encryption_key.key_id=1 缺失）' using errcode = 'P0001';
  end if;

  v_new_key := encode(extensions.gen_random_bytes(32), 'hex');

  -- 逐表重加密；异常信息带上表/列名便于定位（整体回滚，绝不留半新半旧状态）
  begin
    update public.system_services
       set credentials = extensions.pgp_sym_encrypt(
                           extensions.pgp_sym_decrypt(credentials, v_old_key),
                           v_new_key
                         )
     where credentials is not null;
    get diagnostics v_system = row_count;
  exception when others then
    raise exception 'system_services.credentials 重加密失败：%', sqlerrm using errcode = 'P0001';
  end;

  begin
    update public.webhooks
       set secret_enc = extensions.pgp_sym_encrypt(
                          extensions.pgp_sym_decrypt(secret_enc, v_old_key),
                          v_new_key
                        )
     where secret_enc is not null;
    get diagnostics v_wh_secret = row_count;

    update public.webhooks
       set headers_enc = extensions.pgp_sym_encrypt(
                           extensions.pgp_sym_decrypt(headers_enc, v_old_key),
                           v_new_key
                         )
     where headers_enc is not null;
    get diagnostics v_wh_header = row_count;
  exception when others then
    raise exception 'webhooks.secret_enc/headers_enc 重加密失败：%', sqlerrm using errcode = 'P0001';
  end;

  begin
    update public.sync_sources
       set credentials = extensions.pgp_sym_encrypt(
                           extensions.pgp_sym_decrypt(credentials, v_old_key),
                           v_new_key
                         )
     where credentials is not null;
    get diagnostics v_sync = row_count;
  exception when others then
    raise exception 'sync_sources.credentials 重加密失败：%', sqlerrm using errcode = 'P0001';
  end;

  -- 额外覆盖（超出工单清单但必须）：IM 厂商凭据同用 key_id=1，不轮换则 IM 登录即失效
  begin
    update public.im_auth_configs
       set credentials = extensions.pgp_sym_encrypt(
                           extensions.pgp_sym_decrypt(credentials, v_old_key),
                           v_new_key
                         )
     where credentials is not null;
    get diagnostics v_im_cfg = row_count;
  exception when others then
    raise exception 'im_auth_configs.credentials 重加密失败：%', sqlerrm using errcode = 'P0001';
  end;

  -- 企业微信 access_token 缓存为可再生成的临时数据：直接清空（避免脏密文阻断轮换）
  begin
    delete from app.im_wecom_token_cache;
    get diagnostics v_im_cache = row_count;
  exception when others then
    raise exception 'app.im_wecom_token_cache 清理失败：%', sqlerrm using errcode = 'P0001';
  end;

  -- 切换当前密钥：更新 helpers 的读取行（并发读会话 MVCC 下提交前仍见旧 key）
  update app.encryption_key
     set key = v_new_key, rotated_at = null
   where key_id = 1;

  perform app.audit_log(
    'system', 'rotate', 'encryption_key', 'key_id=1',
    jsonb_build_object(
      'system_services',   v_system,
      'webhooks_secret',   v_wh_secret,
      'webhooks_headers',  v_wh_header,
      'sync_sources',      v_sync,
      'im_auth_configs',   v_im_cfg,
      'im_token_cache',    v_im_cache
    )
  );

  return jsonb_build_object(
    'rotated_at',       now(),
    'system_services',  v_system,
    'webhooks_secret',  v_wh_secret,
    'webhooks_headers', v_wh_header,
    'sync_sources',     v_sync,
    'im_auth_configs',  v_im_cfg,
    'im_token_cache',   v_im_cache
  );
end;
$$;

comment on function app.rotate_encryption_key() is
  '加密密钥轮换 RPC（admin）：生成 256-bit 新 key，事务内用旧 key 解密 + 新 key 重加密 '
  'system_services / webhooks / sync_sources / im_auth_configs 凭据并清空 im token 缓存，'
  '任一失败整体回滚（原子）；成功后 key_id=1 切换为新值并写审计（不含密钥本身）；'
  '并发轮换经 advisory xact lock 串行化';

-- ---------------------------------------------------------------------------
-- 5. public 薄包装（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.rotate_encryption_key()
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.rotate_encryption_key()
$$;

comment on function public.rotate_encryption_key() is
  'rotate_encryption_key Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 6. 授权
-- ---------------------------------------------------------------------------
revoke all on function app.rotate_encryption_key() from public, anon, service_role;
grant execute on function app.rotate_encryption_key() to authenticated;

revoke all on function public.rotate_encryption_key() from public, anon, service_role;
grant execute on function public.rotate_encryption_key() to authenticated;
