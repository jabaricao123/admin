-- 系统管理 · 短信模板登记表（工单 system/005）
-- 契约：docs/modules/system/services-sms.md（模板管理：模板 ID 登记表——名称、场景、模板 code、
--       状态；只登记，不管理服务商后台）；docs/modules/INDEX.md 规则 2（审计摘要统一入口）、
--       规则 10（管理 RPC 函数内 admin 校验）。
--
-- 组成：
--   1. public.system_sms_templates：短信模板登记表（id/name/scene/provider_code/status +
--      created_by/updated_by/created_at/updated_at）；不承载发送语义，仅登记服务商后台模板；
--   2. 管理 RPC（admin）：upsert_sms_template（id 为空 = 新建；否则更新，模板 id 建后不可改）、
--      disable_sms_template（停用）；均写 audit 摘要；
--   3. RLS：登录可读表级 SELECT + admin 读策略（写全经 SECURITY DEFINER RPC，无表级写权限）。
--
-- 依赖：app.set_updated_at()（init_profiles）、app.audit_log（audit/001）、app.current_role。

-- ---------------------------------------------------------------------------
-- 1. system_sms_templates：模板登记表
-- ---------------------------------------------------------------------------
create table public.system_sms_templates (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  scene         text not null,
  provider_code text not null,
  status        text not null default 'active',
  created_by    uuid,
  updated_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint system_sms_templates_name_check
    check (length(btrim(name)) > 0),
  constraint system_sms_templates_scene_check
    check (length(btrim(scene)) > 0),
  constraint system_sms_templates_provider_code_check
    check (length(btrim(provider_code)) > 0),
  constraint system_sms_templates_status_check
    check (status in ('active', 'disabled'))
);

comment on table public.system_sms_templates is
  '短信模板登记表：登记服务商后台已审核模板（名称/场景/模板 code/状态），'
  '只登记不管理服务商后台；写仅经 admin RPC，读取需 admin（RLS）';
comment on column public.system_sms_templates.id is '模板登记 id（PK，建后不可改）';
comment on column public.system_sms_templates.name is '模板名称（业务可读名，如「验证码通知」）';
comment on column public.system_sms_templates.scene is '使用场景（如 login_code / approval_notice）';
comment on column public.system_sms_templates.provider_code is '服务商后台模板 code（阿里云/腾讯云控制台登记值）';
comment on column public.system_sms_templates.status is 'active 启用 / disabled 停用（停用不影响服务商后台模板）';
comment on column public.system_sms_templates.created_by is '创建人（弱关联 auth.users）';
comment on column public.system_sms_templates.updated_by is '最近修改人（弱关联 auth.users）';
comment on column public.system_sms_templates.updated_at is '最近修改时间（触发器维护）';

create trigger system_sms_templates_set_updated_at
before update on public.system_sms_templates
for each row
execute function app.set_updated_at();

alter table public.system_sms_templates enable row level security;

