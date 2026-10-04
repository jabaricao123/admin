-- 第三方数据同步 · 执行记录 + 执行函数（工单 sync/005）
-- 契约：docs/modules/sync/runs.md（执行明细：统计/错误/耗时、重跑幂等、冲突人工裁决、
--       明细 30 天清理且 pending 冲突不受影响）、docs/modules/sync/tasks.md（执行以任务属主
--       身份、目标表白名单、profiles 仅更新不新建、写变更触发 audit 快照）、
--       docs/adr/001-job-runner.md（属主身份注入、禁 service_role、pg_cron 调度）、
--       docs/modules/INDEX.md 规则 2（审计摘要）、规则 3（通知单通道）、规则 7（role/status 单通道）、
--       规则 10（内部 RPC 不 GRANT authenticated 直调）。
--
-- 执行身份偏离说明（ADR-001 第 1 节）：
--   ADR 原文为「SECURITY DEFINER + 内部 set local role = authenticated」。PostgreSQL 17 禁止在
--   SECURITY DEFINER 上下文中 SET ROLE（report/007 worker 已因同一限制改为 SECURITY INVOKER +
--   REVOKE API 角色）。sync 的执行入口还有 admin 手动（public.run_sync_task）与 webhook
--   （public.trigger_sync_webhook）两个 DEFINER wrapper，execution 函数若 SET ROLE 会在
--   wrapper 调用链中报错。故本工单落地为：
--     * app.execute_sync_task：SECURITY INVOKER + REVOKE 全部 API 角色（仅 pg_cron 的
--       postgres 与同属主的 DEFINER wrapper 可达）；
--     * 写入边界不依赖 RLS，由函数内硬编码白名单（目标表 + 目标字段 + 不 INSERT profiles +
--       profiles 排除 role/status，复用 app.validate_sync_mapping）保证（等价 RLS 语义）；
--     * 属主身份经 set_config('request.jwt.claims', {sub: owner}) 注入，供 audit 行版本触发器
--       （audit_row_versions.changed_by）等按 auth.uid() 读取的触发器使用；
--     * 全局禁 service_role（BYPASSRLS）不变。
--
-- v1 执行输入 = p_sample（与 dry_run 同一「样本行」通道）。外部 api/db 的真实拉取、以及
--   Excel 源从 storage bucket 解析模板文件，均为 v2；v1 由调用方（页面/直调）提供样本行。
--   cron/webhook 触发无样本 → 空跑记录（真实数据留待 v2 接入后补充）。
--
-- 组成：
--   1. public.sync_runs / public.sync_conflicts：执行明细与冲突队列（仅 admin SELECT）；
--   2. app.validate_sync_mapping 复用（sync/003）；app.sync_resolve_ref / app.sync_apply_target：
--      目标表白名单写入（departments/positions INSERT+UPDATE；profiles 仅 UPDATE 且字段白名单）；
--   3. app.execute_sync_task：执行入口（advisory lock 单任务并发 1；已有 running 拒绝）；
--      冲突策略 skip/overwrite/manual；状态机 running→success/partial/failed；
--      终态失败 audit 摘要 + send_notification 通知属主（ADR-001 §3）；
--   4. app.run_sync_task / app.rerun_sync_task（admin，手动触发；重跑=新 run，幂等由策略保证）；
--   5. app.resolve_sync_conflict（admin；adopted=以源值更新目标行 / ignored=仅标记）；
--   6. app.get_sync_runs / get_sync_run_conflicts / get_sync_task_run_summaries（admin 读取口）；
--   7. app.cleanup_sync_runs + pg_cron 每日清理（30 天；pending 冲突所在 run 不清理）；
--   8. RLS：两表仅 admin SELECT，无表级写；RPC 授权见文末。
--
-- 依赖：sync/003（sync_tasks / validate_sync_mapping）、sync/001（sync_sources）、
--       message/001（send_notification）、audit/001（audit_log）、
--       system/001（pgcrypto 于 extensions schema）。
-- 下游：sync/006 页面、sync/007 调度（execute 收尾处理 pending 注销与 last/next_run_at）。

