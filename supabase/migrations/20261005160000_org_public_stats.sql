-- 组织管理 · 公开统计 RPC（org/013）
-- 工单：org/013（org_stats() / signup_trend(p_days) / department_headcount() 公开 RPC）
--
-- 契约：docs/modules/org/AGENT.md 013、docs/modules/org/chart.md（组织架构图消费
--       department_headcount）、docs/modules/report/builtin.md（部门分布/人员统计）、
--       docs/modules/dashboard/overview.md（org_stats/signup_trend 后续切换）。
--
-- 与 dashboard/001+004（20261005134000_dashboard_stats.sql）的关系（收敛 TODO）：
--   * dashboard 先发布 get_dashboard_stats()/signup_trend() 作为过渡实现；本迁移是
--     org 域公开面：org_stats() 与 get_dashboard_stats 字段兼容（is_admin /
--     total_users / new_this_week / active_users / pending_todos + own.pending_todos），
--     并补充组织计数，dashboard 概览可无改动切换；
--   * signup_trend() 由本迁移 create or replace 为 org 域归属（签名与行为与
--     20261005134000 完全一致，dashboard 页面与既有测试不受影响）；
--   * 收敛 TODO（不在本迁移执行）：dashboard/001 切换 org_stats/signup_trend 后，
--     评估删除 app/public.get_dashboard_stats 与重复的 signup_trend 定义，
--     保留哪一侧由 dashboard 工单决定，避免破坏 dashboard 现状。
--
-- 口径：
--   org_stats：SECURITY DEFINER + 函数内判角色——admin 返回全量计数；非 admin 仅
--     {is_admin:false, own:{pending_todos}}，不泄露全局计数（同 dashboard_stats）。
--     待办数经 approval 公开 RPC app.my_todos 计数（软依赖：未合入时记 0，
--     同 approval 引擎对 emit_event 的先例）。
--   signup_trend：UTC 日切分、零值补齐、p_days 夹取 1..365；仅 admin 返回数据，
--     非 admin 空集（前端按需要管理员权限占位）。
--   department_headcount：返回每个未删除部门的「在岗人数」与「岗位编制」，
--     均含子部门聚合（按 departments_v.path 前缀归属，与 report/部门分布前端
--     聚合口径一致：在岗按 department_id 精确 + 文本兜底；编制为启用岗位
--     headcount 之和）。登录可读（组织架构图节点人数）。
--
-- 依赖：app.current_role()（init_profiles）、departments_v（org/001）、
--       profiles.department_id（org/007 双写）、app.my_todos（approval，软依赖）。

-- ---------------------------------------------------------------------------
-- 1. app.org_stats：组织统计聚合（admin 全量 / 非 admin own 两支）
-- ---------------------------------------------------------------------------
create function app.org_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_pending bigint := 0;
begin
  -- 待办数：approval 公开 RPC（不直查 approval 内部表）；软依赖未合入时记 0
  if to_regprocedure('app.my_todos(boolean,integer)') is not null then
    select count(*) into v_pending
    from app.my_todos(true, 200);
  end if;

  if (select app.current_role()) = 'admin' then
    return jsonb_build_object(
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
  '部门数/岗位数）+ 本人待办数；非 admin 仅 {is_admin:false, own:{pending_todos}}，不泄露全量计数；'
  '字段与 dashboard get_dashboard_stats 兼容（收敛 TODO 见迁移头）';

-- ---------------------------------------------------------------------------
-- 2. app.signup_trend：近 N 天注册趋势（org/013 起 org 域归属；行为与 dashboard 一致）
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
  '仅 admin 返回数据，非 admin 返回空集（前端占位）；org/013 起 org 域归属，'
  '实现与 dashboard 20261005134000 一致（收敛 TODO 见迁移头）';

-- ---------------------------------------------------------------------------
-- 3. app.department_headcount：部门人数/编制聚合（含子部门；登录可读）
--    在岗：profiles.status=active，按 department_id 精确 + department 文本兜底；
--    编制：positions.status=active 的 headcount 之和；
--    子部门：departments_v.path 前缀归属（'%' 同 path 或 path + '/' 前缀）。
-- ---------------------------------------------------------------------------
create function app.department_headcount()
returns table (
  department_id      uuid,
  name               text,
  path               text,
  headcount          bigint,
  position_headcount bigint
)
language sql
stable
security definer
set search_path = ''
as $$
  with dept as (
    select v.id, v.name, v.path
    from public.departments_v v
  )
  select
    d.id as department_id,
    d.name,
    d.path,
    (
      select count(*)
      from dept s
      join public.profiles p
        on (p.department_id is not null and p.department_id = s.id)
        or (p.department_id is null and p.department is not null and p.department = s.name)
      where p.status = 'active'
        and (
          s.path = d.path
          or left(s.path, length(d.path) + 1) = d.path || '/'
        )
    ) as headcount,
    (
      select coalesce(sum(pos.headcount), 0)::bigint
      from dept s
      join public.positions pos on pos.department_id = s.id
      where pos.status = 'active'
        and (
          s.path = d.path
          or left(s.path, length(d.path) + 1) = d.path || '/'
        )
    ) as position_headcount
  from dept d
  order by d.path, d.id
$$;

comment on function app.department_headcount() is
  '部门人数聚合：每个未删除部门返回 department_id/name/path/headcount（在岗人数，含子部门）/'
  'position_headcount（启用岗位编制之和，含子部门）；在岗按 department_id 精确统计、'
  'NULL 行按 department 文本兜底；子部门按 departments_v.path 前缀归属；登录可读（组织架构图/报表）';

-- ---------------------------------------------------------------------------
-- 4. public 薄包装（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.org_stats()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select app.org_stats()
$$;

create or replace function public.signup_trend(p_days integer default 30)
returns table (day date, count bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.signup_trend(p_days)
$$;

create function public.department_headcount()
returns table (
  department_id      uuid,
  name               text,
  path               text,
  headcount          bigint,
  position_headcount bigint
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.department_headcount()
$$;

comment on function public.org_stats() is 'org_stats Data API 薄包装（工作台/报表消费）';
comment on function public.signup_trend(integer) is
  'signup_trend Data API 薄包装（工作台注册趋势消费；与 dashboard 同签名同行为）';
comment on function public.department_headcount() is
  'department_headcount Data API 薄包装（组织架构图/部门分布消费）';

-- ---------------------------------------------------------------------------
-- 5. 授权：仅 authenticated（anon 拒绝）；create or replace 保留既有 ACL，此处重申自洽
-- ---------------------------------------------------------------------------
revoke all on function app.org_stats() from public, anon;
revoke all on function app.signup_trend(integer) from public, anon;
revoke all on function app.department_headcount() from public, anon;
revoke all on function public.org_stats() from public, anon;
revoke all on function public.signup_trend(integer) from public, anon;
revoke all on function public.department_headcount() from public, anon;

grant execute on function app.org_stats() to authenticated;
grant execute on function app.signup_trend(integer) to authenticated;
grant execute on function app.department_headcount() to authenticated;
grant execute on function public.org_stats() to authenticated;
grant execute on function public.signup_trend(integer) to authenticated;
grant execute on function public.department_headcount() to authenticated;
