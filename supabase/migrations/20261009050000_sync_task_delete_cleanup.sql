-- 第三方数据同步 · 批次 2 修复 5：删除任务孤儿 job 清理 + webhook token 哈希索引
-- 背景：
--   1. sync_tasks 删除（sync_schedules 走 FK on delete cascade）只清行，不清 pg_cron job：
--      任务删除后 'sync-task-<id>' job 仍会按点回调（回调因调度行不存在直接返回 NULL，
--      但 job 常驻且登记处 active → 孤儿/僵尸 job）；
--   2. trigger_sync_webhook 按 webhook_token_hash 等值查找，缺索引时随调度量增长退化为
--      顺序扫描（公开端点热路径）。
-- 方案：
--   * BEFORE DELETE 触发器：删任务前调 app.sync_schedule_unregister_cron（cron.unschedule +
--     登记 disabled，幂等），与删除同事务——删除回滚则 job/登记一并回滚；
--   * sync_schedules(webhook_token_hash) 常规索引（公开入口等值查找；NULL 行由 B-tree 正常处理）。
-- pgTAP：sync_batch2_test.sql（删任务后 cron.job 无残留、登记 disabled、级联行清理）。
-- 依赖：20261004231000（sync_tasks）、20261005031000（sync_schedules）、
--       20261009010000（注销 helper 已含登记联动）。

-- ---------------------------------------------------------------------------
-- 1. 删除任务前注销对应 pg_cron job + 登记（幂等）
-- ---------------------------------------------------------------------------
create function app.sync_task_delete_cron_cleanup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.sync_schedule_unregister_cron(old.id);
  return old;
end;
$$;

comment on function app.sync_task_delete_cron_cleanup() is
  'sync_tasks BEFORE DELETE 触发器函数：删除任务前注销 sync-task-<id> job 与登记'
  '（幂等；与删除同事务，回滚则一并回滚）；不 GRANT API 角色';

create trigger sync_tasks_delete_cron_cleanup
before delete on public.sync_tasks
for each row
execute function app.sync_task_delete_cron_cleanup();

-- ---------------------------------------------------------------------------
-- 2. webhook token 哈希索引（公开端点等值查找）
-- ---------------------------------------------------------------------------
create index sync_schedules_webhook_token_hash_idx
  on public.sync_schedules (webhook_token_hash);

comment on index public.sync_schedules_webhook_token_hash_idx is
  'public.trigger_sync_webhook 按 token 哈希等值查找的支撑索引（公开端点热路径）';

-- ---------------------------------------------------------------------------
-- 3. 授权：触发器函数不 GRANT API 角色
-- ---------------------------------------------------------------------------
revoke all on function app.sync_task_delete_cron_cleanup()
  from public, anon, authenticated, service_role;