-- ---------------------------------------------------------------------------
-- 2. 管理 RPC（admin；公开面为 public 同名薄包装）
-- ---------------------------------------------------------------------------
create function app.upsert_sms_template(
  p_id            uuid,
  p_name          text,
  p_scene         text,
  p_provider_code text,
  p_status        text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name     text := btrim(p_name);
  v_scene    text := btrim(p_scene);
  v_code     text := btrim(p_provider_code);
  v_status   text := coalesce(nullif(btrim(p_status), ''), 'active');
  v_prev     public.system_sms_templates;
  v_row      public.system_sms_templates;
  v_created  boolean;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if v_name is null or v_name = '' then
    raise exception '模板名称不能为空' using errcode = '22023';
  end if;
  if v_scene is null or v_scene = '' then
    raise exception '模板场景不能为空' using errcode = '22023';
  end if;
  if v_code is null or v_code = '' then
    raise exception '模板 code 不能为空' using errcode = '22023';
  end if;
  if v_status not in ('active', 'disabled') then
    raise exception '非法模板状态：%', v_status using errcode = '22023';
  end if;

  if p_id is null then
    insert into public.system_sms_templates
      (name, scene, provider_code, status, created_by, updated_by)
    values
      (v_name, v_scene, v_code, v_status, (select auth.uid()), (select auth.uid()))
    returning * into v_row;
    v_created := true;
  else
    select * into v_prev
    from public.system_sms_templates t
    where t.id = p_id
    for update;

    if not found then
      raise exception '短信模板不存在：%', p_id using errcode = 'P0002';
    end if;

    update public.system_sms_templates
       set name          = v_name,
           scene         = v_scene,
           provider_code = v_code,
           status        = v_status,
           updated_by    = (select auth.uid())
     where id = p_id
    returning * into v_row;
    v_created := false;
  end if;

  perform app.audit_log(
    'system', 'upsert', 'sms_template', v_row.id::text,
    jsonb_build_object(
      'created', v_created,
      'name', v_row.name,
      'scene', v_row.scene,
      'provider_code', v_row.provider_code,
      'status_before', case when v_created then null else v_prev.status end,
      'status_after', v_row.status
    )
  );

  return jsonb_build_object(
    'id', v_row.id,
    'name', v_row.name,
    'scene', v_row.scene,
    'provider_code', v_row.provider_code,
    'status', v_row.status,
    'created', v_created,
    'updated_at', v_row.updated_at
  );
end;
$$;

comment on function app.upsert_sms_template(uuid, text, text, text, text) is
  '短信模板登记 RPC（admin）：p_id 为空 = 新建，否则按 id 更新（id 建后不可改）；'
  'name/scene/provider_code 必填，status ∈ active|disabled；均写审计摘要';

create function app.disable_sms_template(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev public.system_sms_templates;
  v_row  public.system_sms_templates;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_prev
  from public.system_sms_templates t
  where t.id = p_id
  for update;

  if not found then
    raise exception '短信模板不存在：%', coalesce(p_id::text, '(null)') using errcode = 'P0002';
  end if;

  update public.system_sms_templates
     set status = 'disabled',
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  perform app.audit_log(
    'system', 'disable', 'sms_template', v_row.id::text,
    jsonb_build_object('status_before', v_prev.status, 'status_after', v_row.status)
  );

  return jsonb_build_object(
    'id', v_row.id,
    'status', v_row.status,
    'updated_at', v_row.updated_at
  );
end;
$$;

comment on function app.disable_sms_template(uuid) is
  '短信模板停用 RPC（admin）：置 status=disabled（幂等，重新启用走 upsert）；'
  '仅本登记表状态变化，不影响服务商后台模板';

-- ---------------------------------------------------------------------------
-- 3. public 薄包装（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.upsert_sms_template(
  p_id            uuid,
  p_name          text,
  p_scene         text,
  p_provider_code text,
  p_status        text
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.upsert_sms_template(p_id, p_name, p_scene, p_provider_code, p_status)
$$;

create function public.disable_sms_template(p_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.disable_sms_template(p_id)
$$;

comment on function public.upsert_sms_template(uuid, text, text, text, text) is
  'upsert_sms_template Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.disable_sms_template(uuid) is
  'disable_sms_template Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 4. 授权与 RLS：登录可读（RLS 再收口 admin）；写仅经 SECURITY DEFINER RPC
-- ---------------------------------------------------------------------------
revoke all on public.system_sms_templates from public, anon, authenticated, service_role;

grant select on public.system_sms_templates to authenticated;

create policy system_sms_templates_select_admin
on public.system_sms_templates
for select
to authenticated
using ((select app.current_role()) = 'admin');

revoke all on function app.upsert_sms_template(uuid, text, text, text, text) from public, anon;
revoke all on function app.disable_sms_template(uuid) from public, anon;
revoke all on function public.upsert_sms_template(uuid, text, text, text, text) from public, anon;
revoke all on function public.disable_sms_template(uuid) from public, anon;

grant execute on function app.upsert_sms_template(uuid, text, text, text, text) to authenticated;
grant execute on function app.disable_sms_template(uuid) to authenticated;
grant execute on function public.upsert_sms_template(uuid, text, text, text, text) to authenticated;
grant execute on function public.disable_sms_template(uuid) to authenticated;
