-- 组织管理 · 用户停用兜底（org_ban_guard）
-- 工单：批次 2（停用用户即时禁止登录）
--
-- 目的：无论停用操作走哪条写入路径（admin_update_profile RPC、SQL 维护、
--       后续新增 RPC），profiles.status 变更都同步 auth.users.banned_until，
--       从数据库侧保证「停用后立即无法登录、启用后恢复」。
--
-- 分工：
--   * 应用主路径（Server Action banUser）仍调 Auth Admin API ban/unban 并
--     清除当前浏览器会话 Cookie；
--   * 本触发器是兜底：与 Admin API 写同一列（banned_until），幂等不冲突；
--     直改 SQL/漏调 API 时登录同样被 GoTrue 拒绝（"User is banned"）；
--   * 已有会话的数据访问由 app.current_role()（status='active' 才返回角色）
--     与 RLS 兜底，代理层（src/proxy.ts）负责把停用账号强制登出。
--
-- 授权：函数仅由触发器以属主（postgres）身份执行，不 GRANT API 角色
--       （INDEX 规则 10：内部工具函数不开放 EXECUTE）。

create function app.sync_profile_ban()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- 停用 → 封禁（约 100 年，与 Server Action 的 ban_duration '876000h' 一致）；
  -- 启用 → 解除封禁（NULL 即未封禁）
  update auth.users
     set banned_until = case
           when new.status = 'inactive'
             then now() + interval '876000 hours'
           else null
         end
   where id = new.id;

  return new;
end;
$$;

comment on function app.sync_profile_ban() is
  'profiles.status ↔ auth.users.banned_until 同步兜底：inactive → 封禁约 100 年，'
  'active → 解除封禁；security definer，仅触发器调用，不 GRANT API 角色';

revoke all on function app.sync_profile_ban() from public, anon, authenticated;

create trigger profiles_sync_ban
after update of status on public.profiles
for each row
when (new.status is distinct from old.status)
execute function app.sync_profile_ban();

comment on trigger profiles_sync_ban on public.profiles is
  '停用/启用兜底：status 实际变化时同步 Auth 层 banned_until（org_ban_guard）';
