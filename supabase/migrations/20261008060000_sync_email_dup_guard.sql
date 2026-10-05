-- 第三方数据同步 · 数据正确性批次 1：email 重复守卫 / 部门名解析 / 映射重复校验 / dry-run 口径
-- 工单：sync 数据正确性批次 1（修复 1、2、4 的写入路径与试跑口径）
--
-- 背景（审计缺口）：
--   1. profiles 匹配键 email 在目标表不唯一时：执行主流程按 first 行判「已存在」，
--      app.sync_apply_target 却按 lower(email) 命中全部行 UPDATE —— 一行样本可静默改写
--      多行档案，且 stats.update 只计 1，统计与实际写入行数失真；
--   2. profiles.department_name 直接写文本列，依赖 org/007 双写触发器按「active 精确匹配」
--      回写 department_id；部门名不存在（或已停用）时触发器静默把 department_id 置 NULL，
--      与其他引用字段（parent_name / positions.department_name / position_code，缺失即 raise）口径不一；
--   3. app.validate_sync_mapping 未拒绝同一 target_field 重复出现：映射含重复键时后写覆盖
--      先写，属配置错误但可保存并执行；
--   4. app.dry_run_sync_task 未识别 email 重复行，试跑统计与正式执行不一致。
--
-- 语义（本迁移）：
--   1. app.sync_resolve_ref：新增 profiles.department_name → departments.id（仅 active +
--      sort_order 最小 + id 决胜，与 org/007 回填、positions.department_name 同规则）；
--      不存在 raise P0002「部门不存在：xxx」；
--   2. app.sync_apply_target：
--        * profiles 更新前对匹配 email 计数，>1 raise 23505「email 重复 N 行，拒绝写入」
--          （不写任何行；与执行主流程的拦截同口径，覆盖裁决 adopted 路径兜底）；
--        * department_name 先经 sync_resolve_ref 解析，写 department_id（文本列同写，
--          双写触发器以 id 为准回写规范名）；解析失败整行 raise，原 department_id 不变；
--   3. app.validate_sync_mapping：同一 target_field 出现两次 → 22023「映射字段重复：xxx」；
--   4. app.dry_run_sync_task：返回值新增 failed 计数（append 键，不改既有键）；email 重复行
--      计入 failed 并写 notes（code=email_dup），与执行主流程的 failed/update 口径对齐。
--
-- 执行主流程（app.execute_sync_task）的重复行拦截、rejected 状态收敛、输入快照与
-- claims 还原见 20261008070000；本迁移不重复定义执行函数。
--
-- 依赖：20261005181000（sync_resolve_ref / sync_apply_target 现状）、
--       20261004231000（validate_sync_mapping / dry_run_sync_task 现状）。
-- 授权不变：create or replace 保留 20261005030000 文末对执行函数的 REVOKE/GRANT；
--           validate_sync_mapping / dry_run 仍由各自 wrapper 与执行函数内部调用。

-- ---------------------------------------------------------------------------
-- 1. app.sync_resolve_ref：新增 profiles.department_name → departments.id
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
  elsif p_target = 'profiles' and p_field = 'department_name' then
    -- profiles.department_name：与 org/007 回填、positions.department_name 同规则
    -- （仅 active + sort_order 最小 + id 决胜）；不存在/停用即 raise，不再静默置 NULL
    select d.id into v_id
    from public.departments d
    where d.name = v_value and d.status = 'active'
    order by d.sort_order, d.id
    limit 1;
    if v_id is null then
      raise exception '部门不存在：%', v_value using errcode = 'P0002';
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
  'positions.department_name→departments.id（active）/ profiles.department_name→departments.id'
  '（active、sort_order 最小、id 决胜）/ profiles.position_code→positions.id；'
  '不存在 raise P0002；SECURITY INVOKER 且撤销 API 角色（仅执行函数/postgres 可达）';

