-- 第三方数据同步 · 批次 2 修复 4：瞬态滞留收敛（disabled_pending_unschedule 不永久挂起）
-- 背景：pending 态（停用待注销）依赖「执行函数收尾」解除；若运行 run 已在编辑/停用之前结束
--       （跨事务时序）或编辑时改了 trigger_type，pending 会永久滞留：job 在册、登记 active、
--       却不再产生新 run。
-- 方案：
--   * create or replace app.upsert_sync_schedule：
--       - 仅「非新建 且 原为 active/pending 且 目标停用 且 cron 型 且 有运行中 run」进入 pending；
--       - 编辑保存时原 pending 若已无运行中 run，或 trigger_type 变化 → 立即收敛 disabled
--         并完成注销（job + 登记）；
--       - 注册调用补传调度时区（登记时区准确）。
--   * create or replace app.set_sync_schedule_status：停用分支同口径收敛（非 cron 不进入 pending；
--       注册调用补传时区）。
--   * 新增 AFTER UPDATE 触发器 sync_schedules_disable_cleanup：行状态迁移到 disabled 时兜底
--     注销 job/登记——覆盖执行函数收尾路径（sync/005 内联 unschedule 收敛为 disabled 时，
--     登记同步 disabled），保证不变量「status=disabled ⇒ pg_cron 无 job 且登记 disabled」。
-- 授权不变（同签名 replace 保留 ACL）；触发器函数不 GRANT API 角色。
-- pgTAP：sync_batch2_test.sql（pending 态改 trigger=manual → 收敛 disabled 且 job 已注销；
--       无运行 run 的 pending 编辑 → 收敛 disabled 且登记 disabled）。
-- 依赖：20261005031000（调度现状）、20261009010000（注册/注销 helper 已含登记联动）。

