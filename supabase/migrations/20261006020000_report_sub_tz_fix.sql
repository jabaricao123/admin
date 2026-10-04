-- 报表中心 · 订阅时区换算修复（report 批次 2 / 修复项 1）
-- 问题：upsert_report_subscription 把页面本地时间（Asia/Shanghai）原样映射为 cron 表达式，
--   而 pg_cron 内部统一按 UTC 解析执行 → 每天 09:00 CST 实际在 09:00 UTC（17:00 CST）
--   执行；get_report_subscriptions 又按 Asia/Shanghai 解释同一表达式，展示与实际再次偏离。
-- 修复：
--   1. app.upsert_report_subscription：生成 cron 前把本地 HH:mm 换算为 UTC
--      （Asia/Shanghai 固定 UTC+8：小时减 8 回绕；跨日时 weekly 星期字段回退一天）；
--      cron_expr 落表统一为 UTC 语义 = pg_cron 实际执行时区。
--   2. app.get_report_subscriptions：next_run_at 按 UTC 解释 cron_expr（返回 timestamptz，
--      客户端按本地时区展示）。
-- 依赖：20261005091000（report_subscriptions / upsert / get_report_subscriptions）。
--
-- 迁移方式：create or replace 全量替换（主体复制自 20261005091000，仅差异处按上述修改）。

create or replace function app.upsert_report_subscription(
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
  v_uid         uuid := (select auth.uid());
  v_role        public.user_role := (select app.current_role());
  v_preset      text := lower(btrim(coalesce(p_preset, '')));
  v_time        text := btrim(coalesce(p_time, ''));
  v_weekday     integer := coalesce(p_weekday, 1);
  v_channels    text[];
  v_channel     text;
  v_hour        integer;
  v_minute      integer;
  v_cron        text;
  v_utc_hour    integer;
  v_utc_weekday integer;
  v_def         public.report_definitions;
  v_prev        public.report_subscriptions;
  v_row         public.report_subscriptions;
begin
  if v_uid is null then
    raise exception '未登录，无法保存报表订阅' using errcode = '42501';
  end if;

  -- 频率预设 → cron 表达式（页面只给预设；本地时间换算为 UTC 后存表）
  if v_preset not in ('hourly', 'daily', 'weekly', 'monthly') then
    raise exception '频率预设不合法（hourly/daily/weekly/monthly）：%', coalesce(p_preset, '(null)')
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

  -- 本地时间（Asia/Shanghai，固定 UTC+8）→ UTC：pg_cron 内部统一按 UTC 解析执行；
  -- 小时减 8 回绕；跨日时 weekly 的星期字段回退一天（如周一 01:00 CST = 周日 17:00 UTC）。
  if v_preset <> 'hourly' then
    v_utc_hour := (v_hour + 16) % 24;
    v_utc_weekday := case
                       when v_hour < 8 then (v_weekday + 6) % 7
                       else v_weekday
                     end;
  end if;

  if v_preset = 'weekly' then
    if v_weekday < 0 or v_weekday > 6 then
      raise exception '星期取值需在 0..6（0=周日）：%', v_weekday using errcode = '22023';
    end if;
    v_cron := format('%s %s * * %s', v_minute, v_utc_hour, v_utc_weekday);
  elsif v_preset = 'daily' then
    v_cron := format('%s %s * * *', v_minute, v_utc_hour);
  elsif v_preset = 'monthly' then
    -- 每月 1 日 HH:mm（本地）→ UTC：HH<8 时日为上月末日，cron 不支持「末日」，
    -- 采用统一保守策略：HH>=8 为当月 1 日 UTC，HH<8 固定为当月最后一日 UTC 的近似（28 日，保证每月必触发且不跨月重复）
    v_cron := case
                when v_hour < 8 then format('%s %s 28 * *', v_minute, v_utc_hour)
                else format('%s %s 1 * *', v_minute, v_utc_hour)
              end;
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


create or replace function app.get_report_subscriptions()
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
        then app.next_cron_run(s.cron_expr, 'UTC', now())
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


comment on function app.upsert_report_subscription(uuid, uuid, text, text, integer, text[], text) is
  '新增/编辑订阅（owner/admin）：频率预设按 Asia/Shanghai（UTC+8）换算为 pg_cron 的 UTC '
  'cron_expr 落表（hourly/daily/weekly；跨日时 weekly 星期回退一天）；'
  'channels 限 inbox/email（email 降级经 message 分发）；recipients self/role:<code>；'
  '报表须 public/本人/admin；active 时注册 pg_cron job + 平台登记；写审计';

comment on function app.get_report_subscriptions() is
  '订阅列表（owner/admin）：联合报表名/可见性、最近执行、下次执行（app.next_cron_run 按 '
  'UTC 解释 cron_expr，返回 timestamptz 供客户端本地展示）；'
  '逻辑删行不返回；DEFINER 内显式按 created_by/admin 收口';

comment on column public.report_subscriptions.cron_expr is
  '五段 cron 表达式（UTC 语义，pg_cron 实际执行时区）：由频率预设按 Asia/Shanghai 换算后落表；'
  '每小时 0 * * * *、每天 m H * * *、每周 m H * * w（均为 UTC）';
