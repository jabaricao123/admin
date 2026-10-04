-- 报表中心 · 失败通知与事件契约（report 批次 2 / 修复项 2 + 4）
-- 1. 事件契约修正（register_message_event 幂等 upsert）：
--    * report.export_ready：available_vars 改为订阅摘要实际发送键
--      （title/body/report_name/row_count/summary），移除未被 send_notification 使用的
--      download_url（模板变量以实际发送 jsonb 键为准）；
--    * 补注册 report.subscription_failed（title/report_name/error）与
--      report.export_failed（source/error）。
-- 2. 失败收尾补通知属主（ADR-001 §3）：
--    * app.report_subscription_run_finish：failed → send_notification(created_by)；
--    * app.process_export_jobs：failed → send_notification(requested_by)；
--    通知失败不影响落库（begin/exception 包裹，同 sync 失败通知先例）。
-- 依赖：20261005020000（register_message_event）、20261005090000（send_notification 当前版）、
--       20261005091000（run_finish 当前版）、20261005124000（process_export_jobs 当前版）。
--
-- 迁移方式：create or replace 全量替换（主体复制自上述当前版本，仅差异处按上述修改）。

-- ---------------------------------------------------------------------------
-- 1. 事件注册表：修正 export_ready + 补两事件
-- ---------------------------------------------------------------------------
select app.register_message_event(
  'report.export_ready',
  'report',
  '报表订阅结果就绪（摘要投递）',
  '["title","body","report_name","row_count","summary"]'::jsonb
);

select app.register_message_event(
  'report.subscription_failed',
  'report',
  '报表订阅执行失败（通知订阅属主）',
  '["title","report_name","error"]'::jsonb
);

select app.register_message_event(
  'report.export_failed',
  'report',
  '报表导出失败（通知任务属主）',
  '["source","error"]'::jsonb
);

-- ---------------------------------------------------------------------------
-- 2. app.report_subscription_run_finish：失败通知属主
-- ---------------------------------------------------------------------------

