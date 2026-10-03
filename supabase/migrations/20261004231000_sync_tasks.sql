-- 第三方数据同步 · 同步任务 + 版本化 + dry-run（工单 sync/003）
-- 契约：docs/modules/sync/tasks.md（目标表白名单 departments/positions/profiles；profiles 映射
--       排除 role/status；仅更新不新建按 email 匹配；冲突策略三档；dry-run 统计；
--       配置版本快照可追溯）、docs/modules/INDEX.md 规则 7（角色写入单通道）、
--       docs/adr/001-job-runner.md（执行身份——执行函数 sync/005，不在本迁移）。
-- 组成：
--   1. public.sync_tasks：任务定义（source_id → sync_sources；field_mapping；conflict_policy）；
--   2. public.sync_task_versions：配置快照（每次 upsert 自动 version+1，函数内实现）；
--   3. app.validate_sync_mapping(p_target, p_mapping)：目标表白名单 + 目标字段白名单硬编码；
--      profiles 显式排除 role/status；越界 raise 22023；
--   4. app.upsert_sync_task / public.upsert_sync_task：admin 新建/编辑；映射校验 + 版本快照；
--      启用任务（新建 active 或 disabled→active）要求数据源 active 且 verified；
--   5. app.dry_run_sync_task(p_task_id, p_sample) / public.dry_run_sync_task：v1 试跑 =
--      映射校验 + 目标表现状统计 + 样本行模拟（匹配键：departments→name / positions→code /
--      profiles→email；profiles 未匹配行计入 skip 并标注「不新建用户」）；
--   6. 读取/回滚 RPC：app.get_sync_tasks、app.get_sync_task_versions、app.rollback_sync_task；
--   7. RLS：两表均仅 admin SELECT；无表级写（写仅经 SECURITY DEFINER RPC）。
--
-- 依赖：app.current_role()、app.set_updated_at()（init_profiles）、app.audit_log()（audit/001）、
--       app.encrypt_secret（system/001）、public.sync_sources（sync/001）、
--       public.departments / positions / profiles（org/001、org/004、org/007）。
-- 下游：sync/004 页面、sync/005 执行函数（复用白名单与映射校验）。

-- ---------------------------------------------------------------------------
-- 1. sync_tasks：任务定义
-- ---------------------------------------------------------------------------
create table public.sync_tasks (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  source_id       uuid not null references public.sync_sources(id),
  target_table    text not null
                  constraint sync_tasks_target_table_check
                  check (target_table in ('departments', 'positions', 'profiles')),
  direction       text not null default 'pull'
                  constraint sync_tasks_direction_check
                  check (direction in ('pull', 'push')),
  field_mapping   jsonb not null,
  conflict_policy text not null default 'skip'
                  constraint sync_tasks_conflict_policy_check
                  check (conflict_policy in ('skip', 'overwrite', 'manual')),
  status          text not null default 'active'
                  constraint sync_tasks_status_check
                  check (status in ('active', 'disabled')),
  config_version  integer not null default 1
                  constraint sync_tasks_config_version_check
                  check (config_version >= 1),
  created_by      uuid,
  updated_by      uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint sync_tasks_name_check check (btrim(name) <> ''),
  constraint sync_tasks_field_mapping_array_check
    check (jsonb_typeof(field_mapping) = 'array')
);

create index sync_tasks_source_id_idx on public.sync_tasks (source_id);
create index sync_tasks_status_idx on public.sync_tasks (status);

comment on table public.sync_tasks is
  '同步任务（admin 管理）：数据源 → 白名单目标表的字段映射、方向、冲突策略；'
  '配置变更经 sync_task_versions 留痕；执行身份模型见 docs/adr/001-job-runner.md';
comment on column public.sync_tasks.source_id is '数据源（sync_sources.id；引用存在时不可删除源）';
comment on column public.sync_tasks.target_table is
  '目标表白名单（硬编码）：departments / positions / profiles（防任意表写入）';
