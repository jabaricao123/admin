-- audit/007 + org/011：数据变更页面底座 —— 快照触发器挂载 + 白名单/查询 RPC
-- 工单：audit/007（数据变更页面）、org/011（audit 快照触发器接入）
--
-- 1) 给首期白名单三表（profiles/departments/positions）挂
--    AFTER INSERT OR UPDATE OR DELETE 触发器，统一调用 audit/006 的
--    app.audit_row_version_trigger()（INSERT 首版 version=1；白名单 enabled 闸门）；
-- 2) 白名单管理 RPC（admin）：upsert_row_version_whitelist —— 写 audit_log；
--    启用「尚无触发器」的表时返回提示：触发器 DDL 无法动态生效，需另建迁移挂载；
-- 3) 查询 RPC（admin）：get_row_versions（单记录全部版本按 version 排序，含变更类型）、
--    list_recent_versions（该表最近变更列表，join 操作人姓名）。
--
-- 不改 audit_row_versions 结构（append-only 快照表）。

-- ---------------------------------------------------------------------------
-- 1. 触发器挂载（org/011）：白名单三表；触发器名字面量，每表独立
-- ---------------------------------------------------------------------------
create trigger profiles_row_versions
after insert or update or delete on public.profiles
for each row
execute function app.audit_row_version_trigger();

comment on trigger profiles_row_versions on public.profiles is
  'audit 行版本快照（audit/007 挂载）：AFTER INSERT/UPDATE/DELETE → app.audit_row_version_trigger()';

create trigger departments_row_versions
after insert or update or delete on public.departments
for each row
execute function app.audit_row_version_trigger();

comment on trigger departments_row_versions on public.departments is
  'audit 行版本快照（audit/007 挂载）：AFTER INSERT/UPDATE/DELETE → app.audit_row_version_trigger()';

create trigger positions_row_versions
after insert or update or delete on public.positions
for each row
execute function app.audit_row_version_trigger();

comment on trigger positions_row_versions on public.positions is
  'audit 行版本快照（audit/007 挂载）：AFTER INSERT/UPDATE/DELETE → app.audit_row_version_trigger()';

