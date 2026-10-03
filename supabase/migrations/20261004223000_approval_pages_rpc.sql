-- 审批中心 · 页面辅助 RPC（工单 approval/005+006+007 合并交付：我的待办/我发起的/抄送我的）
-- 契约：docs/modules/approval/todo.md（待办/已办/批量通过）、mine.md（撤回/催办节流）、cc.md（未读业务标记）
-- 内容：
--   1. approval_instances.last_urged_at 列（催办节流事实源；不改其他核心结构）；
--   2. urge_instance：发起人催办（属主 + running + 距上次催办 >2h，通知当前 pending 任务处理人）；
--   3. my_instances：initiator=auth.uid() 的实例 + 当前节点任务处理人；
--   4. my_ccs / mark_cc_read：cc_user=auth.uid() 的抄送列表 + 已读业务标记
--      （未读唯一事实源仍是 messages.read_at，此处仅业务标记，避免双计数）；
--   5. instance_detail：详情 Sheet 一键取数（表单 schema + 实例 + 审批轨迹 tasks jsonb）。
-- 约定同 approval_engine：app schema 实现 + public 薄包装（PostgREST 仅暴露 public）；
--   所有 SECURITY DEFINER 函数 set search_path = '' + 全限定名；内部函数不授 API 角色（INDEX 规则 10）。
-- 依赖：20261004190000_approval_engine.sql。

-- ---------------------------------------------------------------------------
-- 1. 催办节流列（唯一结构性变更）
-- ---------------------------------------------------------------------------
alter table public.approval_instances
  add column last_urged_at timestamptz;

comment on column public.approval_instances.last_urged_at is
  '最近一次催办时间（mine 页节流事实源：同一实例 2 小时内仅可催办一次）';

-- ---------------------------------------------------------------------------
-- 2. 催办 urge_instance（GRANT authenticated；属主 + running + 2h 节流）
-- ---------------------------------------------------------------------------
create function app.urge_instance(p_instance_id uuid)
returns public.approval_instances
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := (select auth.uid());
  v_instance  public.approval_instances;
  v_task      public.approval_tasks;
  v_init_name text;
begin
  if v_uid is null then
    raise exception '未登录，无法催办审批' using errcode = '42501';
  end if;

  select * into v_instance
  from public.approval_instances
  where id = p_instance_id
  for update;

  if not found then
    raise exception '审批实例不存在：%', p_instance_id using errcode = 'P0002';
  end if;
  if v_instance.initiator_id <> v_uid then
    raise exception '仅发起人可催办' using errcode = '42501';
  end if;
  if v_instance.status <> 'running' then
    raise exception '审批实例已结束，不可催办' using errcode = '22023';
  end if;

  -- 节流：2 小时内仅一次；last_urged_at 为 NULL 视为从未催办
  if v_instance.last_urged_at is not null
     and now() < v_instance.last_urged_at + interval '2 hours' then
    raise exception '催办过于频繁：同一单据 2 小时内仅可催办一次' using errcode = '22023';
  end if;

  select * into v_task
  from public.approval_tasks
  where instance_id = p_instance_id
    and seq = v_instance.current_seq
    and status = 'pending'
  for update;

  if not found then
    raise exception '当前审批任务已处理，无需催办' using errcode = '22023';
  end if;

  update public.approval_instances
     set last_urged_at = now()
   where id = p_instance_id
  returning * into v_instance;

  perform app.audit_log(
    'approval', 'urge', 'instance', p_instance_id::text,
    jsonb_build_object('seq', v_task.seq, 'assignee_id', v_task.assignee_id)
  );

  select p.full_name into v_init_name
  from public.profiles p
  where p.id = v_uid;

  perform app.send_notification(
    v_task.assignee_id,
    'approval.urge',
    jsonb_build_object(
      'title', '催办提醒：' || v_instance.title,
      'body', coalesce(v_init_name, '发起人') || ' 催促你尽快处理该审批申请',
      'source_module', 'approval',
      'ref_type', 'approval_instance',
      'ref_id', v_instance.id::text
    )
  );

  return v_instance;
end;
$$;

comment on function app.urge_instance(uuid) is
  '催办审批：仅发起人、实例 running、距上次催办 >2h；通知当前 pending 任务处理人（approval.urge）+ 写审计';

