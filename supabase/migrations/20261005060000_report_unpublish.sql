-- 报表中心 · 自定义报表「取消发布」补齐（工单 report/004）
-- 契约：docs/modules/report/custom.md「admin 可发布为公共报表」的对称操作——
--       已发布报表需可撤回（visibility public → private），否则误发布无法回滚。
--   1. app.unpublish_report_definition：仅 admin；public → private（幂等）；写审计；
--   2. public.unpublish_report_definition：Data API 薄包装（INDEX 规则 10，权限判定在 app 内）。
-- 依赖：report/002 表与 publish RPC（20261005000000）、audit/001 app.audit_log。

-- ---------------------------------------------------------------------------
-- 1. app.unpublish_report_definition：取消发布（仅 admin；已是 private 则幂等）
-- ---------------------------------------------------------------------------
create function app.unpublish_report_definition(p_def_id uuid)
returns public.report_definitions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.report_definitions;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可取消发布公共报表' using errcode = '42501';
  end if;

  update public.report_definitions
     set visibility = 'private',
         updated_by = (select auth.uid())
   where id = p_def_id
  returning * into v_row;

  if not found then
    raise exception '报表定义不存在' using errcode = 'P0002';
  end if;

  perform app.audit_log(
    'report', 'unpublish', 'report_definition', p_def_id::text,
    jsonb_build_object('name', v_row.name, 'owner_id', v_row.owner_id)
  );

  return v_row;
end;
$$;

comment on function app.unpublish_report_definition(uuid) is
  '取消发布（仅 admin）：visibility=public → private，幂等（已是 private 直接返回）；'
  '写审计；内部实现，经 public 薄包装暴露';

-- ---------------------------------------------------------------------------
-- 2. public 薄包装（PostgREST 仅暴露 public schema；INDEX 规则 10）
-- ---------------------------------------------------------------------------
create function public.unpublish_report_definition(p_def_id uuid)
returns public.report_definitions
language sql
security definer
set search_path = ''
as $$
  select app.unpublish_report_definition(p_def_id)
$$;

comment on function public.unpublish_report_definition(uuid) is
  'unpublish_report_definition Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 3. 授权：默认全撤，仅 public 包装给 authenticated
-- ---------------------------------------------------------------------------
revoke all on function app.unpublish_report_definition(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.unpublish_report_definition(uuid)
  from public, anon, authenticated, service_role;

grant execute on function public.unpublish_report_definition(uuid) to authenticated;
