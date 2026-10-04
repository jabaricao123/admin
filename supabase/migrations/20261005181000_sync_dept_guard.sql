-- 第三方数据同步 · 部门同步防环 + 同名名单收紧（审计缺口修复 · 批次 1 / sync 侧）
-- 背景：app.execute_sync_task 对 departments.parent_id 的更新绕过了 org 的
--       app.validate_department_move 防环校验，构造样本可让部门树成环；
--       且 parent_name 解析允许命中 disabled 行、同名多行时不标歧义。
--
-- 语义：
--   1. departments 同级（coalesce(parent_id, 全零 uuid) + name，未删除）名称唯一索引，
--      从数据源头消除「同级同名」歧义（org/007 回填与 sync 解析的歧义根源）；
--      upsert_department 的 unique_violation 中文提示见 20261005180000；
--   2. app.sync_resolve_ref：departments.parent_name 收紧为「仅 active + sort_order
--      最小 + id 决胜」，与 org/007 回填规则一致；无 active 命中 raise P0002；
--   3. app.sync_apply_target：departments 更新 parent_id 前对每个命中行调
--      app.validate_department_move（防环兜底，违规 raise 22023，不写入）；
--   4. app.execute_sync_task：
--        * 同名多 active 的 parent_name 命中在 sync_runs.stats.notes 标注歧义；
--        * overwrite/manual 策略下更新 parent_id 前预校验防环：违规行不写入，
--          记 conflict（sync_conflicts.resolution='rejected'，target_data.reject_reason
--          带拒绝原因，resolved_at 落时间），并计入 stats.conflict 与 stats.notes；
--        * 其余行为（锁/状态机/审计摘要/发射点/失败通知）与 20261005170000 逐行一致。
--
-- 说明：sync_conflicts.resolution 取值由 pending/adopted/ignored 扩展
--       rejected（系统拒绝：防环等不可人工采纳的冲突；resolved_at 非空、resolved_by 空）。
--
-- 依赖：sync/005（execute_sync_task / sync_apply_target / sync_resolve_ref 现状）、
--       sync/009（20261005170000 现状）、org/001（validate_department_move）。

-- ---------------------------------------------------------------------------
-- 1. sync_conflicts.resolution：扩展 rejected（系统拒绝，不可人工采纳）
-- ---------------------------------------------------------------------------
alter table public.sync_conflicts
  drop constraint sync_conflicts_resolution_check;

alter table public.sync_conflicts
  add constraint sync_conflicts_resolution_check
  check (resolution in ('pending', 'adopted', 'ignored', 'rejected'));

comment on column public.sync_conflicts.resolution is
  '裁决：pending 待处理 / adopted 采纳源值 / ignored 忽略 / '
  'rejected 系统拒绝（防环等不可采纳冲突，resolved_at 非空、resolved_by 空）';

-- ---------------------------------------------------------------------------
-- 2. departments 同级名称唯一索引（未删除行；防同名歧义根源）
--    软删除（status=deleted）不参与约束，允许历史重名留档。
-- ---------------------------------------------------------------------------
create unique index departments_parent_name_key
  on public.departments (
    coalesce(parent_id, '00000000-0000-0000-0000-000000000000'::uuid),
    name
  )
  where status <> 'deleted';

comment on index public.departments_parent_name_key is
  '同级部门名称唯一（coalesce(parent_id) + name，未删除行）；软删除不参与；'
  '从源头消除 org/007 回填与 sync parent_name 解析的同级同名歧义';

-- ---------------------------------------------------------------------------
-- 3. app.sync_resolve_ref：parent_name 收紧为 active + sort_order 最小
-- ---------------------------------------------------------------------------
create or replace function app.sync_resolve_ref(p_target text, p_field text, p_value text)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_value text := nullif(btrim(coalesce(p_value, '')), '');
  v_id    uuid;
