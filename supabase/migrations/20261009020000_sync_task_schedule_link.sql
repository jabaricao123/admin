-- 第三方数据同步 · 批次 2 修复 2：任务停用联动调度停用（schedules.md：停用即时生效）
-- 背景：upsert_sync_task 把任务置 disabled 后，对应 sync_schedules 仍可能 active 且 pg_cron job
--       在册——run_scheduled_sync 因任务停用跳过执行（不产新 run），但 job 常驻、登记处仍 active，
--       属「任务停用不联动调度」缺口。
-- 方案：
--   * 新增内部 helper app.sync_disable_schedule_for_task(uuid)：给定任务停用其调度——
--       有运行中 run 且 cron 型 → disabled_pending_unschedule（job 保留，执行函数收尾注销；
--       与 set_sync_schedule_status 停用语义一致）；否则立即 disabled + 注销 job/登记；
--       已 disabled 幂等（兜底补一次注销）；写 set_status 审计（reason=task_disabled）。
--   * create or replace app.upsert_sync_task：任务 active→disabled 迁移时调用 helper（同一事务）；
--       disabled→active 不自动启用调度（需人工在调度页启用——避免误启用旧配置），
--       仅任务自身状态与版本快照按原语义更新。
-- 授权：helper 不 GRANT API 角色（内部，仅 upsert_sync_task / postgres 可达）。
-- pgTAP：sync_batch2_test.sql（任务停用 → 调度 disabled 且 cron.job 删除、登记 disabled；
--       反向启用不自动启用调度；有 running run 时 pending 保留 job）。
-- 依赖：20261004231000（upsert_sync_task 现状）、20261005031000（sync_schedules）、
--       20261009010000（注销 helper 已含登记联动）。

