-- 组织管理 · 用户列表按数据范围过滤 RPC list_users（access 批次 2 / 修复项 2）pgTAP 测试
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构/授权 / admin 全量与筛选分页 / engineer（scope=all）全量 /
--       改 self 后仅本人 / 停用账号 fail-closed / 无会话空集 / 行数据 join 名称。
-- 说明：夹具仅在事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(22);

-- ===========================================================================
-- 1. 结构 / 授权（6）
-- ===========================================================================
select has_function('public', 'list_users',
  array['text', 'text', 'text', 'uuid', 'integer', 'integer'],
  'public.list_users 存在（6 参数，默认值齐备）');
select ok(
  (select count(*) = 1
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'list_users'
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  'public.list_users：security definer + search_path 固定为空'
);
select ok(
  (select count(*) = 1
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = 'list_users'
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  'app.list_users：security definer + search_path 固定为空'
);
select ok(
  has_function_privilege('authenticated',
    'public.list_users(text,text,text,uuid,integer,integer)', 'EXECUTE'),
  'authenticated 可执行 public.list_users'
);
select ok(
  not has_function_privilege('anon',
    'public.list_users(text,text,text,uuid,integer,integer)', 'EXECUTE'),
  'anon 不可执行 public.list_users'
);
select ok(
  not has_function_privilege('authenticated',
    'app.list_users(text,text,text,uuid,integer,integer)', 'EXECUTE'),
  'authenticated 不可直接执行 app.list_users（仅包装层）'
);

-- ===========================================================================
-- 2. 夹具（as postgres）：部门 + 岗位 + 2 个夹具用户（种子已有 admin/engineer）
-- ===========================================================================
insert into public.departments (id, name, parent_id, sort_order, status) values
  ('a0000000-0000-4000-a000-000000000001', 'RPC用户-部门甲', null, 1, 'active');

insert into public.positions (id, name, code, department_id, status) values
  ('a1000000-0000-4000-a000-000000000001', 'RPC用户-岗位甲', 'rpc-users-pos-a',
   'a0000000-0000-4000-a000-000000000001', 'active');

insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
  ('a2000000-0000-4000-a000-000000000001', 'rpc-users-eng1@example.com',
   '{"role":"engineer"}'::jsonb, '{"full_name":"RPC列表-工程师一"}'::jsonb),
  ('a2000000-0000-4000-a000-000000000002', 'rpc-users-planner2@example.com',
   '{"role":"planner"}'::jsonb, '{"full_name":"RPC列表-计划员二"}'::jsonb);

update public.profiles
   set department_id = 'a0000000-0000-4000-a000-000000000001',
       position_id   = 'a1000000-0000-4000-a000-000000000001'
 where id = 'a2000000-0000-4000-a000-000000000001';

update public.profiles
   set status = 'inactive'
 where id = 'a2000000-0000-4000-a000-000000000002';

-- ===========================================================================
-- 3. admin：全量 / 筛选 / 分页 / 行结构（11）
-- ===========================================================================
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;
select is(
  (public.list_users() ->> 'total')::bigint,
  (select count(*) from public.profiles),
  'admin：total = 全量 profiles'
);
select is(
  jsonb_array_length(public.list_users() -> 'rows'),
  least((select count(*) from public.profiles), 20)::int,
  'admin：默认分页返回 min(total, 20) 行'
);
select is(
  (public.list_users('RPC列表-工程师一') ->> 'total')::bigint,
  1::bigint,
  'admin：p_search 按姓名匹配'
);
select is(
  public.list_users('RPC列表-工程师一') -> 'rows' -> 0 ->> 'position_name',
  'RPC用户-岗位甲',
  'admin：行数据 join 岗位名称'
);
select is(
  public.list_users('RPC列表-工程师一') -> 'rows' -> 0 ->> 'department_name',
  'RPC用户-部门甲',
  'admin：行数据 join 部门名称'
);
select is(
  (public.list_users(null, 'planner') ->> 'total')::bigint,
  (select count(*)
     from public.profiles p
     left join public.roles r
       on r.id = coalesce(
            p.role_id,
            (select r2.id from public.roles r2 where r2.code = p.role::text)
          )
    where coalesce(r.code, p.role::text) = 'planner'),
  'admin：p_role 过滤生效'
);
select is(
  (public.list_users(null, null, 'inactive') ->> 'total')::bigint,
  (select count(*) from public.profiles where status = 'inactive'),
  'admin：p_status 过滤生效'
);
select is(
  (public.list_users(
     null, null, null, 'a0000000-0000-4000-a000-000000000001') ->> 'total')::bigint,
  (select count(*) from public.profiles
    where department_id = 'a0000000-0000-4000-a000-000000000001'),
  'admin：p_department_id 过滤生效'
);
select is(
  jsonb_array_length(public.list_users(null, null, null, null, 1, 1) -> 'rows'),
  1,
  'admin：p_limit/p_offset 分页生效（第二页 1 行）'
);
select is(
  (public.list_users(null, null, null, null, 1, 1) ->> 'total')::bigint,
  (select count(*) from public.profiles),
  'admin：分页不改变 total（过滤后全量计数）'
);
select ok(
  public.list_users() -> 'rows' -> 0
    ?& array['id', 'full_name', 'email', 'status', 'role', 'role_id',
             'role_code', 'role_name', 'department', 'department_id',
             'department_name', 'position_id', 'position_name',
             'created_at', 'updated_at'],
  'admin：行数据键齐备（含部门/岗位/角色名称）'
);

-- ===========================================================================
-- 4. engineer：scope=all 全量 → 改 self 仅本人 / 停用账号 fail-closed（4）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;
select is(
  (public.list_users() ->> 'total')::bigint,
  (select count(*) from public.profiles),
  'engineer（scope=all 现状）：全量'
);

reset role;
update public.role_data_scopes
   set scope = 'self'
 where role_id = (select id from public.roles where code = 'engineer');

set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;
select is(
  (public.list_users() ->> 'total')::bigint,
  1::bigint,
  'engineer（scope=self）：total 仅本人'
);
select is(
  public.list_users() -> 'rows' -> 0 ->> 'id',
  '22222222-2222-2222-2222-222222220001',
  'engineer（scope=self）：行数据为本人'
);

reset role;
set local request.jwt.claims = '{"sub":"a2000000-0000-4000-a000-000000000002","role":"authenticated"}';
set local role authenticated;
select is(
  (public.list_users() ->> 'total')::bigint,
  0::bigint,
  '停用账号：角色解析为空 → 空集（fail-closed）'
);

-- ===========================================================================
-- 5. 无会话：空集（1）
-- ===========================================================================
reset role;
set local request.jwt.claims = '';
select is(
  (public.list_users() ->> 'total')::bigint,
  0::bigint,
  '无会话：非 admin 路径返回空集（后台需显式注入身份）'
);

select * from finish();
rollback;
