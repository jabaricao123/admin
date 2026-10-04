-- 报表中心 · 导出过期清理（report 批次 2 / 修复项 3）
-- 问题：export_jobs.content 为 v1 行内存储，完成后一直保留；download_export 的 7 天
--   有效期以 created_at 为基准（排队/执行延迟会让实际可下载窗口不足 7 天，E-2）。
-- 修复：
--   1. 新增 app.cleanup_export_jobs()：7 天前完成（coalesce(finished_at, created_at)）的
--      done 任务 content 置空（size_bytes 保留；status 保持 done——内容即过期标记），
--      download_export 对 content 为空或超期的任务一并拒绝；返回清理行数。
--   2. download_export 过期基准改 coalesce(finished_at, created_at)。
--   3. pg_cron：cleanup-export-jobs 每天 03:30（pg_cron 统一 UTC 语义）+
--      system 平台登记处登记（INDEX 规则 5）。
-- 依赖：20261004210000（export_jobs / download_export 当前版）、20261005080000（register_cron_job）。

-- ---------------------------------------------------------------------------
-- 1. app.cleanup_export_jobs：清理 7 天前完成的导出内容
-- ---------------------------------------------------------------------------
create function app.cleanup_export_jobs()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cleaned integer;
begin
  update public.export_jobs
     set content = null
   where status = 'done'
     and content is not null
     and coalesce(finished_at, created_at) <= now() - interval '7 days';

  get diagnostics v_cleaned = row_count;
  return v_cleaned;
end;
$$;

comment on function app.cleanup_export_jobs() is
  '清理 7 天前完成的导出任务内容（content 置空，size_bytes 保留；status 保持 done）：'
  'download_export 对 content 为空或超期的任务拒绝下载；返回清理行数；'
  '仅 pg_cron 可达（不 GRANT API 角色，INDEX 规则 10）';

revoke all on function app.cleanup_export_jobs()
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. app.download_export：过期基准修正（coalesce(finished_at, created_at)）+ 内容已清理拒绝
-- ---------------------------------------------------------------------------

create or replace function app.download_export(p_job_id uuid)
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

  -- exports.md 功能需求 3：完成后 7 天内可下载（基准 finished_at，缺失回退 created_at）；
  -- 超期内容由 app.cleanup_export_jobs 定时清空（content is null），两条路径同样拒绝（E-2）。
  if v_job.content is null
     or coalesce(v_job.finished_at, v_job.created_at) <= now() - interval '7 days' then
    raise exception '导出文件已过期（完成后 7 天内可下载）' using errcode = 'P0001';
  end if;

  return v_job.content;
end;
$$;

comment on function app.download_export(uuid) is
  '下载导出 CSV（属主或 admin）：校验 status=done 且完成时间（finished_at，缺失回退 '
  'created_at）在 7 天内；content 为空（已由 cleanup_export_jobs 清理）同样拒绝；'
  'content 不做表级暴露，只能经本 RPC 读取；不直接 GRANT API 角色（INDEX 规则 10）';

-- ---------------------------------------------------------------------------
-- 3. pg_cron：cleanup-export-jobs 注册 + 平台登记
-- ---------------------------------------------------------------------------
select app.register_cron_job(
  'cleanup-export-jobs', 'report', '30 3 * * *', 'Asia/Shanghai', '/report/exports'
);

do $$
begin
  if to_regprocedure('cron.schedule(text,text,text)') is null then
    raise exception 'pg_cron 未安装，无法注册导出清理任务' using errcode = '0A000';
  end if;

  -- 03:30（pg_cron 统一 UTC 语义；业务时区展示登记为 Asia/Shanghai，同静态 job 先例）
  perform cron.schedule(
    'cleanup-export-jobs',
    '30 3 * * *',
    $cron$select app.cleanup_export_jobs()$cron$
  );
end;
$$;
