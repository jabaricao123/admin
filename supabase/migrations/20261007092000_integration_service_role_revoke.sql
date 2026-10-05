-- 接口/集成中心 · 批次 1 安全修复：service_role 权限清理（ADR-001）
-- 背景：Supabase 默认权限把新建函数的 EXECUTE 自动授予 service_role；integration/007 的
--       migration 又把 integration_call_logs / integration_call_stats_daily 的 SELECT 显式
--       授予 service_role。ADR-001 全局禁令：service_role 仅限 Supabase Auth Admin 调用，
--       禁止任何数据面（业务表 / RPC）读写。
-- 本迁移只做权限收口（不改函数体）：
--   1. revoke execute：管理/测试 RPC 的 public 薄包装与 app 实现（create/revoke_api_key、
--      create/update/disable/enable/get_webhooks、test_webhook、webhook_test_result）；
--   2. revoke select：integration_call_logs、integration_call_stats_daily。
-- 对标 integration_api_docs_test 的断言模式（service_role 全 false）；authenticated 权限不变。
-- 依赖：integration/001、004、005、006、007（上述函数与表已存在）。

-- ---------------------------------------------------------------------------
-- 1. 管理/测试 RPC：service_role 零执行权（public 薄包装 + app 实现）
-- ---------------------------------------------------------------------------
revoke execute on function public.create_api_key(text, jsonb, timestamptz) from service_role;
revoke execute on function public.revoke_api_key(uuid) from service_role;
revoke execute on function public.create_webhook(text, text, text[], jsonb, jsonb) from service_role;
revoke execute on function public.update_webhook(uuid, text, text, text[], jsonb, jsonb) from service_role;
revoke execute on function public.disable_webhook(uuid) from service_role;
revoke execute on function public.enable_webhook(uuid) from service_role;
revoke execute on function public.get_webhooks() from service_role;
revoke execute on function public.test_webhook(uuid) from service_role;
revoke execute on function public.webhook_test_result(bigint) from service_role;

-- app 实现面同步收口（PostgREST 不暴露 app schema，属纵深防御）
revoke execute on function app.create_api_key(text, jsonb, timestamptz) from service_role;
revoke execute on function app.revoke_api_key(uuid) from service_role;
revoke execute on function app.create_webhook(text, text, text[], jsonb, jsonb) from service_role;
revoke execute on function app.update_webhook(uuid, text, text, text[], jsonb, jsonb) from service_role;
revoke execute on function app.disable_webhook(uuid) from service_role;
revoke execute on function app.enable_webhook(uuid) from service_role;
revoke execute on function app.get_webhooks() from service_role;
revoke execute on function app.test_webhook(uuid) from service_role;
revoke execute on function app.webhook_test_result(bigint) from service_role;

-- ---------------------------------------------------------------------------
-- 2. 调用日志明细/聚合：service_role 零 SELECT（此前显式 GRANT 撤销）
-- ---------------------------------------------------------------------------
revoke select on public.integration_call_logs from service_role;
revoke select on public.integration_call_stats_daily from service_role;