create or replace function app.report_subscription_run_finish(
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
  v_uid         uuid := (select auth.uid());
  v_role        public.user_role := (select app.current_role());
  v_run         public.report_subscription_runs;
  v_sub         public.report_subscriptions;
  v_report_name text;
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

    -- 失败通知订阅属主（ADR-001 §3）；通知失败不影响执行记录落库
    begin
      select d.name into v_report_name
      from public.report_definitions d
      where d.id = v_sub.report_def_id;

      perform app.send_notification(
        v_sub.created_by,
        'report.subscription_failed',
        jsonb_build_object(
          'title', format(
            '报表订阅「%s」执行失败',
            coalesce(v_report_name, '未命名报表')
          ),
          'report_name', coalesce(v_report_name, ''),
          'error', left(coalesce(p_error, ''), 500)
        )
      );
    exception when others then
      null;
    end;
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- 3. app.process_export_jobs：失败通知属主
-- ---------------------------------------------------------------------------

create or replace function app.process_export_jobs()
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  c_batch      constant integer := 5;       -- 每轮最多处理任务数
  c_max_rows   constant integer := 50000;   -- CSV 数据行上限（防御性；先选后裁）
  c_max_size   constant bigint  := 5242880; -- 5MB 内容上限（v1 行内存储）
  v_prev_role  text := pg_catalog.current_setting('role');
  v_job        record;
  v_enabled    boolean;
  v_access     text;
  v_rows       text[][];
  v_content    text;
  v_job_error  text;
  v_processed  integer := 0;
begin
  for v_job in
    select j.id, j.source, j.config, j.requested_by
    from public.export_jobs j
    where j.status = 'queued'
    order by j.created_at, j.id
    for update skip locked
    limit c_batch
  loop
    update public.export_jobs
       set status = 'running', started_at = now(), error = null, finished_at = null
     where id = v_job.id;

    v_processed := v_processed + 1;

    begin
      select s.enabled, s.config_schema ->> 'access'
        into v_enabled, v_access
        from public.export_sources s
       where s.source = v_job.source;

      if v_enabled is null then
        raise exception '导出源不存在：%', v_job.source using errcode = 'P0002';
      end if;
      if not v_enabled then
        raise exception '导出源已停用：%', v_job.source using errcode = 'P0001';
      end if;

      --------------------------------------------------------------------
      -- 属主身份注入（ADR-001）：执行查询前以 authenticated + claims.sub
      -- 运行，RLS 按属主过滤；查询结束/异常均还原角色，回写不受影响。
      -- 全局禁止 service_role（BYPASSRLS）。
      --------------------------------------------------------------------
      begin
        set local role authenticated;
        perform set_config(
          'request.jwt.claims',
          json_build_object('sub', v_job.requested_by, 'role', 'authenticated')::text,
          true
        );

        -- admin 独占源在发起时已拦截；worker 内复检（源配置可能在排队期间变化）
        if v_access = 'admin'
           and app.current_role() is distinct from 'admin' then
          raise exception '仅管理员可导出该来源：%', v_job.source using errcode = '42501';
        end if;

        if v_job.source = 'org.users' then
          -- 用户名单：按属主身份读 profiles（RLS：本人 / 内部通讯录 / admin 全量）
          -- TODO(org 发布用户视图后)：改读公开视图，去掉对 profiles 的直查（INDEX 规则 1）
          select array_agg(row_vals)
            into v_rows
          from (
            select array[
                     p.id::text,
                     p.full_name,
                     p.department,
                     p.role::text,
                     p.status::text,
                     to_char(p.created_at, 'YYYY-MM-DD HH24:MI:SS')
                   ] as row_vals
            from public.profiles p
            order by p.created_at, p.id
            limit c_max_rows + 1
          ) s;
        elsif v_job.source = 'audit.operations' then
          -- 操作日志 admin 全量：读公开视图 audit_operations_v（security_invoker → admin RLS）
          select array_agg(row_vals)
            into v_rows
          from (
            select array[
                     a.id::text,
                     to_char(a.created_at, 'YYYY-MM-DD HH24:MI:SS'),
                     a.actor_id::text,
                     a.actor_name,
                     a.module,
                     a.action,
                     a.object_type,
                     a.object_id,
                     host(a.ip)
                   ] as row_vals
            from public.audit_operations_v a
            order by a.created_at desc, a.id desc
            limit c_max_rows + 1
          ) s;
        elsif v_job.source = 'integration.logs' then
          -- 调用日志 admin 全量：读 integration_call_logs（RLS admin 放行；30 天保留期内明细）
          select array_agg(row_vals)
            into v_rows
          from (
            select array[
                     l.id::text,
                     to_char(l.created_at, 'YYYY-MM-DD HH24:MI:SS'),
                     l.kind,
                     coalesce(k.name, w.name, ''),
                     l.method_event,
                     coalesce(l.status_code::text, ''),
                     coalesce(l.duration_ms::text, ''),
                     coalesce(l.error, '')
                   ] as row_vals
            from public.integration_call_logs l
            left join public.api_keys k
              on l.kind = 'api' and k.id = l.key_id
            left join public.webhooks w
              on l.kind = 'webhook' and w.id = l.webhook_id
            order by l.created_at desc, l.id desc
            limit c_max_rows + 1
          ) s;
        else
          raise exception '导出源无处理器：%', v_job.source using errcode = 'P0001';
        end if;

        -- 查询完成：立即还原角色（CSV 编码/回写以调用者身份执行）
        if v_prev_role is null or v_prev_role = 'none' then
          reset role;
        else
          execute format('set local role %I', v_prev_role);
        end if;
      exception when others then
        if v_prev_role is null or v_prev_role = 'none' then
          reset role;
        else
          execute format('set local role %I', v_prev_role);
        end if;
        raise;
      end;

      -- 角色已还原：以下以调用者（pg_cron → postgres）身份执行
      if coalesce(array_length(v_rows, 1), 0) > c_max_rows then
        raise exception '结果过大请缩小范围（数据行超过 % 条上限）', c_max_rows using errcode = 'P0001';
      end if;

      if v_job.source = 'org.users' then
        v_content := app.csv_encode(
          array['id', 'full_name', 'department', 'role', 'status', 'created_at'],
          v_rows
        );
      elsif v_job.source = 'integration.logs' then
        v_content := app.csv_encode(
          array['id', 'created_at', 'kind', 'ref_name', 'method_event',
                'status_code', 'duration_ms', 'error'],
          v_rows
        );
      else
        v_content := app.csv_encode(
          array['id', 'created_at', 'actor_id', 'actor_name', 'module',
                'action', 'object_type', 'object_id', 'ip'],
          v_rows
        );
      end if;

      if octet_length(v_content) > c_max_size then
        raise exception '结果过大请缩小范围（CSV 超过 5MB 上限）' using errcode = 'P0001';
      end if;

      update public.export_jobs
         set status      = 'done',
             content     = v_content,
             size_bytes  = octet_length(v_content),
             error       = null,
             finished_at = now()
       where id = v_job.id;
    exception when others then
      -- 单任务失败不中断本轮：置 failed 留原因，并写审计摘要（ADR-001 第 3 节）
      v_job_error := left(sqlerrm, 500);

      update public.export_jobs
         set status      = 'failed',
             content     = null,
             size_bytes  = null,
             error       = v_job_error,
             finished_at = now()
       where id = v_job.id;

      perform app.audit_log(
        'report', 'fail', 'export_job', v_job.id::text,
        jsonb_build_object('source', v_job.source, 'error', v_job_error)
      );

      -- 失败通知任务属主（ADR-001 §3）；通知失败不影响任务收尾
      begin
        perform app.send_notification(
          v_job.requested_by,
          'report.export_failed',
          jsonb_build_object(
            'source', v_job.source,
            'error', v_job_error
          )
        );
      exception when others then
        null;
      end;
    end;
  end loop;

  return v_processed;
end;
$$;


comment on function app.report_subscription_run_finish(bigint, text, integer, text) is
  '收尾执行记录（success/failed + duration_ms + error）；失败写审计摘要并通知订阅属主'
  '（report.subscription_failed，ADR-001 §3；通知失败不阻断收尾）；显式校验 owner/admin';

comment on function app.process_export_jobs() is
  '导出 worker（pg_cron 每分钟）：取 queued 任务（for update skip locked 限 5 条/轮）→ '
  '注入任务属主身份生成 CSV（ADR-001，禁 service_role）→ 回写 done/failed；'
  '单任务失败不中断本轮，写审计并通知任务属主（report.export_failed；通知失败不阻断收尾）；'
  '返回本轮处理条数。integration/007 起支持 integration.logs（admin 独占源）。'
  'security invoker + 撤销 API 角色执行权（PG 禁止 definer 内 SET ROLE；仅 pg_cron 的 postgres 可达）';
