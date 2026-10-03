-- pgTAP 冒烟测试：验证 pgTAP 可用与 profiles 基线
-- 运行：supabase test db

begin;
select plan(3);

select has_table('public', 'profiles', 'profiles 表存在');
select has_function('public', 'admin_update_profile', 'admin_update_profile 函数存在');
select ok(
  (select count(*) from public.profiles where role = 'admin') >= 1,
  'seed 后至少 1 个 admin'
);

select * from finish();
rollback;
