-- 接口/集成中心 · Webhook 启停与脱敏列表（工单 integration/006 页面配套增量）
-- 契约：docs/modules/integration/webhooks.md（列表含创建人；自定义 header 脱敏显示、
--       明文/密文均不下发）、docs/modules/INDEX.md 规则 2（审计摘要）、规则 4（凭据保护）。
-- 组成：
--   1. app.enable_webhook：admin 启用 RPC（004 仅有 disable_webhook，配对补齐）；
--   2. app.get_webhooks：admin 列表口（headers_masked = 原键 + ''****'' 掩码值；
--      不下发 headers_enc 密文，弹窗编辑时展示脱敏后的存量 header）；
--   3. public 薄包装与授权（仅 authenticated；admin 校验在 app 实现内）。
-- 说明：004 已合入迁移不动；本迁移为 006 页面的最小增量（enable 缺失 + 列表掩码口）。
--
-- 依赖：integration/004（webhooks 表 / app.mask_jsonb_values）、system/001（app.decrypt_secret）、
--       audit/001（app.audit_log）、init_profiles（app.current_role / app.set_updated_at）。

-- ---------------------------------------------------------------------------
-- 1. app.enable_webhook：admin 启用（与 app.disable_webhook 成对；启用后可再收事件）
-- ---------------------------------------------------------------------------
create function app.enable_webhook(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev public.webhooks;
  v_row  public.webhooks;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_prev
  from public.webhooks
  where id = p_id
  for update;

  if not found then
    raise exception 'Webhook 不存在：%', coalesce(p_id::text, '(null)') using errcode = 'P0002';
  end if;

  update public.webhooks
     set status     = 'active',
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  perform app.audit_log(
    'integration', 'enable', 'webhook', v_row.id::text,
    jsonb_build_object(
      'name', v_row.name,
      'status_before', v_prev.status,
      'status_after', v_row.status
    )
  );

  return jsonb_build_object(
    'id', v_row.id,
    'name', v_row.name,
    'status', v_row.status,
    'updated_at', v_row.updated_at
  );
end;
$$;

comment on function app.enable_webhook(uuid) is
  'Webhook 启用 RPC（admin）：status=active；emit_event 匹配 active 端点，启用后恢复收事件；'
  '与 app.disable_webhook 成对，写审计摘要（enable/webhook）';

-- ---------------------------------------------------------------------------
-- 2. app.get_webhooks：admin 列表口（脱敏 headers，不下发 secret/header 密文）
-- ---------------------------------------------------------------------------
create function app.get_webhooks()
returns table (
  id             uuid,
  name           text,
  url            text,
  events         text[],
  retry_policy   jsonb,
  headers_masked jsonb,
  status         text,
  created_by     uuid,
  updated_by     uuid,
  created_at     timestamptz,
  updated_at     timestamptz
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
    w.id,
    w.name,
    w.url,
    w.events,
    w.retry_policy,
    case
      when w.headers_enc is null then null
      else app.mask_jsonb_values(app.decrypt_secret(w.headers_enc)::jsonb)
    end as headers_masked,
    w.status,
    w.created_by,
    w.updated_by,
    w.created_at,
    w.updated_at
  from public.webhooks w
  order by w.created_at desc, w.id;
end;
$$;

comment on function app.get_webhooks() is
  'Webhook 列表口（admin）：返回管理字段与 headers_masked（''****'' + 明文尾 4 位）；'
  'secret_enc/headers_enc 密文与明文一律不下发；编辑弹窗据此脱敏展示存量自定义 header';

-- ---------------------------------------------------------------------------
-- 3. public 薄包装（PostgREST 仅暴露 public schema；admin 校验在 app 实现内）
-- ---------------------------------------------------------------------------
create function public.enable_webhook(p_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.enable_webhook(p_id)
$$;

create function public.get_webhooks()
returns table (
  id             uuid,
  name           text,
  url            text,
  events         text[],
  retry_policy   jsonb,
  headers_masked jsonb,
  status         text,
  created_by     uuid,
  updated_by     uuid,
  created_at     timestamptz,
  updated_at     timestamptz
)
language sql
security definer
set search_path = ''
as $$
  select * from app.get_webhooks()
$$;

comment on function public.enable_webhook(uuid) is
  'enable_webhook Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.get_webhooks() is
  'get_webhooks Data API 薄包装（admin 校验在 app 实现内；headers 仅掩码）';

-- ---------------------------------------------------------------------------
-- 4. 授权：仅 authenticated（函数内 admin 校验）；anon/public 无路径
-- ---------------------------------------------------------------------------
revoke all on function app.enable_webhook(uuid) from public, anon;
grant execute on function app.enable_webhook(uuid) to authenticated;

revoke all on function app.get_webhooks() from public, anon;
grant execute on function app.get_webhooks() to authenticated;

revoke all on function public.enable_webhook(uuid) from public, anon;
grant execute on function public.enable_webhook(uuid) to authenticated;

revoke all on function public.get_webhooks() from public, anon;
grant execute on function public.get_webhooks() to authenticated;
