-- 审计中心 · 白名单 upsert 幂等（audit 批次 2 修复项 2）
-- 问题：app.upsert_row_version_whitelist 每次调用（含 enabled 未变化的重复开关）
--   都写一条 audit_log，管理页反复保存/刷新即产生噪声审计。
-- 修复：create or replace 该函数——before = after（enabled 未变化）时跳过 audit_log，
--   仅在实际创建或状态变化时留痕；返回值与触发器挂载检测逻辑不变。
-- 依赖：20261005050000_audit_mount_triggers.sql（当前版函数）。
-- 注意：public 薄包装委托 app 实现，无需重建。

-- ---------------------------------------------------------------------------
-- create or replace：白名单管理 RPC（admin；enabled 未变化时幂等跳过审计）
-- ---------------------------------------------------------------------------
create or replace function app.upsert_row_version_whitelist(
  p_table   text,
  p_enabled boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_table       text    := lower(btrim(coalesce(p_table, '')));
  v_enabled     boolean := coalesce(p_enabled, true);
  v_before      boolean;
  v_found       boolean;
  v_changed     boolean;
  v_has_trigger boolean;
  v_notice      text;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if v_table = '' then
    raise exception '表名不能为空' using errcode = '22023';
  end if;

  if v_table !~ '^[a-z_][a-z0-9_]*$' then
    raise exception '表名不合法：%', p_table using errcode = '22023';
  end if;

  select w.enabled into v_before
  from public.audit_row_version_whitelist w
  where w.table_name = v_table;
  v_found := found;

  -- 幂等判据：新建（无 before）或 enabled 实际变化才写审计；重复相同 upsert 跳过
  v_changed := not v_found or v_before is distinct from v_enabled;

  insert into public.audit_row_version_whitelist (table_name, enabled, created_by)
  values (v_table, v_enabled, (select auth.uid()))
  on conflict (table_name) do update
    set enabled = excluded.enabled;

  -- 触发器挂载检测：tgfoid = 通用快照函数；排除内部触发器
  select exists (
    select 1
    from pg_catalog.pg_trigger t
    join pg_catalog.pg_class c on c.oid = t.tgrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = v_table
      and not t.tgisinternal
      and t.tgfoid = 'app.audit_row_version_trigger()'::pg_catalog.regprocedure
  ) into v_has_trigger;

  if v_enabled and not v_has_trigger then
    v_notice := '已登记白名单；表 ' || v_table
      || ' 尚未挂载快照触发器，需另建迁移执行 create trigger ... '
      || 'execute function app.audit_row_version_trigger() 后才会产生快照';
  end if;

  if v_changed then
    perform app.audit_log(
      'audit',
      case when v_found then 'update' else 'create' end,
      'row_version_whitelist',
      v_table,
      jsonb_build_object(
        'before', case when v_found
                       then jsonb_build_object('enabled', v_before)
                       else null::jsonb
                  end,
        'after', jsonb_build_object('enabled', v_enabled)
      )
    );
  end if;

  return jsonb_build_object(
    'table_name', v_table,
    'enabled', v_enabled,
    'trigger_installed', v_has_trigger,
    'notice', v_notice
  );
end;
$$;

comment on function app.upsert_row_version_whitelist(text, boolean) is
  '白名单管理 RPC（admin）：登记/开关留痕表；返回 trigger_installed 与 notice'
  '（启用尚未挂触发器的表时提示需另建迁移；触发器 DDL 无法动态生效）。'
  '幂等：enabled 未变化（before = after）的重复 upsert 跳过 audit_log 写入；'
  '仅新建或状态变化时写审计。';
