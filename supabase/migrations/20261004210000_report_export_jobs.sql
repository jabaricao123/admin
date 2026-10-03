-- 报表中心 · 全站统一导出管道（工单 report/007）
-- 契约：docs/modules/report/exports.md（request_export、任务状态机、限额 ≤3、7 天过期、重试）；
--       docs/adr/001-job-runner.md（pg_cron 轮询队列表 → 执行 → 写记录；属主身份注入，禁 service_role）；
--       docs/modules/INDEX.md 规则 1（共享数据只经公开面）、规则 5（调度统一登记）、
--       规则 10（全模块入口 RPC 不直接 GRANT authenticated，仅 GRANT public 薄包装）。
--
-- v1 取舍（exports.md「数据模型」的 file_url 回写 → 本地等价对象存储上传）：
--   CSV 内容存 export_jobs.content（行内）；content/file_path 做列级授权排除，
--   下载仅经 download_export RPC（含属主 + 7 天过期校验）。内容 > 5MB 或 > 5 万行 → failed
--   「结果过大请缩小范围」。上传 exports bucket（user_id/ 前缀）留 v2——本地 SQL 直写
--   storage.objects 可测但脆，且 system/003 的属主读策略按同批规划；file_path 列保留给 v2
--   对象路径（<requested_by>/<job_id>.csv），v1 恒 NULL。
--
-- 组成：
--   1. export_sources：导出源注册表（source PK = <module>.<entity>；seed org.users / audit.operations）；
--   2. export_jobs：导出任务表（queued/running/done/failed；content 行内 CSV）；
--   3. app.request_export / public.request_export：发起（源 enabled + 权限 + 限额 ≤3，写审计）；
--   4. app.process_export_jobs：worker（for update skip locked 限 5/轮；注入属主身份查询 → CSV）；
--      注：PG 禁止 SECURITY DEFINER 函数内 SET ROLE（cannot set parameter "role"
--      within security-definer function），因此 worker 为 SECURITY INVOKER + 撤销 API 角色
--      执行权，仅 pg_cron（以 postgres 执行）可达；身份注入与 RLS 过滤路径不变（ADR-001）。
--   5. app.download_export / public.download_export：下载（属主或 admin；7 天过期拒绝）；
--   6. app.retry_export / public.retry_export：失败重试（failed → queued 重置，复用限额）；
--   7. app.csv_field/csv_line/csv_encode：CSV 编码 helper（内部，不 GRANT API 角色）；
--   8. pg_cron：每分钟轮询 app.process_export_jobs()。
--
-- 依赖：system/003（20261004180000，exports bucket 已建；属主前缀上传策略随 v2）、
--       audit/001（app.audit_log）、access/003（app.current_role 读 role_id）、
--       public.profiles（源 org.users）、public.audit_operations_v（源 audit.operations）。

