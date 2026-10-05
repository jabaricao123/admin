-- 审批中心 · 抄送人上限（message 批次 2 修复项 2：approval cc 上限）
-- 背景：submit_instance 新增 p_cc_user_ids 后未限制数组长度；单次提交可携带任意多
--   抄送人，add_instance_ccs 会逐人生成 approval.cc 通知（send_notification），
--   形成「一次提交打爆通知面」的放大路径。上限 20 与页面「抄送人选择」容量对齐。
-- 本迁移：create or replace app.submit_instance（签名不变，6 参含 default p_cc_user_ids），
--   在参数校验区追加 cardinality ≤ 20 校验（空 / NULL 数组不受限）；
--   public 薄包装无需变动（校验在 app 实现内）。
-- 依赖：20261005222000（submit_instance 6 参当前版）。

create or replace function app.submit_instance(
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

  -- 抄送人上限：单次提交 ≤ 20（防一次提交放大出超大 cc 通知面；空 / NULL 不受限）
  if p_cc_user_ids is not null and cardinality(p_cc_user_ids) > 20 then
    raise exception '抄送人不能超过 20 人（当前：%）', cardinality(p_cc_user_ids)
      using errcode = '22023';
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
  '落显式 cc（≤ 20 人，防通知面放大）与首节点 cc_rule，写审计+通知（pending 含 initiator 变量）；'
  'p_cc_user_ids 省略兼容旧 5 参调用';
