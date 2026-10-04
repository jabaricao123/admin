-- 报表中心 · 报表订阅（工单 report/005 + report/006）
-- 契约：docs/modules/report/subscriptions.md：
--   * report_subscriptions（频率预设落 cron_expr、渠道 text[]、接收范围 self/role:<code>、
--     逻辑删 is_deleted）与 report_subscription_runs（执行历史：running/success/failed）；
--   * 执行走 pg_cron（system 平台登记处 INDEX 规则 5），产物走 message 发送 RPC（规则 3）；
--   * 执行必须注入订阅属主身份，按 owner 数据范围过滤，禁止 service_role（ADR-001 全局禁令）；
--   * 停用保留历史，删除需二次确认（逻辑删 + 注销 pg_cron job）。
-- 设计要点：
--   1. 页面只给频率预设（每小时 / 每天 HH:mm / 每周几 HH:mm），cron 表达式由
--      upsert_report_subscription 统一映射后落表（普通用户不接触 cron 原文）；
--   2. 邮件渠道经 message 分发降级（message/009 渠道分发），本工单不直发邮件；channels
--      仅存偏好，站内信送达始终经 app.send_notification（规则 3）；
--   3. 执行函数 app.run_report_subscription 为 SECURITY INVOKER + 撤销 API 角色执行权
--      （报告 007 worker 同款落地：PG 禁止 SECURITY DEFINER 内 SET ROLE，见 ADR-001 偏离说明），
--      仅 pg_cron 的 postgres 可达；内部注入属主 claims + 临时 SET ROLE authenticated，
--      调 app.run_report（SECURITY INVOKER）按属主 RLS 生成快照；
--   4. 手动触发（owner/admin）走 public.run_report_subscription_now：从 PostgREST 起
--      全程 SECURITY INVOKER（当前角色已是 authenticated），claims 注入属主后执行；
--      执行记录/通知/审计写经小的 SECURITY DEFINER helper（表级无 API 写权限不变）。
-- 依赖：report/002+003（report_definitions + run_report，20261005000000）、
--       message/001（app.send_notification，20261003205454）、message/004+005（事件注册
--       report.export_ready，20261005020000）、system/011（app.register_cron_job，
--       20261005080000）、sync/007（app.next_cron_run 下次执行时间计算，20261005031000）、
--       audit/001（app.audit_log）、access/003（app.current_role）。

-- ---------------------------------------------------------------------------
-- 1. report_subscriptions：订阅（属主 = created_by）
-- ---------------------------------------------------------------------------
create table public.report_subscriptions (
  id            uuid primary key default gen_random_uuid(),
  report_def_id uuid not null references public.report_definitions (id),
  cron_expr     text not null,
  channels      text[] not null default '{inbox}',
  recipients    text not null default 'self',
  status        text not null default 'active'
                constraint report_subscriptions_status_check
                check (status in ('active', 'disabled')),
  is_deleted    boolean not null default false,
  created_by    uuid not null references public.profiles (id),
  updated_by    uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint report_subscriptions_cron_not_blank check (btrim(cron_expr) <> ''),
  constraint report_subscriptions_channels_not_empty
    check (cardinality(channels) > 0),
  constraint report_subscriptions_channels_allowed
    check (channels <@ array['inbox', 'email']::text[]),
  constraint report_subscriptions_recipients_check
    check (recipients = 'self' or recipients ~ '^role:[a-z][a-z0-9_]*$')
);

comment on table public.report_subscriptions is
  '报表订阅（subscriptions.md 数据模型）：report_def_id → report_definitions；'
  '频率预设经 RPC 映射为 cron_expr 落表；属主 = created_by（RLS 与执行身份锚点）；'
  '写入仅经 SECURITY DEFINER RPC，表级无 API 写权限；删除为逻辑删（is_deleted）';
comment on column public.report_subscriptions.report_def_id is
  '订阅的报表定义（FK 默认 restrict：有订阅的报表不可物理删除）';
comment on column public.report_subscriptions.cron_expr is
  '五段 cron 表达式（由频率预设映射，页面不暴露原文）：每小时 0 * * * *、'
  '每天 m H * * *、每周 m H * * w；实际调度以 pg_cron 为准';
comment on column public.report_subscriptions.channels is
  '投递渠道偏好（inbox/email；email 经 message 渠道分发降级，本工单不直发，message/009 生效）';
comment on column public.report_subscriptions.recipients is
  '接收范围：self 订阅属主本人 | role:<code> 该角色全部 active 用户';
comment on column public.report_subscriptions.status is
  '状态：active 启用（pg_cron job 在册） / disabled 停用（job 已注销，历史保留）';
comment on column public.report_subscriptions.is_deleted is
  '逻辑删标记：删除 = is_deleted=true + status=disabled + 注销 job；执行历史保留';
comment on column public.report_subscriptions.created_by is
  '订阅属主（创建人）：执行身份注入锚点；RLS 按此列收口 owner/admin';

create index report_subscriptions_owner_idx
  on public.report_subscriptions (created_by);