begin
  if v_value is null then
    return null;
  end if;

  if p_target = 'departments' and p_field = 'parent_name' then
    -- 收紧（与 org/007 回填规则一致）：仅 active、sort_order 最小、id 决胜；
    -- 无可选 active 行即视为不存在（disabled 不再作为上级兜底）
    select d.id into v_id
    from public.departments d
    where d.name = v_value
      and d.status = 'active'
    order by d.sort_order, d.id
    limit 1;
    if v_id is null then
      raise exception '上级部门不存在或未启用：%', v_value using errcode = 'P0002';
    end if;
  elsif p_target = 'departments' and p_field = 'leader_email' then
    select p.id into v_id
    from public.profiles p
    where lower(p.email) = lower(v_value)
    order by (p.status = 'active') desc, p.id
    limit 1;
    if v_id is null then
      raise exception '负责人邮箱不存在：%', v_value using errcode = 'P0002';
    end if;
  elsif p_target = 'positions' and p_field = 'department_name' then
    select d.id into v_id
    from public.departments d
    where d.name = v_value and d.status = 'active'
    order by d.sort_order, d.id
    limit 1;
    if v_id is null then
      raise exception '所属部门不存在或未启用：%', v_value using errcode = 'P0002';
    end if;
  elsif p_target = 'profiles' and p_field = 'position_code' then
    select p.id into v_id
    from public.positions p
    where p.code = v_value
    limit 1;
    if v_id is null then
      raise exception '岗位编码不存在：%', v_value using errcode = 'P0002';
    end if;
  else
    raise exception '不支持的引用字段：% / %', p_target, p_field using errcode = '22023';
  end if;

  return v_id;
end;
$$;

comment on function app.sync_resolve_ref(text, text, text) is
  '同步写入引用解析：departments.parent_name→departments.id（仅 active、sort_order 最小，'
  '与 org/007 回填规则一致）/ departments.leader_email→profiles.id / '
  'positions.department_name→departments.id（active）/ profiles.position_code→positions.id；'
  '不存在 raise P0002；SECURITY INVOKER 且撤销 API 角色（仅执行函数/postgres 可达）';

