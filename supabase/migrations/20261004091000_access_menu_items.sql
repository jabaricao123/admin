-- 权限管理 · menu_items 注册表 + 全 10 模块路由级 seed + role_menu_grants（access/005，M0 底座）
-- 工单：access/005
--
-- 约定（对齐 docs/modules/INDEX.md 与 docs/modules/access/permissions.md）：
--   1. menu_items：菜单点注册表。路由级 key = 路由（如 '/org/users'）；按钮级 key =
--      module.menu.button，由各模块交付时经 register_menu_item 登记或迁移内直接 INSERT；
--   2. seed 数据源 = docs/modules/README.md 各模块子菜单表；未交付模块照 seed（矩阵「未激活」
--      由 007 页面处理，数据层不区分）。工作台「概览」路由即 /dashboard，与顶级「工作台」
--      同 key，合并为一条，不再重复登记；
--   3. role_menu_grants：角色 ↔ 菜单授权（矩阵勾选的事实源），主键 (role_id, menu_key)；
--   4. register_menu_item：内部登记入口，SECURITY DEFINER + search_path = '' + 全限定名；
--      不 GRANT 任何 API 角色（INDEX 规则 10），仅 postgres（属主）可执行——各模块交付时
--      在迁移内 INSERT 或经后端 SECURITY DEFINER wrapper（同属主）调用；upsert 幂等；
--   5. grant_menu/revoke_menu：admin 专用管理 RPC（GRANT authenticated + 内部校验 admin）；
--      仅实际变更写 audit 摘要，幂等重放不重复记账；admin 角色授予允许（矩阵 UI 锁定由页面处理）；
--   6. RLS：menu_items 登录用户只读全部（矩阵渲染需要）；role_menu_grants admin 全量只读、
--      其他角色只读本角色授权行（预览用）；两表无任何角色表级写，写仅经 RPC/迁移。

-- ---------------------------------------------------------------------------
-- 1. menu_items：菜单点注册表
-- ---------------------------------------------------------------------------
create table public.menu_items (
  key         text primary key,
  parent_key  text references public.menu_items (key),
  module      text not null,
  label       text not null,
  route       text,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now()
);

comment on table public.menu_items is
  '菜单点注册表（路由级 key=路由，按钮级 key=module.menu.button；写经 register_menu_item/迁移）';
comment on column public.menu_items.key is '菜单点唯一标识：路由级=路由（如 /org/users）；按钮级=module.menu.button';
comment on column public.menu_items.parent_key is '父菜单 key（null=顶级菜单），自引用 menu_items.key';
comment on column public.menu_items.module is '所属模块标识（dashboard/org/access/...）';
comment on column public.menu_items.label is '菜单显示名称';
comment on column public.menu_items.route is '前端路由（顶级目录=模块根路径；按钮级可空）';
comment on column public.menu_items.sort_order is '同父级内排序（升序）';

create index menu_items_parent_key_idx
  on public.menu_items (parent_key);

