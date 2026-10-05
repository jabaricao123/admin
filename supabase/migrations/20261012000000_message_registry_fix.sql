-- 消息中心 · 批次 1 修复（事件注册表修正 + 合并语义 + 模板并发/校验增强）
-- 1. 注册表与真实发送键对齐：
--    * 新增 sync.execute_failed（同步执行失败通知属主；发送方 20261008070000）；
--    * 幽灵事件 sync.run_finished 删除（emit_event 不经 send_notification），有模板引用则保留；
--    * webhook.delivery_failed 注册表保持丰富 vars（endpoint/event/attempt/error），
--      发送方 app.finalize_webhook_deliveries 补传对齐（见 4）。
-- 2. register_message_event 改合并语义：available_vars = 已登记 ∪ 新登记（并集去重，不覆盖）；
--    新增 unregister_message_event_vars：已发布模板仍引用占位符时拒绝并列出引用模板。
--    数据修复：report.export_ready 的 download_url 曾被 20261006021000 覆盖式登记删除，合并补回。
-- 3. 模板并发与校验（批次 4 并入）：
--    * upsert_message_template 版本计算加 (event_key, channel) 级 advisory xact 锁（参照 upsert_setting 先例）；
--    * publish_message_template 指针竞态 catch unique_violation 转可重试友好提示；
--    * available_vars 元素字符串校验（函数可读报错 + 表 check 兜底）；
--    * upsert 模板占位符与 available_vars 差集 raise warning（不阻断保存）。
-- 依赖：20261005020000（registry/templates/register/upsert/publish 当前版）、
--       20261008040000（finalize_webhook_deliveries 当前版）、20261008070000（sync.execute_failed 发送）、
--       20261006021000（report.export_ready 覆盖来源）。

-- ---------------------------------------------------------------------------
-- 0. available_vars 元素字符串校验（表 check 兜底；函数内给可读错误）
-- ---------------------------------------------------------------------------
alter table public.message_event_registry
  add constraint message_event_registry_vars_strings_check
  check (not jsonb_path_exists(available_vars, '$[*] ? (@.type() != "string")'));

comment on constraint message_event_registry_vars_strings_check on public.message_event_registry is
  'available_vars 必须是纯字符串数组（元素类型校验；函数入口另有可读报错）';

-- ---------------------------------------------------------------------------
-- 1. app.register_message_event：available_vars 改并集合并（不覆盖）
-- ---------------------------------------------------------------------------
create or replace function app.register_message_event(
  p_event_key   text,
  p_module      text,
  p_description text,
  p_vars        jsonb
)
returns public.message_event_registry
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_vars jsonb := coalesce(p_vars, '[]'::jsonb);
  v_row  public.message_event_registry;
begin
  if p_event_key is null or btrim(p_event_key) = '' then
    raise exception 'event_key 不能为空' using errcode = '22023';
  end if;
  if p_module is null or btrim(p_module) = '' then
    raise exception 'module 不能为空' using errcode = '22023';
  end if;
  if jsonb_typeof(v_vars) <> 'array' then
    raise exception 'available_vars 必须是 JSON 字符串数组' using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_vars) e
    where jsonb_typeof(e) <> 'string'
  ) then
    raise exception 'available_vars 元素必须是字符串' using errcode = '22023';
  end if;

  insert into public.message_event_registry
    (event_key, module, description, available_vars, registered_by)
  values
    (btrim(p_event_key), btrim(p_module), p_description, v_vars, (select auth.uid()))
  on conflict (event_key) do update
    set module         = excluded.module,
        description    = excluded.description,
        -- 合并语义：已登记变量在前 + 新登记变量追加，并集去重（防止再登记覆盖丢失变量）
        available_vars = (
          select coalesce(jsonb_agg(elem order by ord), '[]'::jsonb)
          from (
            select u.elem, min(u.ord) as ord
            from (
              select x.value as elem, x.ord
              from jsonb_array_elements_text(public.message_event_registry.available_vars)
                   with ordinality as x(value, ord)
              union all
              select y.value, 1000000 + y.ord
              from jsonb_array_elements_text(excluded.available_vars)
                   with ordinality as y(value, ord)
            ) u
            group by u.elem
          ) g
        ),
        -- 保留首个登记人；seed 行为 NULL 时由首次调用者补位
        registered_by  = coalesce(public.message_event_registry.registered_by, excluded.registered_by)
  returning * into v_row;

  return v_row;