-- ---------------------------------------------------------------------------
-- 1. sync_runs：执行记录（每次触发一行）
-- ---------------------------------------------------------------------------
create table public.sync_runs (
  id           uuid primary key default gen_random_uuid(),
  task_id      uuid not null references public.sync_tasks (id) on delete cascade,
  trigger_type text not null default 'manual'
               constraint sync_runs_trigger_type_check
               check (trigger_type in ('manual', 'cron', 'webhook')),
  status       text not null default 'running'
               constraint sync_runs_status_check
               check (status in ('running', 'success', 'partial', 'failed')),
  stats        jsonb not null
               default '{"insert":0,"update":0,"conflict":0,"skip":0,"failed":0}'::jsonb,
  error        text,
  started_at   timestamptz not null default now(),
  finished_at  timestamptz,
  executed_by  uuid,
  constraint sync_runs_stats_object_check check (jsonb_typeof(stats) = 'object'),
  constraint sync_runs_finished_check
    check (finished_at is null or finished_at >= started_at)
);

comment on table public.sync_runs is
  '同步执行记录（排障明细，30 天清理；摘要进 audit）：每次触发一行，记录触发方式/状态/计数/错误；'
  'pending 冲突所在记录不受清理影响';
comment on column public.sync_runs.trigger_type is '触发方式：manual 手动 / cron 定时 / webhook 外部';
comment on column public.sync_runs.status is
  '状态机：running 执行中 / success 成功 / partial 部分成功（存在失败行或待裁决冲突）/ failed 失败';
comment on column public.sync_runs.stats is
  '计数：{insert, update, conflict, skip, failed}（conflict=按 manual 策略进入冲突队列的行数）';
comment on column public.sync_runs.error is '错误明细（每行一条「行 <匹配键>：原因」，最多 20 条）；无失败为 NULL';
comment on column public.sync_runs.executed_by is
  '执行身份（属主）：manual=触发人 auth.uid() / cron/webhook=任务 created_by；弱关联 profiles，不设外键';

create index sync_runs_task_started_idx on public.sync_runs (task_id, started_at desc);
create index sync_runs_started_idx on public.sync_runs (started_at desc);
create index sync_runs_running_idx on public.sync_runs (task_id) where status = 'running';

alter table public.sync_runs enable row level security;

-- ---------------------------------------------------------------------------
-- 2. sync_conflicts：人工裁决冲突队列
-- ---------------------------------------------------------------------------
create table public.sync_conflicts (
  id          uuid primary key default gen_random_uuid(),
  run_id      uuid not null references public.sync_runs (id) on delete cascade,
  row_key     text not null,
  source_data jsonb not null,
  target_data jsonb,
  resolution  text not null default 'pending'
              constraint sync_conflicts_resolution_check
              check (resolution in ('pending', 'adopted', 'ignored')),
  resolved_by uuid,
  resolved_at timestamptz,
  created_at  timestamptz not null default now(),
  constraint sync_conflicts_row_key_check check (btrim(row_key) <> ''),
  constraint sync_conflicts_source_object_check check (jsonb_typeof(source_data) = 'object'),
  constraint sync_conflicts_resolved_check
    check ((resolution = 'pending') = (resolved_at is null))
);

comment on table public.sync_conflicts is
  '同步冲突队列（manual 策略）：待人工裁决的匹配键冲突；adopted=以源值更新目标行，'
  'ignored=保留目标现状仅标记；裁决后随执行记录保留（pending 记录使其所在 run 免于清理）';
comment on column public.sync_conflicts.row_key is
  '目标表匹配键值：departments→name / positions→code / profiles→email（大小写敏感存储）';
