-- sync/009 + integration/010：app.execute_sync_task 追加 sync.run_finished 发射点
-- 工单：sync/009（菜单登记 + emit_event 发射点）、integration/010（首期发射点验收）
-- 契约：docs/modules/integration/webhooks.md「首期发射点契约：approval、org、sync」、
--       docs/modules/INDEX.md 规则 10（emit_event 不 GRANT authenticated，各模块经自身
--       SECURITY DEFINER RPC 或后端 wrapper 调用）。
--
-- 背景：sync/005 的 app.execute_sync_task 尚未接 emit_event（发射点后补工单）；
-- 本迁移仅 create or replace 该函数，在终态落库后追加 sync.run_finished 事件：
--   * 软依赖 integration/004（同 approval_engine 对 emit_event 的先例）：
--     to_regprocedure 判存，未合入自动跳过，不阻塞 sync 迁移链；
--   * 事件在 run 终态（success/partial/failed）与 audit 摘要之后、失败通知之前发出，
--     与 sync_runs 同一事务：队列落库与执行记录互不脱节；
--   * payload：{run_id, task_id, status, trigger, stats}（订阅端排障/联动用）；
--   * 发射失败不应吞掉执行结果？——与 approval 先例一致不做 exception 包裹：emit_event
--     为同库同事务的本地插入，失败即整体回滚（宁可不落半状态）；function 不存在时才跳过。
--
-- 依赖：sync/005（app.execute_sync_task 现状）、integration/004（app.emit_event，软依赖）。
-- 授权不变：create or replace 保留原 REVOKE/GRANT；emit_event 依旧不授予 API 角色。

