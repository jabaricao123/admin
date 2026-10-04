-- dashboard/001+004：工作台聚合统计（get_dashboard_stats / signup_trend）
--
-- 背景：org/013（org_stats/signup_trend 公开 RPC）尚未合入，工作台概览的统计
--       与注册趋势先由本模块发布自有聚合 RPC；口径固定为「RPC 内完成范围过滤、
--       页面不做二次计算」，待 org/013 合入后可评估收敛（对页面签名保持兼容）。
--
-- 范围过滤：
--   get_dashboard_stats：admin 返回全量统计（用户总数 / 本周新增 / 活跃用户）
--     + 当前用户待处理待办数；非 admin 仅返回 {is_admin:false, own:{pending_todos}}，
--     不泄露全量计数。
--   signup_trend：admin 返回近 N 天（零值补齐）注册计数；非 admin 返回空集，
--     前端按「需要管理员权限」占位（与 report 操作活跃度一致模式）。
--
-- 待办数口径：经 approval 公开 RPC app.my_todos 计数（不直查 approval 内部表）；
--   个人待办检索上限 200，个人待办数超过 200 的极端场景计数封顶。

-- ---------------------------------------------------------------------------
-- 1. app.get_dashboard_stats：工作台统计聚合
-- ---------------------------------------------------------------------------
create function app.get_dashboard_stats()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when (select app.current_role()) = 'admin' then
      jsonb_build_object(
        'is_admin', true,
        'total_users', (select count(*) from public.profiles),
        'new_this_week', (
          select count(*)
            from public.profiles p
           where p.created_at >= date_trunc('week', now())
        ),
        'active_users', (
          select count(*)
            from public.profiles p
           where p.status = 'active'
        ),
        'pending_todos', (select count(*) from app.my_todos(true, 200))
      )
    else
      jsonb_build_object(
        'is_admin', false,
        'own', jsonb_build_object(
          'pending_todos', (select count(*) from app.my_todos(true, 200))
        )
      )
  end
$$;

comment on function app.get_dashboard_stats() is
  '工作台统计聚合（SECURITY DEFINER + 函数内判角色）：admin 全量计数（用户总数/本周新增/活跃用户）+ 本人待办数；'
  '非 admin 仅 {is_admin:false, own:{pending_todos}}，不泄露全量计数';

-- ---------------------------------------------------------------------------
-- 2. app.signup_trend：近 N 天注册趋势（按 UTC 日切分，零值补齐）
-- ---------------------------------------------------------------------------
create function app.signup_trend(p_days integer default 30)
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
  )
  select
    g.day::date as day,
    count(p.id) as count
  from bounds b
  cross join lateral generate_series(
    b.today - (b.days - 1), b.today, interval '1 day'
  ) as g(day)
  left join public.profiles p
    on (p.created_at at time zone 'UTC')::date = g.day::date
  where (select app.current_role()) = 'admin'
  group by g.day
  order by g.day
$$;

comment on function app.signup_trend(integer) is
  '近 N 天注册趋势（UTC 日切分，零值补齐；p_days 夹取 1..365，默认 30）；'
  '仅 admin 返回数据，非 admin 返回空集（前端占位）';

-- ---------------------------------------------------------------------------
-- 3. public 薄包装（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.get_dashboard_stats()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select app.get_dashboard_stats()
$$;

create function public.signup_trend(p_days integer default 30)
returns table (day date, count bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.signup_trend(p_days)
$$;

comment on function public.get_dashboard_stats() is 'get_dashboard_stats Data API 薄包装（工作台概览消费）';
comment on function public.signup_trend(integer) is 'signup_trend Data API 薄包装（工作台注册趋势消费）';

-- ---------------------------------------------------------------------------
-- 4. 权限：仅 authenticated 可执行（anon 拒绝）
-- ---------------------------------------------------------------------------
revoke all on function app.get_dashboard_stats() from public, anon;
revoke all on function app.signup_trend(integer) from public, anon;
revoke all on function public.get_dashboard_stats() from public, anon;
revoke all on function public.signup_trend(integer) from public, anon;

grant execute on function app.get_dashboard_stats() to authenticated;
grant execute on function app.signup_trend(integer) to authenticated;
grant execute on function public.get_dashboard_stats() to authenticated;
grant execute on function public.signup_trend(integer) to authenticated;
