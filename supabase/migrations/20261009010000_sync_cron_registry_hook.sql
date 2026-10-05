-- 第三方数据同步 · 批次 2 修复 1：动态 sync-task-* job 登记 system 平台登记处（INDEX 规则 5）
-- 背景：system/011（20261005080000）留下 TODO(sync)：upsert_sync_schedule 注册/注销 pg_cron job 时
--       未联动 system_cron_registry，/system/jobs 监控中动态任务表现为缺失登记或孤儿。
-- 方案：登记/注销收敛到 sync 调度自身的 cron helper（唯一出入口，upsert / set_status /
--       执行收尾三条调用路径自动继承；不再在 upsert 分支里散点调用）：
--   * app.sync_schedule_register_cron(uuid, text, text)：cron.schedule 成功后调
--     app.register_cron_job('sync-task-<id>', 'sync', 表达式, 时区, '/sync/schedules')；
--   * app.sync_schedule_unregister_cron(uuid)：cron.unschedule 后调 app.unregister_cron_job
--     （置 disabled 保留历史；登记缺失幂等跳过）。
-- 签名变更：register helper 新增 p_timezone（default 'Asia/Shanghai'）以登记调度实际时区；
--   create or replace 不能改参数列表，故 drop 后重建——内部函数、零 API 授权、无外部依赖。
-- 授权：两 helper 均不 GRANT API 角色（INDEX 规则 10）；register_cron_job 同属主 postgres，
--   由 SECURITY DEFINER helper 内直接调用，不经 API 角色。
-- pgTAP：sync_batch2_test.sql（注册后 system_cron_registry 有 sync-task-* 行；注销后 disabled）。
-- 依赖：20261005031000（sync_schedules / 两 helper 现状）、20261005080000（register/unregister RPC）。

-- ---------------------------------------------------------------------------
-- 1. app.sync_schedule_register_cron：注册/更新 job + 登记（签名 + 时区参数）
-- ---------------------------------------------------------------------------
drop function app.sync_schedule_register_cron(uuid, text);

create function app.sync_schedule_register_cron(
  p_task_id   uuid,
  p_cron_expr text,
  p_timezone  text default 'Asia/Shanghai'
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job text := 'sync-task-' || p_task_id::text;
  v_tz  text := coalesce(nullif(btrim(coalesce(p_timezone, '')), ''), 'Asia/Shanghai');
begin
  if to_regprocedure('cron.schedule(text,text,text)') is null then
    raise exception 'pg_cron 未安装，无法注册定时调度' using errcode = '0A000';
  end if;

  begin
    perform cron.schedule(
      v_job,
      p_cron_expr,
      format('select public.run_scheduled_sync(%L)', p_task_id::text)
    );
  exception when others then
    raise exception 'cron 表达式注册失败：%', sqlerrm using errcode = '22023';
  end;

  -- INDEX 规则 5：调度统一在 system 平台登记处登记（规则 10：不 GRANT API 角色；
  -- 本函数 SECURITY DEFINER 属主 postgres，可直接调用）
  perform app.register_cron_job(v_job, 'sync', p_cron_expr, v_tz, '/sync/schedules');
end;
$$;

comment on function app.sync_schedule_register_cron(uuid, text, text) is
  '注册/更新该任务的 pg_cron job（同名幂等：pg_cron 对同名 schedule 执行更新）并登记 '
  'system_cron_registry（module=sync、owner_route=/sync/schedules、时区取调度配置）；'
  'job 命令 = select public.run_scheduled_sync(任务 id)；表达式的最终解析以 pg_cron 为准；'
  '不 GRANT API 角色（内部 helper，注册登记由属主 postgres 完成）';

-- ---------------------------------------------------------------------------
-- 2. app.sync_schedule_unregister_cron：注销 job + 登记 disabled（历史保留）
-- ---------------------------------------------------------------------------
create or replace function app.sync_schedule_unregister_cron(p_task_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job    text := 'sync-task-' || p_task_id::text;
  v_exists boolean := false;
begin
  if to_regclass('cron.job') is not null then
    execute format('select exists (select 1 from cron.job where jobname = %L)', v_job)
      into v_exists;

    if v_exists then
      execute format('select cron.unschedule(%L)', v_job);
    end if;
  end if;

  -- 登记注销（置 disabled 保留历史；不存在幂等），登记缺失不阻断停用/删除流程
  perform app.unregister_cron_job(v_job);
end;
$$;

comment on function app.sync_schedule_unregister_cron(uuid) is
  '注销该任务的 pg_cron job（不存在则幂等跳过；job 名 sync-task-<task_id>）并置 '
  'system_cron_registry.status=disabled（历史保留，重登记恢复 active）；不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 3. 授权：重建的 register helper 恢复零 API 授权（unregister 同签名 replace 保留原 ACL，
--    仍显式再收口一次）
-- ---------------------------------------------------------------------------
revoke all on function app.sync_schedule_register_cron(uuid, text, text)
  from public, anon, authenticated, service_role;
revoke all on function app.sync_schedule_unregister_cron(uuid)
  from public, anon, authenticated, service_role;
