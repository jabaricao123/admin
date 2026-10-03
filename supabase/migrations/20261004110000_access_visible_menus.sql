-- 权限管理 · visible_menus RPC（sidebar 数据源，fail-open 兜底）（access/006）
-- 工单：access/006（依赖 access/005：menu_items + role_menu_grants）
--
-- 契约（docs/modules/access/permissions.md「数据模型」）：
--   返回当前登录用户可见菜单树（key/parent_key/module/label/route/sort_order），
--   并附 fallback 列标识本次结果是否走了「零授权兜底」。
--
-- 可见性规则：
--   1. admin 角色：全量菜单（不读授权表），fallback = false；
--   2. 其他角色：role_menu_grants 授权集 + 祖先链补全（授权的叶子自动带出
--      parent 链，保证侧边栏父子结构完整且不泄漏未授权兄弟），fallback = false；
--   3. fail-open 兜底：角色可解析且 role_menu_grants 零记录时返回全量菜单，
--      fallback = true（过渡期默认可见；前端据此提示「未配置授权，暂显全部」）；
--   4. fail-closed 边界：无角色（未建档 / 档案停用 / auth.uid() 为空）返回空集
--      ——「零授权兜底」只适用于能解析出角色的用户，未识别身份不默认放行。
--
-- 其他约定：
--   - SECURITY DEFINER + set search_path = '' + 全限定名（INDEX「RLS 统一声明模板」）；
--   - stable：只读 menu_items / role_menu_grants，事务内结果稳定；
--   - 排序：sort_order 升序、同序按 key 兜底，结果确定可测；
--   - 本 RPC 只做可见性过滤；服务端路由守卫与数据层 RLS 仍为最终防线
--     （permissions.md 验收：三层一致）。
--
-- 依赖：20261004091000（menu_items / role_menu_grants）、
--       20261004100000（app.current_role 优先读 role_id）。

-- ---------------------------------------------------------------------------
-- 1. app.visible_menus：可见性计算唯一实现
-- ---------------------------------------------------------------------------
create function app.visible_menus()
returns table (
  key        text,
  parent_key text,
  module     text,
  label      text,
  route      text,
  sort_order integer,
  fallback   boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  with recursive
  me as (
    select app.current_role()::text as role_code
  ),
  my_role as (
    select r.id
    from public.roles r
    join me on me.role_code = r.code
  ),
  mode as (
    select
      me.role_code,
      mr.id as role_id,
      (mr.id is not null and exists (
        select 1
        from public.role_menu_grants g
        where g.role_id = mr.id
      )) as has_grants
    from me
    left join my_role mr on true
  ),
  flags as (
    select
      (role_code is not null
       and (role_code = 'admin' or (role_id is not null and not has_grants))) as is_full,
      (role_code is not null and role_code <> 'admin'
       and role_id is not null and not has_grants) as is_fallback
    from mode
  ),
  seed_keys as (
    -- admin / 零授权兜底：全量种子
    select mi.key
    from public.menu_items mi
    where (select is_full from flags)

    union

    -- 常规路径：本角色授权集种子
    select g.menu_key
    from public.role_menu_grants g
    join mode m on m.role_id = g.role_id
    where not (select is_full from flags)
  ),
  closure as (
    -- 祖先链补全：从种子向上走到顶级（union 去重并防环）
    select s.key, s.key as item_key
    from seed_keys s

    union

    select c.key, mi.parent_key
    from closure c
    join public.menu_items mi on mi.key = c.item_key
    where mi.parent_key is not null
  )
  select distinct
    mi.key,
    mi.parent_key,
    mi.module,
    mi.label,
    mi.route,
    mi.sort_order,
    (select is_fallback from flags) as fallback
  from closure c
  join public.menu_items mi on mi.key = c.item_key
  order by mi.sort_order, mi.key
$$;

comment on function app.visible_menus() is
  '当前用户可见菜单树（sidebar 数据源）：admin 全量；其他角色按 role_menu_grants + 祖先链；'
  '角色零授权 fail-open 全量并置 fallback=true；无角色返回空集（fail-closed）';

-- ---------------------------------------------------------------------------
-- 2. public 薄包装（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.visible_menus()
returns table (
  key        text,
  parent_key text,
  module     text,
  label      text,
  route      text,
  sort_order integer,
  fallback   boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.visible_menus()
$$;

comment on function public.visible_menus() is
  'visible_menus Data API 薄包装（PostgREST 仅暴露 public schema）';

-- ---------------------------------------------------------------------------
-- 3. 权限：仅 authenticated 可执行（anon 无路径）
-- ---------------------------------------------------------------------------
revoke all on function app.visible_menus() from public, anon;
grant execute on function app.visible_menus() to authenticated;

revoke all on function public.visible_menus() from public, anon;
grant execute on function public.visible_menus() to authenticated;