comment on column public.sync_conflicts.source_data is
  '源行按 field_mapping 映射后的目标字段值（已白名单校验；采纳时直接应用）';
comment on column public.sync_conflicts.target_data is '冲突时目标行现状快照（to_jsonb(row)）';
comment on column public.sync_conflicts.resolution is '裁决：pending 待处理 / adopted 采纳源值 / ignored 忽略';
comment on column public.sync_conflicts.resolved_by is '裁决人（弱关联 profiles，不设外键）';

create index sync_conflicts_run_idx on public.sync_conflicts (run_id);
create index sync_conflicts_pending_idx on public.sync_conflicts (run_id) where resolution = 'pending';

alter table public.sync_conflicts enable row level security;

-- ---------------------------------------------------------------------------
-- 3. app.sync_resolve_ref：外键引用解析（名称/邮箱/编码 → id；不存在 raise P0002）
-- ---------------------------------------------------------------------------
create function app.sync_resolve_ref(p_target text, p_field text, p_value text)
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
    select d.id into v_id
    from public.departments d
    where d.name = v_value and d.status <> 'deleted'
    order by (d.status = 'active') desc, d.sort_order, d.id
    limit 1;
    if v_id is null then
      raise exception '上级部门不存在：%', v_value using errcode = 'P0002';
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
  '同步写入引用解析：departments.parent_name→departments.id / departments.leader_email→profiles.id / '
  'positions.department_name→departments.id（active）/ profiles.position_code→positions.id；'
  '不存在 raise P0002；SECURITY INVOKER 且撤销 API 角色（仅执行函数/postgres 可达）';

