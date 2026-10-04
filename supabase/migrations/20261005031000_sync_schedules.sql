-- 第三方数据同步 · 调度管理（工单 sync/007）
-- 契约：docs/modules/sync/schedules.md（触发方式 manual/cron/webhook；cron 预设 + 高级表达式；
--       时区默认 Asia/Shanghai；webhook token 哈希落库、一次性明文返回、可重置；
--       停用即时生效——进行中当次跑完后注销 pg_cron job；启动要求数据源已验证；
--       单任务并发 1；webhook 限流 60 次/分钟）、docs/adr/001-job-runner.md（pg_cron 调度、
--       任务属主身份、禁 service_role）、docs/modules/INDEX.md 规则 5（pg_cron 登记，system/011
--       登记表上线前直连 cron.schedule 的 TODO 与各 worker 先例一致）。
--
-- 停用语义（「当次跑完再注销」v1 简化）：
--   disable 时若无 running run → 立即 cron.unschedule 并置 disabled；
--   若有 running run → 置 disabled_pending_unschedule（job 保留在 pg_cron 但不产生新 run，
--   run_scheduled_sync 检查 status=active 后直接跳过），由 sync/005 执行函数在本次 run 收尾时
--   注销 job 并收敛为 disabled。status 的第三态为瞬态，页面按「停用（待注销）」展示。
--
-- 组成：
--   1. public.sync_schedules：任务调度（task 唯一）；token 仅存 sha256；
--   2. app.cron_field_values / app.cron_expr_valid / app.next_cron_run：cron 五段解析与
--      下次执行时间计算（v1 支持数字语法：* / N / a-b / */n / a-b/n / 列表；不支持名称与 @ 宏，
--      8 天滚动窗口内无匹配返回 NULL，由页面显示「—」；实际调度由 pg_cron 解析）；
--   3. app.sync_schedule_register_cron / app.sync_schedule_unregister_cron：job
--      'sync-task-<task_id>' 注册/注销（幂等；job 命令 = select public.run_scheduled_sync(id)）；
--   4. app.upsert_sync_schedule / app.set_sync_schedule_status（admin）：配置与启停；
--      webhook 型生成 'st_' + uuid token，明文一次性返回、哈希落库；
--   5. app.get_sync_schedules（admin）：列表联合任务/数据源/最近执行，绝不下发 token 哈希；
--   6. public.trigger_sync_webhook（GRANT anon）：token 验签 → 限流（同任务近 1 分钟 webhook run
--      数 >= 60 拒绝）→ execute webhook；public.run_scheduled_sync（REVOKE API 角色）：
--      cron 回调，schedule active 才执行 + 收尾；
--   7. RLS：仅 admin SELECT；无表级写。
--
-- 依赖：sync/003（sync_tasks）、sync/005（sync_runs + app.execute_sync_task）、
--       system/001（pgcrypto 于 extensions schema）。
-- 下游：sync/008 调度页面。

-- ---------------------------------------------------------------------------
-- 1. sync_schedules：任务调度（task_id 唯一）
-- ---------------------------------------------------------------------------
create table public.sync_schedules (
  id                 uuid primary key default gen_random_uuid(),
  task_id            uuid not null unique references public.sync_tasks (id) on delete cascade,
  trigger_type       text not null default 'manual'
                     constraint sync_schedules_trigger_type_check
                     check (trigger_type in ('manual', 'cron', 'webhook')),
  cron_expr          text,
  timezone           text not null default 'Asia/Shanghai',
  webhook_token_hash text,
  status             text not null default 'active'
                     constraint sync_schedules_status_check
                     check (status in ('active', 'disabled', 'disabled_pending_unschedule')),
  last_run_at        timestamptz,
  next_run_at        timestamptz,
  created_by         uuid,
  updated_by         uuid,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint sync_schedules_timezone_check check (btrim(timezone) <> ''),
  constraint sync_schedules_cron_expr_check
    check (trigger_type <> 'cron' or (cron_expr is not null and btrim(cron_expr) <> '')),
  constraint sync_schedules_cron_only_check check (trigger_type = 'cron' or cron_expr is null),
  constraint sync_schedules_token_check
    check (trigger_type <> 'webhook' or webhook_token_hash is not null)
);

