-- pgTAP：audit/007 + org/011 —— 快照触发器挂载（pg_trigger）/ profiles 演练 /
-- 白名单 disable 闸门 / 管理 RPC 与查询 RPC（越权 + admin）。
-- 运行：supabase test db（先 supabase db reset 保证 seed 已加载）
begin;
select plan(25);

-- ---------------------------------------------------------------------------
-- 结构：三表白名单触发器挂载存在，且均指向通用快照函数
-- ---------------------------------------------------------------------------
select has_trigger('public', 'profiles', 'profiles_row_versions', 'profiles 挂载行版本触发器');
select has_trigger('public', 'departments', 'departments_row_versions', 'departments 挂载行版本触发器');
select has_trigger('public', 'positions', 'positions_row_versions', 'positions 挂载行版本触发器');

select is(
  (
    select count(*)::int
    from pg_catalog.pg_trigger t
    join pg_catalog.pg_class c on c.oid = t.tgrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname in ('profiles', 'departments', 'positions')
      and not t.tgisinternal
      and t.tgfoid = 'app.audit_row_version_trigger()'::pg_catalog.regprocedure
  ),
  3,
  '三表触发器均指向 app.audit_row_version_trigger'
);

-- ---------------------------------------------------------------------------
-- profiles 演练：INSERT 首版=1 / UPDATE +1 / 白名单 disable 闸门 / 恢复
-- ---------------------------------------------------------------------------
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, confirmation_token, recovery_token,
  email_change_token_new, email_change
) values (
  '00000000-0000-0000-0000-000000000000',
  '99999999-9999-9999-9999-999999990001',
  'authenticated', 'authenticated',
  'audit-snapshot-test@example.com',
  crypt('test123', gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}',
  '{"full_name":"快照测试用户"}',
  now(), now(), '', '', '', ''
);

select is(
  (
    select version from public.audit_row_versions
    where table_name = 'profiles'
      and record_id = '99999999-9999-9999-9999-999999990001'
  ),
  1,
  'profiles INSERT（handle_new_user 建档）产生 version=1 首版'
);

select is(
  (
    select data ->> 'full_name' from public.audit_row_versions
    where table_name = 'profiles'
      and record_id = '99999999-9999-9999-9999-999999990001'
      and version = 1
  ),
  '快照测试用户',
  '首版快照含完整 row（full_name）'
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '99999999-9999-9999-9999-999999990001')::text,
  true
);

update public.profiles
   set full_name = '快照测试用户改名'
 where id = '99999999-9999-9999-9999-999999990001';

select results_eq(
  $$ select version, data ->> 'full_name'
       from public.audit_row_versions
      where table_name = 'profiles'
        and record_id = '99999999-9999-9999-9999-999999990001'
      order by version $$,
  $$ values (1, '快照测试用户'::text), (2, '快照测试用户改名'::text) $$,
  'profiles 一次 UPDATE 产生 version+1 快照且含新旧值'
);

select is(
  (
    select changed_by from public.audit_row_versions
    where table_name = 'profiles'
      and record_id = '99999999-9999-9999-9999-999999990001'
      and version = 2
  ),
  '99999999-9999-9999-9999-999999990001'::uuid,
  'UPDATE 快照记录操作人（changed_by = auth.uid()）'
);

-- 白名单 disable 后不再快照
update public.audit_row_version_whitelist
   set enabled = false
 where table_name = 'profiles';

update public.profiles
   set full_name = '禁用期改名'
 where id = '99999999-9999-9999-9999-999999990001';

select is(
  (
    select count(*)::int from public.audit_row_versions
    where table_name = 'profiles'
      and record_id = '99999999-9999-9999-9999-999999990001'
  ),
  2,
  '白名单 enabled=false 时不再产生快照'
);

-- 恢复 enable 后继续快照
update public.audit_row_version_whitelist
   set enabled = true
 where table_name = 'profiles';

update public.profiles
   set full_name = '快照测试用户改名2'
 where id = '99999999-9999-9999-9999-999999990001';

select is(
  (
    select max(version)::int from public.audit_row_versions
    where table_name = 'profiles'
      and record_id = '99999999-9999-9999-9999-999999990001'
  ),
  3,
  '白名单恢复 enabled 后快照继续（version=3）'
);

