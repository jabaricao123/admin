-- pgTAP：dashboard 批次 1 修复项 1 — audit.list_recent_changes 公开 RPC
-- 运行：supabase db reset && supabase test db
-- 覆盖：app/public 函数存在性与安全属性（SECURITY DEFINER + search_path 空）；
--       GRANT 面（public 包装仅 authenticated；app 实现不 GRANT API 角色，规则 10）；
--       admin 调用返回操作人姓名与 change_type（insert/update/delete 推断）；
--       p_limit 生效；engineer/anon 被拒 42501。
-- 说明：夹具触发 profiles 行版本触发器产生 v1/v2/v3；changed_by 取调用时 auth.uid()
--       （admin seed 1111… 作为操作人），断言的 record_id 只命中本测试夹具。

begin;

select plan(9);

-- ---------------------------------------------------------------------------
-- 夹具：以 admin 身份创建/改名/删除一个 profile → v1 insert / v2 update / v3 delete
-- ---------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
  ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01', 'recent-changes-target@example.com',
   '{"provider":"email","providers":["email"]}', '{"full_name":"最近变更测试对象"}');

update public.profiles
   set full_name = '最近变更测试对象（改）'
 where id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01';

delete from public.profiles
 where id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01';

-- ===========================================================================
-- 1. 结构与安全属性（5）
-- ===========================================================================
select has_function('app', 'list_recent_changes', array['integer'],
  'app.list_recent_changes 存在');
select has_function('public', 'list_recent_changes', array['integer'],
  'public.list_recent_changes 薄包装存在');

select ok(
  (select count(*) = 2
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('app', 'public')
      and p.proname = 'list_recent_changes'
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  'app/public 均为 SECURITY DEFINER 且 search_path 固定为空'
);
select ok(
  has_function_privilege('authenticated', 'public.list_recent_changes(integer)', 'EXECUTE'),
  'authenticated 可执行 public.list_recent_changes'
);
select ok(
  not has_function_privilege('authenticated', 'app.list_recent_changes(integer)', 'EXECUTE')
  and not has_function_privilege('service_role', 'app.list_recent_changes(integer)', 'EXECUTE'),
  'app 实现层未 GRANT API 角色 EXECUTE（规则 10）'
);

-- ===========================================================================
-- 2. admin：操作人姓名与 change_type（2）
-- ===========================================================================
set local role authenticated;

select results_eq(
  $$ select table_name, record_id, version, change_type, changed_by_name
       from public.list_recent_changes(200)
      where record_id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01'
      order by version $$,
  $$ values
       ('profiles'::text, 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01'::text,
        1, 'insert'::text, '系统管理员'::text),
       ('profiles', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01', 2, 'update', '系统管理员'),
       ('profiles', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeee01', 3, 'delete', '系统管理员') $$,
  'admin 调用返回操作人姓名与 change_type（insert/update/delete）'
);
select is(
  (select count(*) from public.list_recent_changes(1)),
  1::bigint,
  'p_limit 生效（1 条）'
);

-- ===========================================================================
-- 3. engineer / anon 被拒（2）
-- ===========================================================================
reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}';
set local role authenticated;

select throws_ok(
  $$ select * from public.list_recent_changes(10) $$,
  '42501', null,
  'engineer 调用被拒 42501'
);

reset role;
set local role anon;

select throws_ok(
  $$ select * from public.list_recent_changes(10) $$,
  '42501', null,
  'anon 无 list_recent_changes 执行权限'
);

reset role;

select * from finish();
rollback;
