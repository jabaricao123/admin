-- 第三方数据同步 · run 契约批次：rejected 收敛 / 输入快照 / claims 还原 / 执行主流程最终版
-- 工单：sync 数据正确性批次 1（修复 3 的 run 收尾）+ 批次 4（input_summary、claims 还原）
--
-- 背景：
--   1. app.execute_sync_task 状态机把全部 rejected 冲突（防环等系统拒写）计入 nondeterministic
--      的 partial：无任何失败行、无待裁决 pending 冲突也永久 partial；rejected 冲突又不可人工
--      裁决（resolve_sync_conflict 仅接受 pending），该 run 永远无法收敛；resolve 收尾逻辑
--      （20261005030000 §7）对存量同类记录同样无触发路径；
--   2. sync_runs 未记录执行输入快照：cron/webhook 空跑与 manual 样本跑无法事后区分，
--      重跑时也无从核对「上次喂了什么样本」；
--   3. execute_sync_task 注入 request.jwt.claims 后不还原（PG 会话内 set_config local 仅到
--      事务末或子事务退出），DEFINER wrapper 调用链中后续语句会读到属主身份而非调用者身份。
--
-- 语义（本迁移）：
--   1. public.sync_runs 新增 input_summary jsonb（{sample_rows, sample_hash=md5(p_sample::text)}；
--      p_sample 为空时为 NULL）；execute 落库时写入；rerun_sync_task 未传样本时 raise notice
--      提示最近一次带样本执行的快照（v1 无法按哈希重放，v2 拉取通道上线后据此核对）；
--   2. app.execute_sync_task（最终版）：在 20261005181000 语义基础上
--        * profiles email 重复行执行前拦截（failed，不写任何行；与 20261008060000 的
--          sync_apply_target 守卫同口径）；
--        * 状态机区分待裁决冲突（pending）与系统拒绝（rejected）：无失败行且无 pending
--          冲突即 success —— rejected 属策略性拒绝、非错误；有失败行且无成功写入 failed，
--          其余 partial 不变；
--        * claims 注入前保存原值，正常收尾与 exception 路径均 set_config 还原；
--        * 其余（锁/审计/发射点/通知/防环/同名标注）与 20261005181000 逐行一致；
--   3. app.resolve_sync_conflict：收尾收敛条件注释对齐 rejected 语义（逻辑不变：无 pending
--      冲突 + 无失败行 + error 为空才 partial→success）；
--   4. 存量收敛：历史上「全 rejected 且无失败行」的 partial run 一次性收敛为 success。
--
-- 依赖：20261008060000（sync_apply_target email/部门守卫）、20261005181000（执行函数现状）、
--       20261005030000（resolve 收尾现状、sync_runs 表）。
-- 授权不变：create or replace 保留 20261005030000 文末的 REVOKE/GRANT。

-- ---------------------------------------------------------------------------
-- 1. sync_runs.input_summary：执行输入快照
-- ---------------------------------------------------------------------------
alter table public.sync_runs
  add column input_summary jsonb,
  add constraint sync_runs_input_summary_object_check
    check (input_summary is null or jsonb_typeof(input_summary) = 'object');

comment on column public.sync_runs.input_summary is
  'v1 执行输入快照：{sample_rows, sample_hash=md5(p_sample::text)}；p_sample 为空（cron/webhook 空跑）为 NULL；'
  'v1 无法按哈希重放样本，供重跑核对与 v2 真实拉取对照';

comment on column public.sync_runs.status is
  '状态机：running 执行中 / success 成功（无失败行且无待裁决冲突；全部冲突为 rejected 时同样 success，'
  'rejected 属策略性拒绝、非错误）/ partial 部分成功（存在失败行或待裁决 pending 冲突）/ failed 失败';
comment on column public.sync_runs.stats is
  '计数：{insert, update, conflict, skip, failed}（conflict=进入冲突队列的行数：manual pending + 防环 rejected）';

