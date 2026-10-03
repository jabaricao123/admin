-- 收紧 profiles 授权 + 收紧 public schema 默认权限
-- 背景：Supabase 默认会把 public 下新表的整表 ALL 权限授予 anon / authenticated，
-- 这会绕过列级限制（authenticated 直接拥有整表 UPDATE，可自助修改 role 提权）。
-- 处理原则：显式收回，再按需显式授权（secure by default）。

-- 1) profiles：只保留最小必需权限
revoke all on public.profiles from anon;
revoke insert, update, delete, truncate, references, trigger
  on public.profiles from authenticated;
grant select on public.profiles to authenticated;
grant update (full_name, department) on public.profiles to authenticated;

-- 2) 未来新对象默认不再自动授权给 anon / authenticated
--    需要暴露时由对应迁移显式 grant
alter default privileges in schema public
  revoke all on tables from anon, authenticated;
alter default privileges in schema public
  revoke all on sequences from anon, authenticated;
alter default privileges in schema public
  revoke execute on functions from anon, authenticated;
