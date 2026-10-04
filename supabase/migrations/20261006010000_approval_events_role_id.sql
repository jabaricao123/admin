-- 审批中心 · 修复批次 2：事件契约修正 + 流程 role 规则按 roles.id 存储
-- 契约：docs/modules/approval/engine.md（resolve_approver / act_task / withdraw_instance）、
--       docs/modules/approval/flows.md（节点审批人规则三型）、
--       docs/modules/integration（integration_events 事件队列；emit_event 为 app 内部入口）。
-- 组成：
--   1. act_task 事件语义修正：
--      * approval.approved 仅在终审（末节点通过）发射，payload 增 is_final=true / node_seq；
--      * 中间节点通过改发 approval.node_approved（is_final=false / node_seq），不再冒充 approved；
--      * approval.rejected 保持原样（本批不动通知调用点）。
--   2. withdraw_instance 补发 approval.withdrawn（payload: instance_id/title/initiator_id）。
--      以上均为 integration 事件（app.emit_event → integration_events），非消息事件，
--      无需 register_message_event；网络投递由 webhook 投递器消费队列。
--   3. role 规则 value 支持 roles.id（uuid）：resolve_approver 先按 id 匹配、失败回退 code；
--      validate_flow_nodes 同步接受 id 或 code 的 active 角色（存量 code 节点零迁移兼容）。
-- ---------------------------------------------------------------------------
-- 与批次 1（20261005222000_approval_cc_chain.sql：cc 链路 + act_task 下一节点 cc_rule /
-- 通知 vars 补齐）的合并说明：
--   * 本文件时间戳 20261006010000 排在批次 1 之后；act_task 已基于批次 1 的版本重写，
--     完整保留其下一节点 cc_rule 落 cc、pending 补 initiator、approved/rejected 补 comment 逻辑，
--     仅替换进度事件 emit 段（本文件 emit 块为最终事件契约）。
--   * submit_instance 由批次 1 独立维护（6 参含默认 p_cc_user_ids，兼容旧 5 参调用），本文件未触碰。
-- 依赖：20261005222000_approval_cc_chain.sql（批次 1：act_task / add_instance_ccs 基础版本）、
--       20261005130000_approval_designer_rpc.sql（validate_flow_nodes）、
--       20261004201000_integration_webhooks.sql（app.emit_event，软依赖，未合入自动跳过）。

