-- 组织管理 · 用户管理 RPC 部门/岗位外键参数（org/009）pgTAP 测试
-- 运行：supabase db reset && supabase test db
-- 覆盖：新签名唯一性与权限 / 传 id 写 id 列且触发器回写文本 / id 优先于文本 /
--       文本路径兼容（触发器解析 id）/ 仅传岗位 / 缺省 null 不改动 /
--       5 参位置调用兼容与 p_role 兼容路径 / 不存在或已删除的部门、不存在岗位拒绝 /
--       失败不产生部分写入 / 非 admin 带新参数被拒。

begin;

select plan(23);

-- ===========================================================================
-- 1. 夹具（as postgres 写入）
--    部门：两个 active + 一个 deleted（验证删除态拒绝）；
--    岗位：一个 active + 一个 disabled（验证停用岗位仍可写入存量语义）；
--    用户：handle_new_user 建档
-- ===========================================================================
insert into public.departments (id, name, sort_order, status, created_by)
values
  ('88888888-8888-4888-8888-888888880001', '测试-用户RPC甲', 1, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('88888888-8888-4888-8888-888888880002', '测试-用户RPC乙', 2, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('88888888-8888-4888-8888-888888880003', '测试-用户RPC删除', 3, 'deleted',
   '11111111-1111-1111-1111-111111111111');

insert into public.positions (id, name, code, department_id, status, created_by, updated_by)
values
  ('99999999-9999-4999-8999-999999990001', '测试-用户RPC岗1', 'TEST-USER-RPC-1',
   '88888888-8888-4888-8888-888888880001', 'active',
   '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111'),
  ('99999999-9999-4999-8999-999999990002', '测试-用户RPC岗2', 'TEST-USER-RPC-2',
   '88888888-8888-4888-8888-888888880002', 'disabled',
   '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111');

insert into auth.users (id, email, raw_app_meta_data) values
  ('77777777-7777-4777-8777-777777771001', 'org-users-rpc-u1@example.com', '{}'::jsonb),
  ('77777777-7777-4777-8777-777777771002', 'org-users-rpc-u2@example.com', '{}'::jsonb);

-- ===========================================================================
-- 2. 结构：新签名唯一、无旧签名重载、权限最小化（6）
-- ===========================================================================
select has_function(
  'public', 'admin_update_profile',
  array['uuid', 'text', 'text', 'user_role', 'profile_status', 'uuid', 'uuid',
        'boolean', 'boolean'],
  'admin_update_profile 新签名（9 参：含 clear 参数）存在'
);
select hasnt_function(
  'public', 'admin_update_profile',
  array['uuid', 'text', 'text', 'user_role', 'profile_status', 'uuid', 'uuid'],
  '旧 7 参签名已 drop（避免 PostgREST 具名参数重载歧义）'
);
select is(
  (select count(*)
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'admin_update_profile'),
  1::bigint,
  '同名函数全库唯一（无重载）'
);
select ok(
  (select p.prosecdef and p.proconfig = array['search_path=""']
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'admin_update_profile'),
  'security definer + search_path 固定为空'
);
select ok(
  has_function_privilege(
    'authenticated',
    'public.admin_update_profile(uuid,text,text,public.user_role,public.profile_status,uuid,uuid,boolean,boolean)',
    'EXECUTE'
  ),
  'authenticated 可执行（RPC 内部再校验 admin）'
);
select ok(
  not has_function_privilege(
    'anon',
    'public.admin_update_profile(uuid,text,text,public.user_role,public.profile_status,uuid,uuid,boolean,boolean)',
    'EXECUTE'
  ),
  'anon 不可执行'
);

-- ===========================================================================
-- 3. admin 正常路径：id 写入 + 触发器回写文本 + id 优先（6）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select is(
  (select (public.admin_update_profile(
     '77777777-7777-4777-8777-777777771001', null, null, null, null,
     '88888888-8888-4888-8888-888888880001',
     '99999999-9999-4999-8999-999999990001')).department_id::text),
  '88888888-8888-4888-8888-888888880001',
  '传 p_department_id/p_position_id：id 列写入'
);
select is(
  (select department from public.profiles
    where id = '77777777-7777-4777-8777-777777771001'),
  '测试-用户RPC甲',
  'department 文本由双写触发器回写一致'
);
select is(
  (select position_id::text from public.profiles
    where id = '77777777-7777-4777-8777-777777771001'),
  '99999999-9999-4999-8999-999999990001',
  'position_id 写入'
);
select is(
  (select (public.admin_update_profile(
     '77777777-7777-4777-8777-777777771001', null, '测试-用户RPC乙', null, null,
     '88888888-8888-4888-8888-888888880001', null)).department_id::text),
  '88888888-8888-4888-8888-888888880001',
  'id 与文本同传：id 优先'
);
select is(
  (select department from public.profiles
    where id = '77777777-7777-4777-8777-777777771001'),
  '测试-用户RPC甲',
  '同传时文本被 id 回写覆盖'
);
select is(
  (select (public.admin_update_profile(
     '77777777-7777-4777-8777-777777771001', null, null, null, null,
     null, '99999999-9999-4999-8999-999999990002')).position_id::text),
  '99999999-9999-4999-8999-999999990002',
  '仅传 p_position_id 时岗位更新（停用岗位允许存量写入）'
);

-- ===========================================================================
-- 4. 文本路径兼容 + 缺省 null 不改 + p_role 兼容（4）
-- ===========================================================================
select is(
  (select (public.admin_update_profile(
     '77777777-7777-4777-8777-777777771001', null, '测试-用户RPC乙', null, null)).department_id::text),
  '88888888-8888-4888-8888-888888880002',
  '未传 id：文本路径保持兼容，触发器解析 department_id'
);

-- 装置 u2（postgres 直改，绕开 RPC 预设存量归属）
reset role;
update public.profiles
   set full_name = 'RPC-原名',
       department = '测试-用户RPC甲',
       department_id = '88888888-8888-4888-8888-888888880001',
       position_id = '99999999-9999-4999-8999-999999990001'
 where id = '77777777-7777-4777-8777-777777771002';
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select is(
  (select (public.admin_update_profile(
     '77777777-7777-4777-8777-777777771002', 'RPC-改名', null, null, null)).full_name),
  'RPC-改名',
  '5 参位置调用兼容（姓名写入）'
);
select is(
  (select department_id::text || '|' || position_id::text
     from public.profiles
    where id = '77777777-7777-4777-8777-777777771002'),
  '88888888-8888-4888-8888-888888880001|99999999-9999-4999-8999-999999990001',
  '缺省 null 不改动 department_id/position_id'
);
select is(
  (select (public.admin_update_profile(
     '77777777-7777-4777-8777-777777771002', null, null, 'buyer', null)).role),
  'buyer'::public.user_role,
  'p_role 兼容路径仍转调 assign_role'
);

-- ===========================================================================
-- 5. 拒绝路径（5）
-- ===========================================================================
select throws_ok(
  $$ select public.admin_update_profile(
       '77777777-7777-4777-8777-777777771001', null, null, null, null,
       '00000000-0000-4000-8000-000000000099', null) $$,
  'P0002', '部门不存在或已删除：00000000-0000-4000-8000-000000000099',
  '不存在的 department_id 被拒（P0002）'
);
select throws_ok(
  $$ select public.admin_update_profile(
       '77777777-7777-4777-8777-777777771001', null, null, null, null,
       '88888888-8888-4888-8888-888888880003', null) $$,
  'P0002', '部门不存在或已删除：88888888-8888-4888-8888-888888880003',
  '已删除部门 id 被拒（P0002）'
);
select throws_ok(
  $$ select public.admin_update_profile(
       '77777777-7777-4777-8777-777777771001', null, null, null, null,
       null, '00000000-0000-4000-8000-000000000098') $$,
  'P0002', '岗位不存在：00000000-0000-4000-8000-000000000098',
  '不存在的 position_id 被拒（P0002）'
);
select is(
  (select position_id::text from public.profiles
    where id = '77777777-7777-4777-8777-777777771001'),
  '99999999-9999-4999-8999-999999990002',
  '校验失败不产生部分写入（position_id 保持原值）'
);
select is(
  (select role_id::text from public.profiles
    where id = '77777777-7777-4777-8777-777777771002'),
  (select id::text from public.roles where code = 'buyer'),
  'p_role 兼容路径同步写 role_id（单通道）'
);

-- ===========================================================================
-- 6. 非 admin：带新参数的调用被拒（2）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;
select throws_ok(
  $$ select public.admin_update_profile(
       '77777777-7777-4777-8777-777777771001', null, null, null, null,
       '88888888-8888-4888-8888-888888880001', null) $$,
  '42501', '仅管理员可执行此操作',
  '非 admin 带 p_department_id 被拒'
);
select throws_ok(
  $$ select public.admin_update_profile(
       '77777777-7777-4777-8777-777777771001', null, null, null, null,
       null, '99999999-9999-4999-8999-999999990001') $$,
  '42501', '仅管理员可执行此操作',
  '非 admin 带 p_position_id 被拒'
);

reset role;
select * from finish();
rollback;