comment on table public.sync_schedules is
  '同步任务调度（任务唯一）：触发方式 manual/cron/webhook；webhook token 仅存 sha256（明文一次性返回）；'
  '停用进行中任务时先标记 disabled_pending_unschedule，由执行函数收尾注销 pg_cron job';
comment on column public.sync_schedules.trigger_type is
  '触发方式：manual 仅手动 / cron pg_cron 定时 / webhook 外部 token 触发';
comment on column public.sync_schedules.cron_expr is '五段 cron 表达式（仅 cron 型；v1 支持数字语法）';
comment on column public.sync_schedules.timezone is 'cron 计算时区（默认 Asia/Shanghai）';
comment on column public.sync_schedules.webhook_token_hash is
  'webhook token 的 sha256 hex（sha256(''st_''+uuid)）；明文只在生成时返回一次，可重置';
comment on column public.sync_schedules.status is
  '状态：active 启用 / disabled 停用 / disabled_pending_unschedule 停用待注销（瞬态：进行中 run 完成后注销）';
comment on column public.sync_schedules.last_run_at is '最近一次执行时间（任意触发方式；执行函数收尾更新）';
comment on column public.sync_schedules.next_run_at is '下次执行时间（cron 型按表达式计算；8 天窗口无匹配为 NULL）';

create index sync_schedules_status_idx on public.sync_schedules (status);

create trigger sync_schedules_set_updated_at
before update on public.sync_schedules
for each row
execute function app.set_updated_at();

alter table public.sync_schedules enable row level security;

-- ---------------------------------------------------------------------------
-- 2. app.cron_field_values：cron 字段展开（数字语法；非法返回 NULL）
-- ---------------------------------------------------------------------------
create function app.cron_field_values(p_field text, p_min integer, p_max integer)
returns integer[]
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_field text := btrim(coalesce(p_field, ''));
  v_part  text;
  v_range text;
  v_step  integer;
  v_lo    integer;
  v_hi    integer;
  v_i     integer;
  v_out   integer[] := '{}';
begin
  if v_field = '' then
    return null;
  end if;

  foreach v_part in array string_to_array(v_field, ',') loop
    v_part := btrim(v_part);
    if v_part = '' then
      return null;
    end if;

    v_step := 1;
    v_range := v_part;

    if position('/' in v_part) > 0 then
      v_range := btrim(split_part(v_part, '/', 1));
      begin
        v_step := btrim(split_part(v_part, '/', 2))::integer;
      exception when others then
        return null;
      end;
      if v_step is null or v_step <= 0 then
        return null;
      end if;
    end if;

    if v_range = '*' then
      v_lo := p_min;
      v_hi := p_max;
    elsif position('-' in v_range) > 0 then
      begin
        v_lo := btrim(split_part(v_range, '-', 1))::integer;
        v_hi := btrim(split_part(v_range, '-', 2))::integer;
      exception when others then
        return null;
      end;
    else
      begin
        v_lo := v_range::integer;
      exception when others then
        return null;
      end;
      v_hi := v_lo;
      -- 单值带步长（N/step，Quartz 风格）：按 N..max 展开
      if position('/' in v_part) > 0 then
        v_hi := p_max;
      end if;
    end if;

    if v_lo < p_min or v_hi > p_max or v_lo > v_hi then
      return null;
    end if;

    v_i := v_lo;
    while v_i <= v_hi loop
      if not (v_i = any (v_out)) then
        v_out := v_out || v_i;
      end if;
      v_i := v_i + v_step;
    end loop;
  end loop;

  return (select array_agg(distinct x order by x) from unnest(v_out) as x);
end;
$$;