-- ---------------------------------------------------------------------------
-- departments / positions 挂载演练
-- ---------------------------------------------------------------------------
update public.departments
   set sort_order = sort_order + 1
 where id = '33333333-3333-3333-3333-333333330001';

select is(
  (
    select max(version)::int from public.audit_row_versions
    where table_name = 'departments'
      and record_id = '33333333-3333-3333-3333-333333330001'
  ),
  2,
  'departments UPDATE 产生快照（seed 首版 + 本次 = version=2）'
);

insert into public.positions (name, code, department_id)
values ('快照测试岗位', 'audit-snapshot-test', '33333333-3333-3333-3333-333333330001');

select is(
  (
    select v.version
    from public.audit_row_versions v
    join public.positions p on p.id::text = v.record_id
    where v.table_name = 'positions'
      and p.code = 'audit-snapshot-test'
  ),
  1,
  'positions INSERT 产生 version=1 首版'
);

-- ---------------------------------------------------------------------------
-- admin RPC：白名单管理（登记新表提示需另建迁移挂触发器 + 写 audit_log）
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '11111111-1111-1111-1111-111111111111')::text,
  true
);
set local role authenticated;

select is(
  public.upsert_row_version_whitelist('profiles', true) ->> 'trigger_installed',
  'true',
  'admin 启用已挂触发器表：trigger_installed=true'
);

select isnt(
  public.upsert_row_version_whitelist('audit_pgtap_new_table', true) ->> 'notice',
  null,
  '启用未挂触发器的新表返回 notice（需另建迁移挂触发器）'
);

select is(
  (
    select enabled from public.audit_row_version_whitelist
    where table_name = 'audit_pgtap_new_table'
  ),
  true,
  '新表白名单登记 enabled=true'
);

select is(
  (
    select count(*)::int from public.audit_operations
    where module = 'audit'
      and action = 'create'
      and object_type = 'row_version_whitelist'
      and object_id = 'audit_pgtap_new_table'
  ),
  1,
  '白名单登记写 audit_log'
);

-- ---------------------------------------------------------------------------
-- admin RPC：版本查询（get_row_versions / list_recent_versions）
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select version, change_type from public.get_row_versions(
       'profiles', '99999999-9999-9999-9999-999999990001'
     ) $$,
  $$ values (1, 'insert'::text), (2, 'update'::text), (3, 'update'::text) $$,
  'get_row_versions 按 version 升序返回且变更类型正确'
);

select is(
  (
    select changed_by_name from public.get_row_versions(
      'profiles', '99999999-9999-9999-9999-999999990001'
    ) where version = 3
  ),
  '快照测试用户改名2',
  'get_row_versions join 操作人姓名'
);

select is(
  (
    select count(*)::int
    from public.list_recent_versions('profiles', 1)
  ),
  1,
  'list_recent_versions 遵守 limit'
);

select is(
  (
    select changed_by_name from public.list_recent_versions('profiles', 1)
  ),
  '快照测试用户改名2',
  'list_recent_versions join 操作人姓名'
);

select throws_ok(
  $$ select * from public.get_row_versions('not_in_whitelist', 'x') $$,
  '22023',
  null,
  '非白名单表查询被拒'
);

reset role;

-- ---------------------------------------------------------------------------
-- DELETE 快照与变更类型推断（记录删除后末版 change_type=delete）
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '11111111-1111-1111-1111-111111111111')::text,
  true
);

delete from public.profiles
 where id = '99999999-9999-9999-9999-999999990001';

select is(
  (
    select change_type from public.get_row_versions(
      'profiles', '99999999-9999-9999-9999-999999990001'
    ) where version = 4
  ),
  'delete',
  '记录删除后末版 change_type=delete'
);

-- ---------------------------------------------------------------------------
-- 越权拒绝（engineer 调三个 RPC）
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '22222222-2222-2222-2222-222222220001')::text,
  true
);
set local role authenticated;

select throws_ok(
  $$ select public.upsert_row_version_whitelist('profiles', false) $$,
  '42501',
  null,
  'engineer 调用白名单管理 RPC 被拒'
);

select throws_ok(
  $$ select * from public.get_row_versions('profiles', 'x') $$,
  '42501',
  null,
  'engineer 调用版本查询 RPC 被拒'
);

select throws_ok(
  $$ select * from public.list_recent_versions('profiles', 10) $$,
  '42501',
  null,
  'engineer 调用最近变更 RPC 被拒'
);

reset role;

select * from finish();
rollback;
