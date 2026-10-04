-- audit 批次 1 / 修复项 1：denied 留痕生产者 public.record_denied_attempt
--
-- 问题：RLS 静默拒绝与页面守卫拒绝不会自动写日志，audit_denied_v 此前无生产方，
--   越权尝试视图长期为空（audit/operations.md 记录的「应用层捕获后调 audit_log」未落地）。
-- 修复：新增面向登录用户的公开包装 public.record_denied_attempt：
--   - 接入点 1：src/proxy.ts 403 user_banned 分支（module='auth'，封禁账号越权访问）；
--   - 接入点 2：src/components/forbidden-card.tsx（各 admin 守卫页 403 卡片挂载时上报，
--     module=业务模块标识、route=当前 pathname）；
--   - 内部仍经 app.audit_log(module, 'denied', 'route', route, {reason}) 统一入口写入。
--
-- 契约：
--   - module 白名单 = menu_items 的 10 个业务模块标识 + auth（代理层封禁专用标识）；
--   - route ≤200 截断、reason ≤500 截断（防止客户端构造超长值）；
--   - 限流：同用户 1 分钟 ≤20 条，超限静默丢弃（返回 NULL），避免刷量放大写入；
--   - SECURITY DEFINER + set search_path = '' + 全限定名（INDEX「RLS 统一声明模板」）；
--   - GRANT authenticated；anon 无 EXECUTE（越权本人不可打点自身以外的路径）。
--
-- 依赖：20261003205349（audit_operations / app.audit_log）、20261004091000（menu_items 模块登记）。

-- ---------------------------------------------------------------------------
-- 1. public.record_denied_attempt：越权尝试公开打点（authenticated）
-- ---------------------------------------------------------------------------
create function public.record_denied_attempt(
  p_module text,
  p_route  text,
  p_reason text
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_max_per_minute constant integer := 20;
  -- menu_items 登记的 10 个业务模块标识；auth 为代理层封禁专用标识（下方单独放行）
  c_modules constant text[] := array[
    'dashboard', 'org', 'access', 'approval', 'report',
    'audit', 'integration', 'sync', 'system', 'message'
  ];
  v_module text    := lower(btrim(coalesce(p_module, '')));
  v_route  text;
  v_reason text;
  v_uid    uuid    := (select auth.uid());
  v_recent integer;
begin
  if v_uid is null then
    raise exception '未登录不可记录越权尝试' using errcode = '42501';
  end if;

  if v_module <> 'auth' and not (v_module = any (c_modules)) then
    raise exception '未知模块：%', p_module using errcode = '22023';
  end if;

  -- 字段截断：route ≤200 / reason ≤500
  v_route := left(btrim(coalesce(p_route, '')), 200);
  if v_route = '' then
    raise exception '路由不能为空' using errcode = '22023';
  end if;
  v_reason := nullif(left(btrim(coalesce(p_reason, '')), 500), '');

  -- 防刷：同用户 1 分钟 ≤20 条；超限静默丢弃，不报错以免成为探测信号
  select count(*)::integer into v_recent
  from public.audit_operations
  where actor_id = v_uid
    and action = 'denied'
    and created_at > now() - interval '1 minute';

  if v_recent >= c_max_per_minute then
    return null;
  end if;

  return app.audit_log(
    v_module,
    'denied',
    'route',
    v_route,
    jsonb_build_object('reason', v_reason)
  );
end;
$$;

comment on function public.record_denied_attempt(text, text, text) is
  '越权尝试公开打点（authenticated）：module 白名单（10 业务模块 + auth）/ route ≤200 / '
  'reason ≤500 / 同用户 1 分钟 ≤20 条防刷；写经 app.audit_log(action=denied)，'
  '投影见 audit_denied_v';

-- ---------------------------------------------------------------------------
-- 2. 授权：仅 authenticated；anon 无路径
-- ---------------------------------------------------------------------------
revoke all on function public.record_denied_attempt(text, text, text)
  from public, anon;
grant execute on function public.record_denied_attempt(text, text, text)
  to authenticated;