-- ---------------------------------------------------------------------------
-- 1. resolve_approver：role 规则 value 支持 roles.id（uuid），回退 code（存量兼容）
-- ---------------------------------------------------------------------------
create or replace function app.resolve_approver(p_rule jsonb, p_initiator uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_type        text;
  v_value       text;
  v_role_id     uuid;
  v_role_code   text;
  v_role_status text;
  v_user        uuid;
begin
  if p_rule is null or jsonb_typeof(p_rule) <> 'object' then
    raise exception '审批人规则非法：应为 JSON 对象' using errcode = '22023';
  end if;

  v_type  := p_rule ->> 'type';
  v_value := nullif(btrim(coalesce(p_rule ->> 'value', '')), '');

  if v_type = 'role' then
    if v_value is null then
      raise exception '审批人规则非法：role 缺少 value' using errcode = '22023';
    end if;

    -- 新存储 value=roles.id（uuid）；存量节点 value=roles.code：先按 id 精确匹配，再回退 code
    select r.id, r.code, r.status
      into v_role_id, v_role_code, v_role_status
    from public.roles r
    where r.id::text = v_value
       or r.code = v_value
    order by (r.id::text = v_value) desc, r.id
    limit 1;

    if v_role_id is null then
      raise exception '审批人角色不存在：%', v_value using errcode = 'P0002';
    end if;
    if v_role_status <> 'active' then
      raise exception '审批人角色已停用：%', v_value using errcode = '22023';
    end if;

    -- v1 取该角色 created_at 最早的 active 用户（确定性）；v2 多人会签改返回集合
    -- 兼容 role_id 为空的历史 profile（p.role 文本按角色 code 匹配）
    select p.id into v_user
    from public.profiles p
    where p.status = 'active'
      and (p.role_id = v_role_id or (p.role_id is null and p.role::text = v_role_code))
    order by p.created_at, p.id
    limit 1;

    if v_user is null then
      raise exception '角色 % 下无可用审批人', v_role_code using errcode = 'P0002';
    end if;

    return v_user;
  end if;

  if v_type = 'dept_leader' then
    -- org/007 起按 profiles.department_id → departments.leader_id（id 语义，非部门名文本）
    select d.leader_id into v_user
    from public.profiles p
    join public.departments d on d.id = p.department_id
    join public.profiles l on l.id = d.leader_id and l.status = 'active'
    where p.id = p_initiator;

    if v_user is null then
      raise exception '发起人无可用部门负责人，无法解析审批人' using errcode = '22023';
    end if;

    return v_user;
  end if;

  if v_type = 'user' then
    if v_value is null then
      raise exception '审批人规则非法：user 缺少 value' using errcode = '22023';
    end if;

    begin
      v_user := v_value::uuid;
    exception when invalid_text_representation then
      raise exception '审批人规则非法：value 不是有效用户 id：%', v_value using errcode = '22023';
    end;

    if not exists (
      select 1 from public.profiles p where p.id = v_user and p.status = 'active'
    ) then
      raise exception '指定审批人不存在或已停用：%', v_value using errcode = 'P0002';
    end if;

    return v_user;
  end if;

  raise exception '审批人规则 type 非法：%', coalesce(v_type, '<null>') using errcode = '22023';
end;
$$;

comment on function app.resolve_approver(jsonb, uuid) is
  '审批人解析：role=角色任一 active 用户（value 支持 roles.id 或 roles.code，id 优先；v1 取建档最早）× '
  'dept_leader=发起人部门负责人（department_id→leader_id）× user=指定用户';

-- ---------------------------------------------------------------------------
-- 2. validate_flow_nodes 同步：role 值接受 active 角色 id 或 code
-- ---------------------------------------------------------------------------
create or replace function app.validate_flow_nodes(p_nodes jsonb)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_node     jsonb;
  v_expected integer := 0;
  v_rule     jsonb;
  v_type     text;
  v_value    text;
  v_user     uuid;
  v_timeout  jsonb;
begin
  if p_nodes is null or jsonb_typeof(p_nodes) <> 'array' then
    raise exception '流程节点非法：nodes 应为数组' using errcode = '22023';
  end if;
  if jsonb_array_length(p_nodes) = 0 then
    raise exception '流程节点非法：至少需要一个节点' using errcode = '22023';
  end if;

  for v_node in
    select e.value from pg_catalog.jsonb_array_elements(p_nodes) as e
  loop
    if jsonb_typeof(v_node) <> 'object' then
      raise exception '流程节点非法：节点定义应为 JSON 对象' using errcode = '22023';
    end if;

    v_expected := v_expected + 1;
    if (v_node ->> 'seq') is null
       or (v_node ->> 'seq') !~ '^[0-9]+$'
       or (v_node ->> 'seq')::integer <> v_expected then
      raise exception '流程节点非法：seq 必须从 1 连续编号（第 % 个节点期望 seq=%）', v_expected, v_expected
        using errcode = '22023';
    end if;

    v_rule := v_node -> 'approver_rule';
    if v_rule is null or jsonb_typeof(v_rule) <> 'object' then
      raise exception '流程节点非法：seq=% 缺少审批人规则', v_expected using errcode = '22023';
    end if;

    v_type  := v_rule ->> 'type';
    v_value := nullif(btrim(coalesce(v_rule ->> 'value', '')), '');

    if v_type = 'role' then
      if v_value is null then
        raise exception '流程节点非法：seq=% 的 role 规则缺少 value', v_expected using errcode = '22023';
      end if;
      -- value 支持 roles.id（新存储）与 roles.code（存量兼容），均须为 active 角色
      if not exists (
        select 1 from public.roles r
        where r.status = 'active'
          and (r.id::text = v_value or r.code = v_value)
      ) then
        raise exception '审批角色不存在或已停用：%', v_value using errcode = 'P0002';
      end if;
    elsif v_type = 'dept_leader' then
      -- 无需 value：运行时按发起人 department_id → departments.leader_id 解析
      null;
    elsif v_type = 'user' then
      if v_value is null then
        raise exception '流程节点非法：seq=% 的 user 规则缺少 value', v_expected using errcode = '22023';
      end if;
      begin
        v_user := v_value::uuid;
      exception when invalid_text_representation then
        raise exception '流程节点非法：seq=% 的指定审批人 value 不是有效用户 id：%', v_expected, v_value
          using errcode = '22023';
      end;
      if not exists (
        select 1 from public.profiles p where p.id = v_user and p.status = 'active'
      ) then
        raise exception '指定审批人不存在或已停用：%', v_value using errcode = 'P0002';
      end if;
    else
      raise exception '流程节点非法：审批人规则 type 非法：%', coalesce(v_type, '<null>')
        using errcode = '22023';
    end if;

    v_timeout := v_node -> 'timeout_hours';
    if v_timeout is not null and v_timeout <> 'null'::jsonb then
      if jsonb_typeof(v_timeout) <> 'number' then
        raise exception '流程节点非法：seq=% 的超时时长应为数字', v_expected using errcode = '22023';
      end if;
      if (v_timeout #>> '{}')::numeric < 0 then
        raise exception '流程节点非法：seq=% 的超时时长不能为负数', v_expected using errcode = '22023';
      end if;
    end if;
  end loop;
end;
$$;

comment on function app.validate_flow_nodes(jsonb) is
  '流程 nodes 兜底校验：seq 从 1 连续；approver_rule.type ∈ role/dept_leader/user；'
  'role 须为 active 角色（value 支持角色 id 或 code）、user 须为 active 用户；timeout_hours 可选且非负';

-- ---------------------------------------------------------------------------
-- 3. act_task：终审发 approval.approved（is_final/node_seq），中间节点发 approval.node_approved
--    函数体基于批次 1（20261005222000_approval_cc_chain.sql）：保留下一节点 cc_rule、通知 vars
--    （pending initiator / approved/rejected comment），仅替换进度事件 emit 段。
-- ---------------------------------------------------------------------------
create or replace function app.act_task(
  p_task_id uuid,
  p_action  text,
  p_comment text
)
returns public.approval_instances
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid           uuid := (select auth.uid());
  v_task          public.approval_tasks;
  v_instance      public.approval_instances;
  v_nodes         jsonb;
  v_next          jsonb;
  v_next_assignee uuid;
  v_comment       text := nullif(btrim(coalesce(p_comment, '')), '');
  v_init_name     text;
begin
  if v_uid is null then
    raise exception '未登录，无法处理审批' using errcode = '42501';
  end if;
  if p_action is null or p_action not in ('approve', 'reject') then
    raise exception '非法审批动作：%', coalesce(p_action, '<null>') using errcode = '22023';
  end if;
  if p_action = 'reject' and v_comment is null then
    raise exception '驳回必须填写意见' using errcode = '22023';
  end if;

  select * into v_task
  from public.approval_tasks
  where id = p_task_id;

  if not found then
    raise exception '审批任务不存在：%', p_task_id using errcode = 'P0002';
  end if;
  if v_task.assignee_id <> v_uid then
    raise exception '无权处理该审批任务' using errcode = '42501';
  end if;

  -- 锁序统一：先实例后任务（与 withdraw_instance 一致，防交叉死锁）
  select * into v_instance
  from public.approval_instances
  where id = v_task.instance_id
  for update;

  select * into v_task
  from public.approval_tasks
  where id = p_task_id
  for update;

  if v_task.status <> 'pending' then
    raise exception '任务已处理，不可重复操作' using errcode = '22023';
  end if;
  if v_instance.status <> 'running' then
    raise exception '审批实例已结束，不可操作' using errcode = '22023';
  end if;
  if v_task.seq <> v_instance.current_seq then
    raise exception '该任务不是当前审批节点' using errcode = '22023';
  end if;

  if p_action = 'reject' then
    update public.approval_tasks
       set status = 'rejected', acted_at = now(), comment = v_comment
     where id = p_task_id;

    -- 线性流程正常情况下无其他 pending；兜底清场保持「同实例多 pending」不变量
    update public.approval_tasks
       set status = 'skipped'
     where instance_id = v_instance.id
       and status = 'pending';

    update public.approval_instances
       set status = 'rejected'
     where id = v_instance.id
    returning * into v_instance;

    perform app.audit_log(
      'approval', 'reject', 'instance', v_instance.id::text,
      jsonb_build_object('task_id', p_task_id, 'seq', v_task.seq, 'comment', v_comment)
    );

    perform app.send_notification(
      v_instance.initiator_id,
      'approval.rejected',
      jsonb_build_object(
        'title', '审批已驳回：' || v_instance.title,
        'body', '驳回意见：' || v_comment,
        'comment', v_comment,
        'source_module', 'approval',
        'ref_type', 'approval_instance',
        'ref_id', v_instance.id::text
      )
    );

    -- TODO(integration/004)：emit_event('approval.rejected', ...)
    if to_regprocedure('app.emit_event(text,jsonb)') is not null then
      perform app.emit_event(
        'approval.rejected',
        jsonb_build_object('instance_id', v_instance.id, 'task_id', p_task_id, 'comment', v_comment)
      );
    elsif to_regprocedure('public.emit_event(text,jsonb)') is not null then
      perform public.emit_event(
        'approval.rejected',
        jsonb_build_object('instance_id', v_instance.id, 'task_id', p_task_id, 'comment', v_comment)
      );
    end if;

    return v_instance;
  end if;

  -- approve：推进实例后生成下一节点任务
  select f.nodes into v_nodes
  from public.approval_flows f
  where f.id = v_instance.flow_version_id;

  v_next := app.flow_node(v_nodes, v_instance.current_seq + 1);

  update public.approval_tasks
     set status = 'approved', acted_at = now(), comment = v_comment
   where id = p_task_id;

  if v_next is null then
    -- 末节点：实例通过（comment 变量对齐注册表 available_vars）
    update public.approval_instances
       set status = 'approved'
     where id = v_instance.id
    returning * into v_instance;

    perform app.send_notification(
      v_instance.initiator_id,
      'approval.approved',
      jsonb_build_object(
        'title', '审批已通过：' || v_instance.title,
        'body', coalesce('审批意见：' || v_comment, '你的审批申请已通过'),
        'comment', v_comment,
        'source_module', 'approval',
        'ref_type', 'approval_instance',
        'ref_id', v_instance.id::text
      )
    );
  else
    v_next_assignee := app.resolve_approver(v_next -> 'approver_rule', v_instance.initiator_id);

    update public.approval_instances
       set current_seq = v_instance.current_seq + 1
     where id = v_instance.id
    returning * into v_instance;

    insert into public.approval_tasks (instance_id, seq, assignee_id)
    values (v_instance.id, v_instance.current_seq, v_next_assignee);

    -- 节点 cc_rule：任务生成时解析（与审批人同一 resolve_approver），去重后落 cc + 通知
    if v_next ? 'cc_rule' and v_next -> 'cc_rule' <> 'null'::jsonb then
      perform app.add_instance_ccs(
        v_instance.id,
        array[app.resolve_approver(v_next -> 'cc_rule', v_instance.initiator_id)]
      );
    end if;

    select p.full_name into v_init_name
    from public.profiles p
    where p.id = v_instance.initiator_id;

    perform app.send_notification(
      v_next_assignee,
      'approval.pending',
      jsonb_build_object(
        'title', '待审批：' || v_instance.title,
        'initiator', coalesce(v_init_name, '发起人'),
        'body', '上一节点已通过，该申请待你处理',
        'source_module', 'approval',
        'ref_type', 'approval_instance',
        'ref_id', v_instance.id::text
      )
    );
  end if;

  perform app.audit_log(
    'approval', 'approve', 'instance', v_instance.id::text,
    jsonb_build_object(
      'task_id', p_task_id,
      'seq', v_task.seq,
      'comment', v_comment,
      'instance_status', v_instance.status,
      'current_seq', v_instance.current_seq
    )
  );

  -- 事件契约：终审通过发 approval.approved（is_final=true）；中间节点通过发 approval.node_approved。
  -- 均为 integration 事件（emit_event → integration_events 队列），无需 register_message_event。
  if v_next is null then
    if to_regprocedure('app.emit_event(text,jsonb)') is not null then
      perform app.emit_event(
        'approval.approved',
        jsonb_build_object(
          'instance_id', v_instance.id, 'task_id', p_task_id, 'status', v_instance.status,
          'is_final', true, 'node_seq', v_task.seq
        )
      );
    elsif to_regprocedure('public.emit_event(text,jsonb)') is not null then
      perform public.emit_event(
        'approval.approved',
        jsonb_build_object(
          'instance_id', v_instance.id, 'task_id', p_task_id, 'status', v_instance.status,
          'is_final', true, 'node_seq', v_task.seq
        )
      );
    end if;
  else
    if to_regprocedure('app.emit_event(text,jsonb)') is not null then
      perform app.emit_event(
        'approval.node_approved',
        jsonb_build_object(
          'instance_id', v_instance.id, 'task_id', p_task_id,
          'is_final', false, 'node_seq', v_task.seq
        )
      );
    elsif to_regprocedure('public.emit_event(text,jsonb)') is not null then
      perform public.emit_event(
        'approval.node_approved',
        jsonb_build_object(
          'instance_id', v_instance.id, 'task_id', p_task_id,
          'is_final', false, 'node_seq', v_task.seq
        )
      );
    end if;
  end if;

  return v_instance;
end;
$$;

comment on function app.act_task(uuid, text, text) is
  '审批动作（approve/reject）：校验 assignee+当前节点+状态，原子推进实例（下一节点/终态），'
  '下一节点含 cc_rule 时落 cc + approval.cc 通知；通知 vars 补 initiator/comment；写审计；'
  '终审发 approval.approved（is_final/node_seq），中间节点发 approval.node_approved';

-- ---------------------------------------------------------------------------
-- 4. withdraw_instance：补发 approval.withdrawn 事件
-- ---------------------------------------------------------------------------
create or replace function app.withdraw_instance(p_instance_id uuid)
returns public.approval_instances
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_instance public.approval_instances;
  v_task     public.approval_tasks;
begin
  if v_uid is null then
    raise exception '未登录，无法撤回审批' using errcode = '42501';
  end if;

  select * into v_instance
  from public.approval_instances
  where id = p_instance_id
  for update;

  if not found then
    raise exception '审批实例不存在：%', p_instance_id using errcode = 'P0002';
  end if;
  if v_instance.initiator_id <> v_uid then
    raise exception '仅发起人可撤回审批' using errcode = '42501';
  end if;
  if v_instance.status <> 'running' then
    raise exception '审批实例已结束，不可撤回' using errcode = '22023';
  end if;

  select * into v_task
  from public.approval_tasks
  where instance_id = p_instance_id
    and seq = v_instance.current_seq
  for update;

  if not found or v_task.status <> 'pending' then
    raise exception '当前审批任务已处理，不可撤回' using errcode = '22023';
  end if;

  update public.approval_tasks
     set status = 'skipped'
   where instance_id = p_instance_id
     and status = 'pending';

  update public.approval_instances
     set status = 'withdrawn'
   where id = p_instance_id
  returning * into v_instance;

  perform app.audit_log(
    'approval', 'withdraw', 'instance', p_instance_id::text,
    jsonb_build_object('seq', v_instance.current_seq)
  );

  -- integration 事件：撤回（emit_event → integration_events 队列，非消息事件）
  if to_regprocedure('app.emit_event(text,jsonb)') is not null then
    perform app.emit_event(
      'approval.withdrawn',
      jsonb_build_object(
        'instance_id', v_instance.id,
        'title', v_instance.title,
        'initiator_id', v_instance.initiator_id
      )
    );
  elsif to_regprocedure('public.emit_event(text,jsonb)') is not null then
    perform public.emit_event(
      'approval.withdrawn',
      jsonb_build_object(
        'instance_id', v_instance.id,
        'title', v_instance.title,
        'initiator_id', v_instance.initiator_id
      )
    );
  end if;

  return v_instance;
end;
$$;

comment on function app.withdraw_instance(uuid) is
  '撤回审批：仅发起人、实例 running 且当前节点任务 pending；置 withdrawn + pending 任务 skipped + 写审计，'
  '并发 approval.withdrawn 事件（instance_id/title/initiator_id）';