-- ---------------------------------------------------------------------------
-- 1. app.sync_disable_schedule_for_task：任务停用联动（内部 helper）
-- ---------------------------------------------------------------------------
create function app.sync_disable_schedule_for_task(p_task_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sch     public.sync_schedules;
  v_running boolean := false;
begin
  select * into v_sch
  from public.sync_schedules
  where task_id = p_task_id
  for update;

  if not found then
    return; -- 未配置调度：无联动
  end if;

  if v_sch.status = 'disabled' then
    -- 已停用：幂等兜底补一次注销（清理历史残留 job/登记）
    perform app.sync_schedule_unregister_cron(p_task_id);
    return;
  end if;

  select exists (
    select 1 from public.sync_runs r
    where r.task_id = p_task_id and r.status = 'running'
  ) into v_running;

  if v_sch.trigger_type = 'cron' and v_running then
    -- 当次跑完再注销：job 保留但 run_scheduled_sync 因任务停用不再产新 run，
    -- 由执行函数收尾（disabled_pending_unschedule → disabled）
    update public.sync_schedules
       set status      = 'disabled_pending_unschedule',
           next_run_at = null,
           updated_by  = (select auth.uid())
     where id = v_sch.id;

    perform app.audit_log(
      'sync', 'set_status', 'sync_schedule', v_sch.id::text,
      jsonb_build_object(
        'task_id', p_task_id,
        'status', 'disabled_pending_unschedule',
        'reason', 'task_disabled'
      )
    );
  else
    perform app.sync_schedule_unregister_cron(p_task_id);

    update public.sync_schedules
       set status      = 'disabled',
           next_run_at = null,
           updated_by  = (select auth.uid())
     where id = v_sch.id;

    perform app.audit_log(
      'sync', 'set_status', 'sync_schedule', v_sch.id::text,
      jsonb_build_object(
        'task_id', p_task_id,
        'status', 'disabled',
        'reason', 'task_disabled'
      )
    );
  end if;
end;
$$;

comment on function app.sync_disable_schedule_for_task(uuid) is
  '任务停用联动（内部 helper）：对应调度立即 disabled + 注销 pg_cron job/登记；'
  '存在运行中 run 且 cron 型时置 disabled_pending_unschedule（job 保留，执行函数收尾）；'
  '已 disabled 幂等兜底注销；写 set_status 审计（reason=task_disabled）；不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 2. app.upsert_sync_task：原逻辑不变 + active→disabled 联动调度停用
-- ---------------------------------------------------------------------------
create or replace function app.upsert_sync_task(
  p_id              uuid,
  p_name            text,
  p_source_id       uuid,
  p_target_table    text,
  p_direction       text,
  p_field_mapping   jsonb,
  p_conflict_policy text,
  p_status          text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev     public.sync_tasks;
  v_row      public.sync_tasks;
  v_source   public.sync_sources;
  v_creating boolean := false;
  v_status   text;
  v_snapshot jsonb;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_name is null or btrim(p_name) = '' then
    raise exception '任务名称不能为空' using errcode = '22023';
  end if;

  if p_direction is null or p_direction not in ('pull', 'push') then
    raise exception '同步方向不合法：%', coalesce(p_direction, '(null)') using errcode = '22023';
  end if;

  if p_conflict_policy is null or p_conflict_policy not in ('skip', 'overwrite', 'manual') then
    raise exception '冲突策略不合法：%', coalesce(p_conflict_policy, '(null)') using errcode = '22023';
  end if;

  if p_status is not null and p_status not in ('active', 'disabled') then
    raise exception '任务状态不合法：%', p_status using errcode = '22023';
  end if;

  perform app.validate_sync_mapping(p_target_table, p_field_mapping);

  if p_source_id is null then
    raise exception '数据源不能为空' using errcode = '22023';
  end if;

  select * into v_source
  from public.sync_sources
  where id = p_source_id;

  if not found then
    raise exception '数据源不存在：%', p_source_id using errcode = 'P0002';
  end if;

  select * into v_prev
  from public.sync_tasks
  where id = p_id
  for update;

  if not found then
    v_creating := true;
  end if;

  v_status := coalesce(p_status, case when v_creating then 'active' else v_prev.status end);

  -- 启用任务（新建 active 或 disabled→active）前置：数据源启用且已验证
  if v_status = 'active' and (v_creating or v_prev.status = 'disabled') then
    if v_source.status <> 'active' then
      raise exception '数据源已停用，无法启用任务' using errcode = '22023';
    end if;
    if v_source.verify_status <> 'verified' then
      raise exception '数据源尚未验证通过，无法启用任务（请先在数据源页完成测试验证）'
        using errcode = '22023';
    end if;
  end if;

  v_snapshot := jsonb_build_object(
    'name', btrim(p_name),
    'source_id', p_source_id,
    'target_table', p_target_table,
    'direction', p_direction,
    'field_mapping', p_field_mapping,
    'conflict_policy', p_conflict_policy,
    'status', v_status
  );

  if v_creating then
    insert into public.sync_tasks
      (name, source_id, target_table, direction, field_mapping,
       conflict_policy, status, config_version, created_by, updated_by)
    values
      (btrim(p_name), p_source_id, p_target_table, p_direction, p_field_mapping,
       p_conflict_policy, v_status, 1, (select auth.uid()), (select auth.uid()))
    returning * into v_row;

    insert into public.sync_task_versions (task_id, version, config, created_by)
    values (v_row.id, v_row.config_version, v_snapshot, (select auth.uid()));

    perform app.audit_log(
      'sync', 'upsert', 'sync_task', v_row.id::text,
      jsonb_build_object(
        'created', true,
        'source_id', v_row.source_id,
        'target_table', v_row.target_table,
        'direction', v_row.direction,
        'conflict_policy', v_row.conflict_policy,
        'status', v_row.status,
        'config_version', v_row.config_version,
        'mapping_fields', v_row.field_mapping
      )
    );
  else
    update public.sync_tasks
       set name            = btrim(p_name),
           source_id       = p_source_id,
           target_table    = p_target_table,
           direction       = p_direction,
           field_mapping   = p_field_mapping,
           conflict_policy = p_conflict_policy,
           status          = v_status,
           config_version  = v_prev.config_version + 1,
           updated_by      = (select auth.uid())
     where id = v_prev.id
    returning * into v_row;

    -- 任务停用联动调度（active→disabled；同事务锁定调度行）：立即停用 + 注销 job/登记，
    -- 有运行中 run 时置待注销由执行函数收尾（见 helper）。反向 disabled→active 不自动启用调度。
    if v_prev.status = 'active' and v_row.status = 'disabled' then
      perform app.sync_disable_schedule_for_task(v_row.id);
    end if;

    insert into public.sync_task_versions (task_id, version, config, created_by)
    values (v_row.id, v_row.config_version, v_snapshot, (select auth.uid()));

    perform app.audit_log(
      'sync', 'upsert', 'sync_task', v_row.id::text,
      jsonb_build_object(
        'created', false,
        'source_id', v_row.source_id,
        'target_table', v_row.target_table,
        'direction', v_row.direction,
        'conflict_policy', v_row.conflict_policy,
        'status_before', v_prev.status,
        'status_after', v_row.status,
        'config_version', v_row.config_version,
        'mapping_fields', v_row.field_mapping
      )
    );
  end if;

  return jsonb_build_object(
    'id', v_row.id,
    'name', v_row.name,
    'source_id', v_row.source_id,
    'target_table', v_row.target_table,
    'direction', v_row.direction,
    'field_mapping', v_row.field_mapping,
    'conflict_policy', v_row.conflict_policy,
    'status', v_row.status,
    'config_version', v_row.config_version,
    'updated_at', v_row.updated_at
  );
end;
$$;

comment on function app.upsert_sync_task(uuid, text, uuid, text, text, jsonb, text, text) is
  '同步任务新建/编辑 RPC（admin）：先经 app.validate_sync_mapping 校验（profiles 排除 role/status）；'
  '每次成功 upsert 将 config_version+1 并写入 sync_task_versions 完整快照；'
  '新建 active 或 disabled→active 要求数据源 active 且 verified；'
  'active→disabled 联动对应调度停用（disabled + 注销 job/登记；有运行中 run 时置待注销），'
  'disabled→active 不自动启用调度（需人工在调度页启用）；审计不落凭据（任务本身无凭据）';

-- ---------------------------------------------------------------------------
-- 3. 授权：helper 不 GRANT API 角色；upsert_sync_task 同签名 replace 保留原 ACL
-- ---------------------------------------------------------------------------
revoke all on function app.sync_disable_schedule_for_task(uuid)
  from public, anon, authenticated, service_role;