-- ---------------------------------------------------------------------------
-- 4. app.sync_apply_target：departments 更新 parent_id 前逐个命中行防环校验
-- ---------------------------------------------------------------------------
create or replace function app.sync_apply_target(
  p_task_id uuid,
  p_data    jsonb,
  p_mode    text
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_task        public.sync_tasks;
  v_match       text;
  v_row_key     text;
  v_parent_id   uuid;
  v_leader_id   uuid;
  v_department  uuid;
  v_position    uuid;
  v_sort        integer;
  v_headcount   integer;
  v_description text;
  v_dept_id     uuid;
begin
  if p_mode is null or p_mode not in ('insert', 'update') then
    raise exception '写入模式不合法：%', coalesce(p_mode, '(null)') using errcode = '22023';
  end if;

  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    raise exception '写入数据必须为 JSON 对象' using errcode = '22023';
  end if;

  select * into v_task
  from public.sync_tasks
  where id = p_task_id;

  if not found then
    raise exception '同步任务不存在：%', coalesce(p_task_id::text, '(null)') using errcode = 'P0002';
  end if;

  -- 防御性复核：即使映射被绕过写入（直改表），执行期同样拒绝越界字段
  perform app.validate_sync_mapping(v_task.target_table, v_task.field_mapping);

  v_match := case v_task.target_table
    when 'departments' then 'name'
    when 'positions'   then 'code'
    when 'profiles'    then 'email'
  end;

  v_row_key := nullif(btrim(coalesce(p_data ->> v_match, '')), '');
  if v_row_key is null then
    raise exception '写入数据缺少匹配键：%', v_match using errcode = '22023';
  end if;

  if v_task.target_table = 'departments' then
    v_parent_id := case
      when p_data ? 'parent_name'
        then app.sync_resolve_ref('departments', 'parent_name', p_data ->> 'parent_name')
      else null
    end;
    v_leader_id := case
      when p_data ? 'leader_email'
        then app.sync_resolve_ref('departments', 'leader_email', p_data ->> 'leader_email')
      else null
    end;
    v_sort := case
      when p_data ? 'sort_order' then (p_data ->> 'sort_order')::integer
      else null
    end;

    if p_mode = 'insert' then
      insert into public.departments
        (name, parent_id, leader_id, sort_order, created_by, updated_by)
      values
        (v_row_key, v_parent_id, v_leader_id, coalesce(v_sort, 0),
         (select auth.uid()), (select auth.uid()));
    else
      -- 防环兜底：逐个命中行校验移动合法性（多行同名时全部校验；违规 raise 22023）
      if p_data ? 'parent_name' then
        for v_dept_id in
          select d.id
          from public.departments d
          where d.name = v_row_key
            and d.status <> 'deleted'
        loop
          perform app.validate_department_move(v_dept_id, v_parent_id);
        end loop;
      end if;

      update public.departments d
         set parent_id  = case when p_data ? 'parent_name' then v_parent_id else d.parent_id end,
             leader_id  = case when p_data ? 'leader_email' then v_leader_id else d.leader_id end,
             sort_order = coalesce(v_sort, d.sort_order),
             updated_by = (select auth.uid())
       where d.name = v_row_key
         and d.status <> 'deleted';

      if not found then
        raise exception '目标部门不存在或已删除：%', v_row_key using errcode = 'P0002';
      end if;
    end if;

  elsif v_task.target_table = 'positions' then
    v_department := case
      when p_data ? 'department_name'
        then app.sync_resolve_ref('positions', 'department_name', p_data ->> 'department_name')
      else null
    end;
    v_headcount := case
      when p_data ? 'headcount' then (p_data ->> 'headcount')::integer
      else null
    end;
    v_description := case
      when p_data ? 'description' then p_data ->> 'description'
      else null
    end;

    if p_mode = 'insert' then
      insert into public.positions
        (name, code, department_id, headcount, description, created_by, updated_by)
      values
        (coalesce(nullif(btrim(p_data ->> 'name'), ''), v_row_key), v_row_key,
         v_department, coalesce(v_headcount, 0), v_description,
         (select auth.uid()), (select auth.uid()));
    else
      update public.positions p
         set name          = coalesce(nullif(btrim(p_data ->> 'name'), ''), p.name),
             department_id = case when p_data ? 'department_name' then v_department else p.department_id end,
             headcount     = coalesce(v_headcount, p.headcount),
             description   = case when p_data ? 'description' then v_description else p.description end,
             updated_by    = (select auth.uid())
       where p.code = v_row_key;

      if not found then
        raise exception '目标岗位不存在：%', v_row_key using errcode = 'P0002';
      end if;
    end if;

  else
    -- profiles：仅更新不新建（tasks.md）；role/status 已由 validate_sync_mapping 排除
    v_position := case
      when p_data ? 'position_code'
        then app.sync_resolve_ref('profiles', 'position_code', p_data ->> 'position_code')
      else null
    end;

    if p_mode = 'insert' then
      raise exception 'profiles 仅更新不新建（不产生孤儿档案）' using errcode = '22023';
    end if;

    update public.profiles p
       set full_name   = case when p_data ? 'full_name' then p_data ->> 'full_name' else p.full_name end,
           department  = case when p_data ? 'department_name' then p_data ->> 'department_name' else p.department end,
           position_id = case when p_data ? 'position_code' then v_position else p.position_id end,
           updated_by  = (select auth.uid())
     where lower(p.email) = lower(v_row_key);

    if not found then
      raise exception '目标用户档案不存在（profiles 不新建）：%', v_row_key using errcode = 'P0002';
    end if;
  end if;
end;
$$;

comment on function app.sync_apply_target(uuid, jsonb, text) is
  '目标表白名单写入（执行/冲突裁决共用）：departments/positions 支持 insert/update，profiles 仅 '
  'UPDATE 且 role/status 永不可写（validate_sync_mapping 保证）；引用字段（parent_name/leader_email/'
  'department_name/position_code）解析为 id，缺失 raise；departments 更新 parent_id 前逐个命中行调 '
  'validate_department_move 防环（违规 raise 22023，不写入）；profiles.department_name 写文本列由 org/007 '
  '双写触发器同步 department_id；SECURITY INVOKER 且撤销 API 角色（仅执行函数/postgres 可达）';

-- ---------------------------------------------------------------------------
-- 5. app.execute_sync_task：防环预校验 + 同名歧义标注（其余与 20261005170000 一致）
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
  v_task          public.sync_tasks;
  v_run_id        uuid;
  v_owner         uuid;
  v_row           jsonb;
  v_map           jsonb;
  v_source        text;
  v_field         text;
  v_value         text;
  v_data          jsonb;
  v_match         text;
  v_row_key       text;
  v_target        jsonb;
  v_exists        boolean;
  v_parent_cnt    bigint;
  v_new_parent    uuid;
  v_reject_reason text;
  v_insert        integer := 0;
  v_update        integer := 0;
  v_conflict      integer := 0;
  v_skip          integer := 0;
  v_failed        integer := 0;
  v_notes         text[] := '{}';
  v_stats_notes   text[] := '{}';
  v_stats         jsonb;
  v_status        text;
  v_error         text;
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
  'departments 更新 parent_id 前防环预校验（violation → rejected 冲突不写入，stats.notes 记录；'
  '同名 parent_name 取 active 中 sort_order 最小者并在 stats.notes 标注歧义）；'
  '属主身份 claims 注入（ADR-001，PG17 禁用 definer 内 SET ROLE 的偏离说明见迁移文件头）；'
  '终态写 audit 摘要 + emit_event(''sync.run_finished'', {run_id,task_id,status,trigger,stats})'
  '（软依赖 integration/004）+ 失败 send_notification 通知属主；返回 run id。v1 执行输入 = p_sample（真实拉取为 v2）';