-- ---------------------------------------------------------------------------
-- 1. export_sources：导出源注册表（全站导出白名单）
-- ---------------------------------------------------------------------------
create table public.export_sources (
  source        text primary key,
  config_schema jsonb not null default '{}'::jsonb,
  owner_module  text not null,
  enabled       boolean not null default true,
  created_at    timestamptz not null default now(),
  constraint export_sources_source_format
    check (source ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$')
);

comment on table public.export_sources is
  '导出源白名单：source 命名 <module>.<entity>（消费方只允许注册表中的源）；'
  'enabled=false 停止新任务，且在跑任务由 worker 置 failed；'
  'config_schema 描述 config 结构（v1 仅记录不校验）；config_schema.access=admin 表示仅 admin 可发起';
comment on column public.export_sources.source is '源标识 <module>.<entity>，如 org.users、audit.operations（PK）';
comment on column public.export_sources.config_schema is
  'config 的 JSON Schema 描述；扩展键 access=admin 声明 admin 独占源（v1 唯一生效的键）';
comment on column public.export_sources.owner_module is '拥有该数据源的模块（org/audit/...），供登记与审计归属';
comment on column public.export_sources.enabled is '是否允许发起/继续导出；停用只影响新任务与在跑任务';

-- 首期源：用户名单（org）与操作日志（audit，admin 全量）
insert into public.export_sources (source, config_schema, owner_module)
values
  ('org.users',
   '{"type":"object","properties":{},"additionalProperties":false}'::jsonb,
   'org'),
  ('audit.operations',
   '{"type":"object","properties":{},"additionalProperties":false,"access":"admin"}'::jsonb,
   'audit')
on conflict (source) do nothing;

-- ---------------------------------------------------------------------------
-- 2. export_jobs：导出任务表
-- ---------------------------------------------------------------------------
create table public.export_jobs (
  id           uuid primary key default gen_random_uuid(),
  source       text not null references public.export_sources (source),
  config       jsonb not null default '{}'::jsonb,
  status       text not null default 'queued'
               constraint export_jobs_status_check
               check (status in ('queued', 'running', 'done', 'failed')),
  file_path    text,
  content      text,
  size_bytes   bigint,
  error        text,
  requested_by uuid not null references public.profiles (id),
  created_at   timestamptz not null default now(),
  started_at   timestamptz,
  finished_at  timestamptz
);

comment on table public.export_jobs is
  '导出任务（exports.md 数据模型）：queued → running → done/failed；'
  '写入仅经 SECURITY DEFINER RPC，表级无 API 写权限；'
  'content 为 v1 行内 CSV（下载经 download_export，不在表级读面暴露）';
comment on column public.export_jobs.config is '导出参数（源自定义；v1 记录不校验）';
comment on column public.export_jobs.status is '任务状态机：queued 排队 / running 生成中 / done 完成 / failed 失败';
comment on column public.export_jobs.file_path is
  'v2 对象存储路径（<requested_by>/<job_id>.csv）；v1 行内存储恒 NULL';
comment on column public.export_jobs.content is
  'v1 CSV 内容（行内存取）：列级授权排除，仅 download_export RPC 按属主 + 7 天有效期返回；'
  'v2 上传 exports bucket 后置空，仅保留 file_path';
comment on column public.export_jobs.size_bytes is 'CSV 字节数（octet_length(content)）；失败任务为 NULL';
comment on column public.export_jobs.error is '失败原因（截断 500 字符）；重试成功后清空';
comment on column public.export_jobs.requested_by is '发起人（任务属主，worker 按其身份注入执行）';

-- worker 轮询：queued 队列部分索引 + 任务列表按属主时间倒序
create index export_jobs_queue_idx
  on public.export_jobs (created_at)
  where status = 'queued';
create index export_jobs_owner_created_idx
  on public.export_jobs (requested_by, created_at desc);

-- ---------------------------------------------------------------------------
-- 3. RLS 与授权：表级只读（列级排除内容）；写全经 RPC
-- ---------------------------------------------------------------------------
alter table public.export_sources enable row level security;
alter table public.export_jobs enable row level security;

-- 源注册表：登录用户可读 enabled 源；admin 可见停用源
create policy export_sources_select_enabled
on public.export_sources
for select
to authenticated
using (enabled or (select app.current_role()) = 'admin');

-- 任务表：属主读自己 + admin 全量
create policy export_jobs_select_own
on public.export_jobs
for select
to authenticated
using ((select auth.uid()) = requested_by);

create policy export_jobs_select_admin
on public.export_jobs
for select
to authenticated
using ((select app.current_role()) = 'admin');

revoke all on public.export_sources from public, anon, authenticated, service_role;
grant select on public.export_sources to authenticated, service_role;

revoke all on public.export_jobs from public, anon, authenticated, service_role;
-- 列级 SELECT：content/file_path 不直接暴露（下载必须经 download_export 校验属主与有效期）
grant select (id, source, config, status, size_bytes, error, requested_by,
              created_at, started_at, finished_at)
  on public.export_jobs to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. CSV 编码 helper（内部；仅 worker 以调用者 postgres 身份调用）
--    RFC 4180：含逗号/双引号/换行才加引号，内部双引号翻倍；NULL 输出空字段。
-- ---------------------------------------------------------------------------
create function app.csv_field(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_value is null then ''
    when p_value ~ ('[",' || chr(13) || chr(10) || ']')
      then '"' || replace(p_value, '"', '""') || '"'
    else p_value
  end
$$;

comment on function app.csv_field(text) is 'CSV 字段转义（RFC 4180 最小引号；NULL → 空字段）；内部 helper，不 GRANT API 角色';

create function app.csv_line(p_fields text[])
returns text
language sql
immutable
set search_path = ''
as $$
  select string_agg(app.csv_field(f), ',' order by ord)
  from unnest(p_fields) with ordinality as t(f, ord)
$$;

comment on function app.csv_line(text[]) is 'CSV 行编码（字段逗号分隔）；内部 helper，不 GRANT API 角色';

create function app.csv_encode(p_header text[], p_rows text[][])
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_lines text[] := array[]::text[];
  v_row   text[];
begin
  v_lines := v_lines || app.csv_line(p_header);

  if p_rows is not null then
    foreach v_row slice 1 in array p_rows
    loop
      v_lines := v_lines || app.csv_line(v_row);
    end loop;
  end if;

  return array_to_string(v_lines, E'\n');
end;
$$;

comment on function app.csv_encode(text[], text[][]) is 'CSV 整体编码（表头 + 数据行，LF 分隔）；内部 helper，不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 5. app.request_export：发起导出（属主身份 = 当前登录用户）
--    限额（exports.md 功能需求 5）：单用户 queued + running ≤ 3；
--    咨询锁串行化同一用户并发发起，防 count-then-insert 竞态。
-- ---------------------------------------------------------------------------
create function app.request_export(
  p_source text,
  p_config jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_config jsonb := coalesce(p_config, '{}'::jsonb);
  v_source public.export_sources;
  v_active integer;
  v_id     uuid;
begin
  if v_uid is null then
    raise exception '未登录，无法发起导出' using errcode = '42501';
  end if;

  if p_source is null or btrim(p_source) = '' then
    raise exception '导出源不能为空' using errcode = '22023';
  end if;

  if jsonb_typeof(v_config) <> 'object' then
    raise exception 'config 必须为 jsonb 对象' using errcode = '22023';
  end if;

  select * into v_source
  from public.export_sources
  where source = p_source;

  if not found then
    raise exception '导出源不存在：%', p_source using errcode = 'P0002';
  end if;

  if not v_source.enabled then
    raise exception '导出源已停用：%', p_source using errcode = 'P0001';
  end if;

  if v_source.config_schema ->> 'access' = 'admin'
     and (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可导出该来源：%', p_source using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_uid::text, 0));

  select count(*) into v_active
  from public.export_jobs
  where requested_by = v_uid
    and status in ('queued', 'running');

  if v_active >= 3 then
    raise exception '进行中的导出任务已达上限（3），请等待完成后再试' using errcode = 'P0001';
  end if;

  insert into public.export_jobs (source, config, requested_by)
  values (p_source, v_config, v_uid)
  returning id into v_id;

  perform app.audit_log(
    'report', 'request', 'export_job', v_id::text,
    jsonb_build_object('source', p_source, 'config', v_config)
  );

  return v_id;
end;
$$;

comment on function app.request_export(text, jsonb) is
  '发起导出（登录用户）：校验源存在/enabled/admin 独占；单用户 queued+running ≤3；'
  '插入 queued 任务并写审计；返回任务 id。内部实现，不直接 GRANT API 角色（INDEX 规则 10）';

-- ---------------------------------------------------------------------------
-- 6. app.process_export_jobs：worker（pg_cron 每分钟调用；禁 service_role）
--    执行身份（ADR-001）：任务属主身份注入（set local role authenticated +
--    request.jwt.claims.sub = requested_by），RLS 按属主过滤；查询后立即还原角色，
--    回写任务状态仍以调用者（pg_cron → postgres）执行。
--    偏离说明：ADR-001 原文为「SECURITY DEFINER + 内部 set local role」，但 PostgreSQL
--    禁止在 SECURITY DEFINER 函数内 SET ROLE（cannot set parameter "role" within
--    within security-definer function）。落地为 SECURITY INVOKER + REVOKE ALL FROM
--    API 角色：只有 pg_cron 的 postgres 身份可执行，身份注入/RLS 过滤语义不变。
-- ---------------------------------------------------------------------------
create function app.process_export_jobs()
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
      update public.export_jobs
         set status      = 'failed',
             content     = null,
             size_bytes  = null,
             error       = left(sqlerrm, 500),
             finished_at = now()
       where id = v_job.id;

      perform app.audit_log(
        'report', 'fail', 'export_job', v_job.id::text,
        jsonb_build_object('source', v_job.source, 'error', left(sqlerrm, 500))
      );
    end;
  end loop;

  return v_processed;
end;
$$;

comment on function app.process_export_jobs() is
  '导出 worker（pg_cron 每分钟）：取 queued 任务（for update skip locked 限 5 条/轮）→ '
  '注入任务属主身份生成 CSV（ADR-001，禁 service_role）→ 回写 done/failed；'
  '单任务失败不中断本轮并写审计；返回本轮处理条数。'
  'security invoker + 撤销 API 角色执行权（PG 禁止 definer 内 SET ROLE；仅 pg_cron 的 postgres 可达）';

-- ---------------------------------------------------------------------------
-- 7. app.download_export：下载（属主或 admin；status=done 且 7 天内）
-- ---------------------------------------------------------------------------
create function app.download_export(p_job_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_job public.export_jobs;
begin
  if v_uid is null then
    raise exception '未登录，无法下载导出文件' using errcode = '42501';
  end if;

  if p_job_id is null then
    raise exception '任务 ID 不能为空' using errcode = '22023';
  end if;

  select * into v_job
  from public.export_jobs
  where id = p_job_id;

  if not found then
    raise exception '导出任务不存在' using errcode = 'P0002';
  end if;

  if v_job.requested_by is distinct from v_uid
     and (select app.current_role()) is distinct from 'admin' then
    raise exception '无权访问该导出任务' using errcode = '42501';
  end if;

  if v_job.status <> 'done' then
    raise exception '导出任务尚未完成（当前状态：%）', v_job.status using errcode = 'P0001';
  end if;

  -- exports.md 功能需求 3：完成后 7 天内可下载（以任务创建时间计；过期由清理任务另行回收）
  if v_job.created_at <= now() - interval '7 days' then
    raise exception '导出文件已过期（创建后 7 天内可下载）' using errcode = 'P0001';
  end if;

  return v_job.content;
end;
$$;

comment on function app.download_export(uuid) is
  '下载导出 CSV（属主或 admin）：校验 status=done 且创建时间在 7 天内；'
  'content 不做表级暴露，只能经本 RPC 读取；不直接 GRANT API 角色（INDEX 规则 10）';

-- ---------------------------------------------------------------------------
-- 8. app.retry_export：失败重试（属主或 admin；failed → queued 重置）
--    复用同一限额（含 advisory 锁），防经重试绕过并发上限。
-- ---------------------------------------------------------------------------
create function app.retry_export(p_job_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_job    public.export_jobs;
  v_active integer;
begin
  if v_uid is null then
    raise exception '未登录，无法重试导出任务' using errcode = '42501';
  end if;

  if p_job_id is null then
    raise exception '任务 ID 不能为空' using errcode = '22023';
  end if;

  select * into v_job
  from public.export_jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception '导出任务不存在' using errcode = 'P0002';
  end if;

  if v_job.requested_by is distinct from v_uid
     and (select app.current_role()) is distinct from 'admin' then
    raise exception '无权访问该导出任务' using errcode = '42501';
  end if;

  if v_job.status <> 'failed' then
    raise exception '仅失败任务可重试（当前状态：%）', v_job.status using errcode = 'P0001';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_job.requested_by::text, 0));

  select count(*) into v_active
  from public.export_jobs
  where requested_by = v_job.requested_by
    and status in ('queued', 'running');

  if v_active >= 3 then
    raise exception '进行中的导出任务已达上限（3），请等待完成后再试' using errcode = 'P0001';
  end if;

  update public.export_jobs
     set status      = 'queued',
         error       = null,
         content     = null,
         size_bytes  = null,
         started_at  = null,
         finished_at = null
   where id = p_job_id;

  perform app.audit_log(
    'report', 'retry', 'export_job', p_job_id::text,
    jsonb_build_object('source', v_job.source)
  );

  return p_job_id;
end;
$$;

comment on function app.retry_export(uuid) is
  '失败任务重试（属主或 admin）：failed → queued，清空 error/content/时间戳；'
  '复用单用户并发限额；写审计。不直接 GRANT API 角色（INDEX 规则 10）';

-- ---------------------------------------------------------------------------
-- 9. public 薄包装（PostgREST 仅暴露 public schema；INDEX 规则 10）
-- ---------------------------------------------------------------------------
create function public.request_export(
  p_source text,
  p_config jsonb default '{}'::jsonb
)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select app.request_export(p_source, p_config)
$$;

comment on function public.request_export(text, jsonb) is 'request_export Data API 薄包装（校验与限额在 app 实现内）';

create function public.download_export(p_job_id uuid)
returns text
language sql
security definer
set search_path = ''
as $$
  select app.download_export(p_job_id)
$$;

comment on function public.download_export(uuid) is 'download_export Data API 薄包装（属主/有效期校验在 app 实现内）';

create function public.retry_export(p_job_id uuid)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select app.retry_export(p_job_id)
$$;

comment on function public.retry_export(uuid) is 'retry_export Data API 薄包装（属主/状态校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 10. 授权：用户 RPC 仅 public 包装给 authenticated；app 实现与 worker 无 API 路径
-- ---------------------------------------------------------------------------
revoke all on function app.request_export(text, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.request_export(text, jsonb) from public, anon, authenticated, service_role;
revoke all on function app.download_export(uuid) from public, anon, authenticated, service_role;
revoke all on function public.download_export(uuid) from public, anon, authenticated, service_role;
revoke all on function app.retry_export(uuid) from public, anon, authenticated, service_role;
revoke all on function public.retry_export(uuid) from public, anon, authenticated, service_role;
revoke all on function app.process_export_jobs() from public, anon, authenticated, service_role;
revoke all on function app.csv_field(text) from public, anon, authenticated, service_role;
revoke all on function app.csv_line(text[]) from public, anon, authenticated, service_role;
revoke all on function app.csv_encode(text[], text[][]) from public, anon, authenticated, service_role;

grant execute on function public.request_export(text, jsonb) to authenticated;
grant execute on function public.download_export(uuid) to authenticated;
grant execute on function public.retry_export(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 11. pg_cron：每分钟轮询 worker（pg_cron 已在本地镜像 shared_preload_libraries）
--     TODO(system/011)：system pg_cron 登记处（INDEX 规则 5）上线后，将本 job
--     补登记到平台登记表；在此之前按本工单决定直接 cron.schedule。
-- ---------------------------------------------------------------------------
create extension if not exists pg_cron;

select cron.schedule(
  'process-export-jobs',
  '* * * * *',
  $cron$select app.process_export_jobs()$cron$
);
