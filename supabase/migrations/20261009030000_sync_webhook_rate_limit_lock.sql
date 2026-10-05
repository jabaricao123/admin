-- 第三方数据同步 · 批次 2 修复 3：webhook 限流原子化（并发下精确 60 次/分钟）
-- 背景：原 trigger_sync_webhook「查近 1 分钟计数 → 受理执行」之间存在竞态：并发同 token 请求
--       可同时读到 <60 后被全部受理，突破限流上限。
-- 方案：以事务级 advisory lock 串行化同一 token 的「计数 + 受理」窗口：
--   * 锁键 = hashtextextended('sync-webhook:' || btrim(p_token), 0)；带命名空间前缀，
--     与任务执行锁（hashtextextended(task_id, 0)）区分，避免误与任务锁串扰；
--   * pg_try_advisory_xact_lock 失败（同 token 已有请求在计数/受理中）→ 立即 raise 53400
--     （429 语义，客户端退避重试）；不做阻塞排队，避免请求在同步执行期间堆积；
--   * 锁为事务级：execute_sync_task 在同一事务内完成，提交/回滚即释放；
--     串行后计数可见前序已提交 run，边界精确（第 61 次拒绝）；被拒请求不计数（维持原语义）。
-- 授权与签名不变（create or replace 保留 ACL）：公开端点 GRANT anon/authenticated。
-- pgTAP：sync_batch2_test.sql（60/61 边界行为保持；并发语义以注释说明——pgTAP 单会话无法并发，
--       锁竞争路径以代码审查为准）。
-- 依赖：20261005031000（trigger_sync_webhook 现状）、20261005030000（execute_sync_task）。

-- ---------------------------------------------------------------------------
-- public.trigger_sync_webhook：token 验签 → 同 token 串行化 → 限流 → execute webhook
-- ---------------------------------------------------------------------------
create or replace function public.trigger_sync_webhook(p_token text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash     text;
  v_schedule public.sync_schedules;
  v_task     public.sync_tasks;
  v_recent   bigint;
begin
  if p_token is null or btrim(p_token) = '' then
    raise exception 'Webhook token 无效' using errcode = '42501';
  end if;

  v_hash := encode(extensions.digest(btrim(p_token), 'sha256'), 'hex');

  -- 原子化限流：同一 token 的「计数 + 受理」串行化（事务级 advisory lock，提交即释放）。
  -- 并发同 token 触发时仅一个请求进入窗口，其余立即 429（53400）由客户端退避重试；
  -- execute_sync_task 在同一事务内执行，锁覆盖受理全过程，故计数不会少读并发的在途 run。
  if not pg_try_advisory_xact_lock(hashtextextended('sync-webhook:' || btrim(p_token), 0)) then
    raise exception 'Webhook 触发并发过高，请稍后重试' using errcode = '53400';
  end if;

  select * into v_schedule
  from public.sync_schedules s
  where s.webhook_token_hash = v_hash
    and s.trigger_type = 'webhook';

  if not found then
    raise exception 'Webhook token 无效' using errcode = '42501';
  end if;

  select * into v_task
  from public.sync_tasks t
  where t.id = v_schedule.task_id;

  if v_schedule.status <> 'active' or v_task.status <> 'active' then
    raise exception '调度或任务已停用，拒绝触发' using errcode = '22023';
  end if;

  -- 限流：同任务近 1 分钟已受理的 webhook run ≥ 60 → 拒绝（v1 简化：按 run 计数，
  -- 被拒请求不计数；即每分钟最多受理 60 次）
  select count(*) into v_recent
  from public.sync_runs r
  where r.task_id = v_schedule.task_id
    and r.trigger_type = 'webhook'
    and r.started_at > now() - interval '1 minute';

  if v_recent >= 60 then
    raise exception 'Webhook 触发超过速率限制（60 次/分钟）' using errcode = '53400';
  end if;

  return app.execute_sync_task(v_schedule.task_id, 'webhook');
end;
$$;

comment on function public.trigger_sync_webhook(text) is
  '公开 webhook 触发端点（GRANT anon）：sha256 比对 token（仅 webhook 型调度）；调度/任务停用拒绝；'
  '同 token 事务级 advisory lock 串行化「计数+受理」（并发冲突立即 53400/429，不阻塞排队），'
  '同任务近 1 分钟 webhook run ≥ 60 拒绝；执行身份 = 任务 created_by；返回 run id';
