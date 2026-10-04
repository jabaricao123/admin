-- 审批中心 · cc 抄送数据链路（批次 1：补全 cc 生产端，/approval/cc 页不再永远为空）
-- 契约：docs/modules/approval/cc.md（抄送列表 / 进详情自动已读 / 未读与 message 同源）、
--       docs/modules/approval/engine.md（提交契约）、docs/modules/message/templates.md（事件注册与变量清单）、
--       INDEX 规则 3（send_notification 单通道）、10（内部 RPC 不 GRANT authenticated）。
-- 内容：
--   1. app.add_instance_ccs：cc 落库唯一入口——去重、排除发起人自身、排除已停用（inactive）用户；
--      仅对「本次新插入」的 cc 发送 approval.cc 通知（ref_type=approval_instance，
--      供既有 mark_cc_read 同步 messages.read_at，未读唯一事实源不双计数）；
--   2. submit_instance 签名扩展：新增 p_cc_user_ids uuid[] default null（旧 5 参调用保持兼容），
--      提交时落显式 cc 数组 + 首节点 cc_rule 解析结果；
--   3. 流程节点 cc_rule（{type:'role'|'dept_leader'|'user', value?}）：节点任务生成时
--      （submit 首节点 / act 推进下一节点两处）经 app.resolve_approver 解析（与审批人同一解析函数）
--      后落入 cc；
--   4. 通知变量对齐注册表（审计发现 #4）：pending/urge 补 initiator（发起人姓名）、
--      approved/rejected 补 comment（审批意见）——register_message_event 登记的 available_vars
--      与实际发送一致（本次检查后 approval.* 四事件均已一致，无需改写登记行）；
--   5. 注册 approval.cc 事件（available_vars: initiator/title，幂等 upsert）。
-- 依赖：20261004190000（引擎）、20261004223000（页面 RPC）、20261005020000（事件注册/模板渲染）。

-- ---------------------------------------------------------------------------
-- 1. cc 落库唯一入口 app.add_instance_ccs（内部 RPC；不 GRANT API 角色）
-- ---------------------------------------------------------------------------
create function app.add_instance_ccs(
  p_instance_id uuid,
  p_cc_user_ids uuid[]
)
returns uuid[]
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_initiator uuid;
  v_title     text;
  v_init_name text;
  v_added     uuid[];
  v_cc        uuid;
begin
  if p_instance_id is null then
    raise exception '实例 id 不能为空' using errcode = '22023';
  end if;

  select i.initiator_id, i.title
    into v_initiator, v_title
    from public.approval_instances i
   where i.id = p_instance_id;

  if not found then
    raise exception '审批实例不存在：%', p_instance_id using errcode = 'P0002';
  end if;

  if p_cc_user_ids is null or cardinality(p_cc_user_ids) = 0 then
    return '{}'::uuid[];
  end if;

  -- 去重 + 排除发起人自身 + 排除已停用用户；on conflict 保证同实例同用户仅一行
  with candidates as (
    select distinct t.u
      from unnest(p_cc_user_ids) as t(u)
     where t.u is not null
       and t.u <> v_initiator
  ),
  inserted as (
    insert into public.approval_ccs (instance_id, cc_user_id)
    select p_instance_id, c.u
      from candidates c
      join public.profiles p
        on p.id = c.u and p.status = 'active'
    on conflict (instance_id, cc_user_id) do nothing
    returning cc_user_id
  )
  select coalesce(array_agg(cc_user_id), '{}'::uuid[])
    into v_added
    from inserted;

  if cardinality(v_added) = 0 then
    return '{}'::uuid[];
  end if;

  select p.full_name into v_init_name
    from public.profiles p
   where p.id = v_initiator;

  -- 仅对新增 cc 发送通知：重复 cc（数组重复 / 节点重复解析）不重复打扰
  foreach v_cc in array v_added loop
    perform app.send_notification(
      v_cc,
      'approval.cc',
      jsonb_build_object(
        'title', '抄送：' || v_title,
        'initiator', coalesce(v_init_name, '发起人'),
        'body', coalesce(v_init_name, '发起人') || ' 提交的审批申请已抄送给你',
        'source_module', 'approval',
        'ref_type', 'approval_instance',
        'ref_id', p_instance_id::text
      )
    );
  end loop;

  return v_added;
end;
$$;

