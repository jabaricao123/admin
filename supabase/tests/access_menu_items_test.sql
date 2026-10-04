-- 权限管理 · menu_items + role_menu_grants（access/005，M0 底座）pgTAP 测试
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构存在性 / 全 10 模块 seed（顶级 + 子菜单路由逐条对齐 README）/
--       register_menu_item 幂等 upsert 与越权拒绝（INDEX 规则 10）/
--       grant_menu/revoke_menu admin 校验、幂等与审计摘要 /
--       RLS 读范围（menu_items 全员、role_menu_grants 仅 admin + 本角色）/
--       表级写全拒（含 admin）/ anon 无路径

begin;

select plan(84);

-- ===========================================================================
-- 1. 结构存在性（31）
-- ===========================================================================
select has_table('public', 'menu_items', 'menu_items 表存在');
select has_table('public', 'role_menu_grants', 'role_menu_grants 表存在');

select has_column('public', 'menu_items', 'key', 'menu_items.key 列存在');
select has_column('public', 'menu_items', 'parent_key', 'menu_items.parent_key 列存在');
select has_column('public', 'menu_items', 'module', 'menu_items.module 列存在');
select has_column('public', 'menu_items', 'label', 'menu_items.label 列存在');
select has_column('public', 'menu_items', 'route', 'menu_items.route 列存在');
select has_column('public', 'menu_items', 'sort_order', 'menu_items.sort_order 列存在');
select has_column('public', 'menu_items', 'created_at', 'menu_items.created_at 列存在');
select col_is_pk('public', 'menu_items', 'key', 'menu_items.key 为主键');

select has_column('public', 'role_menu_grants', 'role_id', 'role_menu_grants.role_id 列存在');
select has_column('public', 'role_menu_grants', 'menu_key', 'role_menu_grants.menu_key 列存在');
select has_column('public', 'role_menu_grants', 'granted_by', 'role_menu_grants.granted_by 列存在');
select has_column('public', 'role_menu_grants', 'granted_at', 'role_menu_grants.granted_at 列存在');
select col_is_pk(
  'public', 'role_menu_grants', array['role_id', 'menu_key'],
  'role_menu_grants 主键为 (role_id, menu_key)'
);

select ok(
  exists (
    select 1 from pg_constraint
    where conname = 'menu_items_parent_key_fkey'
      and conrelid = 'public.menu_items'::regclass
      and contype = 'f'
      and confrelid = 'public.menu_items'::regclass
  ),
  'menu_items.parent_key 自引用外键存在'
);
select ok(
  exists (
    select 1 from pg_constraint
    where conname = 'role_menu_grants_role_id_fkey'
      and conrelid = 'public.role_menu_grants'::regclass
      and contype = 'f'
      and confrelid = 'public.roles'::regclass
      and confdeltype = 'c'
  ),
  'role_menu_grants.role_id 外键指向 roles（角色删除级联）'
);
select ok(
  exists (
    select 1 from pg_constraint
    where conname = 'role_menu_grants_menu_key_fkey'
      and conrelid = 'public.role_menu_grants'::regclass
      and contype = 'f'
      and confrelid = 'public.menu_items'::regclass
  ),
  'role_menu_grants.menu_key 外键指向 menu_items'
);

select is(
  (select relrowsecurity from pg_class where oid = 'public.menu_items'::regclass),
  true,
  'menu_items 已启用 RLS'
);
select is(
  (select relrowsecurity from pg_class where oid = 'public.role_menu_grants'::regclass),
  true,
  'role_menu_grants 已启用 RLS'
);
select ok(
  exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'menu_items'
      and policyname = 'menu_items_select_all' and cmd = 'SELECT'
  ),
  'menu_items 有 SELECT 策略（登录用户读全部）'
);
select ok(
  exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'role_menu_grants'
      and policyname = 'role_menu_grants_select' and cmd = 'SELECT'
  ),
  'role_menu_grants 有 SELECT 策略（admin + 本角色）'
);