comment on column public.sync_tasks.direction is '方向：pull 拉取（源→目标）/ push 推送（目标只读视图→外部）';
comment on column public.sync_tasks.field_mapping is
  '字段映射数组：[{source_field, target_field}]；目标字段白名单见 app.validate_sync_mapping；'
  'profiles 显式排除 role/status';
comment on column public.sync_tasks.conflict_policy is
  '冲突策略：skip 跳过 / overwrite 覆盖 / manual 标记人工处理';
comment on column public.sync_tasks.config_version is '配置版本号（每次 upsert +1；快照见 sync_task_versions）';

create trigger sync_tasks_set_updated_at
before update on public.sync_tasks
for each row
execute function app.set_updated_at();

alter table public.sync_tasks enable row level security;

-- ---------------------------------------------------------------------------
-- 2. sync_task_versions：配置快照（version 与 task.config_version 对应）
-- ---------------------------------------------------------------------------
create table public.sync_task_versions (
  task_id    uuid not null references public.sync_tasks(id) on delete cascade,
  version    integer not null,
  config     jsonb not null,
  created_by uuid,
  created_at timestamptz not null default now(),
  primary key (task_id, version),
  constraint sync_task_versions_version_check check (version >= 1),
  constraint sync_task_versions_config_object_check check (jsonb_typeof(config) = 'object')
);

comment on table public.sync_task_versions is
  '同步任务配置快照（append-only）：每次 upsert 写入当时完整配置；回滚经 rollback_sync_task '
  '生成新版本（不修改历史行）';
comment on column public.sync_task_versions.config is
  '配置快照：name/source_id/target_table/direction/field_mapping/conflict_policy/status';

alter table public.sync_task_versions enable row level security;

-- ---------------------------------------------------------------------------
-- 3. app.validate_sync_mapping：映射白名单校验（越界 raise）
-- ---------------------------------------------------------------------------
create function app.validate_sync_mapping(p_target text, p_mapping jsonb)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_allowed text[];
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
  end loop;
end;
$$;

comment on function app.validate_sync_mapping(text, jsonb) is
  '同步映射校验：目标表白名单 + 各目标字段白名单硬编码；profiles 显式拒绝 role/status（INDEX 规则 7）；'
  '违规 raise 22023；不触表、不 GRANT API 角色（由 upsert_sync_task / dry_run 内部调用）';

-- ---------------------------------------------------------------------------
-- 4. app.upsert_sync_task：admin 新建/编辑 + 版本快照
-- ---------------------------------------------------------------------------
create function app.upsert_sync_task(
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
  '新建 active 或 disabled→active 要求数据源 active 且 verified；审计不落凭据（任务本身无凭据）';

-- ---------------------------------------------------------------------------
-- 5. app.dry_run_sync_task：v1 试跑（映射校验 + 现状统计 + 样本模拟）
--    样本行为 JSON 对象数组：字段名可为 source_field（按映射解析）或目标字段本身；
--    匹配键：departments→name / positions→code / profiles→email（大小写不敏感）。
-- ---------------------------------------------------------------------------
create function app.dry_run_sync_task(p_task_id uuid, p_sample jsonb)
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
  v_insert       integer := 0;
  v_update       integer := 0;
  v_conflict     integer := 0;
  v_skip         integer := 0;
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
    'notes', v_notes
  );
end;
$$;

comment on function app.dry_run_sync_task(uuid, jsonb) is
  '同步任务试跑 RPC（admin，只读）：v1 = 映射校验 + 目标表现状统计 + 样本行模拟；'
  '按冲突策略与目标匹配键（departments→name / positions→code / profiles→email）计算 '
  '{insert, update, conflict, skip}；profiles 未匹配行计入 skip 并标注「不新建用户」；'
  '真实外部源拉取与正式执行见 sync/005（本函数不写任何业务表）';