end;
$$;

comment on function app.register_message_event(text, text, text, jsonb) is
  '登记/更新通知事件（幂等 upsert）；available_vars 并集合并不覆盖；元素必须为字符串；'
  '模块交付时调用；不 GRANT authenticated（INDEX 规则 10）';

-- ---------------------------------------------------------------------------
-- 2. app.unregister_message_event_vars：注销事件变量（已发布模板引用则拒绝）
-- ---------------------------------------------------------------------------
create function app.unregister_message_event_vars(
  p_event_key text,
  p_vars      jsonb
)
returns public.message_event_registry
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key  text := btrim(coalesce(p_event_key, ''));
  v_vars text[];
  v_reg  public.message_event_registry;
  v_refs text;
begin
  if v_key = '' then
    raise exception 'event_key 不能为空' using errcode = '22023';
  end if;
  if p_vars is null or jsonb_typeof(p_vars) <> 'array' then
    raise exception '待注销变量必须是 JSON 字符串数组' using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_vars) e
    where jsonb_typeof(e) <> 'string'
  ) then
    raise exception '待注销变量元素必须是字符串' using errcode = '22023';
  end if;

  select * into v_reg
  from public.message_event_registry r
  where r.event_key = v_key
  for update;

  if not found then
    raise exception '事件未注册：%', v_key using errcode = 'P0002';
  end if;

  select coalesce(array_agg(t.value), '{}'::text[])
    into v_vars
    from jsonb_array_elements_text(p_vars) as t(value);

  -- 已发布模板引用校验：任一被注销变量仍被 published 模板 {{var}} 引用即拒绝（列出引用模板）
  select string_agg(
           format('%s / %s v%s', t.event_key, t.channel, t.version),
           '、' order by t.channel, t.version
         )
    into v_refs
  from public.message_templates t
  where t.event_key = v_reg.event_key
    and t.status = 'published'
    and exists (
      select 1
      from unnest(v_vars) as u(var)
      where position('{{' || u.var || '}}' in t.subject_tpl) > 0
         or position('{{' || u.var || '}}' in t.body_tpl) > 0
    );

  if v_refs is not null then
    raise exception '变量 % 仍被已发布模板引用，不可注销：%',
      array_to_string(v_vars, ', '), v_refs
      using errcode = '22023';
  end if;

  update public.message_event_registry
     set available_vars = (
       select coalesce(jsonb_agg(x.value order by x.ord), '[]'::jsonb)
       from jsonb_array_elements_text(v_reg.available_vars)
            with ordinality as x(value, ord)
       where x.value <> all (v_vars)
     )
   where event_key = v_reg.event_key
  returning * into v_reg;

  return v_reg;
end;
$$;

comment on function app.unregister_message_event_vars(text, jsonb) is
  '注销事件注册表的 available_vars（仅 admin 内部 RPC，不 GRANT API 角色）：'
  '删除前校验无已发布模板引用这些占位符，有则拒绝并列出引用模板；返回更新后的注册行';

revoke all on function app.unregister_message_event_vars(text, jsonb)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. 注册表数据修复：幽灵事件清理 + sync.execute_failed 登记 + export_ready 补回
-- ---------------------------------------------------------------------------
-- 3.1 幽灵事件 sync.run_finished：emit_event（Webhook 事件）不经 send_notification，不是通知事件；
--     仅当无任何模板引用时删除，有引用则保留并留 notice（避免破坏存量模板外键）。
do $$
declare
  v_refs bigint;
begin
  select count(*) into v_refs
  from public.message_templates t
  where t.event_key = 'sync.run_finished';

  if v_refs = 0 then
    delete from public.message_event_registry where event_key = 'sync.run_finished';
  else
    raise notice 'sync.run_finished 仍被 % 个模板引用，保留注册行（幽灵事件待模板下线后再清理）', v_refs;
  end if;
end $$;

-- 3.2 同步执行失败通知：对齐 app.execute_sync_task 失败通知发送（sync 模块）
select app.register_message_event(
  'sync.execute_failed',
  'sync',
  '同步执行失败通知',
  '["task_name","error","run_id"]'::jsonb
);

-- 3.3 数据修复：report.export_ready 的 download_url 被 20261006021000 覆盖式登记删除，
--     合并语义下补回（新登记仅含 download_url，与既有 vars 并集，不丢 title/body/report_name/row_count/summary）
select app.register_message_event(
  'report.export_ready',
  'report',
  '报表订阅结果就绪（摘要投递）',
  '["download_url"]'::jsonb
);

