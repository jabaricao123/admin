-- 处理 advisors 告警：
-- 1) 平台自带函数 public.rls_auto_enable() 不应对 API 角色开放（linter 0028/0029）
--    它只作为事件触发器使用，撤销 API 角色的 EXECUTE 不影响自动启用 RLS 的机制
-- 2) 合并 profiles 的两个 SELECT 策略，减少每行策略评估（linter 0006）

revoke execute on function public.rls_auto_enable() from public, anon, authenticated;

drop policy profiles_select_self on public.profiles;
drop policy profiles_select_internal on public.profiles;

create policy profiles_select
on public.profiles
for select
to authenticated
using ((select auth.uid()) = id or app.is_internal());
