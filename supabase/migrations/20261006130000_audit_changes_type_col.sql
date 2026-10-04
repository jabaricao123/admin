-- audit 批次 1 / 修复项 3：list_recent_versions 返回列补 change_type
--
-- 问题：数据变更页「最近变更」列表缺少变更类型（insert/update/delete），
--   与「版本时间线」（get_row_versions 已含 change_type）不一致，前端无法渲染类型 Badge。
-- 修复：重建 app.list_recent_versions / public.list_recent_versions，
--   在返回列追加 change_type，推断逻辑与 app.get_row_versions 对齐：
--     - version = 1 → insert；
--     - 记录已不存在且为该记录末版（max(version) over (partition by record_id)）→ delete；
--     - 其余 → update。
--   删除判定按记录是否存在：候选窗口内逐 record_id 用动态 SQL 探测白名单表（id::text = record_id，
--   表不存在时按已删除处理，与 get_row_versions 一致）。
-- 注意：RETURNS TABLE 列变化不能 create or replace，先 drop public 包装再 drop app 实现后重建；
--   重建后重新 GRANT（仅 authenticated，admin 校验在函数内）。
-- 依赖：20261005050000（audit_mount_triggers：原版 list_recent_versions / get_row_versions）。

-- ---------------------------------------------------------------------------
-- 1. 先删依赖方：public 薄包装 → app 实现（避免依赖阻塞）
-- ---------------------------------------------------------------------------
drop function if exists public.list_recent_versions(text, integer);
drop function if exists app.list_recent_versions(text, integer);

-- ---------------------------------------------------------------------------
-- 2. app.list_recent_versions：最近变更列表 + change_type（admin）
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
  changed_at      timestamptz,
  change_type     text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_table        text    := lower(btrim(coalesce(p_table, '')));
  v_limit        integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_table_exists boolean;
  v_rec          record;
  v_record_exists boolean;
  v_exists_map   jsonb   := '{}'::jsonb;
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

  -- 记录是否仍存在：逐个 record_id 探测（白名单表均有 id 主键列；%I 防注入）。
  -- 表未建时 to_regclass 为 NULL，按已删除处理（与 get_row_versions 一致）。
  v_table_exists := to_regclass(format('public.%I', v_table)) is not null;

  if v_table_exists then
    for v_rec in
      select distinct r.record_id
      from (
        select v.record_id
        from public.audit_row_versions v
        where v.table_name = v_table
        order by v.changed_at desc, v.id desc
        limit v_limit
      ) r
    loop
      execute format(
        'select exists (select 1 from public.%I s where s.id::text = $1)',
        v_table
      )
        into v_record_exists
        using v_rec.record_id;

      v_exists_map := v_exists_map
        || jsonb_build_object(v_rec.record_id, v_record_exists);
    end loop;
  end if;

  return query
  select
    v.id,
    v.version,
    v.record_id,
    v.data,
    v.changed_by,
    p.full_name,
    v.changed_at,
    case
      when v.version = 1 then 'insert'
      when coalesce((v_exists_map ->> v.record_id)::boolean, false) = false
        and v.version = max(v.version) over (partition by v.record_id) then 'delete'
      else 'update'
    end
  from public.audit_row_versions v
  left join public.profiles p on p.id = v.changed_by
  where v.table_name = v_table
  order by v.changed_at desc, v.id desc
  limit v_limit;
end;
$$;

comment on function app.list_recent_versions(text, integer) is
  '最近变更列表 RPC（admin）：按时间倒序（limit 1-200，默认 50）；join profiles 取操作人姓名；'
  'change_type 推断 insert/update/delete（与 get_row_versions 对齐：末版且记录不存在 = delete）';

-- ---------------------------------------------------------------------------
-- 3. public 薄包装（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
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
  changed_at      timestamptz,
  change_type     text
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.list_recent_versions(p_table, p_limit)
$$;

comment on function public.list_recent_versions(text, integer) is
  '最近变更列表 Data API 薄包装：追加 change_type（insert/update/delete）';

-- ---------------------------------------------------------------------------
-- 4. 授权：仅 authenticated 可执行；实现内部再做 admin 校验（INDEX 规则 10）
-- ---------------------------------------------------------------------------
revoke all on function app.list_recent_versions(text, integer) from public, anon;
grant execute on function app.list_recent_versions(text, integer) to authenticated;

revoke all on function public.list_recent_versions(text, integer) from public, anon;
grant execute on function public.list_recent_versions(text, integer) to authenticated;