-- ---------------------------------------------------------------------------
-- 4. app.sync_apply_target：目标表白名单写入（insert/update）
--    仅接受已过 app.validate_sync_mapping 的映射产出；profiles 永不 INSERT（仅按 email UPDATE）；
--    所有列名硬编码，不接受任意标识符（防注入，INDEX 规则：标识符只取白名单）。
-- ---------------------------------------------------------------------------
create function app.sync_apply_target(
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
  'department_name/position_code）解析为 id，缺失 raise；profiles.department_name 写文本列由 org/007 '
  '双写触发器同步 department_id；SECURITY INVOKER 且撤销 API 角色（仅执行函数/postgres 可达）';

-- ---------------------------------------------------------------------------
-- 5. app.execute_sync_task：执行入口（单任务并发 1；手动触发 admin 校验）
-- ---------------------------------------------------------------------------
create function app.execute_sync_task(
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
  '失败写 audit 摘要 + send_notification 通知属主；返回 run id。v1 执行输入 = p_sample（真实拉取为 v2）';

-- ---------------------------------------------------------------------------
-- 6. app.run_sync_task / app.rerun_sync_task：admin 手动触发（重跑=新 run）
-- ---------------------------------------------------------------------------
create function app.run_sync_task(p_task_id uuid, p_sample jsonb default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  return app.execute_sync_task(p_task_id, 'manual', p_sample);
end;
$$;

comment on function app.run_sync_task(uuid, jsonb) is
  '手动触发一次同步（admin；SECURITY DEFINER wrapper → app.execute_sync_task manual）；'
  'p_sample 为 v1 样本通道（与 dry-run 一致），不传则空跑记录；并发冲突由执行函数拒绝';

create function app.rerun_sync_task(p_task_id uuid, p_sample jsonb default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  -- 重跑 = 同一执行函数的 manual 新 run；幂等由 conflict_policy 保证（runs.md）
  return app.execute_sync_task(p_task_id, 'manual', p_sample);
end;
$$;

comment on function app.rerun_sync_task(uuid, jsonb) is
  '重跑（admin）：调同一 app.execute_sync_task（manual 新 run，单一实现）；'
  '幂等由任务 conflict_policy 保证；p_sample 为 v1 执行输入通道';

-- ---------------------------------------------------------------------------
-- 7. app.resolve_sync_conflict：人工裁决（adopted 用源值更新目标行 / ignored 仅标记）
-- ---------------------------------------------------------------------------
create function app.resolve_sync_conflict(p_conflict_id uuid, p_resolution text)
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

    -- 采纳 = 以源值更新目标行（rows.md：用源值覆盖；不存在则拒绝）
    perform app.sync_apply_target(v_task.id, v_conflict.source_data, 'update');
  end if;

  update public.sync_conflicts
     set resolution  = p_resolution,
         resolved_by = (select auth.uid()),
         resolved_at = now()
   where id = p_conflict_id;

  -- 该 run 无剩余 pending 冲突且无失败行 → partial 升级 success（runs.md 验收：裁决后状态一致）
  select count(*) into v_pending
  from public.sync_conflicts c
  where c.run_id = v_run.id and c.resolution = 'pending';

  if v_pending = 0
     and v_run.status = 'partial'
     and coalesce((v_run.stats ->> 'failed')::integer, 0) = 0
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
  'profiles 不新建）；ignored=仅标记；重复裁决/越界键拒绝；裁决后 run 无 pending 冲突且无失败行时 '
  'partial→success；写审计摘要';

-- ---------------------------------------------------------------------------
-- 8. 读取 RPC（admin）
-- ---------------------------------------------------------------------------
create function app.get_sync_runs(
  p_task_id uuid default null,
  p_limit   integer default 50,
  p_offset  integer default 0
)
returns table (
  id                uuid,
  task_id           uuid,
  task_name         text,
  target_table      text,
  trigger_type      text,
  status            text,
  stats             jsonb,
  error             text,
  started_at        timestamptz,
  finished_at       timestamptz,
  executed_by       uuid,
  executed_by_name  text,
  pending_conflicts bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  return query
  select
    r.id,
    r.task_id,
    t.name,
    t.target_table,
    r.trigger_type,
    r.status,
    r.stats,
    r.error,
    r.started_at,
    r.finished_at,
    r.executed_by,
    p.full_name,
    (select count(*) from public.sync_conflicts c
      where c.run_id = r.id and c.resolution = 'pending')
  from public.sync_runs r
  join public.sync_tasks t on t.id = r.task_id
  left join public.profiles p on p.id = r.executed_by
  where p_task_id is null or r.task_id = p_task_id
  order by r.started_at desc, r.id desc
  limit least(greatest(coalesce(p_limit, 50), 1), 200)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

comment on function app.get_sync_runs(uuid, integer, integer) is
  '执行记录列表 RPC（admin）：按任务过滤可选、按开始时间倒序分页（1..200）；附 pending 冲突数与执行人姓名';

create function app.get_sync_run_conflicts(p_run_id uuid)
returns table (
  id               uuid,
  run_id           uuid,
  row_key          text,
  source_data      jsonb,
  target_data      jsonb,
  resolution       text,
  resolved_by      uuid,
  resolved_by_name text,
  resolved_at      timestamptz,
  created_at       timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if not exists (select 1 from public.sync_runs r where r.id = p_run_id) then
    raise exception '执行记录不存在：%', coalesce(p_run_id::text, '(null)') using errcode = 'P0002';
  end if;

  return query
  select
    c.id,
    c.run_id,
    c.row_key,
    c.source_data,
    c.target_data,
    c.resolution,
    c.resolved_by,
    p.full_name,
    c.resolved_at,
    c.created_at
  from public.sync_conflicts c
  left join public.profiles p on p.id = c.resolved_by
  where c.run_id = p_run_id
  order by
    case c.resolution when 'pending' then 0 else 1 end,
    c.created_at,
    c.id;
end;
$$;

comment on function app.get_sync_run_conflicts(uuid) is
  '单次执行的冲突队列 RPC（admin）：pending 优先，附裁决人姓名';

create function app.get_sync_task_run_summaries()
returns table (
  task_id      uuid,
  run_id       uuid,
  trigger_type text,
  status       text,
  stats        jsonb,
  started_at   timestamptz,
  finished_at  timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  return query
  select distinct on (r.task_id)
    r.task_id,
    r.id,
    r.trigger_type,
    r.status,
    r.stats,
    r.started_at,
    r.finished_at
  from public.sync_runs r
  order by r.task_id, r.started_at desc, r.id desc;
end;
$$;

comment on function app.get_sync_task_run_summaries() is
  '每个任务的最近一次执行摘要（admin）：供同步任务列表「最近执行」列';

-- ---------------------------------------------------------------------------
-- 9. app.cleanup_sync_runs：30 天保留策略（pending 冲突所在 run 不清理）
-- ---------------------------------------------------------------------------
create function app.cleanup_sync_runs(p_retention_days integer default 30)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_deleted bigint;
begin
  if p_retention_days is null or p_retention_days < 1 then
    raise exception '保留天数必须 >= 1：%', coalesce(p_retention_days::text, '(null)')
      using errcode = '22023';
  end if;

  delete from public.sync_runs r
   where r.status <> 'running'
     and r.started_at < now() - make_interval(days => p_retention_days)
     and not exists (
       select 1 from public.sync_conflicts c
       where c.run_id = r.id and c.resolution = 'pending'
     );

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

comment on function app.cleanup_sync_runs(integer) is
  '执行明细清理（默认 30 天；runs.md）：删除超期且不含 pending 冲突的 run（conflicts 级联）；'
  'running 保护；仅 pg_cron/owner 可达（撤销 API 角色），返回删除条数';

-- ---------------------------------------------------------------------------
-- 10. public 薄包装（PostgREST 仅暴露 public schema；admin 校验在 app 实现内）
-- ---------------------------------------------------------------------------
create function public.run_sync_task(p_task_id uuid, p_sample jsonb default null)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select app.run_sync_task(p_task_id, p_sample)
$$;

create function public.rerun_sync_task(p_task_id uuid, p_sample jsonb default null)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select app.rerun_sync_task(p_task_id, p_sample)
$$;

create function public.resolve_sync_conflict(p_conflict_id uuid, p_resolution text)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.resolve_sync_conflict(p_conflict_id, p_resolution)
$$;

create function public.get_sync_runs(
  p_task_id uuid default null,
  p_limit   integer default 50,
  p_offset  integer default 0
)
returns table (
  id                uuid,
  task_id           uuid,
  task_name         text,
  target_table      text,
  trigger_type      text,
  status            text,
  stats             jsonb,
  error             text,
  started_at        timestamptz,
  finished_at       timestamptz,
  executed_by       uuid,
  executed_by_name  text,
  pending_conflicts bigint
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.get_sync_runs(p_task_id, p_limit, p_offset)
$$;

create function public.get_sync_run_conflicts(p_run_id uuid)
returns table (
  id               uuid,
  run_id           uuid,
  row_key          text,
  source_data      jsonb,
  target_data      jsonb,
  resolution       text,
  resolved_by      uuid,
  resolved_by_name text,
  resolved_at      timestamptz,
  created_at       timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.get_sync_run_conflicts(p_run_id)
$$;

create function public.get_sync_task_run_summaries()
returns table (
  task_id      uuid,
  run_id       uuid,
  trigger_type text,
  status       text,
  stats        jsonb,
  started_at   timestamptz,
  finished_at  timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.get_sync_task_run_summaries()
$$;

comment on function public.run_sync_task(uuid, jsonb) is 'run_sync_task Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.rerun_sync_task(uuid, jsonb) is 'rerun_sync_task Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.resolve_sync_conflict(uuid, text) is 'resolve_sync_conflict Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.get_sync_runs(uuid, integer, integer) is 'get_sync_runs Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.get_sync_run_conflicts(uuid) is 'get_sync_run_conflicts Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.get_sync_task_run_summaries() is 'get_sync_task_run_summaries Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 11. 授权：表仅 admin SELECT（RLS 再收口）；执行/清理无 API 直调；管理 RPC 仅 authenticated
-- ---------------------------------------------------------------------------
revoke all on public.sync_runs from public, anon, authenticated, service_role;
revoke all on public.sync_conflicts from public, anon, authenticated, service_role;
grant select on public.sync_runs to authenticated;
grant select on public.sync_conflicts to authenticated;

revoke all on function app.sync_resolve_ref(text, text, text)
  from public, anon, authenticated, service_role;
revoke all on function app.sync_apply_target(uuid, jsonb, text)
  from public, anon, authenticated, service_role;
revoke all on function app.execute_sync_task(uuid, text, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function app.run_sync_task(uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function app.rerun_sync_task(uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function app.resolve_sync_conflict(uuid, text) from public, anon, authenticated, service_role;
revoke all on function app.get_sync_runs(uuid, integer, integer)
  from public, anon, authenticated, service_role;
revoke all on function app.get_sync_run_conflicts(uuid) from public, anon, authenticated, service_role;
revoke all on function app.get_sync_task_run_summaries()
  from public, anon, authenticated, service_role;
revoke all on function app.cleanup_sync_runs(integer) from public, anon, authenticated, service_role;

grant execute on function app.run_sync_task(uuid, jsonb) to authenticated;
grant execute on function app.rerun_sync_task(uuid, jsonb) to authenticated;
grant execute on function app.resolve_sync_conflict(uuid, text) to authenticated;
grant execute on function app.get_sync_runs(uuid, integer, integer) to authenticated;
grant execute on function app.get_sync_run_conflicts(uuid) to authenticated;
grant execute on function app.get_sync_task_run_summaries() to authenticated;

revoke all on function public.run_sync_task(uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.rerun_sync_task(uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.resolve_sync_conflict(uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.get_sync_runs(uuid, integer, integer)
  from public, anon, authenticated, service_role;
revoke all on function public.get_sync_run_conflicts(uuid) from public, anon, authenticated, service_role;
revoke all on function public.get_sync_task_run_summaries()
  from public, anon, authenticated, service_role;

grant execute on function public.run_sync_task(uuid, jsonb) to authenticated;
grant execute on function public.rerun_sync_task(uuid, jsonb) to authenticated;
grant execute on function public.resolve_sync_conflict(uuid, text) to authenticated;
grant execute on function public.get_sync_runs(uuid, integer, integer) to authenticated;
grant execute on function public.get_sync_run_conflicts(uuid) to authenticated;
grant execute on function public.get_sync_task_run_summaries() to authenticated;

-- execute_sync_task / sync_apply_target / sync_resolve_ref / cleanup_sync_runs 不 GRANT 任何 API 角色：
-- 仅函数属主（postgres，pg_cron 执行身份）与各 SECURITY DEFINER wrapper（同属主）可达。

-- ---------------------------------------------------------------------------
-- 12. RLS：两表仅 admin SELECT；无 INSERT/UPDATE/DELETE 策略（无策略=拒绝）
-- ---------------------------------------------------------------------------
create policy sync_runs_select_admin
on public.sync_runs
for select
to authenticated
using ((select app.current_role()) = 'admin');

create policy sync_conflicts_select_admin
on public.sync_conflicts
for select
to authenticated
using ((select app.current_role()) = 'admin');

-- ---------------------------------------------------------------------------
-- 13. pg_cron：每日清理 30 天前执行明细
--     TODO(system/011)：system pg_cron 登记处（INDEX 规则 5）上线后补登记；
--     在此之前按各 worker 先例直接 cron.schedule。
-- ---------------------------------------------------------------------------
create extension if not exists pg_cron;

select cron.schedule(
  'sync-cleanup-runs',
  '30 3 * * *',
  $cron$select app.cleanup_sync_runs(30)$cron$
);
