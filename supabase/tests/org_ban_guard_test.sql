-- 组织管理 · 用户停用兜底（org_ban_guard）pgTAP 测试
-- 工单：批次 2（停用用户即时禁止登录）
-- 运行：supabase db reset && supabase test db
-- 覆盖：触发器/函数结构与授权 / status 变更同步 auth.users.banned_until
--       （直改 SQL + admin RPC 两条路径）/ 同值更新与非 status 字段更新不误触发 /
--       停用后 current_role() 为 NULL、is_internal() false、profiles 仅本人可见、
--       admin RPC 被拒（RLS 兜底链）/ 启用后解封且角色恢复。

begin;

select plan(16);

-- ===========================================================================
-- 1. 夹具：admin（A）+ 普通用户（U）；auth.users insert 触发 handle_new_user 建档
-- ===========================================================================
insert into auth.users (id, email, raw_app_meta_data) values
  ('66666666-6666-4666-8666-666666660001', 'ban-guard-admin@example.com',
   '{"role":"admin"}'::jsonb),
  ('66666666-6666-4666-8666-666666660002', 'ban-guard-user@example.com',
   '{}'::jsonb);

-- ===========================================================================
-- 2. 结构与授权（3）
-- ===========================================================================
select has_trigger(
  'public', 'profiles', 'profiles_sync_ban',
  'profiles_sync_ban 触发器存在'
);
select ok(
  (select p.prosecdef and p.proconfig = array['search_path=""']
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = 'sync_profile_ban'),
  'sync_profile_ban security definer + search_path 固定为空'
);
select ok(
  not has_function_privilege(
    'authenticated', 'app.sync_profile_ban()', 'EXECUTE'
  ),
  'authenticated 不可执行内部触发器函数'
);

-- ===========================================================================
-- 3. 直改 profiles.status：同步封禁/解封（6）
-- ===========================================================================
select is(
  (select banned_until from auth.users
    where id = '66666666-6666-4666-8666-666666660002'),
  null,
  '初始 banned_until 为 NULL'
);

update public.profiles
   set status = 'inactive'
 where id = '66666666-6666-4666-8666-666666660002';

select ok(
  (select banned_until is not null from auth.users
    where id = '66666666-6666-4666-8666-666666660002'),
  '停用后 Auth 层 banned_until 已写入'
);
select ok(
  (select banned_until > now() + interval '99 years' from auth.users
    where id = '66666666-6666-4666-8666-666666660002'),
  '封禁时长约 100 年（与 ban_duration 876000h 一致）'
);

-- 非 status 字段更新不动封禁时间（哨兵值验证）
update auth.users
   set banned_until = timestamptz '2030-01-01 00:00:00+08'
 where id = '66666666-6666-4666-8666-666666660002';
update public.profiles
   set full_name = '兜底-改名'
 where id = '66666666-6666-4666-8666-666666660002';
select is(
  (select banned_until from auth.users
    where id = '66666666-6666-4666-8666-666666660002'),
  timestamptz '2030-01-01 00:00:00+08',
  '仅改姓名（status 未变）不触碰封禁时间'
);

-- status 同值更新不触发同步（哨兵值维持）
update auth.users
   set banned_until = null
 where id = '66666666-6666-4666-8666-666666660002';
update public.profiles
   set status = 'inactive'
 where id = '66666666-6666-4666-8666-666666660002';
select is(
  (select banned_until from auth.users
    where id = '66666666-6666-4666-8666-666666660002'),
  null,
  'status 同值更新不触发同步（WHEN 条件生效）'
);

-- 启用 → 解封
update auth.users
   set banned_until = timestamptz '2030-01-01 00:00:00+08'
 where id = '66666666-6666-4666-8666-666666660002';
update public.profiles
   set status = 'active'
 where id = '66666666-6666-4666-8666-666666660002';
select is(
  (select banned_until from auth.users
    where id = '66666666-6666-4666-8666-666666660002'),
  null,
  '启用后 Auth 层解封（banned_until 清空）'
);

-- 再次停用，进入 RLS 兜底链验证
update public.profiles
   set status = 'inactive'
 where id = '66666666-6666-4666-8666-666666660002';

-- ===========================================================================
-- 4. 停用账号的 RLS 兜底链（4）
-- ===========================================================================
set local request.jwt.claims = '{"sub":"66666666-6666-4666-8666-666666660002","role":"authenticated"}';
set local role authenticated;

select is(
  app.current_role()::text, null::text,
  '停用账号 current_role() 为 NULL'
);
select is(
  app.is_internal(), false,
  '停用账号 is_internal() 为 false'
);
select is(
  (select count(*)::integer from public.profiles),
  1,
  '停用账号仅本人档案可见（internal 全量读被 RLS 拒绝）'
);
select throws_ok(
  $$ select public.admin_update_profile(
       '66666666-6666-4666-8666-666666660001', null, null, null, 'inactive') $$,
  '42501', '仅管理员可执行此操作',
  '停用账号调用 admin RPC 被拒（current_role 兜底）'
);

-- ===========================================================================
-- 5. admin RPC 路径：启用 → 解封 + 角色恢复（3）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"66666666-6666-4666-8666-666666660001","role":"authenticated"}';
set local role authenticated;

select is(
  (select (public.admin_update_profile(
     '66666666-6666-4666-8666-666666660002', null, null, null, 'active')).status::text),
  'active',
  'admin 经 RPC 启用：档案状态写为 active'
);

reset role;
select is(
  (select banned_until from auth.users
    where id = '66666666-6666-4666-8666-666666660002'),
  null,
  'admin 经 RPC 启用：Auth 层同步解封'
);

set local request.jwt.claims = '{"sub":"66666666-6666-4666-8666-666666660002","role":"authenticated"}';
set local role authenticated;
select is(
  app.current_role()::text, 'engineer',
  '启用后角色恢复（current_role 兜底链复原）'
);

reset role;
select * from finish();
rollback;