select has_function(
  'app', 'register_menu_item',
  array['text', 'text', 'text', 'text', 'text', 'integer'],
  'app.register_menu_item 存在'
);
select has_function(
  'public', 'register_menu_item',
  array['text', 'text', 'text', 'text', 'text', 'integer'],
  'public.register_menu_item 包装存在'
);
select has_function('app', 'grant_menu', array['uuid', 'text'], 'app.grant_menu 存在');
select has_function('app', 'revoke_menu', array['uuid', 'text'], 'app.revoke_menu 存在');
select has_function('public', 'grant_menu', array['uuid', 'text'], 'public.grant_menu 包装存在');
select has_function('public', 'revoke_menu', array['uuid', 'text'], 'public.revoke_menu 包装存在');

select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = 'register_menu_item'
      and p.prosecdef
      and p.proconfig @> array['search_path=""']
  ),
  'app.register_menu_item 为 SECURITY DEFINER 且 search_path 固定为空'
);
select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = 'grant_menu'
      and p.prosecdef
      and p.proconfig @> array['search_path=""']
  ),
  'app.grant_menu 为 SECURITY DEFINER 且 search_path 固定为空'
);
select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = 'revoke_menu'
      and p.prosecdef
      and p.proconfig @> array['search_path=""']
  ),
  'app.revoke_menu 为 SECURITY DEFINER 且 search_path 固定为空'
);

-- ===========================================================================
-- 2. seed：全 10 模块路由级菜单（9）
-- ===========================================================================
select is(
  (select count(*) from public.menu_items where parent_key is null),
  10::bigint,
  '10 个顶级菜单存在'
);
select results_eq(
  $$ select key, module, label, route
       from public.menu_items
      where parent_key is null
      order by sort_order $$,
  $$ values
       ('/dashboard'::text,   'dashboard'::text,   '工作台'::text,         '/dashboard'::text),
       ('/org'::text,         'org'::text,         '组织管理'::text,       '/org'::text),
       ('/access'::text,      'access'::text,      '权限管理'::text,       '/access'::text),
       ('/approval'::text,    'approval'::text,    '审批中心'::text,       '/approval'::text),
       ('/report'::text,      'report'::text,      '报表中心'::text,       '/report'::text),
       ('/audit'::text,       'audit'::text,       '审计中心'::text,       '/audit'::text),
       ('/integration'::text, 'integration'::text, '接口/集成中心'::text,  '/integration'::text),
       ('/sync'::text,        'sync'::text,        '第三方数据同步'::text, '/sync'::text),
       ('/system'::text,      'system'::text,      '系统管理'::text,       '/system'::text),
       ('/message'::text,     'message'::text,     '消息中心'::text,       '/message'::text) $$,
  '10 个顶级菜单 key/module/label/route 与 README 一致'
);
select ok(
  (select count(*) from public.menu_items) >= 50,
  'seed 总数 ≥ 50（顶级 10 + 子菜单 44 = 54）'
);
select results_eq(
  $$ select key, parent_key, label
       from public.menu_items
      where parent_key is not null
      order by key $$,
  $$ values
       ('/access/audit'::text, '/access'::text, '权限审计'::text),
       ('/access/data-scopes', '/access', '数据权限'),
       ('/access/permissions', '/access', '菜单权限'),
       ('/access/roles', '/access', '角色管理'),
       ('/approval/cc', '/approval', '抄送我的'),
       ('/approval/flows', '/approval', '审批流程'),
       ('/approval/mine', '/approval', '我发起的'),
       ('/approval/templates', '/approval', '审批模板'),
       ('/approval/todo', '/approval', '我的待办'),
       ('/audit/changes', '/audit', '数据变更'),
       ('/audit/compliance', '/audit', '合规报告'),
       ('/audit/logins', '/audit', '登录日志'),
       ('/audit/operations', '/audit', '操作日志'),
       ('/dashboard/notifications', '/dashboard', '我的通知'),
       ('/dashboard/todos', '/dashboard', '我的待办'),
       ('/integration/api-keys', '/integration', 'API 密钥'),
       ('/integration/docs', '/integration', '接口文档'),
       ('/integration/logs', '/integration', '调用日志'),
       ('/integration/webhooks', '/integration', 'Webhook'),
       ('/message/history', '/message', '发送记录'),
       ('/message/inbox', '/message', '站内信'),
       ('/message/templates', '/message', '通知模板'),
       ('/org/chart', '/org', '组织架构图'),
       ('/org/departments', '/org', '部门管理'),
       ('/org/positions', '/org', '岗位管理'),
       ('/org/users', '/org', '用户管理'),
       ('/report/builtin', '/report', '预置报表'),
       ('/report/custom', '/report', '自定义报表'),
       ('/report/exports', '/report', '数据导出'),
       ('/report/subscriptions', '/report', '报表订阅'),
       ('/sync/runs', '/sync', '执行记录'),
       ('/sync/schedules', '/sync', '调度管理'),
       ('/sync/sources', '/sync', '数据源配置'),
       ('/sync/tasks', '/sync', '同步任务'),
       ('/system/about', '/system', '关于/版本'),
       ('/system/announcements', '/system', '公告管理'),
       ('/system/dictionaries', '/system', '字典管理'),
       ('/system/jobs', '/system', '定时任务'),
       ('/system/services/auth', '/system', '身份认证'),
       ('/system/services/mail', '/system', '邮件服务'),
       ('/system/services/push', '/system', '消息推送'),
       ('/system/services/sms', '/system', '短信服务'),
       ('/system/services/storage', '/system', '对象存储'),
       ('/system/settings', '/system', '参数配置') $$,
  '44 个子菜单 key/parent_key/label 与 README 一致'
);
select is(
  (select count(*)
     from public.menu_items c
    where c.parent_key is not null
      and not exists (
        select 1
        from public.menu_items p
        where p.key = c.parent_key
          and p.parent_key is null
          and p.module = c.module
      )),
  0::bigint,
  '全部子菜单都挂在同模块顶级菜单下'
);
select ok(
  exists (
    select 1 from public.menu_items
    where key = '/org/users'
      and parent_key = '/org'
      and module = 'org'
      and route = '/org/users'
  ),
  '用户管理登记为新路径 /org/users（非 /settings/users）'
);
select is(
  (select count(*) from public.menu_items where key like '/organization%'),
  0::bigint,
  '不存在 /organization/* 旧前缀'
);
select is(
  (select count(*) from public.menu_items where key = '/settings/users'),
  0::bigint,
  '未登记旧路径 /settings/users'
);
select is(
  (select parent_key from public.menu_items where key = '/system/services/mail'),
  '/system'::text,
  '/system/services/mail 直接挂 /system 下'
);

