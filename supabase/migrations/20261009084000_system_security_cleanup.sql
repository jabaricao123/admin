-- 系统管理 · 批次 4 并入：service_role 序列清理 + cron 登记审计
-- 1. service_role 序列清理（ADR-001 全局禁令的序列面）：system_cron_registry、
--    system_setting_history 等 identity 序列在迁移期未显式 revoke，Supabase 默认权限
--    使 service_role 仍持 USAGE/SELECT/UPDATE；本迁移对 public 全部序列幂等收回。
--    说明：do 块只覆盖存量序列；后续新序列仍须在各自迁移内 revoke（先例：message/001）。
-- 2. cron 审计：register_cron_job / unregister_cron_job 是平台登记唯一写入口，
--    此前无留痕；补 app.audit_log('system','register'/'disable','cron_job',...)。
-- 依赖：20261005080000（registry RPC 现状）、app.audit_log（audit/001）。

-- ---------------------------------------------------------------------------
-- 1. service_role 序列零权限（幂等：对无权限序列 revoke 为空操作）
-- ---------------------------------------------------------------------------
do $$
declare
  v_seq record;
begin
  for v_seq in
    select c.oid::regclass as seq
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where c.relkind = 'S'
      and n.nspname = 'public'
  loop
    execute format('revoke all on sequence %s from service_role', v_seq.seq);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 2. app.register_cron_job：登记写审计
-- ---------------------------------------------------------------------------
create or replace function app.register_cron_job(
  p_job_name    text,
  p_module      text,
  p_cron        text,
  p_tz          text,
  p_owner_route text
)
returns public.system_cron_registry
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job_name text := btrim(coalesce(p_job_name, ''));
  v_module   text := btrim(coalesce(p_module, ''));
  v_cron     text := btrim(coalesce(p_cron, ''));
  v_tz       text := coalesce(nullif(btrim(coalesce(p_tz, '')), ''), 'Asia/Shanghai');
  v_route    text := btrim(coalesce(p_owner_route, ''));
  v_parts    text[];
  v_row      public.system_cron_registry;
begin
  if v_job_name = '' then
    raise exception 'job 名不能为空' using errcode = '22023';
  end if;
  if v_module = '' then
    raise exception '模块标识不能为空' using errcode = '22023';
  end if;
  if v_cron = '' then
    raise exception 'cron 表达式不能为空' using errcode = '22023';
  end if;

  v_parts := regexp_split_to_array(v_cron, '\s+');
  if array_length(v_parts, 1) <> 5 then
    raise exception 'cron 表达式需为五段（分 时 日 月 周）：%', v_cron using errcode = '22023';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_timezone_names t where t.name = v_tz
  ) then
    raise exception '未知时区：%', v_tz using errcode = '22023';
  end if;

  if v_route = '' or v_route !~ '^/' then
    raise exception 'owner_route 需为模块路由（以 / 开头）' using errcode = '22023';
  end if;

  insert into public.system_cron_registry
    (job_name, module, cron_expr, timezone, owner_route, status, registered_by)
  values
    (v_job_name, v_module, v_cron, v_tz, v_route, 'active', (select auth.uid()))
  on conflict (job_name) do update
    set module        = excluded.module,
        cron_expr     = excluded.cron_expr,
        timezone      = excluded.timezone,
        owner_route   = excluded.owner_route,
        -- 重新登记视为恢复有效；注销仅置 disabled
        status        = 'active',
        -- 保留首个登记人（迁移回填为 NULL 时由首次调用者补位）
        registered_by = coalesce(public.system_cron_registry.registered_by, excluded.registered_by)
  returning * into v_row;

  perform app.audit_log(
    'system', 'register', 'cron_job', v_job_name,
    jsonb_build_object(
      'module', v_module,
      'cron_expr', v_cron,
      'timezone', v_tz,
      'owner_route', v_route
    )
  );

  return v_row;
end;
$$;

comment on function app.register_cron_job(text, text, text, text, text) is
  '登记/更新 pg_cron job 元数据（幂等 upsert，重登记恢复 active）并写审计'
  '（system/register/cron_job）；模块迁移内调用或后端 SECURITY DEFINER wrapper 调用；'
  '不 GRANT authenticated（INDEX 规则 10）';

-- ---------------------------------------------------------------------------
-- 3. app.unregister_cron_job：注销写审计
-- ---------------------------------------------------------------------------
create or replace function app.unregister_cron_job(p_job_name text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job_name text := btrim(coalesce(p_job_name, ''));
  v_row      public.system_cron_registry;
  v_found    boolean;
begin
  if v_job_name = '' then
    raise exception 'job 名不能为空' using errcode = '22023';
  end if;

  update public.system_cron_registry
     set status = 'disabled'
   where job_name = v_job_name
  returning * into v_row;

  -- 不存在时幂等返回 false（模块注销流程不因登记缺失而失败）
  v_found := found;

  perform app.audit_log(
    'system', 'disable', 'cron_job', v_job_name,
    jsonb_build_object('found', v_found)
  );

  return v_found;
end;
$$;

comment on function app.unregister_cron_job(text) is
  '注销登记（置 disabled，历史保留；不存在幂等返回 false）并写审计'
  '（system/disable/cron_job）；不 GRANT API 角色（INDEX 规则 10）';