-- ---------------------------------------------------------------------------
-- app.execute_sync_task：原逻辑不变；终态追加 sync.run_finished 入队
-- ---------------------------------------------------------------------------
create or replace function app.execute_sync_task(
  p_task_id uuid,
  p_trigger text,
  p_sample  jsonb default null
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  c_max_error_lines constant integer := 20;
  v_task     public.sync_tasks;
  v_run_id   uuid;
  v_owner    uuid;
  v_row      jsonb;
  v_map      jsonb;
  v_source   text;
  v_field    text;
  v_value    text;
  v_data     jsonb;
  v_match    text;
  v_row_key  text;
  v_target   jsonb;
  v_exists   boolean;
  v_insert   integer := 0;
  v_update   integer := 0;
  v_conflict integer := 0;
  v_skip     integer := 0;
  v_failed   integer := 0;
  v_notes    text[] := '{}';
  v_stats    jsonb;
  v_status   text;
  v_error    text;
begin
  if p_trigger is null or p_trigger not in ('manual', 'cron', 'webhook') then
    raise exception '触发类型不合法：%', coalesce(p_trigger, '(null)') using errcode = '22023';
  end if;

  -- 手动触发必须 admin（cron/webhook 由受信 wrapper/受控 token 校验后进入）
  if p_trigger = 'manual' and (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可手动执行同步任务' using errcode = '42501';
  end if;

  select * into v_task
  from public.sync_tasks
  where id = p_task_id;

  if not found then
    raise exception '同步任务不存在：%', coalesce(p_task_id::text, '(null)') using errcode = 'P0002';
  end if;

  if v_task.status <> 'active' then
    raise exception '同步任务已停用，无法执行：%', v_task.name using errcode = '22023';
  end if;

  if v_task.direction <> 'pull' then
    raise exception '推送方向（push）执行不在 v1 范围' using errcode = '22023';
  end if;

  perform app.validate_sync_mapping(v_task.target_table, v_task.field_mapping);

  if p_sample is not null and jsonb_typeof(p_sample) <> 'array' then
    raise exception '样本必须为 JSON 数组（每行一个对象）' using errcode = '22023';
  end if;

  -- 单任务并发 1：事务级 advisory lock（同事务重复触发/并发触发直接拒绝）
  if not pg_try_advisory_xact_lock(hashtextextended(v_task.id::text, 0)) then
    raise exception '同步任务正在执行中，拒绝重复触发' using errcode = '55006';
  end if;

  -- 已有 running 记录（如入口被绕过）同样拒绝
  if exists (
    select 1 from public.sync_runs r
    where r.task_id = v_task.id and r.status = 'running'
  ) then
    raise exception '同步任务已有执行中的记录，拒绝重复触发' using errcode = '55006';
  end if;

  v_owner := case
    when p_trigger = 'manual' then coalesce((select auth.uid()), v_task.created_by)
    else v_task.created_by
  end;

  -- 属主身份注入（ADR-001）：见文件头偏离说明；供 audit 行版本等按 auth.uid() 读取的触发器
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text,
    true
  );

  insert into public.sync_runs (task_id, trigger_type, status, stats, executed_by)
  values (
    v_task.id, p_trigger, 'running',
    '{"insert":0,"update":0,"conflict":0,"skip":0,"failed":0}'::jsonb,
    v_owner
  )
  returning id into v_run_id;

  v_match := case v_task.target_table
    when 'departments' then 'name'
    when 'positions'   then 'code'
    when 'profiles'    then 'email'
  end;

  for v_row in select value from jsonb_array_elements(coalesce(p_sample, '[]'::jsonb)) loop
    if jsonb_typeof(v_row) <> 'object' then
      raise exception '样本行必须为 JSON 对象：%', v_row::text using errcode = '22023';
    end if;

    -- 按映射构建目标字段值（优先 source_field，回退目标字段名；与 dry-run 同语义）
    v_data := '{}'::jsonb;
    for v_map in select value from jsonb_array_elements(v_task.field_mapping) loop
      v_source := v_map ->> 'source_field';
      v_field  := v_map ->> 'target_field';
      v_value  := nullif(btrim(coalesce(v_row ->> v_source, '')), '');
      if v_value is null then
        v_value := nullif(btrim(coalesce(v_row ->> v_field, '')), '');
      end if;
      if v_value is not null then
        v_data := v_data || jsonb_build_object(v_field, v_value);
      end if;
    end loop;

    v_row_key := nullif(btrim(coalesce(v_data ->> v_match, v_row ->> v_match, '')), '');
    if v_row_key is null then
      v_skip := v_skip + 1;
      continue;
    end if;

    v_data := v_data || jsonb_build_object(v_match, v_row_key);

    -- 目标行现状（匹配键：departments 名称（未删除）/ positions 编码 / profiles 邮箱）
    v_target := null;
    if v_task.target_table = 'departments' then
      select to_jsonb(d) into v_target
      from public.departments d
      where d.name = v_row_key and d.status <> 'deleted'
      order by (d.status = 'active') desc, d.sort_order, d.id
      limit 1;
    elsif v_task.target_table = 'positions' then
      select to_jsonb(p) into v_target
      from public.positions p
      where p.code = v_row_key
      limit 1;
    else
      select to_jsonb(p) into v_target
      from public.profiles p
      where lower(p.email) = lower(v_row_key)
      order by p.id
      limit 1;
    end if;
    v_exists := v_target is not null;

    begin
      if not v_exists then
        if v_task.target_table = 'profiles' then
          -- profiles 仅更新不新建：未匹配计入 skip（与 dry-run 同语义）
          v_skip := v_skip + 1;
        else
          perform app.sync_apply_target(v_task.id, v_data, 'insert');
          v_insert := v_insert + 1;
        end if;
      else
        case v_task.conflict_policy
          when 'skip' then
            v_skip := v_skip + 1;
          when 'overwrite' then
            perform app.sync_apply_target(v_task.id, v_data, 'update');
            v_update := v_update + 1;
          when 'manual' then
            insert into public.sync_conflicts (run_id, row_key, source_data, target_data)
            values (v_run_id, v_row_key, v_data, v_target);
            v_conflict := v_conflict + 1;
        end case;
      end if;
    exception when others then
      v_failed := v_failed + 1;
      if cardinality(v_notes) < c_max_error_lines then
        v_notes := v_notes || format('行 %s：%s', coalesce(v_row_key, '?'), sqlerrm);
      end if;
    end;
  end loop;

  v_stats := jsonb_build_object(
    'insert', v_insert, 'update', v_update,
    'conflict', v_conflict, 'skip', v_skip, 'failed', v_failed
  );

  -- 状态机：全成功且无待裁决冲突 success；有失败且无成功写入 failed；其余 partial
  v_status := case
    when v_failed = 0 and v_conflict = 0 then 'success'
    when v_failed > 0 and (v_insert + v_update) = 0 then 'failed'
    else 'partial'
  end;

  v_error := case
    when cardinality(v_notes) > 0 then array_to_string(v_notes, E'\n')
    else null
  end;

  update public.sync_runs
     set status = v_status, stats = v_stats, error = v_error, finished_at = now()
   where id = v_run_id;

  -- 调度收尾（schedules.md）：本任务存在调度行时更新 last/next_run_at；
  -- 停用待注销（disabled_pending_unschedule）在本次跑完后注销 pg_cron job 并收敛为 disabled。
  update public.sync_schedules s
     set last_run_at = now(),
         next_run_at = case
           when s.trigger_type = 'cron' and s.status = 'active'
             then app.next_cron_run(s.cron_expr, s.timezone, now())
           else null
         end,
         updated_at = now()
   where s.task_id = v_task.id;

  if exists (
    select 1 from public.sync_schedules s
    where s.task_id = v_task.id and s.status = 'disabled_pending_unschedule'
  ) then
    if to_regclass('cron.job') is not null then
      begin
        execute format('select cron.unschedule(%L)', 'sync-task-' || v_task.id::text);
      exception when others then
        null; -- job 已不存在等按幂等处理
      end;
    end if;

    update public.sync_schedules
       set status = 'disabled', updated_at = now()
     where task_id = v_task.id and status = 'disabled_pending_unschedule';
  end if;

  -- 审计摘要（INDEX 规则 2：明细在 sync_runs，audit 只记摘要）
  perform app.audit_log(
    'sync', 'execute', 'sync_run', v_run_id::text,
    jsonb_build_object(
      'task_id', v_task.id,
      'task_name', v_task.name,
      'trigger', p_trigger,
      'status', v_status,
      'stats', v_stats
    )
  );

  -- 首期发射点（sync/009 + integration/010）：sync.run_finished 软依赖 integration/004；
  -- 未合入时 to_regprocedure 为 NULL，自动跳过（同 approval_engine 对 emit_event 的先例）。
  if to_regprocedure('app.emit_event(text,jsonb)') is not null then
    perform app.emit_event(
      'sync.run_finished',
      jsonb_build_object(
        'run_id', v_run_id, 'task_id', v_task.id, 'status', v_status,
        'trigger', p_trigger, 'stats', v_stats
      )
    );
  elsif to_regprocedure('public.emit_event(text,jsonb)') is not null then
    perform public.emit_event(
      'sync.run_finished',
      jsonb_build_object(
        'run_id', v_run_id, 'task_id', v_task.id, 'status', v_status,
        'trigger', p_trigger, 'stats', v_stats
      )
    );
  end if;

  -- 终态失败通知属主（ADR-001 §3）；通知失败不影响执行记录落库
  if v_status = 'failed' and v_owner is not null then
    begin
      perform app.send_notification(
        v_owner,
        'sync.execute_failed',
        jsonb_build_object(
          'title', '同步任务执行失败',
          'body', format('任务「%s」执行失败：%s', v_task.name, left(coalesce(v_error, ''), 300)),
          'source_module', 'sync',
          'ref_type', 'sync_run',
          'ref_id', v_run_id::text
        )
      );
    exception when others then
      null;
    end;
  end if;

  return v_run_id;
end;
$$;

comment on function app.execute_sync_task(uuid, text, jsonb) is
  '同步执行入口（SECURITY INVOKER，撤销 API 角色；仅 pg_cron postgres 与同属主 DEFINER wrapper 可达）：'
  '手动触发校验 admin；单任务事务级 advisory lock + running 记录双重并发拒绝；'
  '样本经 field_mapping 映射后写入白名单目标表（profiles 仅更新不新建）；'
  '冲突策略 skip/overwrite/manual（manual 写 sync_conflicts pending）；状态机 running→success/partial/failed；'
  '属主身份 claims 注入（ADR-001，PG17 禁用 definer 内 SET ROLE 的偏离说明见迁移文件头）；'
  '终态写 audit 摘要 + emit_event(''sync.run_finished'', {run_id,task_id,status,trigger,stats})'
  '（软依赖 integration/004）+ 失败 send_notification 通知属主；返回 run id。v1 执行输入 = p_sample（真实拉取为 v2）';