comment on function app.cron_field_values(text, integer, integer) is
  'cron 单字段展开为值数组：支持 *、N、a-b、*/n、a-b/n、N/step、逗号列表；'
  '越界或非法返回 NULL（调用方拒绝）；纯函数不触表、不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 3. app.cron_expr_valid：五段表达式校验（数字语法）
-- ---------------------------------------------------------------------------
create function app.cron_expr_valid(p_cron_expr text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_parts text[];
begin
  v_parts := array(
    select x
    from unnest(string_to_array(btrim(coalesce(p_cron_expr, '')), ' ')) as x
    where btrim(x) <> ''
  );

  if coalesce(array_length(v_parts, 1), 0) <> 5 then
    return false;
  end if;

  return app.cron_field_values(v_parts[1], 0, 59) is not null
     and app.cron_field_values(v_parts[2], 0, 23) is not null
     and app.cron_field_values(v_parts[3], 1, 31) is not null
     and app.cron_field_values(v_parts[4], 1, 12) is not null
     and app.cron_field_values(v_parts[5], 0, 7) is not null;
end;
$$;

comment on function app.cron_expr_valid(text) is
  '五段 cron 表达式校验（分/时/日/月/周，数字语法；周 0-7，0 与 7 均为周日）；不触表';

-- ---------------------------------------------------------------------------
-- 4. app.next_cron_run：下次执行时间（8 天窗口逐分钟匹配；窗口内无匹配返回 NULL）
--    dom 与 dow 同时受限时按标准 cron 取 OR，否则 AND；时区经 pg_timezone_names 校验。
-- ---------------------------------------------------------------------------
create function app.next_cron_run(
  p_cron_expr text,
  p_timezone  text,
  p_from      timestamptz default now()
)
returns timestamptz
language plpgsql
stable
set search_path = ''
as $$
declare
  v_parts text[];
  v_tz    text := coalesce(nullif(btrim(coalesce(p_timezone, '')), ''), 'Asia/Shanghai');
  v_from  timestamptz := coalesce(p_from, now());
  v_min   integer[];
  v_hour  integer[];
  v_dom   integer[];
  v_month integer[];
  v_dow   integer[];
  v_ts    timestamptz;
begin
  v_parts := array(
    select x
    from unnest(string_to_array(btrim(coalesce(p_cron_expr, '')), ' ')) as x
    where btrim(x) <> ''
  );

  if coalesce(array_length(v_parts, 1), 0) <> 5 then
    return null;
  end if;

  v_min   := app.cron_field_values(v_parts[1], 0, 59);
  v_hour  := app.cron_field_values(v_parts[2], 0, 23);
  v_dom   := app.cron_field_values(v_parts[3], 1, 31);
  v_month := app.cron_field_values(v_parts[4], 1, 12);
  v_dow   := app.cron_field_values(v_parts[5], 0, 7);

  if v_min is null or v_hour is null or v_dom is null or v_month is null or v_dow is null then
    return null;
  end if;

  if not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = v_tz) then
    return null;
  end if;

  select min(g.ts) into v_ts
  from pg_catalog.generate_series(
         date_trunc('minute', v_from) + interval '1 minute',
         v_from + interval '8 days',
         interval '1 minute'
       ) as g(ts)
  where extract(minute from (g.ts at time zone v_tz))::integer = any (v_min)
    and extract(hour   from (g.ts at time zone v_tz))::integer = any (v_hour)
    and extract(month  from (g.ts at time zone v_tz))::integer = any (v_month)
    and case
          when v_parts[3] <> '*' and v_parts[5] <> '*' then
            extract(day from (g.ts at time zone v_tz))::integer = any (v_dom)
            or extract(dow from (g.ts at time zone v_tz))::integer = any (v_dow)
            or (extract(dow from (g.ts at time zone v_tz))::integer = 0 and 7 = any (v_dow))
          else
            extract(day from (g.ts at time zone v_tz))::integer = any (v_dom)
            and (extract(dow from (g.ts at time zone v_tz))::integer = any (v_dow)
                 or (extract(dow from (g.ts at time zone v_tz))::integer = 0 and 7 = any (v_dow)))
        end;

  return v_ts;