-- ---------------------------------------------------------------------------
-- 2. app.execute_sync_task：email 重复拦截 + rejected 收敛 + 输入快照 + claims 还原
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
  v_task             public.sync_tasks;
  v_run_id           uuid;
  v_owner            uuid;
  v_claims_prev      text;
  v_input_summary    jsonb;
  v_row              jsonb;
  v_map              jsonb;
  v_source           text;
  v_field            text;
  v_value            text;
  v_data             jsonb;
  v_match            text;
  v_row_key          text;
  v_target           jsonb;
  v_exists           boolean;
  v_parent_cnt       bigint;
  v_email_cnt        bigint;
  v_new_parent       uuid;
  v_reject_reason    text;
  v_insert           integer := 0;
  v_update           integer := 0;
  v_conflict         integer := 0;
  v_conflict_pending integer := 0;
  v_skip             integer := 0;
  v_failed           integer := 0;
  v_notes            text[] := '{}';
  v_stats_notes      text[] := '{}';
  v_stats            jsonb;
  v_status           text;
  v_error            text;
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

  -- claims 注入前保存原值（批次 4）：正常收尾与 exception 路径都还原，避免 wrapper
  -- 调用链的后续语句读到属主身份；原值未初始化时以空串表达「无 claims」。
  v_claims_prev := current_setting('request.jwt.claims', true);

  -- 属主身份注入（ADR-001）：见 20261005030000 文件头偏离说明；供 audit 行版本等按 auth.uid() 读取的触发器
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_owner, 'role', 'authenticated')::text,
    true
  );

  -- 以下全部工作置于同一收敛块：异常路径先还原 claims 再向上抛出
  begin
    -- 输入快照（批次 4）：v1 执行输入 = p_sample；为空时 NULL（cron/webhook 空跑）
    v_input_summary := case
      when p_sample is null then null::jsonb
      else jsonb_build_object(
        'sample_rows', jsonb_array_length(p_sample),
        'sample_hash', md5(p_sample::text)
      )
    end;

    insert into public.sync_runs (task_id, trigger_type, status, stats, input_summary, executed_by)
    values (
      v_task.id, p_trigger, 'running',
      '{"insert":0,"update":0,"conflict":0,"skip":0,"failed":0}'::jsonb,
      v_input_summary,
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

      -- email 重复守卫（批次 1）：profiles 目标行不唯一时整行失败、不写任何行
      -- （sync_apply_target 内同样兜底 23505；dry-run 以 failed 计数与 notes 对齐）
      if v_task.target_table = 'profiles' then
        select count(*) into v_email_cnt
        from public.profiles p
        where lower(p.email) = lower(v_row_key);

        if v_email_cnt > 1 then
          v_failed := v_failed + 1;
          if cardinality(v_notes) < c_max_error_lines then
            v_notes := v_notes || format('行 %s：email 重复 %s 行，拒绝写入', v_row_key, v_email_cnt);
          end if;
          continue;
        end if;
      end if;

      -- 同名 parent_name 收紧：解析口径为 active + sort_order 最小（sync_resolve_ref
      -- 与 org/007 回填一致）；存在多个同名 active 行时在 stats.notes 标注歧义
      if v_task.target_table = 'departments' and v_data ? 'parent_name' then
        select count(*) into v_parent_cnt
        from public.departments d
        where d.name = v_data ->> 'parent_name'
          and d.status = 'active';

        if v_parent_cnt > 1 then
          v_stats_notes := v_stats_notes || format(
            '行 %s：上级部门「%s」有 %s 个同名 active 部门，取 sort_order 最小者',
            v_row_key, v_data ->> 'parent_name', v_parent_cnt
          );
        end if;
      end if;

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

      -- 防环预校验（sync_dept_guard）：更新已存在部门 parent_id 前校验移动合法性；
      -- overwrite 违规不写入转 rejected 冲突；manual 违规直接记 rejected（避免不可采纳的 pending）
      v_reject_reason := null;
      if v_exists
         and v_task.target_table = 'departments'
         and v_data ? 'parent_name'
         and v_task.conflict_policy in ('overwrite', 'manual') then
        begin
          select d.id into v_new_parent
          from public.departments d
          where d.name = v_data ->> 'parent_name'
            and d.status = 'active'
          order by d.sort_order, d.id
          limit 1;

          if v_new_parent is null then
            raise exception '上级部门不存在或未启用：%', v_data ->> 'parent_name'
              using errcode = 'P0002';
          end if;

          perform app.validate_department_move((v_target ->> 'id')::uuid, v_new_parent);
        exception when others then
          v_reject_reason := sqlerrm;
        end;
      end if;

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
              if v_reject_reason is not null then
                -- 防环拒绝：记 rejected 冲突，不写入目标行
                insert into public.sync_conflicts
                  (run_id, row_key, source_data, target_data, resolution, resolved_at)
                values (
                  v_run_id, v_row_key, v_data,
                  coalesce(v_target, '{}'::jsonb)
                    || jsonb_build_object('reject_reason', v_reject_reason),
                  'rejected', now()
                );
                v_conflict := v_conflict + 1;
                v_stats_notes := v_stats_notes
                  || format('行 %s：防环拒绝（%s）', v_row_key, v_reject_reason);
              else
                perform app.sync_apply_target(v_task.id, v_data, 'update');
                v_update := v_update + 1;
              end if;
            when 'manual' then
              insert into public.sync_conflicts
                (run_id, row_key, source_data, target_data, resolution, resolved_at)
              values (
                v_run_id, v_row_key, v_data,
                case
                  when v_reject_reason is not null
                    then coalesce(v_target, '{}'::jsonb)
                         || jsonb_build_object('reject_reason', v_reject_reason)
                  else v_target
                end,
                case when v_reject_reason is not null then 'rejected' else 'pending' end,
                case when v_reject_reason is not null then now() else null end
              );
              if v_reject_reason is not null then
                v_stats_notes := v_stats_notes
                  || format('行 %s：防环拒绝（%s）', v_row_key, v_reject_reason);
              else
                -- 待裁决冲突（pending）：唯一会长期拉低 run 状态的冲突类型
                v_conflict_pending := v_conflict_pending + 1;
              end if;
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

    if cardinality(v_stats_notes) > 0 then
      v_stats := v_stats || jsonb_build_object('notes', to_jsonb(v_stats_notes));
    end if;

    -- 状态机（批次 1）：无失败行且无待裁决冲突 → success；有失败且无成功写入 → failed；
    -- 其余 partial。rejected（防环等系统拒绝）属策略性拒绝、非错误：全部冲突为 rejected
    -- 且无失败行时收敛 success，不再永久 partial（rejected 不可人工裁决）。
    v_status := case
      when v_failed = 0 and v_conflict_pending = 0 then 'success'
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

    -- claims 还原（正常路径）
    perform set_config('request.jwt.claims', coalesce(v_claims_prev, ''), true);

    return v_run_id;
  exception when others then
    -- claims 还原（异常路径）
    perform set_config('request.jwt.claims', coalesce(v_claims_prev, ''), true);
    raise;
  end;
end;
$$;

comment on function app.execute_sync_task(uuid, text, jsonb) is
  '同步执行入口（SECURITY INVOKER，撤销 API 角色；仅 pg_cron postgres 与同属主 DEFINER wrapper 可达）：'
  '手动触发校验 admin；单任务事务级 advisory lock + running 记录双重并发拒绝；'
  '样本经 field_mapping 映射后写入白名单目标表（profiles 仅更新不新建；email 重复行 failed 不写）；'
  '冲突策略 skip/overwrite/manual（manual 写 sync_conflicts pending；防环违规写 rejected）；'
  '状态机 running→success/partial/failed：无失败且无待裁决冲突即 success（rejected 属策略性拒绝、非错误），'
  '有失败且无成功写入 failed，其余 partial；departments 更新 parent_id 前防环预校验；'
  '属主身份 claims 注入（ADR-001）并在收尾/异常路径还原；input_summary 记录样本行数与 md5 哈希；'
  '终态写 audit 摘要 + emit_event(''sync.run_finished'', {run_id,task_id,status,trigger,stats})'
  '（软依赖 integration/004）+ 失败 send_notification 通知属主；返回 run id。v1 执行输入 = p_sample（真实拉取为 v2）';

-- ---------------------------------------------------------------------------
-- 3. app.resolve_sync_conflict：收尾收敛注释对齐 rejected 语义（逻辑不变）
-- ---------------------------------------------------------------------------
create or replace function app.resolve_sync_conflict(p_conflict_id uuid, p_resolution text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_conflict public.sync_conflicts;
  v_run      public.sync_runs;
  v_task     public.sync_tasks;
  v_mapping  jsonb;
  v_pending  bigint;
  v_run_status text;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_resolution is null or p_resolution not in ('adopted', 'ignored') then
    raise exception '裁决结果不合法（adopted/ignored）：%', coalesce(p_resolution, '(null)')
      using errcode = '22023';
  end if;

  select * into v_conflict
  from public.sync_conflicts
  where id = p_conflict_id
  for update;

  if not found then
    raise exception '冲突记录不存在：%', coalesce(p_conflict_id::text, '(null)') using errcode = 'P0002';
  end if;

  -- rejected 为系统拒绝（防环等不可人工采纳），与 pending 之外的状态一样不可重复处理
  if v_conflict.resolution <> 'pending' then
    raise exception '冲突已裁决（%），不能重复处理', v_conflict.resolution using errcode = '22023';
  end if;

  select * into v_run
  from public.sync_runs
  where id = v_conflict.run_id
  for update;

  select * into v_task
  from public.sync_tasks
  where id = v_run.task_id;

  if p_resolution = 'adopted' then
    -- 防御性复核：source_data 键必须全部在白名单内（含 profiles 排除 role/status）
    select coalesce(
             jsonb_agg(jsonb_build_object('source_field', k.key, 'target_field', k.key)),
             '[]'::jsonb
           )
      into v_mapping
    from jsonb_object_keys(v_conflict.source_data) as k(key);

    perform app.validate_sync_mapping(v_task.target_table, v_mapping);

    -- 采纳 = 以源值更新目标行（rows.md：用源值覆盖；不存在/重复则拒绝）
    perform app.sync_apply_target(v_task.id, v_conflict.source_data, 'update');
  end if;

  update public.sync_conflicts
     set resolution  = p_resolution,
         resolved_by = (select auth.uid()),
         resolved_at = now()
   where id = p_conflict_id;

  -- 该 run 无剩余 pending 冲突且无失败行 → partial 收敛 success（runs.md 验收：裁决后状态一致）。
  -- rejected 冲突不可裁决且属策略性拒绝、非错误：存量全 rejected 的 partial 由本迁移
  -- 末尾一次性收敛；新执行已在状态机直接判 success，此处覆盖跨版本裁决的收尾场景。
  select count(*) into v_pending
  from public.sync_conflicts c
  where c.run_id = v_run.id and c.resolution = 'pending';

  if v_pending = 0
     and v_run.status = 'partial'
     and coalesce((v_run.stats ->> 'failed')::int, 0) = 0
     and v_run.error is null then
    update public.sync_runs set status = 'success' where id = v_run.id;
  end if;

  select status into v_run_status from public.sync_runs where id = v_run.id;

  perform app.audit_log(
    'sync', 'resolve', 'sync_conflict', p_conflict_id::text,
    jsonb_build_object(
      'resolution', p_resolution,
      'run_id', v_run.id,
      'task_id', v_task.id,
      'run_status', v_run_status
    )
  );

  return jsonb_build_object(
    'id', p_conflict_id,
    'resolution', p_resolution,
    'resolved_at', now(),
    'run_status', v_run_status
  );
end;
$$;

comment on function app.resolve_sync_conflict(uuid, text) is
  '冲突人工裁决（admin）：adopted=以 source_data 按匹配键更新目标行（引用字段重新解析、'
  'profiles 不新建，email 重复拒绝）；ignored=仅标记；rejected 不可裁决；重复裁决/越界键拒绝；'
  '裁决后 run 无 pending 冲突且无失败行时 partial→success（rejected 属策略性拒绝、不影响收敛）；'
  '写审计摘要';

-- ---------------------------------------------------------------------------
-- 4. app.rerun_sync_task：未传样本时提示最近一次输入快照（v2 复现依据）
-- ---------------------------------------------------------------------------
create or replace function app.rerun_sync_task(p_task_id uuid, p_sample jsonb default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_summary jsonb;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  -- 批次 4：未传样本时提示最近一次带样本执行的 input_summary。v1 无真实拉取通道，
  -- 哈希无法重放样本，仅作核对/排障依据；v2 拉取通道上线后可按快照对比源端数据。
  if p_sample is null then
    select r.input_summary into v_summary
    from public.sync_runs r
    where r.task_id = p_task_id
      and r.input_summary is not null
    order by r.started_at desc, r.id desc
    limit 1;

    if v_summary is not null then
      raise notice 'rerun 未提供样本：最近一次带样本执行快照 sample_rows=% sample_hash=%'
        '（v1 无法按快照重放，v2 拉取通道上线后据此核对）',
        v_summary ->> 'sample_rows', v_summary ->> 'sample_hash';
    end if;
  end if;

  -- 重跑 = 同一执行函数的 manual 新 run；幂等由 conflict_policy 保证（runs.md）
  return app.execute_sync_task(p_task_id, 'manual', p_sample);
end;
$$;

comment on function app.rerun_sync_task(uuid, jsonb) is
  '重跑（admin）：调同一 app.execute_sync_task（manual 新 run，单一实现）；'
  '幂等由任务 conflict_policy 保证；p_sample 为 v1 执行输入通道，未传时 raise notice '
  '提示最近一次带样本执行的 input_summary（v2 拉取通道上线后据此核对，v1 无法按哈希重放）';

-- ---------------------------------------------------------------------------
-- 5. 存量收敛：全 rejected 且无失败行的历史 partial run → success
-- ---------------------------------------------------------------------------
update public.sync_runs r
   set status = 'success'
 where r.status = 'partial'
   and coalesce((r.stats ->> 'failed')::int, 0) = 0
   and r.error is null
   and exists (
     select 1 from public.sync_conflicts c
     where c.run_id = r.id and c.resolution = 'rejected'
   )
   and not exists (
     select 1 from public.sync_conflicts c
     where c.run_id = r.id and c.resolution = 'pending'
   );
