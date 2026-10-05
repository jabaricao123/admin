-- dashboard · 统计 RPC 收敛（dashboard 批次 2 修复项 2）
-- 决策：概览页统计切换到 org 公开 RPC org_stats()（20261005160000），dashboard 侧的
--   app.get_dashboard_stats 收编为「委托 org_stats」的兼容包装（deprecated），
--   避免两套统计实现长期双轨漂移；public 包装与旧调用方签名保持兼容。
--
-- 说明：
--   * org_stats 与 get_dashboard_stats 字段兼容（is_admin / total_users /
--     new_this_week / active_users / pending_todos + own.pending_todos），
--     org_stats 额外返回 total_departments / total_positions，页面按需取用；
--   * signup_trend 自 20261005160000 起已是 org 侧 create or replace 单实现，
--     本迁移不再重复定义（保持单实现，实现优化见 20261012120000）；
--   * 页面 src/app/(admin)/dashboard/page.tsx 改调 org_stats；
--   * 原 dashboard_stats 的早绑定问题（语言 sql 直引 app.my_todos）随委托消失，
--     org_stats 自身对 approval 保持软依赖（见 20261012120000）。
-- 依赖：20261005134000（get_dashboard_stats 原实现）、20261005160000（org_stats）。

-- ---------------------------------------------------------------------------
-- app.get_dashboard_stats：收编为 org_stats 委托（deprecated 兼容包装）
-- ---------------------------------------------------------------------------
create or replace function app.get_dashboard_stats()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select app.org_stats()
$$;

comment on function app.get_dashboard_stats() is
  'deprecated：工作台统计已收敛到 app.org_stats（本函数仅委托调用，兼容旧调用方）；'
  '新代码请直接使用 app.org_stats / public.org_stats';

comment on function public.get_dashboard_stats() is
  'get_dashboard_stats Data API 薄包装（deprecated 兼容：委托 org_stats；工作台页面已切换 public.org_stats）';