-- ---------------------------------------------------------------------------
-- 4. app.finalize_webhook_deliveries：终态失败通知 vars 补传（endpoint/event/attempt/error）
-- ---------------------------------------------------------------------------
create or replace function app.finalize_webhook_deliveries()
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  c_stale    constant interval := interval '10 minutes';
  v_delivery record;
  v_event    record;
  v_hook     record;
  v_attempt  integer;
  v_done     integer;
  v_retryable integer;
  v_exhausted integer;
  v_interval interval;
  v_count    integer := 0;
  -- 调用日志收口变量（每次投递终态后写一行）
  v_logged      boolean;
  v_log_status  integer;
  v_log_duration integer;
  v_log_error   text;
begin
  -- 1) 投递明细收口：pg_net 响应 → done/failed；长期无响应 → 超时失败
  for v_delivery in
    select d.id, d.event_id, d.webhook_id, d.attempt_no, d.attempted_at,
           e.event,
           e.payload,
           r.status_code, r.error_msg, r.timed_out, r.created, r.content
    from public.webhook_deliveries d
    join public.integration_events e on e.id = d.event_id
    left join net._http_response r on r.id = d.request_id
    where d.status = 'delivering'
    order by d.id
    for update of d skip locked
  loop
    v_logged := false;
    v_log_status := null;
    v_log_duration := null;
    v_log_error := null;

    if v_delivery.created is not null then
      if v_delivery.status_code between 200 and 299 then
        update public.webhook_deliveries
           set status      = 'done',
               http_status = v_delivery.status_code,
               duration_ms = greatest(
                 0,
                 floor(extract(epoch from (v_delivery.created - v_delivery.attempted_at)) * 1000)::integer
               ),
               error       = null,
               finished_at = v_delivery.created
         where id = v_delivery.id;

        v_log_status := v_delivery.status_code;
        v_log_duration := greatest(
          0,
          floor(extract(epoch from (v_delivery.created - v_delivery.attempted_at)) * 1000)::integer
        );
        v_logged := true;
      else
        update public.webhook_deliveries
           set status      = 'failed',
               http_status = v_delivery.status_code,
               duration_ms = greatest(
                 0,
                 floor(extract(epoch from (v_delivery.created - v_delivery.attempted_at)) * 1000)::integer
               ),
               error       = coalesce(
                 v_delivery.error_msg,
                 case
                   when v_delivery.timed_out then '请求超时（pg_net）'
                   when v_delivery.status_code is not null then 'HTTP ' || v_delivery.status_code
                   else '投递失败（pg_net 无错误详情）'
                 end
               ),
               finished_at = v_delivery.created
         where id = v_delivery.id;

        v_log_status := v_delivery.status_code;
        v_log_duration := greatest(
          0,
          floor(extract(epoch from (v_delivery.created - v_delivery.attempted_at)) * 1000)::integer
        );
        v_log_error := coalesce(
          v_delivery.error_msg,
          case
            when v_delivery.timed_out then '请求超时（pg_net）'
            when v_delivery.status_code is not null then 'HTTP ' || v_delivery.status_code
            else '投递失败（pg_net 无错误详情）'
          end
        );
        v_logged := true;
      end if;
    elsif v_delivery.attempted_at <= now() - c_stale then
      update public.webhook_deliveries
         set status      = 'failed',
             error       = '投递超时（pg_net 10 分钟内无响应）',
             finished_at = now()
       where id = v_delivery.id;

      v_log_error := '投递超时（pg_net 10 分钟内无响应）';
      v_logged := true;
    end if;

    -- 终态投递追加技术调用日志（kind='webhook'；排障明细，不影响状态机）
    if v_logged then
      perform app.log_integration_call(
        'webhook',
        null,
        v_delivery.webhook_id,
        v_delivery.event,
        v_log_status,
        v_log_duration,
        jsonb_build_object(
          'event', v_delivery.event,
          'data', v_delivery.payload
        )::text,
        v_delivery.content,
        v_log_error
      );
    end if;
  end loop;

  -- 2) 事件状态机（投递级）：最新一轮无进行中投递的事件按端点汇总判定；
  --    逐事件包 exception：单条毒事件（如异常重试配置/毒数据）只把自己置 failed，
  --    不回滚整个收口事务，保证其他事件继续收口（防全管线停滞）。
  for v_event in
    select e.id, e.event, e.attempts
    from public.integration_events e
    where e.status = 'delivering'
      and not exists (
        select 1
        from public.webhook_deliveries d
        where d.event_id = e.id
          and d.status = 'delivering'
      )
    order by e.id
    for update skip locked
  loop
    begin
      -- 新派发轮次号；毒数据（attempt_no=integer 上限）在此溢出 → exception 隔离
      select max(d.attempt_no) into v_attempt
      from public.webhook_deliveries d
      where d.event_id = v_event.id;

      v_done := v_attempt + 1;

      -- 端点级汇总：has_done=已有成功终态（永不重投）；failed_count=失败次数；
      -- max_attempts 内联安全解析（regex 预检 + 1..10 兜底 3，与批次 1 语义一致）；
      -- backoff 取端点自身策略；停用端点不再重试。
      select
        count(*) filter (where not x.has_done and x.failed_count >= x.max_attempts)::integer,
        count(*) filter (where not x.has_done and x.failed_count < x.max_attempts
                           and x.is_active)::integer,
        min(case when not x.has_done and x.failed_count < x.max_attempts and x.is_active
                 then app.next_retry(x.failed_count::integer, x.backoff) end)
      into v_exhausted, v_retryable, v_interval
      from (
        select
          d.webhook_id,
          bool_or(d.status = 'done') as has_done,
          count(*) filter (where d.status = 'failed') as failed_count,
          case
            when coalesce(w.retry_policy ->> 'max_attempts', '') ~ '^\d+$'
            then case
                   when (w.retry_policy ->> 'max_attempts')::numeric between 1 and 10
                   then (w.retry_policy ->> 'max_attempts')::integer
                   else 3
                 end
            else 3
          end as max_attempts,
          coalesce(w.retry_policy ->> 'backoff', 'exponential') as backoff,
          coalesce(w.status = 'active', false) as is_active
        from public.webhook_deliveries d
        left join public.webhooks w on w.id = d.webhook_id
        where d.event_id = v_event.id
        group by d.webhook_id, w.retry_policy, w.status
      ) x;

      if v_retryable > 0 then
        -- 仍有未 done 且未耗尽的端点：事件退回 pending，按可重试端点最小退避重派
        update public.integration_events
           set status        = 'pending',
               attempts      = v_done,
               next_retry_at = now() + coalesce(v_interval, interval '1 minute')
         where id = v_event.id;
      elsif v_exhausted > 0 then
        -- 所有未 done 端点均已耗尽：事件终态 failed（audit + 仅通知耗尽端点创建人）
        update public.integration_events
           set status   = 'failed',
               attempts = v_done
         where id = v_event.id;

        perform app.audit_log(
          'integration', 'fail', 'webhook_event', v_event.id::text,
          jsonb_build_object(
            'event', v_event.event,
            'attempts', v_done,
            'endpoints_failed', v_exhausted
          )
        );

        for v_hook in
          with ep as (
            select
              d.webhook_id,
              bool_or(d.status = 'done') as has_done,
              count(*) filter (where d.status = 'failed') as failed_count,
              min(d.error) filter (where d.status = 'failed') as last_error
            from public.webhook_deliveries d
            where d.event_id = v_event.id
            group by d.webhook_id
          )
          select w.id, w.name, w.created_by, ep.failed_count, ep.last_error
          from ep
          join public.webhooks w on w.id = ep.webhook_id
          where not ep.has_done
            and ep.failed_count >= case
              when coalesce(w.retry_policy ->> 'max_attempts', '') ~ '^\d+$'
              then case
                     when (w.retry_policy ->> 'max_attempts')::numeric between 1 and 10
                     then (w.retry_policy ->> 'max_attempts')::integer
                     else 3
                   end
              else 3
            end
          order by w.id
        loop
          if v_hook.created_by is not null
             and exists (select 1 from public.profiles p where p.id = v_hook.created_by) then
            -- 批次 1 修复：vars 补齐注册表 available_vars（endpoint/event/attempt/error），
            -- 与 message_event_registry 的丰富变量清单对齐（此前仅 title/body）。
            perform app.send_notification(
              v_hook.created_by,
              'webhook.delivery_failed',
              jsonb_build_object(
                'title', 'Webhook 投递失败',
                'body', format(
                  '端点「%s」投递事件 %s 失败 %s 次：%s',
                  v_hook.name, v_event.event, v_hook.failed_count,
                  coalesce(v_hook.last_error, '未知错误')
                ),
                'endpoint', v_hook.name,
                'event', v_event.event,
                'attempt', v_hook.failed_count,
                'error', coalesce(v_hook.last_error, '未知错误'),
                'ref_type', 'webhook',
                'ref_id', v_hook.id::text,
                'source_module', 'integration'
              )
            );
          end if;
        end loop;
      else
        -- 全部端点 done（或仅剩已停用端点，不再投递）：事件终结
        update public.integration_events
           set status = 'done'
         where id = v_event.id;
      end if;

      v_count := v_count + 1;
    exception when others then
      -- 单事件故障隔离：标记该事件 failed 后继续处理后续事件（不回滚整个事务）
      begin
        update public.integration_events
           set status = 'failed'
         where id = v_event.id;
      exception when others then
        null; -- 连失败标记都失败时静默跳过，避免全管线停滞
      end;

      v_count := v_count + 1;
    end;
  end loop;

  return v_count;
