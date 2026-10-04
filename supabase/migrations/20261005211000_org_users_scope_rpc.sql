-- 组织管理 · 用户列表按数据范围过滤 RPC list_users（access 批次 2 / 修复项 2）
--
-- 背景：app.scope_user_ids() 落地后尚无消费方，本迁移提供首个消费方入口。
-- 语义：
--   - admin：全量（搜索/筛选/分页与现状一致）；
--   - 非 admin：p.id in (select app.scope_user_ids())，无会话 / 账号非 active /
--     角色未配置 scope 时自然返回空集（fail-closed，与 helper 语义一致）；
--   - 支持搜索（姓名/邮箱）、角色、状态、部门筛选与分页；
--   - 返回 {total, rows}：total 为过滤后全量计数，rows 为当前页（join 部门/岗位/
--     角色名称，含 compat 期 role 枚举兜底）。
--
-- 决策（access 批次 2 复核）：/org/users 页面守卫保持 admin-only（用户管理是
-- 管理功能，非 admin 无入口），本次仅落地 RPC（infra 就绪）。首个消费方为
-- list_users；页面接入待「非 admin 用户目录」场景立项后切换数据源。
--
-- 约定：业务实现放 app schema；public.list_users 为 Data API 薄包装（INDEX 规则 6/10）；
-- 两者 SECURITY DEFINER + search_path = '' + 全限定名引用。
--
-- 依赖：20261004170000（scope helper）、20261004140000（部门/岗位外键）、
--       20261004100000（profiles.role_id 兼容双写）、20261003145513（profiles.email）。

create function app.list_users(
  p_search        text default null,
  p_role          text default null,
  p_status        text default null,
  p_department_id uuid default null,
  p_limit         integer default 20,
  p_offset        integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_is_admin boolean := coalesce((select app.current_role()) = 'admin', false);
  v_search   text    := nullif(btrim(coalesce(p_search, '')), '');
  v_role     text    := nullif(btrim(coalesce(p_role, '')), '');
  v_status   text    := nullif(btrim(coalesce(p_status, '')), '');
  v_limit    integer := least(greatest(coalesce(p_limit, 20), 1), 200);
  v_offset   integer := greatest(coalesce(p_offset, 0), 0);
  v_total    bigint;
  v_rows     jsonb;
begin
  select
    count(*),
    coalesce(
      jsonb_agg(t.row_data order by t.created_at desc, t.id)
        filter (where t.rn > v_offset and t.rn <= v_offset + v_limit),
      '[]'::jsonb
    )
  into v_total, v_rows
  from (
    select
      row_number() over (order by p.created_at desc, p.id) as rn,
      jsonb_build_object(
        'id',              p.id,
        'full_name',       p.full_name,
        'email',           p.email,
        'status',          p.status::text,
        'role',            p.role::text,
        'role_id',         p.role_id,
        'role_code',       coalesce(r.code, p.role::text),
        'role_name',       coalesce(r.name, p.role::text),
        'department',      p.department,
        'department_id',   p.department_id,
        'department_name', d.name,
        'position_id',     p.position_id,
        'position_name',   pos.name,
        'created_at',      p.created_at,
        'updated_at',      p.updated_at
      ) as row_data,
      p.created_at,
      p.id
    from public.profiles p
    left join public.roles r
      on r.id = coalesce(
           p.role_id,
           (select r2.id from public.roles r2 where r2.code = p.role::text)
         )
    left join public.departments d on d.id = p.department_id
    left join public.positions pos on pos.id = p.position_id
    where (v_is_admin or p.id in (select app.scope_user_ids()))
      and (
        v_search is null
        or strpos(lower(coalesce(p.full_name, '')), lower(v_search)) > 0
        or strpos(lower(coalesce(p.email, '')), lower(v_search)) > 0
      )
      and (v_role is null or coalesce(r.code, p.role::text) = v_role)
      and (v_status is null or p.status::text = v_status)
      and (p_department_id is null or p.department_id = p_department_id)
  ) t;

  return jsonb_build_object('total', v_total, 'rows', v_rows);
end;
$$;

comment on function app.list_users(text, text, text, uuid, integer, integer) is
  '用户列表 RPC（scope helper 首个消费方）：admin 全量；非 admin 按 app.scope_user_ids() '
  '过滤（fail-closed）；支持姓名/邮箱搜索、角色/状态/部门筛选与分页；'
  '返回 {total, rows}（行 join 部门/岗位/角色名称）。页面接入待「非 admin 用户目录」场景立项';

-- ---------------------------------------------------------------------------
-- public 包装层（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.list_users(
  p_search        text default null,
  p_role          text default null,
  p_status        text default null,
  p_department_id uuid default null,
  p_limit         integer default 20,
  p_offset        integer default 0
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select app.list_users(
    p_search, p_role, p_status, p_department_id, p_limit, p_offset
  )
$$;

comment on function public.list_users(text, text, text, uuid, integer, integer) is
  '用户列表 Data API 薄包装（scope 过滤在 app.list_users 内；页面接入待立项）';

-- ---------------------------------------------------------------------------
-- 授权：实现不直接暴露；包装层仅 authenticated（非 admin 由 scope 过滤约束）
-- ---------------------------------------------------------------------------
revoke all on function
  app.list_users(text, text, text, uuid, integer, integer)
  from public, anon, authenticated, service_role;

revoke all on function
  public.list_users(text, text, text, uuid, integer, integer)
  from public, anon;
grant execute on function
  public.list_users(text, text, text, uuid, integer, integer)
  to authenticated;