create index report_subscriptions_active_idx
  on public.report_subscriptions (report_def_id)
  where status = 'active' and not is_deleted;

-- ---------------------------------------------------------------------------
-- 2. report_subscription_runs：执行历史（每次触发一条）
-- ---------------------------------------------------------------------------
create table public.report_subscription_runs (
  id              bigint generated always as identity primary key,
  subscription_id uuid not null references public.report_subscriptions (id) on delete cascade,
  status          text not null default 'running'
                  constraint report_subscription_runs_status_check
                  check (status in ('running', 'success', 'failed')),
  duration_ms     integer,
  error           text,
  created_at      timestamptz not null default now(),
  constraint report_subscription_runs_duration_check
    check (duration_ms is null or duration_ms >= 0)
);

comment on table public.report_subscription_runs is
  '订阅执行历史（subscriptions.md）：每次 cron/手动触发一条；running 起点，'
  '收尾置 success/failed（失败记 error，可手动重发）；写入仅经内部函数，无 API 表级写';
comment on column public.report_subscription_runs.status is
  '状态：running 执行中 / success 成功 / failed 失败（失败原因见 error）';
comment on column public.report_subscription_runs.duration_ms is '执行耗时（毫秒）；起点到收尾的墙钟时间';
comment on column public.report_subscription_runs.error is '失败原因（截断 500 字符；成功为 NULL）';
comment on column public.report_subscription_runs.created_at is '触发时间（running 行的创建时间即开始时间）';

create index report_subscription_runs_subscription_idx
  on public.report_subscription_runs (subscription_id, created_at desc, id desc);
-- 低频历史表：身份列不暴露给 API 角色，仅内部函数写入

-- ---------------------------------------------------------------------------
-- 3. pg_cron job 注册/注销（job 名 'report-sub-<id>'，幂等；同步登记 system 平台登记处）
-- ---------------------------------------------------------------------------
create function app.report_subscription_register_cron(
  p_subscription_id uuid,
  p_cron_expr       text
)
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
      'report-sub-' || p_subscription_id::text,
      p_cron_expr,
      format('select app.run_report_subscription(%L)', p_subscription_id::text)
    );
  exception when others then
    raise exception 'cron 表达式注册失败：%', sqlerrm using errcode = '22023';
  end;

  -- INDEX 规则 5：调度统一在 system 平台登记处登记（不 GRANT API 角色，规则 10）
  perform app.register_cron_job(
    'report-sub-' || p_subscription_id::text,
    'report',
    p_cron_expr,
    'Asia/Shanghai',
    '/report/subscriptions'
  );
end;
$$;

comment on function app.report_subscription_register_cron(uuid, text) is
  '注册/更新订阅的 pg_cron job（同名幂等）并登记 system_cron_registry；'
  'job 命令 = select app.run_report_subscription(<id>)；仅内部 RPC 调用，不 GRANT API 角色';