-- ===========================================================================
-- 3. register_menu_item：幂等 upsert 与越权拒绝（11）
-- ===========================================================================
select is(
  (select (app.register_menu_item(
     '/system/test-item', '/system', 'system', '测试菜单项', '/system/test-item', 5)).label),
  '测试菜单项',
  'postgres 经 app.register_menu_item 登记新菜单（首次 INSERT）'
);
select is(
  (select count(*) from public.menu_items where key = '/system/test-item'),
  1::bigint,
  '登记后注册表存在该行'
);
select is(
  (select (app.register_menu_item(
     '/system/test-item', '/system', 'system', '测试菜单项2', null, 99)).label),
  '测试菜单项2',
  '重复登记执行 upsert 更新（幂等）'
);
select is(
  (select count(*) from public.menu_items where key = '/system/test-item'),
  1::bigint,
  'upsert 不产生重复行'
);
select is(
  (select sort_order from public.menu_items where key = '/system/test-item'),
  99,
  'upsert 更新 sort_order 与 route（全字段覆盖）'
);
select throws_ok(
  $$ select app.register_menu_item('/system/test-orphan', '/no/such/parent', 'system', '孤儿菜单', null, 1) $$,
  'P0002', '父菜单不存在：/no/such/parent',
  '父菜单不存在被拒'
);
select throws_ok(
  $$ select app.register_menu_item('', null, 'system', '空key', null, 1) $$,
  '22023', '菜单 key 不能为空',
  '空 key 被拒'
);
select throws_ok(
  $$ select app.register_menu_item('/system/self', '/system/self', 'system', '自引用', null, 1) $$,
  '22023', '菜单不能以自身为父级：/system/self',
  '自引用父级被拒'
);

reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;

select throws_ok(
  $$ select public.register_menu_item('/system/evil-item', '/system', 'system', '越权登记', null, 1) $$,
  '42501', null,
  'authenticated 调 public.register_menu_item 被拒（无 GRANT）'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'app.register_menu_item(text,text,text,text,text,integer)',
    'EXECUTE'
  ),
  'authenticated 无 app.register_menu_item 执行权（INDEX 规则 10）'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'public.register_menu_item(text,text,text,text,text,integer)',
    'EXECUTE'
  ),
  'authenticated 无 public.register_menu_item 执行权（INDEX 规则 10）'
);

-- ===========================================================================
-- 4. grant_menu / revoke_menu：admin 校验、幂等与审计（15）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select is(
  (select (public.grant_menu(
     (select id from public.roles where code = 'engineer'), '/org/users')).menu_key),
  '/org/users',
  'admin 授予 engineer /org/users'
);
select is(
  (select count(*) from public.role_menu_grants where menu_key = '/org/users'),
  1::bigint,
  '授权行写入（1 条）'
);
select is(
  (select (public.grant_menu(
     (select id from public.roles where code = 'engineer'), '/org/users')).menu_key),
  '/org/users',
  '重复授予幂等返回现有行'
);
select is(
  (select count(*) from public.audit_operations
    where module = 'access' and action = 'grant' and object_type = 'menu_grant'
      and diff ->> 'menu_key' = '/org/users'),
  1::bigint,
  '幂等重放不重复写审计（grant 摘要仍 1 条）'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'access' and action = 'grant' and object_type = 'menu_grant'
      and diff ->> 'menu_key' = '/org/users'
      and diff ->> 'role_code' = 'engineer'
      and actor_id = '11111111-1111-1111-1111-111111111111'
  ),
  'grant 审计摘要含 role_code 与操作人'
);
select ok(
  (select (public.grant_menu(
     (select id from public.roles where code = 'admin'), '/system/settings')).menu_key)
    = '/system/settings',
  'admin 角色可被授予（矩阵 UI 锁定由页面处理）'
);
select throws_ok(
  $$ select public.grant_menu('44444444-4444-4444-4444-444444440099', '/org/users') $$,
  'P0002', '角色不存在：44444444-4444-4444-4444-444444440099',
  '授予不存在角色被拒'
);
select throws_ok(
  $$ select public.grant_menu(
       (select id from public.roles where code = 'engineer'), '/no/such/menu') $$,
  'P0002', '菜单项不存在：/no/such/menu',
  '授予不存在菜单项被拒'
);
select is(
  (select (public.revoke_menu(
     (select id from public.roles where code = 'admin'), '/system/settings')).menu_key),
  '/system/settings',
  'admin 角色授权可撤销（清理）'
);
select is(
  (select (public.revoke_menu(
     (select id from public.roles where code = 'engineer'), '/org/users')).menu_key),
  '/org/users',
  'admin 撤销 engineer /org/users'
);
select is(
  (select public.revoke_menu(
     (select id from public.roles where code = 'engineer'), '/org/users')),
  null,
  '重复撤销幂等返回 null'
);
select is(
  (select count(*) from public.audit_operations
    where module = 'access' and action = 'revoke' and object_type = 'menu_grant'
      and diff ->> 'menu_key' = '/org/users'),
  1::bigint,
  'revoke 写审计摘要（幂等重放仍 1 条）'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'access' and action = 'revoke' and object_type = 'menu_grant'
      and diff ->> 'menu_key' = '/org/users'
      and diff ->> 'role_code' = 'engineer'
      and actor_id = '11111111-1111-1111-1111-111111111111'
  ),
  'revoke 审计摘要含 role_code 与操作人'
);

reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;

select throws_ok(
  $$ select public.grant_menu(
       (select id from public.roles where code = 'engineer'), '/org/users') $$,
  '42501', '仅管理员可执行此操作',
  '非 admin 调 grant_menu 被拒'
);
select throws_ok(
  $$ select public.revoke_menu(
       (select id from public.roles where code = 'engineer'), '/org/users') $$,
  '42501', '仅管理员可执行此操作',
  '非 admin 调 revoke_menu 被拒'
);