-- ---------------------------------------------------------------------------
-- 2. app.sync_apply_target：profiles email 重复守卫 + department_name 解析写 id
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
  v_email_cnt   bigint;
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
    -- department_name 解析为 departments.id（批次 1 修复）：不存在/停用 raise，
    -- 不再静默依赖双写触发器置 NULL；写 department_id 由触发器回写规范部门名
    v_department := case
      when p_data ? 'department_name'
        then app.sync_resolve_ref('profiles', 'department_name', p_data ->> 'department_name')
      else null
    end;

    if p_mode = 'insert' then
      raise exception 'profiles 仅更新不新建（不产生孤儿档案）' using errcode = '22023';
    end if;

    -- email 唯一守卫（批次 1 修复）：写前计数，>1 拒绝整行（不写任何行）
    -- 保证 stats.update 与实际写入行数一致（恰 1 行），防一行样本误改多行
    select count(*) into v_email_cnt
    from public.profiles p
    where lower(p.email) = lower(v_row_key);

    if v_email_cnt > 1 then
      raise exception 'email 重复 % 行，拒绝写入', v_email_cnt using errcode = '23505';
    end if;

    update public.profiles p
       set full_name     = case when p_data ? 'full_name' then p_data ->> 'full_name' else p.full_name end,
           department    = case when p_data ? 'department_name' then p_data ->> 'department_name' else p.department end,
           department_id = case when p_data ? 'department_name' then v_department else p.department_id end,
           position_id   = case when p_data ? 'position_code' then v_position else p.position_id end,
           updated_by    = (select auth.uid())
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
  'department_name/position_code）解析为 id，缺失 raise；profiles.department_name 经 sync_resolve_ref '
  '解析后写 department_id（不再静默置 NULL）；profiles 写前 email 计数 >1 raise 23505 拒绝整行；'
  'departments 更新 parent_id 前逐个命中行调 validate_department_move 防环（违规 raise 22023，不写入）；'
  'SECURITY INVOKER 且撤销 API 角色（仅执行函数/postgres 可达）';

-- ---------------------------------------------------------------------------
-- 3. app.validate_sync_mapping：同一 target_field 不得重复
-- ---------------------------------------------------------------------------
create or replace function app.validate_sync_mapping(p_target text, p_mapping jsonb)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_allowed text[];
  v_seen    text[] := '{}';
  v_item    jsonb;
  v_source  text;
  v_field   text;
begin
  if p_target is null or p_target not in ('departments', 'positions', 'profiles') then
    raise exception '目标表不在白名单：%', coalesce(p_target, '(null)') using errcode = '22023';
  end if;

  if p_mapping is null or jsonb_typeof(p_mapping) <> 'array' then
    raise exception '字段映射必须为数组：[{source_field, target_field}]' using errcode = '22023';
  end if;

  if jsonb_array_length(p_mapping) = 0 then
    raise exception '字段映射不能为空' using errcode = '22023';
  end if;

  -- 目标字段白名单硬编码（tasks.md 数据模型；新增字段须同步修订本函数与页面字典）
  v_allowed := case p_target
    when 'departments' then array['name', 'parent_name', 'leader_email', 'sort_order']
    when 'positions'   then array['name', 'code', 'department_name', 'headcount', 'description']
    when 'profiles'    then array['full_name', 'department_name', 'position_code', 'email']
  end;

  for v_item in select value from jsonb_array_elements(p_mapping) loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception '映射项必须为对象：%', v_item::text using errcode = '22023';
    end if;

    v_source := btrim(coalesce(v_item ->> 'source_field', ''));
    v_field  := btrim(coalesce(v_item ->> 'target_field', ''));

    if v_source = '' then
      raise exception '映射项缺少 source_field：%', v_item::text using errcode = '22023';
    end if;

    if v_field = '' then
      raise exception '映射项缺少 target_field：%', v_item::text using errcode = '22023';
    end if;

    -- INDEX 规则 7：角色走 access 单通道、启停用走 org RPC，sync 显式排除
    if p_target = 'profiles' and v_field in ('role', 'status') then
      raise exception 'profiles 的 role/status 不可作为同步目标字段（角色走 access 单通道，启停用走 org RPC）'
        using errcode = '22023';
    end if;

    if not (v_field = any (v_allowed)) then
      raise exception '目标字段不在白名单：% → %.%（允许：%）',
        v_source, p_target, v_field, array_to_string(v_allowed, ' / ')
        using errcode = '22023';
    end if;

    -- 批次 1 修复：同一 target_field 出现两次即配置错误（重复键会互相覆盖）
    if v_field = any (v_seen) then
      raise exception '映射字段重复：%', v_field using errcode = '22023';
    end if;
    v_seen := v_seen || v_field;
  end loop;
end;
$$;

comment on function app.validate_sync_mapping(text, jsonb) is
  '同步映射校验：目标表白名单 + 各目标字段白名单硬编码 + 同一 target_field 不得重复'
  '（重复 raise 22023「映射字段重复：xxx」）；profiles 显式拒绝 role/status（INDEX 规则 7）；'
  '违规 raise 22023；不触表、不 GRANT API 角色（由 upsert_sync_task / dry_run 内部调用）';