-- ---------------------------------------------------------------------------
-- 2. seed：全 10 模块路由级菜单（顶级 10 条 + 子菜单 44 条 = 54 条）
--    数据源：docs/modules/README.md 各模块「子菜单 | 路由」表，路由逐字一致
--    （/org/* 而非 /organization/*；/settings/users 旧路径不登记）
-- ---------------------------------------------------------------------------
insert into public.menu_items (key, parent_key, module, label, route, sort_order)
values
  -- 顶级目录（10）
  ('/dashboard',   null, 'dashboard',   '工作台',         '/dashboard',   10),
  ('/org',         null, 'org',         '组织管理',       '/org',         20),
  ('/access',      null, 'access',      '权限管理',       '/access',      30),
  ('/approval',    null, 'approval',    '审批中心',       '/approval',    40),
  ('/report',      null, 'report',      '报表中心',       '/report',      50),
  ('/audit',       null, 'audit',       '审计中心',       '/audit',       60),
  ('/integration', null, 'integration', '接口/集成中心',  '/integration', 70),
  ('/sync',        null, 'sync',        '第三方数据同步', '/sync',        80),
  ('/system',      null, 'system',      '系统管理',       '/system',      90),
  ('/message',     null, 'message',     '消息中心',       '/message',    100),

  -- 工作台（概览 /dashboard 与顶级同 key 合并，此处仅登记其余 2 条）
  ('/dashboard/todos',         '/dashboard', 'dashboard', '我的待办', '/dashboard/todos',         10),
  ('/dashboard/notifications', '/dashboard', 'dashboard', '我的通知', '/dashboard/notifications', 20),

  -- 组织管理
  ('/org/users',       '/org', 'org', '用户管理',   '/org/users',       10),
  ('/org/departments', '/org', 'org', '部门管理',   '/org/departments', 20),
  ('/org/positions',   '/org', 'org', '岗位管理',   '/org/positions',   30),
  ('/org/chart',       '/org', 'org', '组织架构图', '/org/chart',       40),

  -- 权限管理
  ('/access/roles',       '/access', 'access', '角色管理',   '/access/roles',       10),
  ('/access/permissions', '/access', 'access', '菜单权限',   '/access/permissions', 20),
  ('/access/data-scopes', '/access', 'access', '数据权限',   '/access/data-scopes', 30),
  ('/access/audit',       '/access', 'access', '权限审计',   '/access/audit',       40),

  -- 审批中心
  ('/approval/todo',      '/approval', 'approval', '我的待办', '/approval/todo',      10),
  ('/approval/mine',      '/approval', 'approval', '我发起的', '/approval/mine',      20),
  ('/approval/cc',        '/approval', 'approval', '抄送我的', '/approval/cc',        30),
  ('/approval/templates', '/approval', 'approval', '审批模板', '/approval/templates', 40),
  ('/approval/flows',     '/approval', 'approval', '审批流程', '/approval/flows',     50),

  -- 报表中心
  ('/report/builtin',       '/report', 'report', '预置报表', '/report/builtin',       10),
  ('/report/custom',        '/report', 'report', '自定义报表', '/report/custom',      20),
  ('/report/subscriptions', '/report', 'report', '报表订阅', '/report/subscriptions', 30),
  ('/report/exports',       '/report', 'report', '数据导出', '/report/exports',       40),

  -- 审计中心
  ('/audit/operations', '/audit', 'audit', '操作日志', '/audit/operations', 10),
  ('/audit/logins',     '/audit', 'audit', '登录日志', '/audit/logins',     20),
  ('/audit/changes',    '/audit', 'audit', '数据变更', '/audit/changes',    30),
  ('/audit/compliance', '/audit', 'audit', '合规报告', '/audit/compliance', 40),

  -- 接口/集成中心
  ('/integration/api-keys', '/integration', 'integration', 'API 密钥',  '/integration/api-keys', 10),
  ('/integration/webhooks', '/integration', 'integration', 'Webhook',   '/integration/webhooks', 20),
  ('/integration/logs',     '/integration', 'integration', '调用日志',  '/integration/logs',     30),
  ('/integration/docs',     '/integration', 'integration', '接口文档',  '/integration/docs',     40),

  -- 第三方数据同步
  ('/sync/sources',   '/sync', 'sync', '数据源配置', '/sync/sources',   10),
  ('/sync/tasks',     '/sync', 'sync', '同步任务',   '/sync/tasks',     20),
  ('/sync/runs',      '/sync', 'sync', '执行记录',   '/sync/runs',      30),
  ('/sync/schedules', '/sync', 'sync', '调度管理',   '/sync/schedules', 40),

  -- 系统管理（/system/services/* 直接挂 /system 下）
  ('/system/services/mail',    '/system', 'system', '邮件服务',   '/system/services/mail',    10),
  ('/system/services/storage', '/system', 'system', '对象存储',   '/system/services/storage', 20),
  ('/system/services/sms',     '/system', 'system', '短信服务',   '/system/services/sms',     30),
  ('/system/services/push',    '/system', 'system', '消息推送',   '/system/services/push',    40),
  ('/system/services/auth',    '/system', 'system', '身份认证',   '/system/services/auth',    50),
  ('/system/settings',         '/system', 'system', '参数配置',   '/system/settings',         60),
  ('/system/dictionaries',     '/system', 'system', '字典管理',   '/system/dictionaries',     70),
  ('/system/jobs',             '/system', 'system', '定时任务',   '/system/jobs',             80),
  ('/system/announcements',    '/system', 'system', '公告管理',   '/system/announcements',    90),
  ('/system/about',            '/system', 'system', '关于/版本',  '/system/about',           100),

  -- 消息中心
  ('/message/inbox',     '/message', 'message', '站内信',   '/message/inbox',     10),
  ('/message/templates', '/message', 'message', '通知模板', '/message/templates', 20),
  ('/message/history',   '/message', 'message', '发送记录', '/message/history',   30)
on conflict (key) do update
  set parent_key = excluded.parent_key,
      module     = excluded.module,
      label      = excluded.label,
      route      = excluded.route,
      sort_order = excluded.sort_order;

-- ---------------------------------------------------------------------------
-- 3. role_menu_grants：角色 ↔ 菜单授权
-- ---------------------------------------------------------------------------
create table public.role_menu_grants (
  role_id    uuid not null
             references public.roles (id) on delete cascade,
  menu_key   text not null
             references public.menu_items (key),
  granted_by uuid,
  granted_at timestamptz not null default now(),
  primary key (role_id, menu_key)
);

comment on table public.role_menu_grants is
  '角色 ↔ 菜单授权（矩阵勾选事实源；写仅经 grant_menu/revoke_menu RPC）';
comment on column public.role_menu_grants.role_id is '角色 id（roles.id；角色删除级联清理授权）';
comment on column public.role_menu_grants.menu_key is '菜单点 key（menu_items.key；菜单项无删除入口，不设级联）';
comment on column public.role_menu_grants.granted_by is '授权人（弱关联 auth.users，不设外键以保留追溯）';
comment on column public.role_menu_grants.granted_at is '授权时间';

create index role_menu_grants_menu_key_idx
  on public.role_menu_grants (menu_key);

-- ---------------------------------------------------------------------------
-- 4. RPC：register_menu_item（菜单登记唯一入口；不 GRANT API 角色）
--    路由级：register_menu_item('/org/users', '/org', 'org', '用户管理', '/org/users', 10)
--    按钮级：register_menu_item('org.users.create', '/org/users', 'org', '新建用户', null, 10)
-- ---------------------------------------------------------------------------
create function app.register_menu_item(
  p_key        text,
  p_parent_key text,
  p_module     text,
  p_label      text,
  p_route      text,
  p_sort_order integer
)
returns public.menu_items
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.menu_items;
begin
  if p_key is null or btrim(p_key) = '' then
    raise exception '菜单 key 不能为空' using errcode = '22023';
  end if;
  if p_module is null or btrim(p_module) = '' then
    raise exception '所属模块不能为空' using errcode = '22023';
  end if;
  if p_label is null or btrim(p_label) = '' then
    raise exception '菜单名称不能为空' using errcode = '22023';
  end if;
  if p_parent_key is not null and btrim(p_parent_key) = btrim(p_key) then
    raise exception '菜单不能以自身为父级：%', btrim(p_key) using errcode = '22023';
  end if;
  if p_parent_key is not null and not exists (
    select 1 from public.menu_items where key = p_parent_key
  ) then
    raise exception '父菜单不存在：%', p_parent_key using errcode = 'P0002';
  end if;

  insert into public.menu_items
    (key, parent_key, module, label, route, sort_order)
  values
    (btrim(p_key), p_parent_key, btrim(p_module), btrim(p_label),
     p_route, coalesce(p_sort_order, 0))
  on conflict (key) do update
    set parent_key = excluded.parent_key,
        module     = excluded.module,
        label      = excluded.label,
        route      = excluded.route,
        sort_order = excluded.sort_order
  returning * into v_row;

  return v_row;
end;
$$;

comment on function app.register_menu_item(text, text, text, text, text, integer) is
  '菜单登记唯一入口：key 冲突时 upsert（幂等）；不 GRANT anon/authenticated（INDEX 规则 10）';

-- ---------------------------------------------------------------------------
-- 5. RPC：grant_menu / revoke_menu（admin 专用；写审计摘要）
-- ---------------------------------------------------------------------------
create function app.grant_menu(p_role_id uuid, p_menu_key text)
returns public.role_menu_grants
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.roles;
  v_row  public.role_menu_grants;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_role
  from public.roles
  where id = p_role_id;

  if not found then
    raise exception '角色不存在：%', p_role_id using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.menu_items where key = p_menu_key
  ) then
    raise exception '菜单项不存在：%', p_menu_key using errcode = 'P0002';
  end if;

  insert into public.role_menu_grants
    (role_id, menu_key, granted_by)
  values
    (p_role_id, p_menu_key, (select auth.uid()))
  on conflict (role_id, menu_key) do nothing
  returning * into v_row;

  if not found then
    -- 已授权：幂等返回现有行，不重复写审计
    select * into v_row
    from public.role_menu_grants
    where role_id = p_role_id and menu_key = p_menu_key;
    return v_row;
  end if;

  perform app.audit_log(
    'access', 'grant', 'menu_grant', p_role_id::text,
    jsonb_build_object('role_code', v_role.code, 'menu_key', p_menu_key)
  );

  return v_row;
end;
$$;

comment on function app.grant_menu(uuid, text) is
  '菜单授权 RPC（admin）：幂等 upsert 风格；仅实际新增写审计摘要；admin 角色亦可授予（UI 锁定）';

create function app.revoke_menu(p_role_id uuid, p_menu_key text)
returns public.role_menu_grants
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.roles;
  v_row  public.role_menu_grants;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_role
  from public.roles
  where id = p_role_id;

  if not found then
    raise exception '角色不存在：%', p_role_id using errcode = 'P0002';
  end if;

  delete from public.role_menu_grants
  where role_id = p_role_id
    and menu_key = p_menu_key
  returning * into v_row;

  if not found then
    return null; -- 幂等：未授权时无变更、无审计
  end if;

  perform app.audit_log(
    'access', 'revoke', 'menu_grant', p_role_id::text,
    jsonb_build_object('role_code', v_role.code, 'menu_key', p_menu_key)
  );

  return v_row;
end;
$$;

comment on function app.revoke_menu(uuid, text) is
  '菜单撤权 RPC（admin）：幂等（未授权返回 null）；仅实际删除写审计摘要';

-- ---------------------------------------------------------------------------
-- 6. public 包装层（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.register_menu_item(
  p_key        text,
  p_parent_key text,
  p_module     text,
  p_label      text,
  p_route      text,
  p_sort_order integer
)
returns public.menu_items
language sql
security definer
set search_path = ''
as $$
  select app.register_menu_item(p_key, p_parent_key, p_module, p_label, p_route, p_sort_order)
$$;

create function public.grant_menu(p_role_id uuid, p_menu_key text)
returns public.role_menu_grants
language sql
security definer
set search_path = ''
as $$
  select app.grant_menu(p_role_id, p_menu_key)
$$;

create function public.revoke_menu(p_role_id uuid, p_menu_key text)
returns public.role_menu_grants
language sql
security definer
set search_path = ''
as $$
  select app.revoke_menu(p_role_id, p_menu_key)
$$;

-- ---------------------------------------------------------------------------
-- 7. 权限：表级只读、函数最小授权
-- ---------------------------------------------------------------------------
-- 两表无任何角色表级写（含 service_role），写仅经 RPC/迁移
revoke all on public.menu_items from public, anon, authenticated, service_role;
grant select on public.menu_items to authenticated, service_role;

revoke all on public.role_menu_grants from public, anon, authenticated, service_role;
grant select on public.role_menu_grants to authenticated, service_role;

-- register_menu_item：内部入口，不 GRANT API 角色（INDEX 规则 10）；仅 postgres（属主 + 迁移）可执行
revoke all on function app.register_menu_item(text, text, text, text, text, integer)
  from public, anon, authenticated, service_role;
grant execute on function app.register_menu_item(text, text, text, text, text, integer)
  to postgres;

revoke all on function public.register_menu_item(text, text, text, text, text, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.register_menu_item(text, text, text, text, text, integer)
  to postgres;

-- 管理 RPC：GRANT authenticated，函数内部校验当前用户为 admin
revoke all on function app.grant_menu(uuid, text) from public, anon;
grant execute on function app.grant_menu(uuid, text) to authenticated;

revoke all on function app.revoke_menu(uuid, text) from public, anon;
grant execute on function app.revoke_menu(uuid, text) to authenticated;

revoke all on function public.grant_menu(uuid, text) from public, anon;
grant execute on function public.grant_menu(uuid, text) to authenticated;

revoke all on function public.revoke_menu(uuid, text) from public, anon;
grant execute on function public.revoke_menu(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. RLS：登录用户读 menu_items 全部；role_menu_grants admin 全量 / 本角色行只读
--    两表无写策略（无 INSERT/UPDATE/DELETE 策略 = 拒绝）
-- ---------------------------------------------------------------------------
alter table public.menu_items enable row level security;

create policy menu_items_select_all
on public.menu_items
for select
to authenticated
using (true);

alter table public.role_menu_grants enable row level security;

create policy role_menu_grants_select
on public.role_menu_grants
for select
to authenticated
using (
  (select app.current_role()) = 'admin'
  or role_id in (
    select r.id
    from public.roles r
    where r.code = (select app.current_role())::text
  )
);