-- ---------------------------------------------------------------------------
-- 1. app.upsert_sync_schedule：原逻辑 + 瞬态收敛 + 时区登记
-- ---------------------------------------------------------------------------
create or replace function app.upsert_sync_schedule(
  p_task_id               uuid,
  p_trigger_type          text,
  p_cron_expr             text default null,
  p_timezone              text default null,
  p_status                text default null,
  p_regenerate_token      boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task        public.sync_tasks;
  v_prev        public.sync_schedules;
  v_creating    boolean := false;
  v_trigger     text := nullif(btrim(coalesce(p_trigger_type, '')), '');
  v_tz          text;
  v_status      text;
  v_cron        text;
  v_hash        text;
  v_token       text;
  v_src_status  text;
  v_src_verify  text;
  v_next        timestamptz;
  v_running     boolean := false;
  v_row         public.sync_schedules;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if v_trigger is null or v_trigger not in ('manual', 'cron', 'webhook') then
    raise exception '触发方式不合法（manual/cron/webhook）：%', coalesce(p_trigger_type, '(null)')
      using errcode = '22023';
  end if;

  if p_status is not null and p_status not in ('active', 'disabled') then
    raise exception '调度状态不合法（active/disabled）：%', p_status using errcode = '22023';
  end if;

  select * into v_task
  from public.sync_tasks
  where id = p_task_id
  for update;

  if not found then
    raise exception '同步任务不存在：%', coalesce(p_task_id::text, '(null)') using errcode = 'P0002';
  end if;

  select * into v_prev
  from public.sync_schedules
  where task_id = p_task_id
  for update;

  v_creating := not found;

  v_tz := coalesce(
    nullif(btrim(coalesce(p_timezone, '')), ''),
    case when v_creating then 'Asia/Shanghai' else v_prev.timezone end
  );

  if not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = v_tz) then
    raise exception '时区不存在：%', v_tz using errcode = '22023';
  end if;

  v_status := coalesce(
    p_status,
    case
      when v_creating then case when v_task.status = 'active' then 'active' else 'disabled' end
      else v_prev.status
    end
  );

  v_running := exists (
    select 1 from public.sync_runs r
    where r.task_id = p_task_id and r.status = 'running'
  );

  -- 停用（含待注销延续）：cron 型且存在运行中 run → 待注销（job 保留到当次跑完，
  -- 执行函数收尾注销）；新建调度无历史 job，不进入瞬态
  if not v_creating
     and v_prev.status in ('active', 'disabled_pending_unschedule')
     and v_status in ('disabled', 'disabled_pending_unschedule')
     and v_trigger = 'cron'
     and v_running then
    v_status := 'disabled_pending_unschedule';
  end if;

  -- 瞬态收敛（编辑保存时）：原 pending 若保留 job 的条件已消失 → 立即 disabled 并完成注销
  --   (a) 已无运行中 run（等待条件消失）；
  --   (b) trigger_type 变化（原 cron job 不再匹配新触发方式）。
  if not v_creating
     and v_prev.status = 'disabled_pending_unschedule'
     and v_status = 'disabled_pending_unschedule'
     and (not v_running or v_trigger is distinct from v_prev.trigger_type) then
    v_status := 'disabled';
  end if;

  -- 启用前置：任务启用 + 数据源启用且已验证（schedules.md）
  if v_status = 'active' then
    if v_task.status <> 'active' then
      raise exception '任务未启用，无法启用调度（请先启用任务）' using errcode = '22023';
    end if;

    select s.status, s.verify_status
      into v_src_status, v_src_verify
    from public.sync_sources s
    where s.id = v_task.source_id;

    if v_src_status <> 'active' or v_src_verify <> 'verified' then
      raise exception '数据源未启用或未验证通过，无法启用调度' using errcode = '22023';
    end if;
  end if;

  -- cron 表达式：cron 型必填且先过内部语法校验（pg_cron 注册为最终闸门）
  v_cron := nullif(
    btrim(coalesce(p_cron_expr, case when v_creating then null else v_prev.cron_expr end, '')),
    ''
  );

  if v_trigger = 'cron' then
    if v_cron is null then
      raise exception 'cron 型调度必须填写 cron 表达式' using errcode = '22023';
    end if;
    if not app.cron_expr_valid(v_cron) then
      raise exception 'cron 表达式不合法（v1 支持五段数字语法：* / N / a-b / */n / 列表）'
        using errcode = '22023';
    end if;
  else
    v_cron := null;
  end if;

  -- webhook token：生成 'st_' + uuid；明文仅本次返回，哈希落库；显式重置才轮换
  v_hash := case when v_creating then null else v_prev.webhook_token_hash end;
  v_token := null;

  if v_trigger = 'webhook' and (p_regenerate_token or v_hash is null) then
    v_token := 'st_' || gen_random_uuid()::text;
    v_hash := encode(extensions.digest(v_token, 'sha256'), 'hex');
  end if;

  -- pg_cron job 同步：active cron → 注册 + 登记（时区随调度）；disabled cron / 非 cron →
  -- 注销 + 登记 disabled；disabled_pending_unschedule 保留 job（执行函数收尾注销）
  if v_trigger = 'cron' and v_status = 'active' then
    perform app.sync_schedule_register_cron(p_task_id, v_cron, v_tz);
  elsif v_trigger <> 'cron' or v_status = 'disabled' then
    perform app.sync_schedule_unregister_cron(p_task_id);
  end if;

  v_next := case
    when v_trigger = 'cron' and v_status = 'active'
      then app.next_cron_run(v_cron, v_tz, now())
    else null
  end;

  if v_creating then
    insert into public.sync_schedules
      (task_id, trigger_type, cron_expr, timezone, webhook_token_hash,
       status, next_run_at, created_by, updated_by)
    values
      (p_task_id, v_trigger, v_cron, v_tz, v_hash,
       v_status, v_next, (select auth.uid()), (select auth.uid()))
    returning * into v_row;
  else
    update public.sync_schedules
       set trigger_type       = v_trigger,
           cron_expr          = v_cron,
           timezone           = v_tz,
           webhook_token_hash = v_hash,
           status             = v_status,
           next_run_at        = v_next,
           updated_by         = (select auth.uid())
     where id = v_prev.id
    returning * into v_row;
  end if;

  perform app.audit_log(
    'sync', 'upsert', 'sync_schedule', v_row.id::text,
    jsonb_build_object(
      'task_id', p_task_id,
      'trigger_type', v_trigger,
      'cron_expr', v_cron,
      'timezone', v_tz,
      'status', v_status,
      'token_rotated', v_token is not null
    )
  );

  return jsonb_build_object(
    'id', v_row.id,
    'task_id', v_row.task_id,
    'trigger_type', v_row.trigger_type,
    'cron_expr', v_row.cron_expr,
    'timezone', v_row.timezone,
    'status', v_row.status,
    'last_run_at', v_row.last_run_at,
    'next_run_at', v_row.next_run_at,
    'webhook_token', v_token
  );
end;
$$;

comment on function app.upsert_sync_schedule(uuid, text, text, text, text, boolean) is
  '调度新建/编辑 RPC（admin）：cron 型校验表达式并注册 pg_cron job（含 system 登记，时区随调度）；'
  'webhook 型生成 st_<uuid> token（明文一次性返回、sha256 落库；p_regenerate_token 轮换）；'
  '启用要求任务启用且数据源已验证；停用有 running run 时置 disabled_pending_unschedule 待执行函数收尾，'
  '编辑保存时无 running run 或 trigger_type 变化则立即收敛 disabled 并完成注销（防瞬态滞留）';