comment on function app.add_instance_ccs(uuid, uuid[]) is
  'cc 落库唯一入口：去重、排除发起人自身与停用用户，仅对新插入 cc 发 approval.cc 通知；返回本次新增 cc 用户数组；内部 RPC';

revoke all on function app.add_instance_ccs(uuid, uuid[])
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. submit_instance 签名扩展（app 实现；旧 5 参经 default 兼容）
-- ---------------------------------------------------------------------------
drop function if exists public.submit_instance(text, text, text, text, jsonb);
drop function if exists app.submit_instance(text, text, text, text, jsonb);

create function app.submit_instance(
  p_module        text,
  p_ref_type      text,
  p_ref_id        text,
  p_template_code text,
  p_form_data     jsonb,
  p_cc_user_ids   uuid[] default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_initiator   uuid := (select auth.uid());
  v_template    public.approval_form_templates;
  v_flow        public.approval_flows;
  v_node        jsonb;
  v_assignee    uuid;
  v_instance_id uuid;
  v_title       text;
  v_init_name   text;
  v_module      text := nullif(btrim(coalesce(p_module, '')), '');
  v_ref_type    text := nullif(btrim(coalesce(p_ref_type, '')), '');
  v_ref_id      text := nullif(btrim(coalesce(p_ref_id, '')), '');
begin
  if v_initiator is null then
    raise exception '未登录，无法提交审批' using errcode = '42501';
  end if;
  if v_module is null then
    raise exception '来源模块不能为空' using errcode = '22023';
  end if;
  if p_template_code is null or btrim(p_template_code) = '' then
    raise exception '模板 code 不能为空' using errcode = '22023';
  end if;

  -- 当前 published 最新版本模板
  select * into v_template
  from public.approval_form_templates
  where code = p_template_code
    and status = 'published'
  order by version desc
  limit 1;

  if not found then
    raise exception '审批表单模板不存在或未发布：%', p_template_code using errcode = 'P0002';
  end if;
  if v_template.module <> v_module then
    raise exception '模板 % 不适用于来源模块 %', v_template.code, v_module using errcode = '22023';
  end if;

  perform app.validate_form_data(v_template.schema, p_form_data);

  -- 绑定 flow：该模板当前 published 最新版本
  select * into v_flow
  from public.approval_flows
  where template_id = v_template.id
    and status = 'published'
  order by version desc
  limit 1;

  if not found then
    raise exception '模板 % 未绑定已发布流程', v_template.code using errcode = 'P0002';
  end if;

  v_node := app.flow_node(v_flow.nodes, 1);
  if v_node is null then
    raise exception '流程 % 节点配置非法：缺少 seq=1 节点', v_flow.id using errcode = '22023';
  end if;

  v_assignee := app.resolve_approver(v_node -> 'approver_rule', v_initiator);
  v_title    := coalesce(nullif(btrim(coalesce(p_form_data ->> 'title', '')), ''), v_template.name);

  insert into public.approval_instances (
    title, module, ref_type, ref_id,
    template_version_id, flow_version_id, form_data,
    status, current_seq, initiator_id
  )
  values (
    v_title, v_module, v_ref_type, v_ref_id,
    v_template.id, v_flow.id, coalesce(p_form_data, '{}'::jsonb),
    'running', 1, v_initiator
  )
  returning id into v_instance_id;

  insert into public.approval_tasks (instance_id, seq, assignee_id)
  values (v_instance_id, 1, v_assignee);

  -- cc 链路：显式 cc 数组 + 首节点 cc_rule（与审批人同一 resolve_approver）
  perform app.add_instance_ccs(v_instance_id, p_cc_user_ids);
  if v_node ? 'cc_rule' and v_node -> 'cc_rule' <> 'null'::jsonb then
    perform app.add_instance_ccs(
      v_instance_id,
      array[app.resolve_approver(v_node -> 'cc_rule', v_initiator)]
    );
  end if;

  perform app.audit_log(
    'approval', 'submit', 'instance', v_instance_id::text,
    jsonb_build_object(
      'module', v_module,
      'template_code', v_template.code,
      'template_version', v_template.version,
      'flow_version', v_flow.version,
      'ref_type', v_ref_type,
      'ref_id', v_ref_id,
      'assignee_id', v_assignee
    )
  );

  select p.full_name into v_init_name
  from public.profiles p
  where p.id = v_initiator;

  perform app.send_notification(
    v_assignee,
    'approval.pending',
    jsonb_build_object(
      'title', '待审批：' || v_title,
      'initiator', coalesce(v_init_name, '发起人'),
      'body', coalesce(v_init_name, '发起人') || ' 提交的审批申请待你处理',
      'source_module', 'approval',
      'ref_type', 'approval_instance',
      'ref_id', v_instance_id::text
    )
  );

  -- TODO(integration/004)：emit_event('approval.submitted', ...) 待 integration/004 合入；
  -- 软依赖同 message/001 对 audit_log 的先例：存在则调用，未合入自动跳过。
  if to_regprocedure('app.emit_event(text,jsonb)') is not null then
    perform app.emit_event(
      'approval.submitted',
      jsonb_build_object(
        'instance_id', v_instance_id, 'module', v_module,
        'template_code', v_template.code, 'initiator_id', v_initiator
      )
    );
  elsif to_regprocedure('public.emit_event(text,jsonb)') is not null then
    perform public.emit_event(
      'approval.submitted',
      jsonb_build_object(
        'instance_id', v_instance_id, 'module', v_module,
        'template_code', v_template.code, 'initiator_id', v_initiator
      )
    );
  end if;

  return v_instance_id;
end;
$$;

comment on function app.submit_instance(text, text, text, text, jsonb, uuid[]) is
  '提交审批入口：取 published 最新模板+流程，schema 兜底校验，事务内建实例+首节点任务（resolve_approver），'
  '落显式 cc 与首节点 cc_rule，写审计+通知（pending 含 initiator 变量）；p_cc_user_ids 省略兼容旧 5 参调用';

-- ---------------------------------------------------------------------------
-- 3. public 包装层（Data API 入口）
-- ---------------------------------------------------------------------------
create function public.submit_instance(
  p_module        text,
  p_ref_type      text,
  p_ref_id        text,
  p_template_code text,
  p_form_data     jsonb,
  p_cc_user_ids   uuid[] default null
)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select app.submit_instance(p_module, p_ref_type, p_ref_id, p_template_code, p_form_data, p_cc_user_ids)
$$;

comment on function public.submit_instance(text, text, text, text, jsonb, uuid[]) is
  'submit_instance Data API 薄包装（p_cc_user_ids 可省略）';

revoke all on function app.submit_instance(text, text, text, text, jsonb, uuid[]) from public, anon;
grant execute on function app.submit_instance(text, text, text, text, jsonb, uuid[]) to authenticated;

revoke all on function public.submit_instance(text, text, text, text, jsonb, uuid[]) from public, anon;
grant execute on function public.submit_instance(text, text, text, text, jsonb, uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. act_task：下一节点 cc_rule + 通知 vars 对齐（initiator/comment）
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

  -- TODO(integration/004)：emit_event('approval.approved', ...)
  if to_regprocedure('app.emit_event(text,jsonb)') is not null then
    perform app.emit_event(
      'approval.approved',
      jsonb_build_object('instance_id', v_instance.id, 'task_id', p_task_id, 'status', v_instance.status)
    );
  elsif to_regprocedure('public.emit_event(text,jsonb)') is not null then
    perform public.emit_event(
      'approval.approved',
      jsonb_build_object('instance_id', v_instance.id, 'task_id', p_task_id, 'status', v_instance.status)
    );
  end if;

  return v_instance;
end;
$$;

comment on function app.act_task(uuid, text, text) is
  '审批动作（approve/reject）：校验 assignee+当前节点+状态，原子推进实例（下一节点/终态），'
  '下一节点含 cc_rule 时落 cc + approval.cc 通知；通知 vars 补 initiator/comment；写审计';

-- ---------------------------------------------------------------------------
-- 5. urge_instance：通知 vars 补 initiator（注册表 available_vars 对齐）
-- ---------------------------------------------------------------------------
create or replace function app.urge_instance(p_instance_id uuid)
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
      'initiator', coalesce(v_init_name, '发起人'),
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
  '催办审批：仅发起人、实例 running、距上次催办 >2h；通知当前 pending 任务处理人（approval.urge，含 initiator 变量）+ 写审计';

-- ---------------------------------------------------------------------------
-- 6. 事件注册：approval.cc（幂等 upsert；available_vars 为模板可用变量）
-- ---------------------------------------------------------------------------
select app.register_message_event(
  'approval.cc',
  'approval',
  '审批抄送（通知抄送人）',
  '["initiator","title"]'::jsonb
);