end;
$$;

comment on function app.finalize_webhook_deliveries() is
  '投递收口：按 net._http_response 将 delivering 明细置 done（2xx）/failed（非 2xx/错误/超时>10min）；'
  '事件状态机为投递级重试：端点已有 done 终态即不再重投——仍有未 done 且未耗尽端点则 pending 退避，'
  '未 done 端点全部耗尽则 failed（audit + 仅通知耗尽端点创建人，vars 含 endpoint/event/attempt/error），其余 done；'
  '返回收口事件数。'
  '每条终态投递追加 integration_call_logs（kind=webhook，含响应摘要/耗时/错误）。'
  'max_attempts 安全解析（脏值兜底 3，不抛错）；逐事件 exception 隔离（毒事件置 failed 继续）。'
  'security invoker + 仅函数属主/pg_cron 可达（撤销 API 角色执行权），禁 service_role（ADR-001）';

-- ---------------------------------------------------------------------------
-- 5. app.upsert_message_template：版本计算 advisory 锁 + 占位符差集 warning
-- ---------------------------------------------------------------------------
create or replace function app.upsert_message_template(
  p_event_key   text,
  p_channel     text,
  p_subject_tpl text,
  p_body_tpl    text,
  p_id          uuid default null
)
returns public.message_templates
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid          uuid := (select auth.uid());
  v_row          public.message_templates;
  v_version      integer;
  v_reg_vars     jsonb;
  v_placeholders text[];
  v_registered   text[];
  v_unknown      text[];
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_event_key is null or p_channel is null then
    raise exception '事件与渠道不能为空' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.message_event_registry r where r.event_key = p_event_key
  ) then
    raise exception '事件未注册，不可创建模板：%', p_event_key using errcode = '22023';
  end if;

  if p_channel not in ('inbox', 'email', 'push') then
    raise exception '渠道不合法：%', p_channel using errcode = '22023';
  end if;

  if p_subject_tpl is null or p_body_tpl is null then
    raise exception '标题模板与正文模板不能为空' using errcode = '22023';
  end if;

  -- 占位符与注册表 available_vars 差集提示（best-effort warning，不阻断保存）：
  -- 未登记变量多为模块侧漏登（register_message_event 并集补登）或模板笔误（渲染保留占位符原文）。
  select r.available_vars into v_reg_vars
  from public.message_event_registry r
  where r.event_key = p_event_key;

  select coalesce(array_agg(distinct m[1]), '{}'::text[])
    into v_placeholders
    from regexp_matches(
           coalesce(p_subject_tpl, '') || E'\n' || coalesce(p_body_tpl, ''),
           '\{\{([^{}]+)\}\}',
           'g'
         ) as m;

  select coalesce(array_agg(value), '{}'::text[])
    into v_registered
    from jsonb_array_elements_text(v_reg_vars) as t(value);

  select array_agg(ph.value)
    into v_unknown
    from unnest(v_placeholders) as ph(value)
   where ph.value <> all (v_registered);

  if v_unknown is not null and cardinality(v_unknown) > 0 then
    raise warning '模板占位符未在事件 % 的 available_vars 中登记：%',
      p_event_key, array_to_string(v_unknown, ', ');
  end if;

  -- 版本计算并发防护：同 (event_key, channel) 串行（参照 upsert_setting 的 key 级 advisory 锁）。
  -- 缺失草稿行上 FOR UPDATE 不上锁，两个并发保存都会看到 not found 并各自算 max+1 造成唯一冲突；
  -- 命名空间前缀避免与其他模块 advisory 锁（sync webhook / system setting）撞键。
  perform pg_advisory_xact_lock(hashtext('message_template:' || p_event_key || ':' || p_channel));

  if p_id is null then
    select * into v_row
    from public.message_templates
    where event_key = p_event_key
      and channel = p_channel
      and status = 'draft'
    order by version desc
    limit 1
    for update;

    if found then
      update public.message_templates
         set subject_tpl = p_subject_tpl,
             body_tpl    = p_body_tpl,
             updated_by  = v_uid
       where id = v_row.id
      returning * into v_row;
    else
      select coalesce(max(version), 0) + 1 into v_version
      from public.message_templates
      where event_key = p_event_key
        and channel = p_channel;

      insert into public.message_templates
        (event_key, channel, subject_tpl, body_tpl, version, status, updated_by)
      values
        (p_event_key, p_channel, p_subject_tpl, p_body_tpl, v_version, 'draft', v_uid)
      returning * into v_row;
    end if;
  else
    select * into v_row
    from public.message_templates
    where id = p_id
    for update;

    if not found then
      raise exception '模板不存在' using errcode = 'P0002';
    end if;

    if v_row.status <> 'draft' then
      raise exception '该版本非草稿状态（%），不可修改：请新建草稿版本或回滚', v_row.status
        using errcode = '22023';
    end if;

    if v_row.event_key is distinct from p_event_key
       or v_row.channel is distinct from p_channel then
      raise exception '模板事件与渠道不可修改' using errcode = '22023';
    end if;

    update public.message_templates
       set subject_tpl = p_subject_tpl,
           body_tpl    = p_body_tpl,
           updated_by  = v_uid
     where id = p_id
    returning * into v_row;
  end if;

  perform app.audit_log(
    'message', 'save', 'message_template', v_row.id::text,
    jsonb_build_object(
      'event_key', v_row.event_key, 'channel', v_row.channel,
      'version', v_row.version, 'status', v_row.status
    )
  );

  return v_row;
