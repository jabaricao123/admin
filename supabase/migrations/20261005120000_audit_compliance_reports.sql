-- 审计中心 · 合规报告（工单 audit/008）
-- 契约：docs/modules/audit/compliance.md：
--   * 报告参数：周期（周/月/季度）+ 范围（全系统/指定模块）；
--   * 内容：操作总量与 Top 活跃用户、权限与角色变更摘要、登录失败摘要、数据变更量趋势；
--   * 生成：HTML + 浏览器打印（@media print 适配 A4）；PDF 经 report 导出管道留 v2；
--   * 历史归档 compliance_reports（file_content HTML 快照），文件保留 1 年，过期清理；
--   * 聚合只读，仅 admin，不受个人数据范围过滤（admin 视角全量）。
-- INDEX 规则 2（写审计摘要）、规则 5（pg_cron 统一登记）、规则 10（内部 RPC 不 GRANT）。
--
-- 落地取舍（工单交付物与子文档 file_url 的差异）：首期报告为可打印 HTML，内容直接存
--   compliance_reports.file_content（行内快照，随记录一并保留/清理）；对象存储 file_url
--   与 PDF 导出留 v2（report 导出管道已具备 CSV 通道，HTML/PDF 产物通道后续接）。
-- 组成：
--   1. public.compliance_reports：报告归档（admin 只读；写仅经 RPC）；
--   2. app.html_escape：HTML 转义 helper（防报表 XSS）；
--   3. app.generate_compliance_report：聚合 → 渲染 HTML → 归档 → 写审计；
--   4. app.cleanup_compliance_reports：1 年过期清理（pg_cron 每日）；
--   5. pg_cron：cleanup-compliance-reports（登记 system 平台登记处）。
-- 依赖：audit/003（audit_operations_v）、audit/005（audit_logins）、
--       audit/006（audit_row_versions）、app.audit_log、app.current_role、
--       system/011（app.register_cron_job）、pg_cron（report/007 已建）。

-- ---------------------------------------------------------------------------
-- 1. compliance_reports：合规报告归档
-- ---------------------------------------------------------------------------
create table public.compliance_reports (
  id           uuid primary key default gen_random_uuid(),
  period       text not null
               constraint compliance_reports_period_check
               check (period in ('week', 'month', 'quarter')),
  "range"      text not null default 'all'
               constraint compliance_reports_range_check
               check (btrim("range") <> ''),
  file_content text not null,
  generated_by uuid,
  created_at   timestamptz not null default now()
);

comment on table public.compliance_reports is
  '合规报告归档（工单 audit/008）：file_content 为可直接浏览器打印的 HTML 快照（@media print A4）；'
  'admin 只读，写入仅经 app.generate_compliance_report；保留 1 年，由 cleanup-compliance-reports 清理';
comment on column public.compliance_reports.period is '报告周期：week 周 / month 月 / quarter 季度';
comment on column public.compliance_reports."range" is
  '报告范围：all 全系统 / 模块标识（org/access/... 与 audit_operations.module 一致）';
comment on column public.compliance_reports.file_content is
  'HTML 快照（行内存储；v2 接对象存储后改存文件路径，本列保留/置空待定）';
comment on column public.compliance_reports.generated_by is
  '生成人 auth.uid()（迁移/后台为 NULL）';

create index compliance_reports_created_idx
  on public.compliance_reports (created_at desc, id desc);

alter table public.compliance_reports enable row level security;