end;
$$;

comment on function app.next_cron_run(text, text, timestamptz) is
  'cron 下次执行时间（8 天滚动窗口逐分钟匹配，含时区换算；窗口内无匹配返回 NULL）；'
  'dom 与 dow 同时受限按标准 cron 取 OR；不触表、不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 5. pg_cron job 注册/注销（job 名 'sync-task-<task_id>'，幂等）
-- ---------------------------------------------------------------------------
create function app.sync_schedule_register_cron(p_task_id uuid, p_cron_expr text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if to_regprocedure('cron.schedule(text,text,text)') is null then
    raise exception 'pg_cron 未安装，无法注册定时调度' using errcode = '0A000';
  end if;

  begin
    perform cron.schedule(
      'sync-task-' || p_task_id::text,
      p_cron_expr,
      format('select public.run_scheduled_sync(%L)', p_task_id::text)
    );
  exception when others then
    raise exception 'cron 表达式注册失败：%', sqlerrm using errcode = '22023';
  end;
end;
$$;

comment on function app.sync_schedule_register_cron(uuid, text) is
  '注册/更新该任务的 pg_cron job（同名幂等：pg_cron 对同名 schedule 执行更新）；'
  'job 命令 = select public.run_scheduled_sync(任务 id)；表达式的最终解析以 pg_cron 为准';

create function app.sync_schedule_unregister_cron(p_task_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job    text := 'sync-task-' || p_task_id::text;
  v_exists boolean := false;
begin
  if to_regclass('cron.job') is null then
    return;
  end if;

  execute format('select exists (select 1 from cron.job where jobname = %L)', v_job)
    into v_exists;

  if v_exists then
    execute format('select cron.unschedule(%L)', v_job);
  end if;
end;
$$;

comment on function app.sync_schedule_unregister_cron(uuid) is
  '注销该任务的 pg_cron job（不存在则幂等跳过；job 名 sync-task-<task_id>）';

-- ---------------------------------------------------------------------------
-- 6. app.upsert_sync_schedule：admin 新建/编辑配置（含启停与 token 轮换）
-- ---------------------------------------------------------------------------
create function app.upsert_sync_schedule(
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

  -- 停用时有运行中 run → 待注销（当次跑完由执行函数收尾）
  if v_status = 'disabled'
     and exists (
       select 1 from public.sync_runs r
       where r.task_id = p_task_id and r.status = 'running'
     ) then
    v_status := 'disabled_pending_unschedule';
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

  -- pg_cron job 同步：active cron → 注册；disabled cron / 非 cron → 注销；
  -- disabled_pending_unschedule 保留 job（执行函数收尾注销）
  if v_trigger = 'cron' and v_status = 'active' then
    perform app.sync_schedule_register_cron(p_task_id, v_cron);
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
  '调度新建/编辑 RPC（admin）：cron 型校验表达式并注册 pg_cron job；webhook 型生成 st_<uuid> '
  'token（明文一次性返回、sha256 落库；p_regenerate_token 轮换）；启用要求任务启用且数据源已验证；'
  '停用有 running run 时置 disabled_pending_unschedule 待执行函数收尾注销';

-- ---------------------------------------------------------------------------
-- 7. app.set_sync_schedule_status：admin 启停（唯一状态迁移入口，页面快捷按钮）
-- ---------------------------------------------------------------------------
create function app.set_sync_schedule_status(p_task_id uuid, p_status text)
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
      perform app.sync_schedule_register_cron(p_task_id, v_prev.cron_expr);
      v_next := app.next_cron_run(v_prev.cron_expr, v_prev.timezone, now());
    elsif v_prev.trigger_type = 'webhook' and v_hash is null then
      v_token := 'st_' || gen_random_uuid()::text;
      v_hash := encode(extensions.digest(v_token, 'sha256'), 'hex');
    end if;
  else
    -- 停用：cron 有运行中 run → 待注销（job 保留但不再产新 run）；否则立即注销
    if v_prev.trigger_type = 'cron' then
      if exists (
        select 1 from public.sync_runs r
        where r.task_id = p_task_id and r.status = 'running'
      ) then
        v_status := 'disabled_pending_unschedule';
      else
        perform app.sync_schedule_unregister_cron(p_task_id);
        v_status := 'disabled';
      end if;
    else
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
  '调度启停 RPC（admin）：启用要求任务启用且数据源已验证；cron 停用时无 running run 立即注销 job，'
  '有则置 disabled_pending_unschedule；webhook 缺 token 时启用返回一次性明文';

-- ---------------------------------------------------------------------------
-- 8. app.get_sync_schedules：admin 列表（绝不下发 token 哈希）
-- ---------------------------------------------------------------------------
create function app.get_sync_schedules()
returns table (
  id              uuid,
  task_id         uuid,
  task_name       text,
  source_name     text,
  target_table    text,
  trigger_type    text,
  cron_expr       text,
  timezone        text,
  status          text,
  has_token       boolean,
  last_run_at     timestamptz,
  next_run_at     timestamptz,
  last_run_status text,
  created_at      timestamptz,
  updated_at      timestamptz
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
    s.id,
    s.task_id,
    t.name,
    src.name,
    t.target_table,
    s.trigger_type,
    s.cron_expr,
    s.timezone,
    s.status,
    (s.webhook_token_hash is not null),
    s.last_run_at,
    s.next_run_at,
    lr.status,
    s.created_at,
    s.updated_at
  from public.sync_schedules s
  join public.sync_tasks t on t.id = s.task_id
  join public.sync_sources src on src.id = t.source_id
  left join lateral (
    select r.status
    from public.sync_runs r
    where r.task_id = s.task_id
    order by r.started_at desc, r.id desc
    limit 1
  ) lr on true
  order by t.name, s.id;
end;
$$;

comment on function app.get_sync_schedules() is
  '调度列表 RPC（admin）：联合任务/数据源/最近执行状态；仅返回 has_token 布尔，不下发 token 哈希/明文';

-- ---------------------------------------------------------------------------
-- 9. public.trigger_sync_webhook：公开 webhook 入口（anon；验签 + 限流）
-- ---------------------------------------------------------------------------
create function public.trigger_sync_webhook(p_token text)
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
  '同任务近 1 分钟 webhook run ≥ 60 拒绝；执行身份 = 任务 created_by；返回 run id';

-- ---------------------------------------------------------------------------
-- 10. public.run_scheduled_sync：pg_cron 回调（REVOKE API 角色）
-- ---------------------------------------------------------------------------
create function public.run_scheduled_sync(p_task_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_schedule public.sync_schedules;
  v_task     public.sync_tasks;
begin
  select * into v_schedule
  from public.sync_schedules s
  where s.task_id = p_task_id
    and s.trigger_type = 'cron';

  -- 停用/待注销/已删除：不再产生新 run（当次进行中的由执行函数收尾）
  if not found or v_schedule.status <> 'active' then
    return null;
  end if;

  select * into v_task
  from public.sync_tasks t
  where t.id = p_task_id;

  if not found or v_task.status <> 'active' then
    return null;
  end if;

  return app.execute_sync_task(p_task_id, 'cron');
end;
$$;

comment on function public.run_scheduled_sync(uuid) is
  'cron 回调（REVOKE API 角色；仅 pg_cron/owner 可达）：schedule active 且任务 active 才执行 '
  'execute_sync_task(cron)；last/next_run_at 由执行函数收尾统一更新；未执行返回 NULL';

-- ---------------------------------------------------------------------------
-- 11. public 薄包装（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.upsert_sync_schedule(
  p_task_id          uuid,
  p_trigger_type     text,
  p_cron_expr        text default null,
  p_timezone         text default null,
  p_status           text default null,
  p_regenerate_token boolean default false
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.upsert_sync_schedule(
    p_task_id, p_trigger_type, p_cron_expr, p_timezone, p_status, p_regenerate_token
  )
$$;

create function public.set_sync_schedule_status(p_task_id uuid, p_status text)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.set_sync_schedule_status(p_task_id, p_status)
$$;

create function public.get_sync_schedules()
returns table (
  id              uuid,
  task_id         uuid,
  task_name       text,
  source_name     text,
  target_table    text,
  trigger_type    text,
  cron_expr       text,
  timezone        text,
  status          text,
  has_token       boolean,
  last_run_at     timestamptz,
  next_run_at     timestamptz,
  last_run_status text,
  created_at      timestamptz,
  updated_at      timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.get_sync_schedules()
$$;

comment on function public.upsert_sync_schedule(uuid, text, text, text, text, boolean) is
  'upsert_sync_schedule Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.set_sync_schedule_status(uuid, text) is
  'set_sync_schedule_status Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.get_sync_schedules() is
  'get_sync_schedules Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 12. 授权：表仅 admin SELECT；执行/注册内部函数无 API 直调；管理 RPC authenticated；
--     webhook 入口 GRANT anon（公开端点）
-- ---------------------------------------------------------------------------
revoke all on public.sync_schedules from public, anon, authenticated, service_role;
grant select on public.sync_schedules to authenticated;

revoke all on function app.cron_field_values(text, integer, integer)
  from public, anon, authenticated, service_role;
revoke all on function app.cron_expr_valid(text) from public, anon, authenticated, service_role;
revoke all on function app.next_cron_run(text, text, timestamptz)
  from public, anon, authenticated, service_role;
revoke all on function app.sync_schedule_register_cron(uuid, text)
  from public, anon, authenticated, service_role;
revoke all on function app.sync_schedule_unregister_cron(uuid)
  from public, anon, authenticated, service_role;
revoke all on function app.upsert_sync_schedule(uuid, text, text, text, text, boolean)
  from public, anon, authenticated, service_role;
revoke all on function app.set_sync_schedule_status(uuid, text)
  from public, anon, authenticated, service_role;
revoke all on function app.get_sync_schedules() from public, anon, authenticated, service_role;

grant execute on function app.upsert_sync_schedule(uuid, text, text, text, text, boolean) to authenticated;
grant execute on function app.set_sync_schedule_status(uuid, text) to authenticated;
grant execute on function app.get_sync_schedules() to authenticated;

revoke all on function public.upsert_sync_schedule(uuid, text, text, text, text, boolean)
  from public, anon, authenticated, service_role;
revoke all on function public.set_sync_schedule_status(uuid, text)
  from public, anon, authenticated, service_role;
revoke all on function public.get_sync_schedules() from public, anon, authenticated, service_role;
revoke all on function public.trigger_sync_webhook(text) from public, anon, authenticated, service_role;
revoke all on function public.run_scheduled_sync(uuid) from public, anon, authenticated, service_role;

grant execute on function public.upsert_sync_schedule(uuid, text, text, text, text, boolean) to authenticated;
grant execute on function public.set_sync_schedule_status(uuid, text) to authenticated;
grant execute on function public.get_sync_schedules() to authenticated;
grant execute on function public.trigger_sync_webhook(text) to anon, authenticated;

-- run_scheduled_sync 不 GRANT API 角色：仅 pg_cron 的 postgres 可达。

-- ---------------------------------------------------------------------------
-- 13. RLS：仅 admin SELECT；无 INSERT/UPDATE/DELETE 策略（无策略=拒绝）
-- ---------------------------------------------------------------------------
create policy sync_schedules_select_admin
on public.sync_schedules
for select
to authenticated
using ((select app.current_role()) = 'admin');
