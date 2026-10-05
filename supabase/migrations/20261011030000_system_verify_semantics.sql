-- 系统管理 · 服务「测试验证」语义修正（system 批次 2 修复项 3）
-- 1. app.test_storage_config：provider='s3' 不再复用「storage.buckets 存在性」判定
--    （原实现永远 failed——s3 的目标 bucket 由外部对象存储持有，本地 storage.buckets 无该记录）。
--    新语义：
--      * supabase-storage：保持原语义——provider/endpoint/bucket 必填 + storage.buckets 存在目标 bucket；
--      * s3：校验 endpoint（http(s) URL）/ region / access_key / secret_key 格式完整性即 verified，
--        真实连通性探测待出站运行时 ADR 落地后启用（注释标注）。
-- 2. app.test_mail_config：补 from_addr 邮箱格式 + port 数字/范围校验（1-65535）。
-- 3. app.test_push_config：补钉钉渠道启用时加签 Secret 非空校验（services-push.md 功能需求 2/3）。
-- 依赖：system/001-002（system_services / mark_service_verified）、20261011010000（解密失败可读错误）。

-- ---------------------------------------------------------------------------
-- 1. app.test_storage_config：按 provider 分派验证语义（admin）
-- ---------------------------------------------------------------------------
create or replace function app.test_storage_config()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row      public.system_services;
  v_provider text;
  v_endpoint text;
  v_bucket   text;
  v_region   text;
  v_creds    jsonb := '{}'::jsonb;
  v_access   text;
  v_secret   text;
  v_ok       boolean;
  v_message  text;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.system_services
  where service = 'storage';

  if not found then
    raise exception '对象存储配置不存在，请先保存配置' using errcode = 'P0002';
  end if;

  v_provider := nullif(btrim(v_row.config ->> 'provider'), '');
  v_endpoint := nullif(btrim(v_row.config ->> 'endpoint'), '');
  v_bucket   := nullif(btrim(v_row.config ->> 'bucket'), '');
  v_region   := nullif(btrim(v_row.config ->> 'region'), '');

  if v_provider is null then
    v_ok      := false;
    v_message := '配置不完整：provider / endpoint / bucket 均为必填';
  elsif v_provider not in ('supabase-storage', 's3') then
    v_ok      := false;
    v_message := format('未知 provider：%s（支持 supabase-storage / s3）', v_provider);
  elsif v_provider = 'supabase-storage' then
    -- 走 Supabase Storage 通道：endpoint 可省（默认项目端点），bucket 必须存在
    if v_endpoint is null or v_bucket is null then
      v_ok      := false;
      v_message := '配置不完整：provider / endpoint / bucket 均为必填';
    elsif exists (select 1 from storage.buckets b where b.id = v_bucket) then
      v_ok      := true;
      v_message := format('配置校验通过：bucket「%s」可访问（连通性实测待出站运行时上线后启用）', v_bucket);
    else
      v_ok      := false;
      v_message := format('bucket 不存在或不可访问：%s', v_bucket);
    end if;
  else
    -- S3 兼容通道：目标 bucket 由外部对象存储持有，本地不校验 bucket 存在性；
    -- 校验 endpoint/region/access_key/secret_key 完整性即 verified（真实连通性待出站 ADR）
    if v_row.credentials is not null then
      begin
        v_creds := coalesce(
          nullif(app.decrypt_secret(v_row.credentials), '')::jsonb,
          '{}'::jsonb
        );
      exception when others then
        return app.mark_service_verified(
                 'storage', false,
                 '凭据解密失败，可能密钥已轮换，请重新保存 Access Key / Secret Key'
               )
               || jsonb_build_object(
                    'ok', false,
                    'message', '凭据解密失败，可能密钥已轮换，请重新保存 Access Key / Secret Key',
                    'provider', v_provider,
                    'bucket', v_bucket
                  );
      end;
    end if;

    v_access := nullif(btrim(v_creds ->> 'access_key'), '');
    v_secret := nullif(btrim(v_creds ->> 'secret_key'), '');

    if v_endpoint is null or v_region is null or v_access is null or v_secret is null then
      v_ok      := false;
      v_message := '配置不完整：S3 需 endpoint / region / access_key / secret_key';
    elsif v_endpoint !~* '^https?://' then
      v_ok      := false;
      v_message := format('endpoint 需以 http:// 或 https:// 开头：%s', v_endpoint);
    else
      v_ok      := true;
      v_message := format(
        '配置校验通过：S3 端点 %s / region %s（真实连通性探测待出站运行时 ADR 落地后启用）',
        v_endpoint, v_region
      );
    end if;
  end if;

  return app.mark_service_verified('storage', v_ok, v_message)
         || jsonb_build_object(
              'ok', v_ok,
              'message', v_message,
              'provider', v_provider,
              'bucket', v_bucket
            );
end;
$$;