-- ---------------------------------------------------------------------------
-- 6. 读取 / 回滚 RPC
-- ---------------------------------------------------------------------------
create function app.get_sync_tasks()
returns table (
  id               uuid,
  name             text,
  source_id        uuid,
  source_name      text,
  source_type      text,
  source_status    text,
  source_verify_status text,
  target_table     text,
  direction        text,
  field_mapping    jsonb,
  conflict_policy  text,
  status           text,
  config_version   integer,
  created_by       uuid,
  updated_by       uuid,
  created_at       timestamptz,
  updated_at       timestamptz
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
    t.id,
    t.name,
    t.source_id,
    s.name,
    s.type,
    s.status,
    s.verify_status,
    t.target_table,
    t.direction,
    t.field_mapping,
    t.conflict_policy,
    t.status,
    t.config_version,
    t.created_by,
    t.updated_by,
    t.created_at,
    t.updated_at
  from public.sync_tasks t
  join public.sync_sources s on s.id = t.source_id
  order by t.created_at desc, t.id;
end;
$$;

comment on function app.get_sync_tasks() is
  '同步任务列表 RPC（admin）：联表返回数据源名称/类型/状态/验证状态；任务表无凭据字段，原样返回配置';

create function app.get_sync_task_versions(p_task_id uuid)
returns table (
  version    integer,
  config     jsonb,
  created_by uuid,
  created_at timestamptz
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

  if not exists (select 1 from public.sync_tasks t where t.id = p_task_id) then
    raise exception '同步任务不存在：%', coalesce(p_task_id::text, '(null)') using errcode = 'P0002';
  end if;

  return query
  select v.version, v.config, v.created_by, v.created_at
  from public.sync_task_versions v
  where v.task_id = p_task_id
  order by v.version desc;
end;
$$;

comment on function app.get_sync_task_versions(uuid) is
  '同步任务版本快照列表 RPC（admin，按 version 倒序）；用于追溯与回滚前确认';

create function app.rollback_sync_task(p_task_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task        public.sync_tasks;
  v_prev_config jsonb;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_task
  from public.sync_tasks
  where id = p_task_id
  for update;

  if not found then
    raise exception '同步任务不存在：%', coalesce(p_task_id::text, '(null)') using errcode = 'P0002';
  end if;

  if v_task.config_version <= 1 then
    raise exception '没有可回滚的历史版本' using errcode = '22023';
  end if;

  select v.config into v_prev_config
  from public.sync_task_versions v
  where v.task_id = p_task_id
    and v.version = v_task.config_version - 1;

  if v_prev_config is null then
    raise exception '历史版本不存在：v%', v_task.config_version - 1 using errcode = 'P0002';
  end if;

  -- 以「上一版配置」作为新一次 upsert：校验复用，快照自动生成 config_version+1
  return app.upsert_sync_task(
    p_task_id,
    v_prev_config ->> 'name',
    (v_prev_config ->> 'source_id')::uuid,
    v_prev_config ->> 'target_table',
    v_prev_config ->> 'direction',
    v_prev_config -> 'field_mapping',
    v_prev_config ->> 'conflict_policy',
    v_prev_config ->> 'status'
  );
end;
$$;

comment on function app.rollback_sync_task(uuid) is
  '回滚到上一版配置 RPC（admin）：读取 config_version-1 快照并经 upsert_sync_task 重放，'
  '产生新版本（append-only，不修改历史行）；上一版为 active 时同样要求数据源已启用且已验证';

-- ---------------------------------------------------------------------------
-- 7. public 薄包装（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.upsert_sync_task(
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
language sql
security definer
set search_path = ''
as $$
  select app.upsert_sync_task(
    p_id, p_name, p_source_id, p_target_table, p_direction,
    p_field_mapping, p_conflict_policy, p_status
  )
$$;

create function public.dry_run_sync_task(p_task_id uuid, p_sample jsonb)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select app.dry_run_sync_task(p_task_id, p_sample)
$$;

create function public.get_sync_tasks()
returns table (
  id               uuid,
  name             text,
  source_id        uuid,
  source_name      text,
  source_type      text,
  source_status    text,
  source_verify_status text,
  target_table     text,
  direction        text,
  field_mapping    jsonb,
  conflict_policy  text,
  status           text,
  config_version   integer,
  created_by       uuid,
  updated_by       uuid,
  created_at       timestamptz,
  updated_at       timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.get_sync_tasks()
$$;

create function public.get_sync_task_versions(p_task_id uuid)
returns table (
  version    integer,
  config     jsonb,
  created_by uuid,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.get_sync_task_versions(p_task_id)
$$;

create function public.rollback_sync_task(p_task_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.rollback_sync_task(p_task_id)
$$;

comment on function public.upsert_sync_task(uuid, text, uuid, text, text, jsonb, text, text) is
  'upsert_sync_task Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.dry_run_sync_task(uuid, jsonb) is
  'dry_run_sync_task Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.get_sync_tasks() is
  'get_sync_tasks Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.get_sync_task_versions(uuid) is
  'get_sync_task_versions Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.rollback_sync_task(uuid) is
  'rollback_sync_task Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 8. 授权：两表仅 admin SELECT（RLS 再收口）；无表级写；管理 RPC 仅 authenticated
-- ---------------------------------------------------------------------------
revoke all on public.sync_tasks from public, anon, authenticated, service_role;
revoke all on public.sync_task_versions from public, anon, authenticated, service_role;
grant select on public.sync_tasks to authenticated;
grant select on public.sync_task_versions to authenticated;

revoke all on function app.validate_sync_mapping(text, jsonb)
  from public, anon, authenticated, service_role;

revoke all on function app.upsert_sync_task(uuid, text, uuid, text, text, jsonb, text, text)
  from public, anon, authenticated, service_role;
revoke all on function app.dry_run_sync_task(uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function app.get_sync_tasks() from public, anon, authenticated, service_role;
revoke all on function app.get_sync_task_versions(uuid) from public, anon, authenticated, service_role;
revoke all on function app.rollback_sync_task(uuid) from public, anon, authenticated, service_role;

grant execute on function app.upsert_sync_task(uuid, text, uuid, text, text, jsonb, text, text)
  to authenticated;
grant execute on function app.dry_run_sync_task(uuid, jsonb) to authenticated;
grant execute on function app.get_sync_tasks() to authenticated;
grant execute on function app.get_sync_task_versions(uuid) to authenticated;
grant execute on function app.rollback_sync_task(uuid) to authenticated;

revoke all on function public.upsert_sync_task(uuid, text, uuid, text, text, jsonb, text, text)
  from public, anon, authenticated, service_role;
revoke all on function public.dry_run_sync_task(uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.get_sync_tasks() from public, anon, authenticated, service_role;
revoke all on function public.get_sync_task_versions(uuid) from public, anon, authenticated, service_role;
revoke all on function public.rollback_sync_task(uuid) from public, anon, authenticated, service_role;

grant execute on function public.upsert_sync_task(uuid, text, uuid, text, text, jsonb, text, text)
  to authenticated;
grant execute on function public.dry_run_sync_task(uuid, jsonb) to authenticated;
grant execute on function public.get_sync_tasks() to authenticated;
grant execute on function public.get_sync_task_versions(uuid) to authenticated;
grant execute on function public.rollback_sync_task(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. RLS：两表仅 admin SELECT；无 INSERT/UPDATE/DELETE 策略（无策略=拒绝）
-- ---------------------------------------------------------------------------
create policy sync_tasks_select_admin
on public.sync_tasks
for select
to authenticated
using ((select app.current_role()) = 'admin');

create policy sync_task_versions_select_admin
on public.sync_task_versions
for select
to authenticated
using ((select app.current_role()) = 'admin');
