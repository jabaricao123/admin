-- 审计中心 · 合规报告模块中文化（audit 批次 2 修复项 3）
-- 问题：generate_compliance_report 的「按模块分布」直接输出英文模块标识
--   （audit/org/access/...）；范围标签对 dashboard/demo 缺映射时回退原始标识。
-- 修复：create or replace 该函数——
--   * 按模块分布：已知模块标识映射中文展示名（audit 审计中心 / org 组织管理 /
--     access 权限管理 / report 报表中心 / approval 审批中心 / integration 接口集成 /
--     sync 数据同步 / system 系统管理 / message 消息中心 / dashboard 工作台 / demo 演示），
--     未知模块回退原始标识（聚合仍按原始 module 分组）；
--   * 范围标签：补 dashboard→工作台、demo→演示模块，与前端 COMPLIANCE_RANGE_OPTIONS
--     （lib/audit.ts AUDIT_MODULE_LABELS）全覆盖对齐。
-- 依赖：20261005120000_audit_compliance_reports.sql（当前版函数）。

-- ---------------------------------------------------------------------------
-- create or replace：app.generate_compliance_report（模块分布中文化 + 范围映射补齐）
-- ---------------------------------------------------------------------------
create or replace function app.generate_compliance_report(
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
    when 'dashboard'   then '工作台'
    when 'org'         then '组织管理'
    when 'access'      then '权限管理'
    when 'approval'    then '审批中心'
    when 'report'      then '报表中心'
    when 'audit'       then '审计中心'
    when 'integration' then '接口/集成'
    when 'sync'        then '数据同步'
    when 'system'      then '系统管理'
    when 'message'     then '消息中心'
    when 'demo'        then '演示模块'
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

  -- 模块分布：聚合按原始 module 标识，输出前映射中文展示名（未知回退原始标识）
  select string_agg(
           format('<tr><td>%s</td><td class="num">%s</td></tr>',
                  app.html_escape(
                    case m.module
                      when 'dashboard'   then '工作台'
                      when 'org'         then '组织管理'
                      when 'access'      then '权限管理'
                      when 'approval'    then '审批中心'
                      when 'report'      then '报表中心'
                      when 'audit'       then '审计中心'
                      when 'integration' then '接口集成'
                      when 'sync'        then '数据同步'
                      when 'system'      then '系统管理'
                      when 'message'     then '消息中心'
                      when 'demo'        then '演示'
                      else m.module
                    end
                  ), m.cnt),
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
  '「按模块分布」与范围标签输出中文展示名（未知模块回退原始标识）；'
  'SECURITY DEFINER + search_path 空 + 动态值 HTML 转义；不直接 GRANT API 角色（规则 10）';