-- ---------------------------------------------------------------------------
-- 2. app.html_escape：HTML 文本转义（& 优先，防聚合值注入标签）
-- ---------------------------------------------------------------------------
create function app.html_escape(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select replace(
           replace(
             replace(
               replace(
                 replace(coalesce(p_text, ''), '&', '&amp;'),
                 '<', '&lt;'),
               '>', '&gt;'),
             '"', '&quot;'),
           '''', '&#39;')
$$;

comment on function app.html_escape(text) is
  'HTML 文本转义（& < > " ''；& 优先）；报告模板拼接前必须对动态值调用；不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 3. app.generate_compliance_report：聚合 + HTML 渲染 + 归档 + 审计
--    周期 = 当前周期至今（周/月/季度的 date_trunc 起点 → now()）；
--    范围过滤作用于操作/权限/变更量；登录摘要为全系统口径（audit_logins 无模块维度）。
-- ---------------------------------------------------------------------------
create function app.generate_compliance_report(
  p_period text,
  p_range  text default 'all'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_tz          constant text := 'Asia/Shanghai';
  v_uid         uuid := (select auth.uid());
  v_period      text := lower(btrim(coalesce(p_period, '')));
  v_range       text := lower(btrim(coalesce(nullif(p_range, ''), 'all')));
  v_start       timestamptz;
  v_end         timestamptz := now();
  v_period_lbl  text;
  v_range_lbl   text;
  v_actor       text;
  v_total       bigint := 0;
  v_module_rows text;
  v_top_rows    text;
  v_perm_total  bigint := 0;
  v_perm_rows   text;
  v_login_total bigint := 0;
  v_login_fail  bigint := 0;
  v_login_rows  text;
  v_change_total bigint := 0;
  v_trend_rows  text;
  v_html        text;
  v_id          uuid;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可生成合规报告' using errcode = '42501';
  end if;

  if v_period not in ('week', 'month', 'quarter') then
    raise exception '周期不合法（week/month/quarter）：%', coalesce(p_period, '(null)')
      using errcode = '22023';
  end if;

  if v_range <> 'all' and v_range !~ '^[a-z][a-z0-9_]*$' then
    raise exception '范围不合法：%', v_range using errcode = '22023';
  end if;

  v_start := case v_period
    when 'week'    then date_trunc('week', now())
    when 'month'   then date_trunc('month', now())
    else                date_trunc('quarter', now())
  end;

  v_period_lbl := case v_period
    when 'week'  then '周报'
    when 'month' then '月报'
    else              '季度报'
  end;

  v_range_lbl := case v_range
    when 'all'         then '全系统'
    when 'org'         then '组织管理'
    when 'access'      then '权限管理'
    when 'approval'    then '审批中心'
    when 'report'      then '报表中心'
    when 'audit'       then '审计中心'
    when 'integration' then '接口/集成'
    when 'sync'        then '数据同步'
    when 'system'      then '系统管理'
    when 'message'     then '消息中心'
    else                    v_range
  end;

  select p.full_name into v_actor
  from public.profiles p
  where p.id = v_uid;
  v_actor := coalesce(v_actor, '系统/后台');

  -- ------------------------------------------------------------------
  -- 3.1 操作总量 / 模块分布 / Top 活跃用户
  -- ------------------------------------------------------------------
  select count(*)::bigint into v_total
  from public.audit_operations_v o
  where o.created_at >= v_start
    and o.created_at <= v_end
    and (v_range = 'all' or o.module = v_range);

  select string_agg(
           format('<tr><td>%s</td><td class="num">%s</td></tr>',
                  app.html_escape(m.module), m.cnt),
           '' order by m.cnt desc, m.module
         )
    into v_module_rows
  from (
    select o.module, count(*)::bigint as cnt
    from public.audit_operations_v o
    where o.created_at >= v_start
      and o.created_at <= v_end
      and (v_range = 'all' or o.module = v_range)
    group by o.module
  ) m;

  select string_agg(
           format('<tr><td>%s</td><td class="num">%s</td></tr>',
                  app.html_escape(t.actor), t.cnt),
           '' order by t.cnt desc, t.actor
         )
    into v_top_rows
  from (
    select coalesce(o.actor_name, '系统/后台') as actor, count(*)::bigint as cnt
    from public.audit_operations_v o
    where o.created_at >= v_start
      and o.created_at <= v_end
      and (v_range = 'all' or o.module = v_range)
    group by 1
    order by cnt desc, actor
    limit 10
  ) t;

  -- ------------------------------------------------------------------
  -- 3.2 权限与角色变更摘要（access 模块的授权类动作）
  -- ------------------------------------------------------------------
  select count(*)::bigint into v_perm_total
  from public.audit_operations_v o
  where o.created_at >= v_start
    and o.created_at <= v_end
    and (v_range = 'all' or o.module = v_range)
    and o.module = 'access'
    and o.action in ('assign', 'create', 'update', 'delete', 'revoke', 'enable', 'disable');

  select string_agg(
           format('<tr><td>%s</td><td class="num">%s</td></tr>',
                  app.html_escape(a.action), a.cnt),
           '' order by a.cnt desc, a.action
         )
    into v_perm_rows
  from (
    select
      case o.action
        when 'assign' then '分配角色'
        when 'create' then '新建'
        when 'update' then '修改'
        when 'delete' then '删除'
        when 'revoke' then '吊销'
        when 'enable' then '启用'
        when 'disable' then '停用'
        else o.action
      end as action,
      count(*)::bigint as cnt
    from public.audit_operations_v o
    where o.created_at >= v_start
      and o.created_at <= v_end
      and (v_range = 'all' or o.module = v_range)
      and o.module = 'access'
      and o.action in ('assign', 'create', 'update', 'delete', 'revoke', 'enable', 'disable')
    group by 1
  ) a;

  -- ------------------------------------------------------------------
  -- 3.3 登录失败摘要（全系统口径）
  -- ------------------------------------------------------------------
  select count(*)::bigint,
         count(*) filter (where not l.success)::bigint
    into v_login_total, v_login_fail
  from public.audit_logins l
  where l.created_at >= v_start
    and l.created_at <= v_end;

  select string_agg(
           format('<tr><td>%s</td><td class="num">%s</td></tr>',
                  app.html_escape(f.reason), f.cnt),
           '' order by f.cnt desc, f.reason
         )
    into v_login_rows
  from (
    select
      case l.fail_reason
        when 'invalid_credentials' then '邮箱或密码错误'
        when 'user_banned' then '账号已禁用'
        when 'other' then '其他原因'
        else '未归类'
      end as reason,
      count(*)::bigint as cnt
    from public.audit_logins l
    where l.created_at >= v_start
      and l.created_at <= v_end
      and not l.success
    group by 1
  ) f;

  -- ------------------------------------------------------------------
  -- 3.4 数据变更量趋势（audit_row_versions 按日；范围映射到首期白名单表）
  -- ------------------------------------------------------------------
  select count(*)::bigint into v_change_total
  from public.audit_row_versions v
  where v.changed_at >= v_start
    and v.changed_at <= v_end
    and (
      v_range = 'all'
      or (v_range = 'org'
          and v.table_name = any (array['profiles', 'departments', 'positions']))
    );

  select string_agg(
           format('<tr><td>%s</td><td class="num">%s</td></tr>',
                  to_char(d.day, 'YYYY-MM-DD'), d.cnt),
           '' order by d.day
         )
    into v_trend_rows
  from (
    select (v.changed_at at time zone c_tz)::date as day, count(*)::bigint as cnt
    from public.audit_row_versions v
    where v.changed_at >= v_start
      and v.changed_at <= v_end
      and (
        v_range = 'all'
        or (v_range = 'org'
            and v.table_name = any (array['profiles', 'departments', 'positions']))
      )
    group by 1
  ) d;

  -- ------------------------------------------------------------------
  -- 3.5 HTML 渲染（SQL 字符串拼接；动态值经 app.html_escape 转义）
  -- ------------------------------------------------------------------
  v_html := '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">'
         || '<title>合规报告</title><style>'
         || 'body{margin:0;padding:24px;color:#18181b;font-size:13px;line-height:1.6;'
         || 'font-family:"PingFang SC","Microsoft YaHei",-apple-system,"Segoe UI",sans-serif}'
         || 'h1{font-size:22px;margin:0 0 6px}'
         || 'h2{font-size:15px;margin:22px 0 8px;border-left:4px solid #2aaf50;padding-left:8px}'
         || 'h3{font-size:13px;margin:14px 0 4px;color:#3f3f46}'
         || '.meta{color:#52525b;font-size:12px;margin-bottom:12px}'
         || '.meta span{margin-right:16px;white-space:nowrap}'
         || '.kpi{display:flex;flex-wrap:wrap;gap:12px;margin:8px 0}'
         || '.kpi div{border:1px solid #d4d4d8;border-radius:6px;padding:8px 14px;min-width:140px}'
         || '.kpi span{display:block;color:#71717a;font-size:12px}'
         || '.kpi b{font-size:20px}'
         || 'table{width:100%;border-collapse:collapse;margin-top:6px}'
         || 'th,td{border:1px solid #d4d4d8;padding:5px 8px;text-align:left}'
         || 'th{background:#f4f4f5;font-weight:600}'
         || 'td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}'
         || '.empty{color:#a1a1aa;padding:6px 0}'
         || '.footer{margin-top:24px;color:#71717a;font-size:11px;border-top:1px solid #e4e4e7;padding-top:8px}'
         || '@media print{@page{size:A4;margin:14mm}body{padding:0}'
         || 'h2,h3{break-inside:avoid}tr{break-inside:avoid}}'
         || '</style></head><body>';

  v_html := v_html || '<h1>合规报告</h1>';

  v_html := v_html || '<div class="meta">'
         || '<span>周期：' || app.html_escape(v_period_lbl)
         || '（' || to_char(v_start at time zone c_tz, 'YYYY-MM-DD')
         || ' 至 ' || to_char(v_end at time zone c_tz, 'YYYY-MM-DD') || '）</span>'
         || '<span>范围：' || app.html_escape(v_range_lbl) || '</span>'
         || '<span>生成时间：' || to_char(v_end at time zone c_tz, 'YYYY-MM-DD HH24:MI') || '</span>'
         || '<span>生成人：' || app.html_escape(v_actor) || '</span>'
         || '</div>';

  -- 一、操作总量与 Top 活跃用户
  v_html := v_html || '<h2>一、操作总量与 Top 活跃用户</h2>'
         || '<div class="kpi">'
         || '<div><span>操作总量</span><b>' || v_total || '</b></div>'
         || '<div><span>登录总次数</span><b>' || v_login_total || '</b></div>'
         || '<div><span>登录失败</span><b>' || v_login_fail || '</b></div>'
         || '<div><span>数据变更量</span><b>' || v_change_total || '</b></div>'
         || '</div>';

  v_html := v_html || '<h3>按模块分布</h3>'
         || case when v_module_rows is null
                 then '<div class="empty">本周期内无操作记录</div>'
                 else '<table><thead><tr><th>模块</th><th class="num">操作数</th></tr></thead><tbody>'
                      || v_module_rows || '</tbody></table>'
            end;

  v_html := v_html || '<h3>Top 活跃用户</h3>'
         || case when v_top_rows is null
                 then '<div class="empty">本周期内无操作记录</div>'
                 else '<table><thead><tr><th>操作人</th><th class="num">操作数</th></tr></thead><tbody>'
                      || v_top_rows || '</tbody></table>'
            end;

  -- 二、权限与角色变更摘要
  v_html := v_html || '<h2>二、权限与角色变更摘要</h2>'
         || '<div class="kpi"><div><span>权限类变更</span><b>' || v_perm_total || '</b></div></div>'
         || case when v_perm_rows is null
                 then '<div class="empty">本周期内无权限/角色变更</div>'
                 else '<table><thead><tr><th>动作</th><th class="num">次数</th></tr></thead><tbody>'
                      || v_perm_rows || '</tbody></table>'
            end;

  -- 三、登录失败摘要
  v_html := v_html || '<h2>三、登录失败摘要</h2>'
         || '<div class="kpi"><div><span>失败次数</span><b>' || v_login_fail || '</b></div></div>'
         || case when v_login_rows is null
                 then '<div class="empty">本周期内无登录失败</div>'
                 else '<table><thead><tr><th>失败原因</th><th class="num">次数</th></tr></thead><tbody>'
                      || v_login_rows || '</tbody></table>'
            end;

  -- 四、数据变更量趋势
  v_html := v_html || '<h2>四、数据变更量趋势</h2>'
         || case when v_trend_rows is null
                 then '<div class="empty">本周期内无数据变更快照</div>'
                 else '<table><thead><tr><th>日期</th><th class="num">变更快照数</th></tr></thead><tbody>'
                      || v_trend_rows
                      || '<tr><td>合计</td><td class="num">' || v_change_total || '</td></tr>'
                      || '</tbody></table>'
            end;

  v_html := v_html || '<div class="footer">'
         || '本报告由系统自动生成，聚合口径与审计明细页一致；'
         || '登录摘要为全系统口径，不受模块范围过滤；报告保留 1 年，过期自动清理。'
         || '</div></body></html>';

  insert into public.compliance_reports (period, "range", file_content, generated_by)
  values (v_period, v_range, v_html, v_uid)
  returning id into v_id;

  perform app.audit_log(
    'audit', 'create', 'compliance_report', v_id::text,
    jsonb_build_object(
      'period', v_period,
      'range', v_range,
      'start', v_start,
      'end', v_end,
      'total_operations', v_total,
      'login_failed', v_login_fail,
      'data_changes', v_change_total
    )
  );

  return v_id;
end;
$$;

comment on function app.generate_compliance_report(text, text) is
  '生成合规报告（admin）：按周期（week/month/quarter）与范围（all/模块）聚合 '
  'audit_operations_v / audit_logins / audit_row_versions，渲染可打印 HTML（@media print A4）'
  '存入 compliance_reports.file_content，写审计摘要并返回报告 id；'
  'SECURITY DEFINER + search_path 空 + 动态值 HTML 转义；不直接 GRANT API 角色（规则 10）';

-- ---------------------------------------------------------------------------
-- 4. app.cleanup_compliance_reports：1 年过期清理（pg_cron 每日；登记表登记）
-- ---------------------------------------------------------------------------
create function app.cleanup_compliance_reports(p_retention_days integer default 365)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_days    integer := greatest(coalesce(p_retention_days, 365), 1);
  v_deleted integer;
begin
  delete from public.compliance_reports
   where created_at < now() - make_interval(days => v_days);

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

comment on function app.cleanup_compliance_reports(integer) is
  '合规报告过期清理（默认 365 天；返回删除条数）：security invoker + 撤销 API 角色执行权，'
  '仅 pg_cron 的 postgres 可达（同 report/007 worker 模式）';

-- ---------------------------------------------------------------------------
-- 5. public 薄包装（PostgREST 仅暴露 public schema；INDEX 规则 10）
-- ---------------------------------------------------------------------------
create function public.generate_compliance_report(
  p_period text,
  p_range  text default 'all'
)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select app.generate_compliance_report(p_period, p_range)
$$;

comment on function public.generate_compliance_report(text, text) is
  'generate_compliance_report Data API 薄包装（admin 校验与聚合在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 6. 授权：报告 admin 只读；生成 RPC 仅 authenticated（函数内 admin 校验）；
--    helper/清理函数不 GRANT（规则 10）
-- ---------------------------------------------------------------------------
revoke all on public.compliance_reports from public, anon, authenticated, service_role;
grant select on public.compliance_reports to authenticated;

create policy compliance_reports_select_admin
on public.compliance_reports
for select
to authenticated
using ((select app.current_role()) = 'admin');

revoke all on function app.html_escape(text)
  from public, anon, authenticated, service_role;

revoke all on function app.generate_compliance_report(text, text)
  from public, anon, authenticated, service_role;

revoke all on function app.cleanup_compliance_reports(integer)
  from public, anon, authenticated, service_role;

revoke all on function public.generate_compliance_report(text, text)
  from public, anon, service_role;
grant execute on function public.generate_compliance_report(text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 7. pg_cron：每日清理（同时登记 system 平台登记处，规则 5）
-- ---------------------------------------------------------------------------
select cron.schedule(
  'cleanup-compliance-reports',
  '40 3 * * *',
  $cron$select app.cleanup_compliance_reports()$cron$
);

select app.register_cron_job(
  'cleanup-compliance-reports', 'audit', '40 3 * * *', 'Asia/Shanghai', '/audit/compliance'
);