-- ---------------------------------------------------------------------------
-- 2. RPC：白名单管理（admin）
--    两步走：本 RPC 只登记/开关白名单；启用尚未挂触发器的表时返回 notice 提示
--    「需另建迁移挂触发器」，配置无法动态生效（静态 DDL）。
-- ---------------------------------------------------------------------------
create function app.upsert_row_version_whitelist(
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

  return jsonb_build_object(
    'table_name', v_table,
    'enabled', v_enabled,
    'trigger_installed', v_has_trigger,
    'notice', v_notice
  );
end;
$$;

comment on function app.upsert_row_version_whitelist(text, boolean) is
  '白名单管理 RPC（admin）：登记/开关留痕表并写 audit_log；返回 trigger_installed 与 notice'
  '（启用尚未挂触发器的表时提示需另建迁移；触发器 DDL 无法动态生效）';

-- ---------------------------------------------------------------------------
-- 3. RPC：单记录版本序列（admin）
--    白名单三表均有 id 主键；查询记录当前是否仍存在以区分 delete 快照。
-- ---------------------------------------------------------------------------
create function app.get_row_versions(
  p_table     text,
  p_record_id text
)
returns table (
  id              bigint,
  version         integer,
  data            jsonb,
  changed_by      uuid,
  changed_by_name text,
  changed_at      timestamptz,
  change_type     text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_table  text    := lower(btrim(coalesce(p_table, '')));
  v_exists boolean := false;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if v_table = '' then
    raise exception '表名不能为空' using errcode = '22023';
  end if;

  if coalesce(p_record_id, '') = '' then
    raise exception '记录标识不能为空' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.audit_row_version_whitelist w
    where w.table_name = v_table
  ) then
    raise exception '表 % 不在数据变更白名单中', v_table using errcode = '22023';
  end if;

  -- 记录是否仍存在（区分「删除前快照」）；白名单表均有 id 主键列。
  -- %I 防注入；表未建时 to_regclass 为 NULL，按已删除处理。
  if to_regclass(format('public.%I', v_table)) is not null then
    execute format(
      'select exists (select 1 from public.%I s where s.id::text = $1)',
      v_table
    )
      into v_exists
      using p_record_id;
  end if;

  return query
  select
    v.id,
    v.version,
    v.data,
    v.changed_by,
    p.full_name,
    v.changed_at,
    case
      when v.version = 1 then 'insert'
      when not v_exists and v.version = max(v.version) over () then 'delete'
      else 'update'
    end
  from public.audit_row_versions v
  left join public.profiles p on p.id = v.changed_by
  where v.table_name = v_table
    and v.record_id = p_record_id
  order by v.version;
end;
$$;

comment on function app.get_row_versions(text, text) is
  '单记录全部版本 RPC（admin）：按 version 升序；change_type 推断 insert/update/delete'
  '（delete = 记录已不存在且为末版）；join profiles 取操作人姓名';

-- ---------------------------------------------------------------------------
-- 4. RPC：最近变更列表（admin）
-- ---------------------------------------------------------------------------
create function app.list_recent_versions(
  p_table text,
  p_limit integer default 50
)
returns table (
  id              bigint,
  version         integer,
  record_id       text,
  data            jsonb,
  changed_by      uuid,
  changed_by_name text,
  changed_at      timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_table text    := lower(btrim(coalesce(p_table, '')));
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if v_table = '' then
    raise exception '表名不能为空' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.audit_row_version_whitelist w
    where w.table_name = v_table
  ) then
    raise exception '表 % 不在数据变更白名单中', v_table using errcode = '22023';
  end if;

  return query
  select
    v.id,
    v.version,
    v.record_id,
    v.data,
    v.changed_by,
    p.full_name,
    v.changed_at
  from public.audit_row_versions v
  left join public.profiles p on p.id = v.changed_by
  where v.table_name = v_table
  order by v.changed_at desc, v.id desc
  limit v_limit;
end;
$$;

comment on function app.list_recent_versions(text, integer) is
  '最近变更列表 RPC（admin）：按时间倒序（limit 1-200，默认 50）；join profiles 取操作人姓名';

-- ---------------------------------------------------------------------------
-- 5. public 包装层（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.upsert_row_version_whitelist(
  p_table   text,
  p_enabled boolean
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.upsert_row_version_whitelist(p_table, p_enabled)
$$;

create function public.get_row_versions(
  p_table     text,
  p_record_id text
)
returns table (
  id              bigint,
  version         integer,
  data            jsonb,
  changed_by      uuid,
  changed_by_name text,
  changed_at      timestamptz,
  change_type     text
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.get_row_versions(p_table, p_record_id)
$$;

create function public.list_recent_versions(
  p_table text,
  p_limit integer default 50
)
returns table (
  id              bigint,
  version         integer,
  record_id       text,
  data            jsonb,
  changed_by      uuid,
  changed_by_name text,
  changed_at      timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.list_recent_versions(p_table, p_limit)
$$;

-- ---------------------------------------------------------------------------
-- 6. 授权：仅 authenticated 可执行；实现内部再做 admin 校验（INDEX 规则 10）
-- ---------------------------------------------------------------------------
revoke all on function app.upsert_row_version_whitelist(text, boolean) from public, anon;
grant execute on function app.upsert_row_version_whitelist(text, boolean) to authenticated;

revoke all on function app.get_row_versions(text, text) from public, anon;
grant execute on function app.get_row_versions(text, text) to authenticated;

revoke all on function app.list_recent_versions(text, integer) from public, anon;
grant execute on function app.list_recent_versions(text, integer) to authenticated;

revoke all on function public.upsert_row_version_whitelist(text, boolean) from public, anon;
grant execute on function public.upsert_row_version_whitelist(text, boolean) to authenticated;

revoke all on function public.get_row_versions(text, text) from public, anon;
grant execute on function public.get_row_versions(text, text) to authenticated;

revoke all on function public.list_recent_versions(text, integer) from public, anon;
grant execute on function public.list_recent_versions(text, integer) to authenticated;