-- ---------------------------------------------------------------------------
-- 4. app.dry_run_sync_task：email 重复行与 execute 同口径（failed + notes）
-- ---------------------------------------------------------------------------
create or replace function app.dry_run_sync_task(p_task_id uuid, p_sample jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_task         public.sync_tasks;
  v_sample       jsonb := coalesce(p_sample, '[]'::jsonb);
  v_row          jsonb;
  v_match        text;
  v_value        text;
  v_exists       boolean;
  v_email_dup    bigint;
  v_insert       integer := 0;
  v_update       integer := 0;
  v_conflict     integer := 0;
  v_skip         integer := 0;
  v_failed       integer := 0;
  v_no_key       integer := 0;
  v_profiles_new integer := 0;
  v_notes        jsonb := '[]'::jsonb;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_task
  from public.sync_tasks
  where id = p_task_id;

  if not found then
    raise exception '同步任务不存在：%', coalesce(p_task_id::text, '(null)') using errcode = 'P0002';
  end if;

  -- 防御性复核：映射若被绕过写入（如直改表）也拒绝试跑
  perform app.validate_sync_mapping(v_task.target_table, v_task.field_mapping);

  if jsonb_typeof(v_sample) <> 'array' then
    raise exception '样本必须为 JSON 数组（每行一个对象）' using errcode = '22023';
  end if;

  v_match := case v_task.target_table
    when 'departments' then 'name'
    when 'positions'   then 'code'
    when 'profiles'    then 'email'
  end;

  for v_row in select value from jsonb_array_elements(v_sample) loop
    if jsonb_typeof(v_row) <> 'object' then
      raise exception '样本行必须为 JSON 对象：%', v_row::text using errcode = '22023';
    end if;

    -- 优先按映射从 source_field 取匹配键；否则直接读目标字段名（样本已是目标格式）
    select nullif(btrim(coalesce(v_row ->> (m.value ->> 'source_field'), '')), '')
      into v_value
    from jsonb_array_elements(v_task.field_mapping) as m(value)
    where m.value ->> 'target_field' = v_match
    limit 1;

    if v_value is null then
      v_value := nullif(btrim(coalesce(v_row ->> v_match, '')), '');
    end if;

    if v_value is null then
      v_skip := v_skip + 1;
      v_no_key := v_no_key + 1;
      continue;
    end if;

    -- email 重复守卫（批次 1 修复）：与 app.execute_sync_task 同口径 ——
    -- 重复行计入 failed（试跑不写表，仅统计），notes 标注原因，不计 update/conflict
    if v_task.target_table = 'profiles' then
      select count(*) into v_email_dup
      from public.profiles pr
      where lower(pr.email) = lower(v_value);

      if v_email_dup > 1 then
        v_failed := v_failed + 1;
        v_notes := v_notes || jsonb_build_object(
          'code', 'email_dup',
          'message', format('行 %s：email 重复 %s 行，拒绝写入', v_value, v_email_dup)
        );
        continue;
      end if;
    end if;

    if v_task.target_table = 'departments' then
      select exists (
        select 1 from public.departments d
        where d.name = v_value and d.status <> 'deleted'
      ) into v_exists;
    elsif v_task.target_table = 'positions' then
      select exists (
        select 1 from public.positions p
        where p.code = v_value
      ) into v_exists;
    else
      select exists (
        select 1 from public.profiles pr
        where lower(pr.email) = lower(v_value)
      ) into v_exists;
    end if;

    if not v_exists then
      if v_task.target_table = 'profiles' then
        -- tasks.md：profiles 按 id/email 匹配，仅更新不新建（用户创建另立流程）
        v_skip := v_skip + 1;
        v_profiles_new := v_profiles_new + 1;
      else
        v_insert := v_insert + 1;
      end if;
    else
      case v_task.conflict_policy
        when 'skip'      then v_skip := v_skip + 1;
        when 'overwrite' then v_update := v_update + 1;
        when 'manual'    then v_conflict := v_conflict + 1;
      end case;
    end if;
  end loop;

  if v_no_key > 0 then
    v_notes := v_notes || jsonb_build_object(
      'code', 'missing_match_key',
      'message', format('%s 行样本缺少匹配键 %s，已跳过', v_no_key, v_match)
    );
  end if;

  if v_profiles_new > 0 then
    v_notes := v_notes || jsonb_build_object(
      'code', 'profiles_no_insert',
      'message', format('profiles 仅更新不新建：%s 行未匹配用户档案，已跳过', v_profiles_new)
    );
  end if;

  return jsonb_build_object(
    'task_id', v_task.id,
    'target_table', v_task.target_table,
    'match_field', v_match,
    'conflict_policy', v_task.conflict_policy,
    'sample_rows', jsonb_array_length(v_sample),
    'insert', v_insert,
    'update', v_update,
    'conflict', v_conflict,
    'skip', v_skip,
    'failed', v_failed,
    'notes', v_notes
  );
end;
$$;

comment on function app.dry_run_sync_task(uuid, jsonb) is
  '同步任务试跑 RPC（admin，只读）：v1 = 映射校验 + 目标表现状统计 + 样本行模拟；'
  '按冲突策略与目标匹配键（departments→name / positions→code / profiles→email）计算 '
  '{insert, update, conflict, skip, failed}；profiles 未匹配行计入 skip 并标注「不新建用户」，'
  'email 重复行计入 failed（code=email_dup）与执行主流程同口径；'
  '真实外部源拉取与正式执行见 sync/005（本函数不写任何业务表）';
