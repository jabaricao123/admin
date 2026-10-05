-- dashboard · 性能三件套 + app 层 EXECUTE 收口 + 待办数封顶修复（dashboard 批次 2 修复项 3/4）
--
-- 1) 索引：profiles(created_at)（signup_trend 范围谓词）、profiles(status)（active 统计）、
--    audit_row_versions(changed_at desc, id desc)（最近更新排序取数）；
-- 2) signup_trend：join 谓词由「(created_at at time zone 'UTC')::date = 日」改范围谓词
--    （created_at >= 当日 00:00 UTC and < 次日 00:00 UTC），sargable 可用 created_at 索引，
--    逐日计数口径不变；
-- 3) org_stats：profiles 三次独立 count 改单趟聚合（count(*) filter）；待办数由
--    app.my_todos(true, 200) 计数（limit 夹取 1..200 会封顶 200）改 SECURITY DEFINER
--    内直查 approval_tasks 的 pending 全量计数（不限量；approval 未合入时软依赖记 0）；
-- 4) app 层 EXECUTE 收口：get_dashboard_stats / signup_trend 的实现层回收 API 角色
--    EXECUTE（对齐 20261012040000 口径），调用只经 public 薄包装。
--
-- 依赖：20261005134000 / 20261005160000（两个 RPC）、20261012110000（get_dashboard_stats
--       已委托 org_stats）、20261004190000（approval_tasks）。

-- ---------------------------------------------------------------------------
-- 1. 索引
-- ---------------------------------------------------------------------------
create index if not exists profiles_created_at_idx
  on public.profiles (created_at);

create index if not exists profiles_status_idx
  on public.profiles (status);

create index if not exists audit_row_versions_changed_at_idx
  on public.audit_row_versions (changed_at desc, id desc);

-- ---------------------------------------------------------------------------
-- 2. app.signup_trend：范围谓词（sargable）
-- ---------------------------------------------------------------------------
create or replace function app.signup_trend(p_days integer default 30)
returns table (day date, count bigint)
language sql
stable
security definer
set search_path = ''
as $$
  with bounds as (
    select
      (now() at time zone 'UTC')::date as today,
      least(greatest(coalesce(p_days, 30), 1), 365) as days
  ),
  days as (
    select (b.today - offs)::date as day
    from bounds b
    cross join generate_series(0, b.days - 1) as offs
  )
  select
    d.day,
    count(p.id) as count
  from days d
  left join public.profiles p
    on p.created_at >= (d.day::timestamp at time zone 'UTC')
   and p.created_at < ((d.day + 1)::timestamp at time zone 'UTC')
  where (select app.current_role()) = 'admin'
  group by d.day
  order by d.day
$$;

comment on function app.signup_trend(integer) is
  '近 N 天注册趋势（UTC 日切分，零值补齐；p_days 夹取 1..365，默认 30）；'
  '仅 admin 返回数据，非 admin 返回空集（前端占位）；'
  'join 采用 created_at 范围谓词（sargable，可用 profiles_created_at_idx）';

-- ---------------------------------------------------------------------------
-- 3. app.org_stats：单趟聚合 + 待办全量计数（去掉 my_todos 200 封顶）
-- ---------------------------------------------------------------------------
create or replace function app.org_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_pending      bigint := 0;
  v_total_users  bigint := 0;
  v_new_week     bigint := 0;
  v_active_users bigint := 0;
begin
  -- 待办数：SECURITY DEFINER 内直查 approval_tasks（不直查他模块内部表由本函数归属方
  -- 承担；替代 app.my_todos(true, 200) 计数——my_todos limit 夹取 1..200 会封顶 200）。
  -- 软依赖保持：approval 未合入时记 0。
  if to_regclass('public.approval_tasks') is not null then
    select count(*)
      into v_pending
      from public.approval_tasks t
     where t.assignee_id = (select auth.uid())
       and t.status = 'pending';
  end if;

  if (select app.current_role()) = 'admin' then
    -- profiles 多口径单趟聚合：total / 本周新增 / active（替代三次独立 count）
    select
      count(*),
      count(*) filter (where p.created_at >= date_trunc('week', now())),
      count(*) filter (where p.status = 'active')
      into v_total_users, v_new_week, v_active_users
      from public.profiles p;

    return jsonb_build_object(
      'is_admin', true,
      'total_users', v_total_users,
      'new_this_week', v_new_week,
      'active_users', v_active_users,
      'total_departments', (
        select count(*)
          from public.departments d
         where d.status <> 'deleted'
      ),
      'total_positions', (select count(*) from public.positions),
      'pending_todos', v_pending
    );
  end if;

  return jsonb_build_object(
    'is_admin', false,
    'own', jsonb_build_object(
      'pending_todos', v_pending
    )
  );
end;
$$;

comment on function app.org_stats() is
  '组织统计聚合（SECURITY DEFINER + 函数内判角色）：admin 全量计数（用户总数/本周新增/活跃用户/'
  '部门数/岗位数，profiles 单趟聚合）+ 本人待办数（approval_tasks pending 全量计数，不封顶）；'
  '非 admin 仅 {is_admin:false, own:{pending_todos}}，不泄露全量计数；'
  '字段与 dashboard get_dashboard_stats 兼容（后者已委托本函数）';

-- ---------------------------------------------------------------------------
-- 4. app 层 EXECUTE 收口（对齐 20261012040000：public 薄包装保留，app 实现不 GRANT）
-- ---------------------------------------------------------------------------
do $$
declare
  v_sig  text;
  v_sigs constant text[] := array[
    'app.get_dashboard_stats()',
    'app.signup_trend(integer)'
  ];
begin
  foreach v_sig in array v_sigs loop
    if to_regprocedure(v_sig) is null then
      raise exception '待收口函数不存在：%', v_sig using errcode = '42883';
    end if;
    execute format(
      'revoke execute on function %s from public, anon, authenticated, service_role',
      v_sig
    );
  end loop;
end $$;