-- ===========================================================================
-- 5. RLS 读范围：menu_items 全员可读；role_menu_grants 仅 admin + 本角色（9）
--    装置：engineer /org/users + planner /report/builtin；
--    计数含内置角色默认授权 seed（内部各 10 条、外部各 3 条）。
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

do $$
begin
  perform public.grant_menu((select id from public.roles where code = 'engineer'), '/org/users');
  perform public.grant_menu((select id from public.roles where code = 'planner'), '/report/builtin');
end
$$;

reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*) from public.role_menu_grants),
  11::bigint,
  'engineer 仅见本角色授权行（seed 10 + 装置 1 = 11 条）'
);
select ok(
  exists (select 1 from public.role_menu_grants where menu_key = '/org/users'),
  'engineer 可见本角色 /org/users 授权'
);
select is(
  (select count(*) from public.role_menu_grants where menu_key = '/report/builtin'),
  0::bigint,
  'engineer 不可见 planner 的授权行'
);
select ok(
  (select count(*) from public.menu_items) >= 50,
  'engineer 可读全部 menu_items（矩阵渲染）'
);

reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220002","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*) from public.role_menu_grants),
  11::bigint,
  'planner 仅见本角色授权行（seed 10 + 装置 1 = 11 条）'
);
select ok(
  exists (select 1 from public.role_menu_grants where menu_key = '/report/builtin')
    and not exists (select 1 from public.role_menu_grants where menu_key = '/org/users'),
  'planner 可见本角色行、不可见 engineer 行'
);

reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220003","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*) from public.role_menu_grants),
  10::bigint,
  'buyer 见本角色默认授权行（seed 10 条）'
);

reset role;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*) from public.role_menu_grants),
  48::bigint,
  'admin 可见全部授权行（seed 46 + 装置 2 = 48 条）'
);
select ok(
  exists (select 1 from public.role_menu_grants where menu_key = '/org/users')
    and exists (select 1 from public.role_menu_grants where menu_key = '/report/builtin'),
  'admin 可见 engineer 与 planner 的授权行'
);

-- ===========================================================================
-- 6. 表级写全拒（含 admin）+ anon 无路径（9）
-- ===========================================================================
select throws_ok(
  $$ insert into public.menu_items (key, module, label) values ('/evil', 'evil', '越权') $$,
  '42501', null,
  'authenticated（admin）表级 INSERT menu_items 被拒'
);
select throws_ok(
  $$ update public.menu_items set label = '越权' where key = '/org' $$,
  '42501', null,
  'authenticated（admin）表级 UPDATE menu_items 被拒'
);
select throws_ok(
  $$ delete from public.menu_items where key = '/org' $$,
  '42501', null,
  'authenticated（admin）表级 DELETE menu_items 被拒'
);
select throws_ok(
  $$ insert into public.role_menu_grants (role_id, menu_key)
     select id, '/org' from public.roles where code = 'admin' $$,
  '42501', null,
  'authenticated（admin）表级 INSERT role_menu_grants 被拒'
);
select throws_ok(
  $$ update public.role_menu_grants set granted_by = null $$,
  '42501', null,
  'authenticated（admin）表级 UPDATE role_menu_grants 被拒'
);
select throws_ok(
  $$ delete from public.role_menu_grants $$,
  '42501', null,
  'authenticated（admin）表级 DELETE role_menu_grants 被拒'
);

reset role;
set local role anon;

select throws_ok(
  $$ select count(*) from public.menu_items $$,
  '42501', null,
  'anon 无 menu_items 读取权限'
);
select throws_ok(
  $$ select count(*) from public.role_menu_grants $$,
  '42501', null,
  'anon 无 role_menu_grants 读取权限'
);
select throws_ok(
  $$ select public.grant_menu('00000000-0000-0000-0000-000000000000', '/org') $$,
  '42501', null,
  'anon 无管理 RPC 执行权限'
);

reset role;
select * from finish();
rollback;
