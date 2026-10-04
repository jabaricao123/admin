-- 审计中心 · 登录日志导出源（audit 批次 2 修复项 1）
-- 契约：docs/modules/audit/logins.md 功能需求 5（导出走 report 导出管道）、
--       docs/modules/report/exports.md（export_sources 白名单 + worker 分支）、
--       docs/modules/INDEX.md 规则 1（共享数据只经公开面）、规则 10（内部 RPC 不 GRANT）。
-- 组成：
--   1. export_sources seed：audit.logins（admin 独占源；audit 模块）；
--   2. create or replace app.process_export_jobs()：
--      * 新增 audit.logins 分支（属主身份注入后读 audit_logins，admin RLS 放行；
--        CSV 列：时间/邮箱/结果/失败原因/IP/UA）；
--      * audit.operations 分支补 config.start/end 筛选（YYYY-MM-DD 业务时区日界闭区间；
--        原逻辑其余原样保留）；
--      * audit.operations 的 config_schema 同步登记 start/end 描述（v1 仅记录不校验）。
-- 说明：登录日志为 append-only，不设时间筛选（按需后续随需求再扩展 config）；
--   audit.operations 筛选由 /audit/operations 页导出按钮传入当前日期筛选。
-- 依赖：report/007（export_sources / export_jobs / worker / CSV helpers）、
--       audit/005（audit_logins）、audit 批次 2（report 失败通知版 worker 为基线）。

-- ---------------------------------------------------------------------------
-- 1. export_sources：登记 audit.logins（admin 独占）+ 补 audit.operations 筛选描述
-- ---------------------------------------------------------------------------
insert into public.export_sources (source, config_schema, owner_module)
values (
  'audit.logins',
  '{"type":"object","properties":{},"additionalProperties":false,"access":"admin"}'::jsonb,
  'audit'
)
on conflict (source) do nothing;

update public.export_sources
   set config_schema = '{
         "type":"object",
         "properties":{
           "start":{"type":"string","format":"date",
                    "description":"起始日期（YYYY-MM-DD，Asia/Shanghai，含当日）"},
           "end":{"type":"string","format":"date",
                  "description":"结束日期（YYYY-MM-DD，Asia/Shanghai，含当日）"}
         },
         "additionalProperties":false,
         "access":"admin"
       }'::jsonb
 where source = 'audit.operations';

-- ---------------------------------------------------------------------------
-- 2. app.process_export_jobs：新增 audit.logins 分支 + audit.operations 日期筛选
--    （基线：20261006021000_report_failure_notify.sql，其余逻辑原样）
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
  c_tz         constant text    := 'Asia/Shanghai'; -- 操作日志筛选日界的业务时区
  v_prev_role  text := pg_catalog.current_setting('role');
  v_job        record;
  v_enabled    boolean;
  v_access     text;
  v_start      date;
  v_end        date;
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

      -- 操作日志导出筛选（config.start/end，YYYY-MM-DD；业务时区闭区间日界，
      -- 缺省不过滤）；非法值不入库执行，直接失败任务并留中文原因。
      if v_job.source = 'audit.operations' then
        if coalesce(btrim(v_job.config ->> 'start'), '') <> '' then
          if (v_job.config ->> 'start') !~ '^\d{4}-\d{2}-\d{2}$' then
            raise exception '筛选起始日期不合法（YYYY-MM-DD）：%', v_job.config ->> 'start'
              using errcode = '22023';
          end if;
          v_start := (v_job.config ->> 'start')::date;
        end if;

        if coalesce(btrim(v_job.config ->> 'end'), '') <> '' then
          if (v_job.config ->> 'end') !~ '^\d{4}-\d{2}-\d{2}$' then
            raise exception '筛选结束日期不合法（YYYY-MM-DD）：%', v_job.config ->> 'end'
              using errcode = '22023';
          end if;
          v_end := (v_job.config ->> 'end')::date;
        end if;

        if v_start is not null and v_end is not null and v_start > v_end then
          raise exception '筛选日期区间不合法：起始日期晚于结束日期' using errcode = '22023';
        end if;
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
          -- 操作日志 admin 全量：读公开视图 audit_operations_v（security_invoker → admin RLS）；
          -- config.start/end 按业务时区闭区间过滤（[start 00:00, end+1 00:00)）
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
            where (v_start is null
                   or a.created_at >= (v_start::timestamp at time zone c_tz))
              and (v_end is null
                   or a.created_at < ((v_end + 1)::timestamp at time zone c_tz))
            order by a.created_at desc, a.id desc
            limit c_max_rows + 1
          ) s;
        elsif v_job.source = 'audit.logins' then
          -- 登录日志 admin 全量：读 audit_logins（RLS admin 放行）；
          -- CSV 列：时间/邮箱/结果/失败原因/IP/UA
          select array_agg(row_vals)
            into v_rows
          from (
            select array[
                     to_char(l.created_at, 'YYYY-MM-DD HH24:MI:SS'),
                     l.email,
                     l.success::text,
                     l.fail_reason,
                     host(l.ip),
                     l.ua
                   ] as row_vals
            from public.audit_logins l
            order by l.created_at desc, l.id desc
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
      elsif v_job.source = 'audit.logins' then
        v_content := app.csv_encode(
          array['created_at', 'email', 'success', 'fail_reason', 'ip', 'ua'],
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

comment on function app.process_export_jobs() is
  '导出 worker（pg_cron 每分钟）：取 queued 任务（for update skip locked 限 5 条/轮）→ '
  '注入任务属主身份生成 CSV（ADR-001，禁 service_role）→ 回写 done/failed；'
  '单任务失败不中断本轮，写审计并通知任务属主（report.export_failed；通知失败不阻断收尾）；'
  '返回本轮处理条数。integration/007 起支持 integration.logs（admin 独占源），'
  'audit 批次 2 起支持 audit.logins（admin 独占源）与 audit.operations config.start/end 筛选。'
  'security invoker + 撤销 API 角色执行权（PG 禁止 definer 内 SET ROLE；仅 pg_cron 的 postgres 可达）';