create function app.report_subscription_unregister_cron(p_subscription_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job    text := 'report-sub-' || p_subscription_id::text;
  v_exists boolean := false;
begin
  if to_regclass('cron.job') is not null then
    execute format('select exists (select 1 from cron.job where jobname = %L)', v_job)
      into v_exists;

    if v_exists then
      execute format('select cron.unschedule(%L)', v_job);
    end if;
  end if;

  -- 登记注销（幂等）：登记缺失不阻断删除流程
  perform app.unregister_cron_job(v_job);
end;
$$;

comment on function app.report_subscription_unregister_cron(uuid) is
  '注销订阅的 pg_cron job（不存在幂等跳过）并置 system_cron_registry.status=disabled（历史保留）';

-- ---------------------------------------------------------------------------
-- 4. app.report_subscription_run_begin / notify / finish：执行记录与通知 helper
--    （SECURITY DEFINER：表级无 API 写权限；内部显式校验 owner/admin，
--      供 cron（postgres）与手动（authenticated INVOKER 链）两条路径共用）
-- ---------------------------------------------------------------------------
create function app.report_subscription_run_begin(p_subscription_id uuid)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_role   public.user_role := (select app.current_role());
  v_sub    public.report_subscriptions;
  v_run_id bigint;
begin
  if p_subscription_id is null then
    raise exception '订阅 ID 不能为空' using errcode = '22023';
  end if;

  select * into v_sub
  from public.report_subscriptions
  where id = p_subscription_id
  for update;

  if not found then
    raise exception '订阅不存在' using errcode = 'P0002';
  end if;

  if v_sub.is_deleted then
    raise exception '订阅已删除，无法执行' using errcode = 'P0001';
  end if;

  if v_sub.created_by is distinct from v_uid
     and v_role is distinct from 'admin' then
    raise exception '无权执行该报表订阅' using errcode = '42501';
  end if;

  insert into public.report_subscription_runs (subscription_id, status)
  values (p_subscription_id, 'running')
  returning id into v_run_id;

  return v_run_id;
end;
$$;

comment on function app.report_subscription_run_begin(uuid) is
  '创建 running 执行记录（锁定订阅行）；显式校验 owner/admin（cron 路径由属主 claims 通过）；'
  'internal helper，供执行函数调用';

create function app.report_subscription_run_notify(
  p_subscription_id uuid,
  p_run_id          bigint,
  p_result          jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_preview_rows constant integer := 10;
  v_uid          uuid := (select auth.uid());
  v_role         public.user_role := (select app.current_role());
  v_sub          public.report_subscriptions;
  v_report_name  text;
  v_rows         jsonb;
  v_count        integer;
  v_preview      text;
  v_title        text;
  v_body         text;
  v_recipients   uuid[];
  v_recipient    uuid;
  v_sent         integer := 0;
  v_role_code    text;
begin
  select * into v_sub
  from public.report_subscriptions
  where id = p_subscription_id;

  if not found then
    raise exception '订阅不存在' using errcode = 'P0002';
  end if;

  if v_sub.created_by is distinct from v_uid
     and v_role is distinct from 'admin' then
    raise exception '无权发送该订阅通知' using errcode = '42501';
  end if;

  select d.name into v_report_name
  from public.report_definitions d
  where d.id = v_sub.report_def_id;

  v_rows := coalesce(p_result -> 'rows', '[]'::jsonb);
  if jsonb_typeof(v_rows) <> 'array' then
    v_rows := '[]'::jsonb;
  end if;
  v_count := jsonb_array_length(v_rows);

  -- 摘要：行数 + 前 10 行（列=值，逗号分隔）
  select string_agg(line, E'\n' order by ord)
    into v_preview
  from (
    select
      r.ord,
      (
        select string_agg(
                 format('%s=%s', kv.key, coalesce(kv.value, '')),
                 ', ' order by kv.key
               )
        from jsonb_each_text(r.value) as kv(key, value)
      ) as line
    from jsonb_array_elements(v_rows) with ordinality as r(value, ord)
    where r.ord <= c_preview_rows
  ) t;

  v_title := format('报表订阅「%s」已生成', coalesce(v_report_name, '未命名报表'));
  v_body := format('共 %s 行。', v_count)
    || case
         when coalesce(v_preview, '') = '' then ''
         else format(E'\n前 %s 行：\n%s', least(v_count, c_preview_rows), v_preview)
       end;

  -- 接收范围：self → 订阅属主；role:<code> → 该角色全部 active 用户（role_id 优先，枚举兜底）
  if v_sub.recipients = 'self' then
    v_recipients := array[v_sub.created_by];
  else
    v_role_code := split_part(v_sub.recipients, ':', 2);

    select coalesce(array_agg(p.id order by p.id), '{}'::uuid[])
      into v_recipients
    from public.profiles p
    left join public.roles r on r.id = p.role_id
    where p.status = 'active'
      and (
        r.code = v_role_code
        or (p.role_id is null and p.role::text = v_role_code)
      );
  end if;

  -- 统一经 message 发送 RPC（INDEX 规则 3）；event_key report.export_ready 已登记
  foreach v_recipient in array coalesce(v_recipients, '{}'::uuid[])
  loop
    perform app.send_notification(
      v_recipient,
      'report.export_ready',
      jsonb_build_object(
        'title', v_title,
        'body', v_body,
        'report_name', coalesce(v_report_name, ''),
        'row_count', v_count,
        'summary', coalesce(v_preview, ''),
        'source_module', 'report',
        'ref_type', 'report_subscription_run',
        'ref_id', p_run_id::text
      )
    );
    v_sent := v_sent + 1;
  end loop;

  return v_sent;
end;
$$;

comment on function app.report_subscription_run_notify(uuid, bigint, jsonb) is
  '发送订阅结果摘要站内信（行数 + 前 10 行）：self → 属主；role:<code> → 角色 active 用户 loop；'
  '统一经 app.send_notification（report.export_ready）；返回发送条数';

create function app.report_subscription_run_finish(
  p_run_id      bigint,
  p_status      text,
  p_duration_ms integer,
  p_error       text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_role public.user_role := (select app.current_role());
  v_run  public.report_subscription_runs;
  v_sub  public.report_subscriptions;
begin
  if p_status is null or p_status not in ('success', 'failed') then
    raise exception '执行状态不合法（success/failed）：%', coalesce(p_status, '(null)')
      using errcode = '22023';
  end if;

  select * into v_run
  from public.report_subscription_runs
  where id = p_run_id;

  if not found then
    raise exception '执行记录不存在' using errcode = 'P0002';
  end if;

  select * into v_sub
  from public.report_subscriptions
  where id = v_run.subscription_id;

  if v_sub.created_by is distinct from v_uid
     and v_role is distinct from 'admin' then
    raise exception '无权操作该执行记录' using errcode = '42501';
  end if;

  update public.report_subscription_runs
     set status      = p_status,
         duration_ms = greatest(coalesce(p_duration_ms, 0), 0),
         error       = case
                         when p_status = 'failed'
                           then left(nullif(btrim(coalesce(p_error, '')), ''), 500)
                         else null
                       end
   where id = p_run_id;

  if p_status = 'failed' then
    perform app.audit_log(
      'report',
      'fail',
      'report_subscription_run',
      p_run_id::text,
      jsonb_build_object(
        'subscription_id', v_run.subscription_id,
        'report_def_id', v_sub.report_def_id,
        'error', left(coalesce(p_error, ''), 500)
      )
    );
  end if;
end;
$$;

comment on function app.report_subscription_run_finish(bigint, text, integer, text) is
  '收尾执行记录（success/failed + duration_ms + error）；失败写审计摘要（ADR-001 §3）；'
  '显式校验 owner/admin';

-- ---------------------------------------------------------------------------
-- 5. app.execute_report_subscription：执行核心（两条入口共用）
--    - cron（app.run_report_subscription）与手动（app.run_report_subscription_now）
--      共用本函数；SECURITY INVOKER，身份注入 + 属主 RLS 视角见文件头；
--    - 手动路径由调用方已完成 owner/admin 可见性校验，本函数再显式复检；
--    - 失败不向外抛：记录 failed + error 后返回 run id（cron 回调不中断，历史可重发）。
-- ---------------------------------------------------------------------------
create function app.execute_report_subscription(
  p_subscription_id uuid,
  p_trigger         text
)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_prev_role   text := current_setting('role');
  v_prev_claims text := current_setting('request.jwt.claims', true);
  v_uid         uuid := (select auth.uid());
  v_role        public.user_role := (select app.current_role());
  v_sub         public.report_subscriptions;
  v_run_id      bigint;
  v_started     timestamptz;
  v_duration    integer;
  v_result      jsonb;
begin
  if p_subscription_id is null then
    raise exception '订阅 ID 不能为空' using errcode = '22023';
  end if;

  if p_trigger is null or p_trigger not in ('cron', 'manual') then
    raise exception '触发类型不合法（cron/manual）：%', coalesce(p_trigger, '(null)')
      using errcode = '22023';
  end if;

  select * into v_sub
  from public.report_subscriptions
  where id = p_subscription_id;

  if not found then
    if p_trigger = 'cron' then
      return null; -- 订阅已不存在：cron 回调静默跳过
    end if;
    raise exception '订阅不存在或无权访问' using errcode = 'P0002';
  end if;

  -- 逻辑删：cron 跳过；停用：cron 跳过（job 未及时注销时兜底）
  if v_sub.is_deleted or (p_trigger = 'cron' and v_sub.status <> 'active') then
    if p_trigger = 'cron' then
      return null;
    end if;
    raise exception '订阅已删除，无法执行' using errcode = 'P0001';
  end if;

  -- 手动触发：owner/admin 显式复检（RLS 可见性不为授权真相）
  if p_trigger = 'manual'
     and v_sub.created_by is distinct from v_uid
     and v_role is distinct from 'admin' then
    raise exception '无权执行该报表订阅' using errcode = '42501';
  end if;

  -- 属主身份注入（ADR-001）：先落 claims，供 helper 与 run_report 的 auth.uid() 使用；
  -- 全局禁止 service_role（BYPASSRLS）。
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_sub.created_by, 'role', 'authenticated')::text,
    true
  );

  v_run_id := app.report_subscription_run_begin(p_subscription_id);
  v_started := clock_timestamp();

  begin
    -- 属主 RLS 视角：pg_cron（postgres）需临时 SET ROLE authenticated；
    -- 手动路径当前角色已是 authenticated（GUC role 同步反映），无需切换。
    if v_prev_role is distinct from 'authenticated' then
      set local role authenticated;
    end if;

    v_result := app.run_report(v_sub.report_def_id);

    if v_prev_role is distinct from 'authenticated' then
      if v_prev_role is null or v_prev_role = 'none' then
        reset role;
      else
        execute format('set local role %I', v_prev_role);
      end if;
    end if;

    -- 摘要投递（在属主身份下发送，helper 内再校验 owner/admin）
    perform app.report_subscription_run_notify(v_sub.id, v_run_id, v_result);

    v_duration := (extract(epoch from clock_timestamp() - v_started) * 1000)::integer;

    perform app.report_subscription_run_finish(v_run_id, 'success', v_duration, null);
  exception when others then
    -- 失败不中断：还原角色/claims 后记录 failed + 原因（历史可手动重发）
    if v_prev_role is distinct from 'authenticated' then
      if v_prev_role is null or v_prev_role = 'none' then
        reset role;
      else
        execute format('set local role %I', v_prev_role);
      end if;
    end if;

    v_duration := (extract(epoch from clock_timestamp() - v_started) * 1000)::integer;

    perform app.report_subscription_run_finish(
      v_run_id, 'failed', v_duration, left(sqlerrm, 500)
    );

    perform set_config('request.jwt.claims', coalesce(v_prev_claims, ''), true);
    return v_run_id;
  end;

  -- 正常收尾：还原调用方 claims（事务级 GUC；cron 路径无调用方 claims 时置空）
  perform set_config('request.jwt.claims', coalesce(v_prev_claims, ''), true);

  return v_run_id;
end;
$$;

comment on function app.execute_report_subscription(uuid, text) is
  '订阅执行核心（SECURITY INVOKER）：注入订阅属主 claims + 属主 RLS 视角调 run_report，'
  '结果摘要经 send_notification 投递后写 runs；失败记 failed + error 不中断；'
  'cron 路径禁用/逻辑删直接跳过；返回 run id（跳过为 NULL）';

-- ---------------------------------------------------------------------------
-- 6. app.run_report_subscription：pg_cron 回调入口（REVOKE API 角色，仅 postgres 可达）
-- ---------------------------------------------------------------------------
create function app.run_report_subscription(p_subscription_id uuid)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
begin
  return app.execute_report_subscription(p_subscription_id, 'cron');
end;
$$;

comment on function app.run_report_subscription(uuid) is
  'cron 回调（REVOKE API 角色；仅 pg_cron 的 postgres 可达）：订阅 active 且未删才执行；'
  '返回 run id，跳过为 NULL';

-- ---------------------------------------------------------------------------
-- 7. 管理 RPC（owner/admin）：upsert / delete / set_status
-- ---------------------------------------------------------------------------
create function app.upsert_report_subscription(
  p_id            uuid,
  p_report_def_id uuid,
  p_preset        text,
  p_time          text default '09:00',
  p_weekday       integer default 1,
  p_channels      text[] default array['inbox'],
  p_recipients    text default 'self'
)
returns public.report_subscriptions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_role     public.user_role := (select app.current_role());
  v_preset   text := lower(btrim(coalesce(p_preset, '')));
  v_time     text := btrim(coalesce(p_time, ''));
  v_weekday  integer := coalesce(p_weekday, 1);
  v_channels text[];
  v_channel  text;
  v_hour     integer;
  v_minute   integer;
  v_cron     text;
  v_def      public.report_definitions;
  v_prev     public.report_subscriptions;
  v_row      public.report_subscriptions;
begin
  if v_uid is null then
    raise exception '未登录，无法保存报表订阅' using errcode = '42501';
  end if;

  -- 频率预设 → cron 表达式（页面只给预设，cron 存表）
  if v_preset not in ('hourly', 'daily', 'weekly') then
    raise exception '频率预设不合法（hourly/daily/weekly）：%', coalesce(p_preset, '(null)')
      using errcode = '22023';
  end if;

  if v_preset <> 'hourly' then
    if v_time !~ '^([01]\d|2[0-3]):[0-5]\d$' then
      raise exception '时间格式需为 HH:mm：%', coalesce(nullif(v_time, ''), '(null)')
        using errcode = '22023';
    end if;
    v_hour := substring(v_time from 1 for 2)::integer;
    v_minute := substring(v_time from 4 for 2)::integer;
  end if;

  if v_preset = 'weekly' then
    if v_weekday < 0 or v_weekday > 6 then
      raise exception '星期取值需在 0..6（0=周日）：%', v_weekday using errcode = '22023';
    end if;
    v_cron := format('%s %s * * %s', v_minute, v_hour, v_weekday);
  elsif v_preset = 'daily' then
    v_cron := format('%s %s * * *', v_minute, v_hour);
  else
    v_cron := '0 * * * *';
  end if;

  -- 渠道：非空、限 inbox/email（email 经 message 分发降级，本工单不直发）
  if p_channels is null or cardinality(p_channels) = 0 then
    raise exception '至少选择一个投递渠道' using errcode = '22023';
  end if;

  select array_agg(distinct c order by c)
    into v_channels
  from unnest(p_channels) as c;

  foreach v_channel in array v_channels
  loop
    if v_channel is null or v_channel not in ('inbox', 'email') then
      raise exception '不支持的投递渠道：%', coalesce(v_channel, '(null)') using errcode = '22023';
    end if;
  end loop;

  -- 接收范围：self 或 role:<code>（角色须存在）
  if p_recipients is distinct from 'self' then
    if p_recipients is null or p_recipients !~ '^role:[a-z][a-z0-9_]*$' then
      raise exception '接收范围不合法（self 或 role:<code>）：%', coalesce(p_recipients, '(null)')
        using errcode = '22023';
    end if;

    if not exists (
      select 1 from public.roles r where r.code = split_part(p_recipients, ':', 2)
    ) then
      raise exception '角色不存在：%', split_part(p_recipients, ':', 2) using errcode = 'P0002';
    end if;
  end if;

  -- 可订阅的报表：public / 本人 / admin
  select * into v_def
  from public.report_definitions
  where id = p_report_def_id;

  if not found then
    raise exception '报表定义不存在' using errcode = 'P0002';
  end if;

  if v_def.visibility <> 'public'
     and v_def.owner_id is distinct from v_uid
     and v_role is distinct from 'admin' then
    raise exception '无权订阅该报表定义' using errcode = '42501';
  end if;

  if p_id is null then
    insert into public.report_subscriptions
      (report_def_id, cron_expr, channels, recipients, status, created_by, updated_by)
    values
      (p_report_def_id, v_cron, v_channels,
       coalesce(p_recipients, 'self'), 'active', v_uid, v_uid)
    returning * into v_row;
  else
    select * into v_prev
    from public.report_subscriptions
    where id = p_id
    for update;

    if not found then
      raise exception '订阅不存在' using errcode = 'P0002';
    end if;

    if v_prev.created_by is distinct from v_uid
       and v_role is distinct from 'admin' then
      raise exception '无权修改该报表订阅' using errcode = '42501';
    end if;

    if v_prev.is_deleted then
      raise exception '订阅已删除，无法修改' using errcode = 'P0001';
    end if;

    update public.report_subscriptions
       set report_def_id = p_report_def_id,
           cron_expr     = v_cron,
           channels      = v_channels,
           recipients    = coalesce(p_recipients, 'self'),
           updated_by    = v_uid
     where id = p_id
    returning * into v_row;
  end if;

  -- active 才注册/更新 job；disabled 等 enable（历史上已无 job，无需处理）
  if v_row.status = 'active' then
    perform app.report_subscription_register_cron(v_row.id, v_row.cron_expr);
  end if;

  perform app.audit_log(
    'report', 'upsert', 'report_subscription', v_row.id::text,
    jsonb_build_object(
      'report_def_id', v_row.report_def_id,
      'cron_expr', v_row.cron_expr,
      'channels', v_row.channels,
      'recipients', v_row.recipients,
      'created', p_id is null
    )
  );

  return v_row;
end;
$$;

comment on function app.upsert_report_subscription(uuid, uuid, text, text, integer, text[], text) is
  '新增/编辑订阅（owner/admin）：频率预设映射 cron（hourly/daily/weekly）→ cron_expr 落表；'
  'channels 限 inbox/email（email 降级经 message 分发）；recipients self/role:<code>；'
  '报表须 public/本人/admin；active 时注册 pg_cron job + 平台登记；写审计';

create function app.delete_report_subscription(p_subscription_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_role public.user_role := (select app.current_role());
  v_prev public.report_subscriptions;
begin
  if v_uid is null then
    raise exception '未登录，无法删除报表订阅' using errcode = '42501';
  end if;

  select * into v_prev
  from public.report_subscriptions
  where id = p_subscription_id
  for update;

  if not found then
    raise exception '订阅不存在' using errcode = 'P0002';
  end if;

  if v_prev.created_by is distinct from v_uid
     and v_role is distinct from 'admin' then
    raise exception '无权删除该报表订阅' using errcode = '42501';
  end if;

  if v_prev.is_deleted then
    return; -- 幂等：已删除直接返回
  end if;

  update public.report_subscriptions
     set is_deleted = true,
         status     = 'disabled',
         updated_by = v_uid
   where id = p_subscription_id;

  perform app.report_subscription_unregister_cron(p_subscription_id);

  perform app.audit_log(
    'report', 'delete', 'report_subscription', p_subscription_id::text,
    jsonb_build_object('report_def_id', v_prev.report_def_id, 'logical', true)
  );
end;
$$;

comment on function app.delete_report_subscription(uuid) is
  '删除订阅（owner/admin）：逻辑删 is_deleted=true + status=disabled + 注销 pg_cron job/登记；'
  '执行历史保留；写审计；已删幂等';

create function app.set_report_subscription_status(
  p_subscription_id uuid,
  p_status          text
)
returns public.report_subscriptions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_role  public.user_role := (select app.current_role());
  v_prev  public.report_subscriptions;
  v_row   public.report_subscriptions;
begin
  if v_uid is null then
    raise exception '未登录，无法修改订阅状态' using errcode = '42501';
  end if;

  if p_status is null or p_status not in ('active', 'disabled') then
    raise exception '订阅状态不合法（active/disabled）：%', coalesce(p_status, '(null)')
      using errcode = '22023';
  end if;

  select * into v_prev
  from public.report_subscriptions
  where id = p_subscription_id
  for update;

  if not found then
    raise exception '订阅不存在' using errcode = 'P0002';
  end if;

  if v_prev.created_by is distinct from v_uid
     and v_role is distinct from 'admin' then
    raise exception '无权修改该报表订阅' using errcode = '42501';
  end if;

  if v_prev.is_deleted then
    raise exception '订阅已删除，无法修改' using errcode = 'P0001';
  end if;

  if v_prev.status = p_status then
    return v_prev; -- 幂等
  end if;

  if p_status = 'active' then
    perform app.report_subscription_register_cron(v_prev.id, v_prev.cron_expr);
  else
    perform app.report_subscription_unregister_cron(v_prev.id);
  end if;

  update public.report_subscriptions
     set status     = p_status,
         updated_by = v_uid
   where id = p_subscription_id
  returning * into v_row;

  perform app.audit_log(
    'report', 'set_status', 'report_subscription', p_subscription_id::text,
    jsonb_build_object('status', p_status)
  );

  return v_row;
end;
$$;

comment on function app.set_report_subscription_status(uuid, text) is
  '启停订阅（owner/admin）：active 注册/更新 pg_cron job；disabled 注销 job；写审计；幂等';

-- ---------------------------------------------------------------------------
-- 8. 列表 / 执行历史查询（owner/admin；DEFINER 显式收口）
-- ---------------------------------------------------------------------------
create function app.get_report_subscriptions()
returns table (
  id                   uuid,
  report_def_id        uuid,
  report_name          text,
  report_visibility    text,
  cron_expr            text,
  channels             text[],
  recipients           text,
  status               text,
  last_run_status      text,
  last_run_at          timestamptz,
  last_run_duration_ms integer,
  next_run_at          timestamptz,
  created_at           timestamptz,
  updated_at           timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_role public.user_role := (select app.current_role());
begin
  if v_uid is null then
    raise exception '未登录，无法查看报表订阅' using errcode = '42501';
  end if;

  return query
  select
    s.id,
    s.report_def_id,
    d.name,
    d.visibility,
    s.cron_expr,
    s.channels,
    s.recipients,
    s.status,
    lr.status,
    lr.created_at,
    lr.duration_ms,
    case
      when s.status = 'active' and not s.is_deleted
        then app.next_cron_run(s.cron_expr, 'Asia/Shanghai', now())
    end,
    s.created_at,
    s.updated_at
  from public.report_subscriptions s
  join public.report_definitions d on d.id = s.report_def_id
  left join lateral (
    select r.status, r.created_at, r.duration_ms
    from public.report_subscription_runs r
    where r.subscription_id = s.id
    order by r.created_at desc, r.id desc
    limit 1
  ) lr on true
  where not s.is_deleted
    and (s.created_by = v_uid or v_role = 'admin')
  order by s.created_at desc, s.id;
end;
$$;

comment on function app.get_report_subscriptions() is
  '订阅列表（owner/admin）：联合报表名/可见性、最近执行、下次执行（app.next_cron_run 粗算）；'
  '逻辑删行不返回；DEFINER 内显式按 created_by/admin 收口';

-- ---------------------------------------------------------------------------
-- 9. 手动触发（owner/admin；INVOKER 链，见文件头第 4 点）
-- ---------------------------------------------------------------------------
create function app.run_report_subscription_now(p_subscription_id uuid)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_sub public.report_subscriptions;
begin
  -- RLS 读取：owner 自己 / admin 全量；不可见即视为不存在
  select * into v_sub
  from public.report_subscriptions
  where id = p_subscription_id;

  if not found then
    raise exception '订阅不存在或无权访问' using errcode = 'P0002';
  end if;

  if v_sub.is_deleted then
    raise exception '订阅已删除，无法执行' using errcode = 'P0001';
  end if;

  return app.execute_report_subscription(p_subscription_id, 'manual');
end;
$$;

comment on function app.run_report_subscription_now(uuid) is
  '手动执行一次（owner/admin，INVOKER 链）：停用订阅也可手动重发；逻辑删拒绝；返回 run id';

-- ---------------------------------------------------------------------------
-- 10. public 薄包装（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.upsert_report_subscription(
  p_id            uuid,
  p_report_def_id uuid,
  p_preset        text,
  p_time          text default '09:00',
  p_weekday       integer default 1,
  p_channels      text[] default array['inbox'],
  p_recipients    text default 'self'
)
returns public.report_subscriptions
language sql
security definer
set search_path = ''
as $$
  select app.upsert_report_subscription(
    p_id, p_report_def_id, p_preset, p_time, p_weekday, p_channels, p_recipients
  )
$$;

comment on function public.upsert_report_subscription(uuid, uuid, text, text, integer, text[], text) is
  'upsert_report_subscription Data API 薄包装（owner/admin 校验在 app 实现内）';

create function public.delete_report_subscription(p_subscription_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  select app.delete_report_subscription(p_subscription_id)
$$;

comment on function public.delete_report_subscription(uuid) is
  'delete_report_subscription Data API 薄包装（owner/admin 校验在 app 实现内）';

create function public.set_report_subscription_status(
  p_subscription_id uuid,
  p_status          text
)
returns public.report_subscriptions
language sql
security definer
set search_path = ''
as $$
  select app.set_report_subscription_status(p_subscription_id, p_status)
$$;

comment on function public.set_report_subscription_status(uuid, text) is
  'set_report_subscription_status Data API 薄包装（owner/admin 校验在 app 实现内）';

create function public.get_report_subscriptions()
returns table (
  id                   uuid,
  report_def_id        uuid,
  report_name          text,
  report_visibility    text,
  cron_expr            text,
  channels             text[],
  recipients           text,
  status               text,
  last_run_status      text,
  last_run_at          timestamptz,
  last_run_duration_ms integer,
  next_run_at          timestamptz,
  created_at           timestamptz,
  updated_at           timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.get_report_subscriptions()
$$;

comment on function public.get_report_subscriptions() is
  'get_report_subscriptions Data API 薄包装（owner/admin 收口在 app 实现内）';

-- 手动触发必须 SECURITY INVOKER：保持调用者 authenticated 身份进入执行链（claims 注入生效）
create function public.run_report_subscription_now(p_subscription_id uuid)
returns bigint
language sql
security invoker
set search_path = ''
as $$
  select app.run_report_subscription_now(p_subscription_id)
$$;

comment on function public.run_report_subscription_now(uuid) is
  'run_report_subscription_now Data API 薄包装（SECURITY INVOKER，保持调用者身份执行 RLS）';

-- ---------------------------------------------------------------------------
-- 11. RLS 与授权
-- ---------------------------------------------------------------------------
alter table public.report_subscriptions enable row level security;
alter table public.report_subscription_runs enable row level security;

-- 订阅：属主 SELECT 自己 + admin 全量；无任何表级写
create policy report_subscriptions_select_own
on public.report_subscriptions
for select
to authenticated
using ((select auth.uid()) = created_by);

create policy report_subscriptions_select_admin
on public.report_subscriptions
for select
to authenticated
using ((select app.current_role()) = 'admin');

-- 执行历史：跟随订阅属主；admin 全量
create policy report_subscription_runs_select_own
on public.report_subscription_runs
for select
to authenticated
using (
  exists (
    select 1
    from public.report_subscriptions s
    where s.id = report_subscription_runs.subscription_id
      and s.created_by = (select auth.uid())
  )
);

create policy report_subscription_runs_select_admin
on public.report_subscription_runs
for select
to authenticated
using (
  exists (
    select 1
    from public.report_subscriptions s
    where s.id = report_subscription_runs.subscription_id
      and (select app.current_role()) = 'admin'
  )
);

revoke all on public.report_subscriptions from public, anon, authenticated, service_role;
grant select on public.report_subscriptions to authenticated;

revoke all on public.report_subscription_runs from public, anon, authenticated, service_role;
grant select on public.report_subscription_runs to authenticated;

revoke all on sequence public.report_subscription_runs_id_seq
  from public, anon, authenticated, service_role;

-- 函数授权：默认全撤；管理/user RPC 经 public 薄包装给 authenticated
revoke all on function app.report_subscription_register_cron(uuid, text)
  from public, anon, authenticated, service_role;
revoke all on function app.report_subscription_unregister_cron(uuid)
  from public, anon, authenticated, service_role;
revoke all on function app.report_subscription_run_begin(uuid)
  from public, anon, authenticated, service_role;
revoke all on function app.report_subscription_run_notify(uuid, bigint, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function app.report_subscription_run_finish(bigint, text, integer, text)
  from public, anon, authenticated, service_role;
revoke all on function app.execute_report_subscription(uuid, text)
  from public, anon, authenticated, service_role;
revoke all on function app.run_report_subscription(uuid)
  from public, anon, authenticated, service_role;
revoke all on function app.run_report_subscription_now(uuid)
  from public, anon, authenticated, service_role;
revoke all on function app.upsert_report_subscription(uuid, uuid, text, text, integer, text[], text)
  from public, anon, authenticated, service_role;
revoke all on function app.delete_report_subscription(uuid)
  from public, anon, authenticated, service_role;
revoke all on function app.set_report_subscription_status(uuid, text)
  from public, anon, authenticated, service_role;
revoke all on function app.get_report_subscriptions()
  from public, anon, authenticated, service_role;

revoke all on function public.upsert_report_subscription(uuid, uuid, text, text, integer, text[], text)
  from public, anon, authenticated, service_role;
revoke all on function public.delete_report_subscription(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.set_report_subscription_status(uuid, text)
  from public, anon, authenticated, service_role;
revoke all on function public.get_report_subscriptions()
  from public, anon, authenticated, service_role;
revoke all on function public.run_report_subscription_now(uuid)
  from public, anon, authenticated, service_role;

grant execute on function public.upsert_report_subscription(uuid, uuid, text, text, integer, text[], text)
  to authenticated;
grant execute on function public.delete_report_subscription(uuid) to authenticated;
grant execute on function public.set_report_subscription_status(uuid, text) to authenticated;
grant execute on function public.get_report_subscriptions() to authenticated;
grant execute on function public.run_report_subscription_now(uuid) to authenticated;

-- 例外：手动触发为 SECURITY INVOKER 链路，执行链上的 app 函数必须对 authenticated 可见
-- （app schema 不在 Data API 暴露面；helper 内均有 owner/admin 显式校验，同 run_report 先例）。
grant execute on function app.run_report_subscription_now(uuid) to authenticated;
grant execute on function app.execute_report_subscription(uuid, text) to authenticated;
grant execute on function app.report_subscription_run_begin(uuid) to authenticated;
grant execute on function app.report_subscription_run_notify(uuid, bigint, jsonb) to authenticated;
grant execute on function app.report_subscription_run_finish(bigint, text, integer, text)
  to authenticated;

-- app.run_report_subscription 不 GRANT API 角色：仅 pg_cron 的 postgres 可达。
