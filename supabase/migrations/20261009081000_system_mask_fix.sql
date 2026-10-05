-- 系统管理 · 批次 1 安全修复 2：短凭据掩码统一（get_service_status / get_push_status）
-- 背景：两处脱敏展示固定 '****' || right(plain, 4)——长度 ≤8 的凭据会被暴露最多一半
--       （4/8），薄弱凭据等于半公开；与 sync 20261009070000 的掩码口径不一致。
-- 方案：明文长度 ≤8 仅返回 '****'（不泄露尾段）；>8 仍 '****' + 尾 4 位（对齐 sync）。
-- 签名不变（create or replace），ACL 与 public 薄包装不动。
-- 依赖：20261004151000（get_service_status 现状）、20261005150000（get_push_status 现状）。

-- ---------------------------------------------------------------------------
-- 1. app.get_service_status：掩码 ≤8 全掩
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
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  return query
  select
    s.service,
    s.config,
    case
      when s.credentials is null then null
      when length(d.plain) <= 8 then '****'
      else '****' || right(d.plain, 4)
    end as credentials_masked,
    s.verify_status,
    s.verified_at,
    s.updated_by,
    s.updated_at
  from public.system_services s
  left join lateral (
    select app.decrypt_secret(s.credentials) as plain
  ) d on true
  order by s.service;
end;
$$;

comment on function app.get_service_status() is
  '服务配置脱敏展示 RPC（admin）：凭据掩码在函数内计算——明文长度 ≤8 仅 ''****'''
  '（不泄露尾段），>8 为 ''****'' + 明文尾 4 位；不下发明文/密文；'
  '所有 service 行按 service 升序返回';

-- ---------------------------------------------------------------------------
-- 2. app.get_push_status：双渠道掩码 ≤8 全掩
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
  v_row     public.system_services;
  v_secrets jsonb := '{}'::jsonb;
  v_channel text;
  v_items   text[] := array['wecom', 'dingtalk'];
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.system_services s
  where s.service = 'push';

  if found and v_row.credentials is not null then
    -- 凭据为每渠道 secret 的加密 JSON；解析失败按「未配置」处理（不因脏数据阻断页面）
    begin
      v_secrets := coalesce(
        nullif(app.decrypt_secret(v_row.credentials), '')::jsonb,
        '{}'::jsonb
      );
    exception when others then
      v_secrets := '{}'::jsonb;
    end;
  end if;

  foreach v_channel in array v_items loop
    channel       := v_channel;
    webhook_url   := nullif(btrim(v_row.config -> v_channel ->> 'webhook_url'), '');
    enabled       := coalesce(
                       (v_row.config -> v_channel -> 'enabled') = 'true'::jsonb,
                       false
                     );
    secret_masked := case
                       when v_secrets ->> v_channel is null
                            or btrim(v_secrets ->> v_channel) = ''
                       then null
                       when length(v_secrets ->> v_channel) <= 8 then '****'
                       else '****' || right(v_secrets ->> v_channel, 4)
                     end;
    return next;
  end loop;
end;
$$;

comment on function app.get_push_status() is
  '推送配置脱敏读取 RPC（admin）：返回 wecom/dingtalk 双渠道 webhook_url、enabled 与 '
  'secret 掩码——明文长度 ≤8 仅 ''****''（不泄露尾段），>8 为 ''****'' + 明文尾 4 位；'
  '密文在函数内解密、明文不出函数；行不存在时返回两行空配置';
