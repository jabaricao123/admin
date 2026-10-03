-- 权限管理 · 角色用户数统计 RPC（access/004）
-- 工单：access/004（角色管理页 /access/roles）
--
-- 背景（docs/modules/access/roles.md 验收标准）：
--   1. 列表需要「用户数统计列」，且数字要与 disable_role/delete_role 的人数诊断一致
--      （该角色下仍有 N 名用户 → 拒绝停用/删除），避免界面显示 0 而操作被拒；
--   2. 统计口径与守卫一致：profiles.role::text = roles.code，全量计数（含非 active 行）；
--   3. 在 DB 侧聚合，绕开 PostgREST max_rows=1000 对前端直查 profiles 的截断风险。
--
-- 权限：SECURITY DEFINER + 函数内 admin 校验（与 access/002 管理 RPC 同口径）；
--       roles / roles_v 名录读取仍走各自 RLS。

create function app.get_role_user_counts()
returns table (role_id uuid, role_code text, user_count bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  return query
  select
    r.id,
    r.code,
    (select count(*) from public.profiles p where p.role::text = r.code)
  from public.roles r;
end;
$$;

comment on function app.get_role_user_counts() is
  '角色用户数统计（admin）：按 profiles.role::text = roles.code 全量计数，口径与停用/删除守卫一致';

create function public.get_role_user_counts()
returns table (role_id uuid, role_code text, user_count bigint)
language sql
security definer
set search_path = ''
as $$
  select * from app.get_role_user_counts()
$$;

comment on function public.get_role_user_counts() is
  '角色用户数统计 Data API 薄包装（函数内 admin 校验）';

-- 授权：与 access/002 一致，仅 authenticated 可执行，函数内部再校验 admin
revoke all on function app.get_role_user_counts() from public, anon;
grant execute on function app.get_role_user_counts() to authenticated;

revoke all on function public.get_role_user_counts() from public, anon;
grant execute on function public.get_role_user_counts() to authenticated;