end;
$$;

comment on function app.upsert_message_template(text, text, text, text, uuid) is
  '保存通知模板草稿（仅 admin）：未注册事件拒绝；续编既有草稿或新建 version=max+1；'
  '同 (event_key, channel) advisory xact 锁防并发版本冲突；模板占位符与 available_vars 差集 raise warning（不阻断）；写审计';

-- ---------------------------------------------------------------------------
-- 6. app.publish_message_template：current 指针竞态 catch unique_violation
-- ---------------------------------------------------------------------------
create or replace function app.publish_message_template(p_id uuid)
returns public.message_templates
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.message_templates;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.message_templates
  where id = p_id
  for update;

  if not found then
    raise exception '模板不存在' using errcode = 'P0002';
  end if;

  if v_row.status = 'disabled' then
    raise exception '已停用版本不可发布' using errcode = '22023';
  end if;

  if btrim(v_row.subject_tpl) = '' then
    raise exception '标题模板不能为空，无法发布' using errcode = '22023';
  end if;

  update public.message_templates
     set status = 'published',
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  begin
    insert into public.message_template_current (event_key, channel, template_id)
    values (v_row.event_key, v_row.channel, v_row.id)
    on conflict (event_key, channel) do update
      set template_id = excluded.template_id;
  exception when unique_violation then
    -- 并发发布同一 (event_key, channel) 的指针竞态兜底：串行化失败时给可重试的友好错误
    raise exception '模板发布指针冲突：事件 % / 渠道 % 正被并发发布，请重试',
      v_row.event_key, v_row.channel
      using errcode = '40001';
  end;

  perform app.audit_log(
    'message', 'publish', 'message_template', v_row.id::text,
    jsonb_build_object(
      'event_key', v_row.event_key, 'channel', v_row.channel, 'version', v_row.version
    )
  );

  return v_row;
end;
$$;

comment on function app.publish_message_template(uuid) is
  '发布通知模板（仅 admin）：draft → published 并把 current 指针指向本版本；'
  '指针更新 catch unique_violation 转可重试友好提示（40001）；写审计';