-- ---------------------------------------------------------------------------
-- 3. 我发起的 my_instances（GRANT authenticated；initiator=uid + 当前任务处理人）
-- ---------------------------------------------------------------------------
create function app.my_instances(p_limit integer default 20)
returns table (
  instance_id           uuid,
  title                 text,
  module                text,
  ref_type              text,
  ref_id                text,
  form_data             jsonb,
  instance_status       text,
  current_seq           integer,
  current_task_id       uuid,
  current_task_status   text,
  current_assignee_id   uuid,
  current_assignee_name text,
  current_acted_at      timestamptz,
  current_comment       text,
  created_at            timestamptz,
  updated_at            timestamptz,
  last_urged_at         timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    i.id              as instance_id,
    i.title           as title,
    i.module          as module,
    i.ref_type        as ref_type,
    i.ref_id          as ref_id,
    i.form_data       as form_data,
    i.status          as instance_status,
    i.current_seq     as current_seq,
    t.id              as current_task_id,
    t.status          as current_task_status,
    t.assignee_id     as current_assignee_id,
    a.full_name       as current_assignee_name,
    t.acted_at        as current_acted_at,
    t.comment         as current_comment,
    i.created_at      as created_at,
    i.updated_at      as updated_at,
    i.last_urged_at   as last_urged_at
  from public.approval_instances i
  left join public.approval_tasks t
    on t.instance_id = i.id and t.seq = i.current_seq
  left join public.profiles a on a.id = t.assignee_id
  where i.initiator_id = (select auth.uid())
  order by i.created_at desc, i.id
  limit least(greatest(coalesce(p_limit, 20), 1), 200)
$$;

comment on function app.my_instances(integer) is
  '我发起的实例列表（发起时间倒序）：join 当前 seq 任务处理人；limit 夹取 1..200';

-- ---------------------------------------------------------------------------
-- 4. 抄送我的 my_ccs / 已读标记 mark_cc_read（GRANT authenticated）
-- ---------------------------------------------------------------------------
create function app.my_ccs(p_unread boolean default false)
returns table (
  instance_id           uuid,
  title                 text,
  module                text,
  ref_type              text,
  ref_id                text,
  form_data             jsonb,
  instance_status       text,
  current_seq           integer,
  initiator_id          uuid,
  initiator_name        text,
  current_task_id       uuid,
  current_task_status   text,
  current_assignee_id   uuid,
  current_assignee_name text,
  cc_read_at            timestamptz,
  cc_created_at         timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    i.id              as instance_id,
    i.title           as title,
    i.module          as module,
    i.ref_type        as ref_type,
    i.ref_id          as ref_id,
    i.form_data       as form_data,
    i.status          as instance_status,
    i.current_seq     as current_seq,
    i.initiator_id    as initiator_id,
    p.full_name       as initiator_name,
    t.id              as current_task_id,
    t.status          as current_task_status,
    t.assignee_id     as current_assignee_id,
    a.full_name       as current_assignee_name,
    c.read_at         as cc_read_at,
    c.created_at      as cc_created_at
  from public.approval_ccs c
  join public.approval_instances i on i.id = c.instance_id
  left join public.approval_tasks t
    on t.instance_id = i.id and t.seq = i.current_seq
  left join public.profiles p on p.id = i.initiator_id
  left join public.profiles a on a.id = t.assignee_id
  where c.cc_user_id = (select auth.uid())
    and (not coalesce(p_unread, false) or c.read_at is null)
  order by c.created_at desc, i.id
$$;

comment on function app.my_ccs(boolean) is
  '抄送我（cc_user=uid）的实例列表（抄送时间倒序）；p_unread=true 仅未读（业务标记 read_at，未读全局唯一事实源为 messages.read_at）';

create function app.mark_cc_read(p_instance_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_read_at timestamptz;
begin
  if v_uid is null then
    raise exception '未登录，无法标记抄送已读' using errcode = '42501';
  end if;

  update public.approval_ccs
     set read_at = coalesce(read_at, now())
   where instance_id = p_instance_id
     and cc_user_id = v_uid
  returning read_at into v_read_at;

  if not found then
    raise exception '审批抄送不存在或无权操作' using errcode = '42501';
  end if;

  -- 未读唯一事实源是 messages.read_at：同步标记本人在该实例上的通知消息，
  -- 使「抄送未读」与消息中心未读数一致，避免双计数（approval_ccs.read_at 仅业务标记）。
  update public.messages
     set read_at = now()
   where recipient_id = v_uid
     and ref_type = 'approval_instance'
     and ref_id = p_instance_id::text
     and read_at is null;

  return v_read_at;
end;
$$;

comment on function app.mark_cc_read(uuid) is
  '抄送已读业务标记（幂等）：仅 cc_user=uid 的抄送行，并同步本人该实例通知消息 messages.read_at（与消息中心同源）；非属主/不存在报 42501';

-- ---------------------------------------------------------------------------
-- 5. 详情实例详情 instance_detail（GRANT authenticated；参与方可见）
-- ---------------------------------------------------------------------------
create function app.instance_detail(p_instance_id uuid)
returns table (
  instance_id    uuid,
  title          text,
  module         text,
  ref_type       text,
  ref_id         text,
  form_data      jsonb,
  schema         jsonb,
  instance_status text,
  current_seq    integer,
  initiator_id   uuid,
  initiator_name text,
  last_urged_at  timestamptz,
  created_at     timestamptz,
  updated_at     timestamptz,
  tasks          jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  -- 参与方（发起人/任务处理人/抄送人/admin）可见；否则统一 42501 防探测
  if not app.is_instance_participant(p_instance_id) then
    raise exception '审批实例不存在或无权查看' using errcode = '42501';
  end if;

  return query
  select
    i.id,
    i.title,
    i.module,
    i.ref_type,
    i.ref_id,
    i.form_data,
    f.schema,
    i.status,
    i.current_seq,
    i.initiator_id,
    p.full_name,
    i.last_urged_at,
    i.created_at,
    i.updated_at,
    (
      select coalesce(
               jsonb_agg(
                 jsonb_build_object(
                   'task_id',       t.id,
                   'seq',           t.seq,
                   'assignee_id',   t.assignee_id,
                   'assignee_name', tp.full_name,
                   'status',        t.status,
                   'acted_at',      t.acted_at,
                   'comment',       t.comment,
                   'created_at',    t.created_at
                 )
                 order by t.seq
               ),
               '[]'::jsonb
             )
      from public.approval_tasks t
      left join public.profiles tp on tp.id = t.assignee_id
      where t.instance_id = i.id
    ) as tasks
  from public.approval_instances i
  join public.approval_form_templates f on f.id = i.template_version_id
  left join public.profiles p on p.id = i.initiator_id
  where i.id = p_instance_id;
end;
$$;

comment on function app.instance_detail(uuid) is
  '实例详情（详情 Sheet 一次取数）：模板 schema + form_data + 状态 + 审批轨迹 tasks jsonb（按 seq 排序，含处理人姓名）';

-- ---------------------------------------------------------------------------
-- 6. public 包装层（PostgREST Data API 入口）
-- ---------------------------------------------------------------------------
create function public.urge_instance(p_instance_id uuid)
returns public.approval_instances
language sql
security definer
set search_path = ''
as $$
  select app.urge_instance(p_instance_id)
$$;

create function public.my_instances(p_limit integer default 20)
returns table (
  instance_id           uuid,
  title                 text,
  module                text,
  ref_type              text,
  ref_id                text,
  form_data             jsonb,
  instance_status       text,
  current_seq           integer,
  current_task_id       uuid,
  current_task_status   text,
  current_assignee_id   uuid,
  current_assignee_name text,
  current_acted_at      timestamptz,
  current_comment       text,
  created_at            timestamptz,
  updated_at            timestamptz,
  last_urged_at         timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.my_instances(p_limit)
$$;

create function public.my_ccs(p_unread boolean default false)
returns table (
  instance_id           uuid,
  title                 text,
  module                text,
  ref_type              text,
  ref_id                text,
  form_data             jsonb,
  instance_status       text,
  current_seq           integer,
  initiator_id          uuid,
  initiator_name        text,
  current_task_id       uuid,
  current_task_status   text,
  current_assignee_id   uuid,
  current_assignee_name text,
  cc_read_at            timestamptz,
  cc_created_at         timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.my_ccs(p_unread)
$$;

create function public.mark_cc_read(p_instance_id uuid)
returns timestamptz
language sql
security definer
set search_path = ''
as $$
  select app.mark_cc_read(p_instance_id)
$$;

create function public.instance_detail(p_instance_id uuid)
returns table (
  instance_id     uuid,
  title           text,
  module          text,
  ref_type        text,
  ref_id          text,
  form_data       jsonb,
  schema          jsonb,
  instance_status text,
  current_seq     integer,
  initiator_id    uuid,
  initiator_name  text,
  last_urged_at   timestamptz,
  created_at      timestamptz,
  updated_at      timestamptz,
  tasks           jsonb
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.instance_detail(p_instance_id)
$$;

comment on function public.urge_instance(uuid) is 'urge_instance Data API 薄包装';
comment on function public.my_instances(integer) is 'my_instances Data API 薄包装';
comment on function public.my_ccs(boolean) is 'my_ccs Data API 薄包装';
comment on function public.mark_cc_read(uuid) is 'mark_cc_read Data API 薄包装';
comment on function public.instance_detail(uuid) is 'instance_detail Data API 薄包装';

-- ---------------------------------------------------------------------------
-- 7. 权限：业务 RPC app+public 授 authenticated，内部一律不授（INDEX 规则 10）
-- ---------------------------------------------------------------------------
revoke all on function app.urge_instance(uuid) from public, anon;
grant execute on function app.urge_instance(uuid) to authenticated;

revoke all on function app.my_instances(integer) from public, anon;
grant execute on function app.my_instances(integer) to authenticated;

revoke all on function app.my_ccs(boolean) from public, anon;
grant execute on function app.my_ccs(boolean) to authenticated;

revoke all on function app.mark_cc_read(uuid) from public, anon;
grant execute on function app.mark_cc_read(uuid) to authenticated;

revoke all on function app.instance_detail(uuid) from public, anon;
grant execute on function app.instance_detail(uuid) to authenticated;

revoke all on function public.urge_instance(uuid) from public, anon;
grant execute on function public.urge_instance(uuid) to authenticated;

revoke all on function public.my_instances(integer) from public, anon;
grant execute on function public.my_instances(integer) to authenticated;

revoke all on function public.my_ccs(boolean) from public, anon;
grant execute on function public.my_ccs(boolean) to authenticated;

revoke all on function public.mark_cc_read(uuid) from public, anon;
grant execute on function public.mark_cc_read(uuid) to authenticated;

revoke all on function public.instance_detail(uuid) from public, anon;
grant execute on function public.instance_detail(uuid) to authenticated;