-- ---------------------------------------------------------------------------
-- 2. app.set_sync_schedule_status：停用同口径收敛 + 时区登记
-- ---------------------------------------------------------------------------
create or replace function app.set_sync_schedule_status(p_task_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task       public.sync_tasks;
  v_prev       public.sync_schedules;
  v_src_status text;
  v_src_verify text;
  v_status     text;
  v_token      text;
  v_hash       text;
  v_next       timestamptz;
  v_row        public.sync_schedules;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_status is null or p_status not in ('active', 'disabled') then
    raise exception '调度状态不合法（active/disabled）：%', coalesce(p_status, '(null)')
      using errcode = '22023';
  end if;

  select * into v_task
  from public.sync_tasks
  where id = p_task_id
  for update;

  if not found then
    raise exception '同步任务不存在：%', coalesce(p_task_id::text, '(null)') using errcode = 'P0002';
  end if;

  select * into v_prev
  from public.sync_schedules
  where task_id = p_task_id
  for update;

  if not found then
    raise exception '调度不存在：%', p_task_id using errcode = 'P0002';
  end if;

  v_hash := v_prev.webhook_token_hash;
  v_token := null;

  if p_status = 'active' then
    if v_prev.status = 'active' then
      return jsonb_build_object(
        'task_id', p_task_id, 'status', v_prev.status, 'webhook_token', null
      );
    end if;

    if v_task.status <> 'active' then
      raise exception '任务未启用，无法启用调度（请先启用任务）' using errcode = '22023';
    end if;

    select s.status, s.verify_status
      into v_src_status, v_src_verify
    from public.sync_sources s
    where s.id = v_task.source_id;

    if v_src_status <> 'active' or v_src_verify <> 'verified' then
      raise exception '数据源未启用或未验证通过，无法启用调度' using errcode = '22023';
    end if;

    v_status := 'active';

    if v_prev.trigger_type = 'cron' then
      perform app.sync_schedule_register_cron(p_task_id, v_prev.cron_expr, v_prev.timezone);
      v_next := app.next_cron_run(v_prev.cron_expr, v_prev.timezone, now());
    elsif v_prev.trigger_type = 'webhook' and v_hash is null then
      v_token := 'st_' || gen_random_uuid()::text;
      v_hash := encode(extensions.digest(v_token, 'sha256'), 'hex');
    end if;
  else
    -- 停用：cron 有运行中 run → 待注销（job 保留但不再产新 run，执行函数收尾注销）；
    -- 其余（无运行中 run / 非 cron）立即停用并注销 job + 登记
    if v_prev.trigger_type = 'cron' and exists (
      select 1 from public.sync_runs r
      where r.task_id = p_task_id and r.status = 'running'
    ) then
      v_status := 'disabled_pending_unschedule';
    else
      perform app.sync_schedule_unregister_cron(p_task_id);
      v_status := 'disabled';
    end if;
    v_next := null;
  end if;

  update public.sync_schedules
     set status             = v_status,
         webhook_token_hash = v_hash,
         next_run_at        = v_next,
         updated_by         = (select auth.uid())
   where id = v_prev.id
  returning * into v_row;

  perform app.audit_log(
    'sync', 'set_status', 'sync_schedule', v_row.id::text,
    jsonb_build_object('task_id', p_task_id, 'status', v_status, 'token_generated', v_token is not null)
  );

  return jsonb_build_object(
    'id', v_row.id,
    'task_id', v_row.task_id,
    'trigger_type', v_row.trigger_type,
    'status', v_row.status,
    'next_run_at', v_row.next_run_at,
    'webhook_token', v_token
  );
end;
$$;

comment on function app.set_sync_schedule_status(uuid, text) is
  '调度启停 RPC（admin）：启用要求任务启用且数据源已验证（cron 注册含 system 登记与时区）；'
  '停用时 cron 有 running run 置 disabled_pending_unschedule，否则立即注销 job/登记并置 disabled';

-- ---------------------------------------------------------------------------
-- 3. 不变量触发器：status → disabled 时兜底注销 job/登记
--    覆盖执行函数收尾（execute_sync_task 内联 unschedule 后置 disabled）与任何后续新增路径；
--    unregister 幂等，与显式注销调用叠加无副作用。
-- ---------------------------------------------------------------------------
create function app.sync_schedule_disable_cleanup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'disabled' and old.status is distinct from 'disabled' then
    perform app.sync_schedule_unregister_cron(new.task_id);
  end if;
  return new;
end;
$$;

comment on function app.sync_schedule_disable_cleanup() is
  'sync_schedules AFTER UPDATE 触发器函数：行状态迁移到 disabled 时注销 pg_cron job 与登记'
  '（幂等）；保证 status=disabled ⇒ 无 job 且登记 disabled 的不变量；不 GRANT API 角色';

create trigger sync_schedules_disable_cleanup
after update on public.sync_schedules
for each row
execute function app.sync_schedule_disable_cleanup();

-- ---------------------------------------------------------------------------
-- 4. 授权：触发器函数不 GRANT API 角色（两 RPC 同签名 replace 保留原 ACL）
-- ---------------------------------------------------------------------------
revoke all on function app.sync_schedule_disable_cleanup()
  from public, anon, authenticated, service_role;
