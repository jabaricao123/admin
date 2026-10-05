-- audit · 公开 RPC：list_recent_changes（dashboard 批次 1 修复项 1：最近更新直查收敛）
-- 背景：dashboard/page.tsx 原直查 audit_row_versions + profiles（跨模块 join 内部表 +
--   两次往返），违反 INDEX 规则 1（共享数据只经公开面）。本迁移在 audit 域新增公开面：
--   public.list_recent_changes(p_limit) → app.list_recent_changes（SECURITY DEFINER，
--   admin 校验在函数内完成），页面只发一次 RPC 调用。
--
-- 口径：
--   * 按 changed_at desc, id desc 取最近 N 条（p_limit 夹取 1..200，默认 10）；
--   * join profiles 取操作人姓名（full_name；后台调用 changed_by 为空 → NULL）；
--   * change_type 推断与 app.list_recent_versions / app.get_row_versions 对齐：
--       version=1 → insert；末版且记录不存在 → delete；其余 → update。
--   记录存在性逐 (table_name, record_id) 用动态 SQL 探测（表未建按已删除处理）。
--
-- 授权：public 薄包装仅 authenticated；app 实现按 INDEX 规则 10 不 GRANT API 角色
--   （与 20261012040000 收口口径一致，调用只经 public 包装）。
-- 依赖：20261003205350（audit_row_versions）、20261005050000（触发器挂载）、
--       20261006130000（list_recent_versions 的 change_type 推断先例）。

-- ---------------------------------------------------------------------------
-- 1. app.list_recent_changes：全表最近变更列表 + 操作人姓名 + change_type（admin）
-- ---------------------------------------------------------------------------
create function app.list_recent_changes(p_limit integer default 10)
returns table (
  table_name      text,
  record_id       text,
  version         integer,
  change_type     text,
  changed_by_name text,
  changed_at      timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_limit         integer := least(greatest(coalesce(p_limit, 10), 1), 200);
  v_rec           record;
  v_record_exists boolean;
  v_exists_map    jsonb   := '{}'::jsonb;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  -- 记录是否仍存在：只探测窗口内出现的 (table_name, record_id)（≤ v_limit 个），
  -- 表未建时 to_regclass 为 NULL，按已删除处理（与 list_recent_versions 一致）。
  for v_rec in
    select distinct r.table_name, r.record_id
    from (
      select av.table_name, av.record_id, av.changed_at, av.id
      from public.audit_row_versions av
      order by av.changed_at desc, av.id desc
      limit v_limit
    ) r
  loop
    if to_regclass(format('public.%I', v_rec.table_name)) is not null then
      execute format(
        'select exists (select 1 from public.%I s where s.id::text = $1)',
        v_rec.table_name
      )
        into v_record_exists
        using v_rec.record_id;
    else
      v_record_exists := false;
    end if;

    v_exists_map := v_exists_map
      || jsonb_build_object(
           v_rec.table_name || ':' || v_rec.record_id,
           v_record_exists
         );
  end loop;

  return query
  select
    v.table_name,
    v.record_id,
    v.version,
    case
      when v.version = 1 then 'insert'
      when coalesce(
             (v_exists_map ->> (v.table_name || ':' || v.record_id))::boolean,
             false
           ) = false
        and not exists (
          select 1
          from public.audit_row_versions v2
          where v2.table_name = v.table_name
            and v2.record_id = v.record_id
            and v2.version > v.version
        )
        then 'delete'
      else 'update'
    end as change_type,
    p.full_name as changed_by_name,
    v.changed_at
  from public.audit_row_versions v
  left join public.profiles p on p.id = v.changed_by
  order by v.changed_at desc, v.id desc
  limit v_limit;
end;
$$;

comment on function app.list_recent_changes(integer) is
  '最近变更列表 RPC（admin）：跨白名单表按 changed_at desc, id desc 取最近 N 条'
  '（limit 1-200，默认 10）；join profiles 取操作人姓名；'
  'change_type 推断 insert/update/delete（与 list_recent_versions 对齐：末版且记录不存在 = delete）';

-- ---------------------------------------------------------------------------
-- 2. public 薄包装（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.list_recent_changes(p_limit integer default 10)
returns table (
  table_name      text,
  record_id       text,
  version         integer,
  change_type     text,
  changed_by_name text,
  changed_at      timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.list_recent_changes(p_limit)
$$;

comment on function public.list_recent_changes(integer) is
  '最近变更列表 Data API 薄包装（工作台「最近更新」消费；admin only 内部校验）';

-- ---------------------------------------------------------------------------
-- 3. 授权：public 包装仅 authenticated；app 实现不 GRANT API 角色（规则 10）
-- ---------------------------------------------------------------------------
revoke all on function app.list_recent_changes(integer)
  from public, anon, authenticated, service_role;
revoke all on function public.list_recent_changes(integer)
  from public, anon, service_role;
grant execute on function public.list_recent_changes(integer) to authenticated;
