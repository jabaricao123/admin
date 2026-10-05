-- 接口/集成中心 · 批次 1 安全修复补充：调用日志分区表权限收口（service_role 零直读）
-- 背景：integration_call_logs 的分区表（integration_call_logs_YYYY_MM）在 public schema、
--       RLS 关闭；Supabase 默认权限给 service_role（BYPASSRLS）留下了 SELECT。父表上的
--       revoke（20261007092000）不影响分区直读，存在绕过路径。
-- 本迁移：
--   1. 对既有全部分区 revoke all（public/anon/authenticated/service_role）；
--   2. create or replace app.ensure_integration_call_log_partition：新建分区后同样收口
--      （访问一律经父表 + 父表 RLS/授权；分区不直接暴露给 API 角色）。
-- 说明：RLS 仍保持在父表收口；分区层以「零授权」阻断直读（service_role bypassrls，
--       故不能只依赖 RLS）。父表权限与策略不变。

-- ---------------------------------------------------------------------------
-- 1. 既有分区：撤销全部 API 角色权限
-- ---------------------------------------------------------------------------
do $do$
declare
  v_part record;
begin
  for v_part in
    select c.relname
    from pg_catalog.pg_class c
    join pg_catalog.pg_inherits i on i.inhrelid = c.oid
    where i.inhparent = 'public.integration_call_logs'::regclass
  loop
    execute format(
      'revoke all on table public.%I from public, anon, authenticated, service_role',
      v_part.relname
    );
  end loop;
end
$do$;

-- ---------------------------------------------------------------------------
-- 2. 分区确保函数：新建/既存分区均收口（其余逻辑不变，签名不变）
-- ---------------------------------------------------------------------------
create or replace function app.ensure_integration_call_log_partition(p_month date default current_date)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_month date := date_trunc('month', coalesce(p_month, current_date))::date;
  v_name  text := 'integration_call_logs_' || to_char(v_month, 'YYYY_MM');
begin
  if to_regclass(format('public.%I', v_name)) is null then
    begin
      execute format(
        'create table public.%I partition of public.integration_call_logs for values from (%L) to (%L)',
        v_name, v_month, (v_month + interval '1 month')::date
      );
    exception when duplicate_table then
      null; -- 并发下另一会话已建：幂等
    end;
  end if;

  -- 分区不直接暴露给 API 角色：访问经父表（授权 + RLS 收口）；service_role 禁数据面
  execute format(
    'revoke all on table public.%I from public, anon, authenticated, service_role',
    v_name
  );

  return v_name;
end;
$$;

comment on function app.ensure_integration_call_log_partition(date) is
  '确保集成调用日志的月分区存在（integration_call_logs_YYYY_MM，幂等）；'
  '分区不直接 GRANT API 角色（访问经父表授权 + RLS；service_role bypassrls 故零授权阻断）；'
  '写入路径 log_integration_call 自动调用；不 GRANT API 角色';