comment on function app.test_storage_config() is
  '对象存储配置测试验证 RPC（admin）：provider 分派——supabase-storage 校验必填 + '
  'storage.buckets 存在目标 bucket；s3 校验 endpoint(http(s)) / region / access_key / secret_key '
  '完整性即 verified（目标 bucket 在外部对象存储，本地不校验；真实连通性待出站 ADR）；'
  '经 app.mark_service_verified 回写；凭据解密失败 → failed 可读提示';

-- ---------------------------------------------------------------------------
-- 2. app.test_mail_config：补 from_addr 格式 + port 数字范围校验（admin）
-- ---------------------------------------------------------------------------
create or replace function app.test_mail_config(p_to text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row      public.system_services;
  v_host     text;
  v_port     text;
  v_port_num integer;
  v_username text;
  v_from     text;
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
  v_from     := nullif(btrim(v_row.config ->> 'from_addr'), '');

  if v_host is null or v_port is null or v_username is null then
    v_ok      := false;
    v_message := '配置不完整：host / port / username 均为必填';
  else
    -- port 数字/范围校验：CASE 保证仅正则匹配后才 cast（非法输入不触发异常）
    v_port_num := case
                    when v_port ~ '^[1-9][0-9]{0,4}$' then v_port::integer
                    else null
                  end;

    if v_port_num is null or v_port_num > 65535 then
      v_ok      := false;
      v_message := format('端口需为 1-65535 的数字：%s', v_port);
    elsif v_from is not null
          and v_from !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
      v_ok      := false;
      v_message := format('发件人地址格式不正确：%s', v_from);
    else
      v_ok      := true;
      v_message := '配置校验通过（真实发送验证在 Edge Function 投递器上线后启用）';
    end if;
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
  '邮件配置测试验证 RPC（admin）：校验 host/port/username 完整性 + port 数字（1-65535）'
  '+ from_addr 邮箱格式（可选，填写则必须合法）并经 app.mark_service_verified 回写；'
  '本期不做真实 SMTP 发送，p_to 仅记录于审计备注；返回 {ok, message, verify_status, verified_at}';

-- ---------------------------------------------------------------------------
-- 3. app.test_push_config：补钉钉启用加签 Secret 校验（admin）
-- ---------------------------------------------------------------------------
create or replace function app.test_push_config(p_channel text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_channel        text := lower(btrim(p_channel));
  v_row            public.system_services;
  v_webhook        text;
  v_enabled        boolean;
  v_secret         text;
  v_decrypt_failed boolean := false;
  v_ok             boolean;
  v_message        text;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if v_channel is null or v_channel not in ('wecom', 'dingtalk') then
    raise exception '未知推送渠道：%', coalesce(p_channel, '(null)') using errcode = '22023';
  end if;

  select * into v_row
  from public.system_services s
  where s.service = 'push';

  if not found then
    raise exception '推送配置不存在，请先保存配置' using errcode = 'P0002';
  end if;

  v_webhook := nullif(btrim(v_row.config -> v_channel ->> 'webhook_url'), '');
  v_enabled := coalesce((v_row.config -> v_channel -> 'enabled') = 'true'::jsonb, false);

  if v_webhook is null then
    v_ok      := false;
    v_message := '配置不完整：Webhook URL 为必填';
  elsif v_webhook !~* '^https?://' then
    v_ok      := false;
    v_message := 'Webhook URL 需以 http:// 或 https:// 开头';
  elsif not v_enabled then
    v_ok      := false;
    v_message := '渠道未启用：请先打开渠道开关再测试';
  else
    -- 钉钉启用加签时 Secret 必填（services-push.md 功能需求 2）；企业微信 URL key 模式无 secret
    if v_channel = 'dingtalk' then
      if v_row.credentials is not null then
        begin
          v_secret := nullif(
            btrim(coalesce(app.decrypt_secret(v_row.credentials)::jsonb ->> 'dingtalk', '')),
            ''
          );
        exception when others then
          v_decrypt_failed := true;
        end;
      end if;
    end if;

    if v_decrypt_failed then
      v_ok      := false;
      v_message := '钉钉渠道 Secret 解密失败，可能密钥已轮换，请重新保存 Secret';
    elsif v_channel = 'dingtalk' and v_secret is null then
      v_ok      := false;
      v_message := '钉钉渠道启用后需填写加签 Secret（当前未配置）';
    else
      v_ok      := true;
      v_message := '配置校验通过（真实推送待 Webhook 通道接入后启用）';
    end if;
  end if;

  return app.mark_service_verified(
           'push',
           v_ok,
           format('测试推送渠道：%s；%s', v_channel, v_message)
         )
         || jsonb_build_object('ok', v_ok, 'message', v_message, 'channel', v_channel);
end;
$$;

comment on function app.test_push_config(text) is
  '推送渠道测试 RPC（admin）：校验 Webhook URL 完整性、渠道启用状态，钉钉渠道追加'
  '加签 Secret 非空校验（解密失败给出可读提示）并经 app.mark_service_verified 回写；'
  '本期不做真实出站，返回 {ok, message, channel, verify_status, verified_at}'
