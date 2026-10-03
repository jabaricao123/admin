-- pgTAP：audit/006 —— audit_row_versions 快照表 / 白名单 / 通用触发器
-- 运行：supabase test db
begin;
select plan(23);

-- ---------------------------------------------------------------------------
-- 结构
-- ---------------------------------------------------------------------------
select has_table('public', 'audit_row_versions', 'audit_row_versions 表存在');
select has_column('public', 'audit_row_versions', 'version', 'version 列存在');
select col_is_pk('public', 'audit_row_versions', 'id', 'id 为主键');
select has_table('public', 'audit_row_version_whitelist', 'audit_row_version_whitelist 表存在');
select col_is_pk('public', 'audit_row_version_whitelist', 'table_name', 'table_name 为主键');
select has_function('app', 'audit_row_version_trigger', 'app.audit_row_version_trigger() 存在');
select is(
  (select relrowsecurity from pg_class where oid = 'public.audit_row_versions'::regclass),
  true,
  'audit_row_versions 已启用 RLS'
);
select is(
  (select relrowsecurity from pg_class where oid = 'public.audit_row_version_whitelist'::regclass),
  true,
  'audit_row_version_whitelist 已启用 RLS'
);

-- 首期白名单登记
select results_eq(
  $$ select table_name from public.audit_row_version_whitelist order by table_name $$,
  $$ values ('departments'::text), ('positions'::text), ('profiles'::text) $$,
  '白名单登记 departments/positions/profiles'
);

-- ---------------------------------------------------------------------------
-- append-only：authenticated 直写被拒
-- ---------------------------------------------------------------------------
set local role authenticated;
select throws_ok(
  $$ insert into public.audit_row_versions (table_name, record_id, version, data) values ('x', '1', 1, '{}') $$,
  '42501', null, 'authenticated 直 INSERT audit_row_versions 被拒'
);
select throws_ok(
  $$ update public.audit_row_versions set version = 99 $$,
  '42501', null, 'authenticated 直 UPDATE audit_row_versions 被拒'
);
select throws_ok(
  $$ delete from public.audit_row_versions $$,
  '42501', null, 'authenticated 直 DELETE audit_row_versions 被拒'
);
select throws_ok(
  $$ insert into public.audit_row_version_whitelist (table_name) values ('hack') $$,
  '42501', null, 'authenticated 直 INSERT whitelist 被拒'
);
select throws_ok(
  $$ update public.audit_row_version_whitelist set enabled = false $$,
  '42501', null, 'authenticated 直 UPDATE whitelist 被拒'
);
reset role;

-- ---------------------------------------------------------------------------
-- 触发器演练：临时表挂载（不碰任何业务表）
-- ---------------------------------------------------------------------------
insert into public.audit_row_version_whitelist (table_name)
values ('audit_pgtap_demo');

create temp table audit_pgtap_demo (
  id   bigint generated always as identity primary key,
  name text,
  qty  int
);

create trigger audit_pgtap_demo_versions
after insert or update or delete on audit_pgtap_demo
for each row
execute function app.audit_row_version_trigger();

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '11111111-1111-1111-1111-111111111111')::text,
  true
);

insert into audit_pgtap_demo (name, qty) values ('v1', 1);

select results_eq(
  $$ select version, data ->> 'name', data ->> 'qty', changed_by
       from public.audit_row_versions
      where table_name = 'audit_pgtap_demo' $$,
  $$ values (1, 'v1'::text, '1'::text, '11111111-1111-1111-1111-111111111111'::uuid) $$,
  'INSERT 产生 version=1 首版快照且 changed_by 记录'
);

update audit_pgtap_demo set qty = 2 where name = 'v1';

select results_eq(
  $$ select version, data ->> 'qty'
       from public.audit_row_versions
      where table_name = 'audit_pgtap_demo'
      order by version $$,
  $$ values (1, '1'::text), (2, '2'::text) $$,
  'UPDATE 产生 version=2 快照'
);

delete from audit_pgtap_demo where name = 'v1';

select results_eq(
  $$ select version, data ->> 'name', data ->> 'qty'
       from public.audit_row_versions
      where table_name = 'audit_pgtap_demo'
      order by version $$,
  $$ values (1, 'v1'::text, '1'::text), (2, 'v1'::text, '2'::text), (3, 'v1'::text, '2'::text) $$,
  'DELETE 产生 version=3 快照（删除前整行）'
);

insert into audit_pgtap_demo (name, qty) values ('v2', 5);

select is(
  (select version from public.audit_row_versions
    where table_name = 'audit_pgtap_demo' and data ->> 'name' = 'v2'),
  1,
  '新记录版本号重置为 version=1'
);

-- 白名单 enabled=false 时不快照
update public.audit_row_version_whitelist
   set enabled = false
 where table_name = 'audit_pgtap_demo';
insert into audit_pgtap_demo (name, qty) values ('skipped', 9);

select is(
  (select count(*)::int from public.audit_row_versions
    where table_name = 'audit_pgtap_demo' and data ->> 'name' = 'skipped'),
  0,
  '白名单 enabled=false 时不写快照'
);

-- 未登记白名单的表不快照
create temp table audit_pgtap_unlisted (
  id   bigint generated always as identity primary key,
  name text
);

create trigger audit_pgtap_unlisted_versions
after insert on audit_pgtap_unlisted
for each row
execute function app.audit_row_version_trigger();

insert into audit_pgtap_unlisted (name) values ('x');

select is(
  (select count(*)::int from public.audit_row_versions where table_name = 'audit_pgtap_unlisted'),
  0,
  '未登记白名单的表不写快照'
);

-- ---------------------------------------------------------------------------
-- RLS：仅 admin 可读
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '11111111-1111-1111-1111-111111111111')::text,
  true
);
set local role authenticated;
select cmp_ok(
  (select count(*)::int from public.audit_row_versions),
  '>', 0,
  'admin 可读版本快照'
);
reset role;

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '22222222-2222-2222-2222-222222220001')::text,
  true
);
set local role authenticated;
select is(
  (select count(*)::int from public.audit_row_versions),
  0,
  'engineer 不可读版本快照'
);
select is(
  (select count(*)::int from public.audit_row_version_whitelist),
  0,
  'engineer 不可读白名单'
);
reset role;

select * from finish();
rollback;
