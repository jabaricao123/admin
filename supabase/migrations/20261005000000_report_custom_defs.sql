-- 报表中心 · 自定义报表定义与白名单执行层（工单 report/002 + report/003）
-- 契约：
--   docs/modules/report/custom.md —— report_definitions / report_allowed_views / run_report
--     「标识符（表/字段/分组/排序）仅取自白名单映射表，值全部参数化」；
--   docs/modules/INDEX.md 规则 1（共享数据只经公开面）、规则 10（内部实现不直接 GRANT API
--     角色）、模块 RLS 边界速查（report：写入仅经 SECURITY DEFINER RPC，owner/admin；
--     public 报表全员可读）。
--
-- 组成：
--   1. report_allowed_views：白名单映射表（view_name PK；allowed_columns = {"列名":"PG 类型"}）；
--      seed：departments_v（org 公开视图）、audit_operations_v（audit 公开视图）；
--   2. report_definitions：报表定义（config = {dimensions, metrics, filters, chart}；private/public）；
--   3. app.validate_report_config：config 结构 + 标识符白名单 + 操作符校验（保存与执行共用）；
--   4. app.run_report / public.run_report：聚合执行（group by 维度 + count/sum/avg 度量）。
--      **SECURITY INVOKER**（关键取舍）：动态 SQL 以调用者身份执行，底层 security_invoker
--      视图的 RLS 自动生效；PG 禁止 SECURITY DEFINER 函数内 SET ROLE，因此不做 definer +
--      身份注入。为让 invoker 链成立，app.run_report / app.validate_report_config 显式
--      GRANT authenticated（见第 7 节注释），public.run_report 同样是 SECURITY INVOKER
--      （若包装层用 definer，动态 SQL 会以 postgres 执行而绕过 RLS）。
--   5. 管理 RPC：save / delete / publish / register_allowed_view（SECURITY DEFINER +
--      函数内显式 owner/admin 校验 + 审计摘要）。
--   6. RLS 与授权：definitions 无表级写；allowed_views 登录可读、仅 RPC 写。
--
-- 依赖：public.departments_v（org/001-002）、public.audit_operations_v（audit/003）、
--       app.current_role()（access/003 已 replace）、app.audit_log（audit/001）、
--       app.set_updated_at（org/001）、public.profiles。

-- ---------------------------------------------------------------------------
-- 1. report_allowed_views：白名单映射表
--    allowed_columns 形如 {"name":"text","created_at":"timestamptz"}；
--    run_report 的标识符与类型转换只依赖本表（列名进 format('%I')，类型来自固定白名单集合）。
-- ---------------------------------------------------------------------------
create table public.report_allowed_views (
  view_name       text primary key,
  allowed_columns jsonb not null,
  registered_by   uuid references public.profiles (id) on delete set null,
  created_at      timestamptz not null default now(),
  constraint report_allowed_views_name_format
    check (view_name ~ '^[a-z][a-z0-9_]*$'),
  constraint report_allowed_views_columns_object
    check (jsonb_typeof(allowed_columns) = 'object' and allowed_columns <> '{}'::jsonb)
);

comment on table public.report_allowed_views is
  '报表白名单映射表：登记可用于自定义报表的公开视图与列清单；'
  '新视图注册 = 本表登记（register_allowed_view）+ docs/modules/INDEX.md 公开面登记（两步）';
comment on column public.report_allowed_views.view_name is '白名单视图名（public schema，PK；须真实存在且为 v/m 视图）';
comment on column public.report_allowed_views.allowed_columns is
  '可引用列清单 {"列名":"PG 类型"}；列名仅作标识符，类型仅取函数内固定白名单枚举';
comment on column public.report_allowed_views.registered_by is '登记人（admin）；seed 行为 NULL';

-- seed：org 部门视图 + audit 操作日志视图（本工单 003 的执行层直接消费）
insert into public.report_allowed_views (view_name, allowed_columns)
values
  ('departments_v', jsonb_build_object(
    'name', 'text',
    'path', 'text',
    'depth', 'integer',
    'status', 'text',
    'sort_order', 'integer',
    'leader_id', 'uuid',
    'created_at', 'timestamptz'
  )),
  ('audit_operations_v', jsonb_build_object(
    'module', 'text',
    'action', 'text',
    'actor_name', 'text',
    'object_type', 'text',
    'object_id', 'text',
    'created_at', 'timestamptz'
  ))
on conflict (view_name) do nothing;

-- ---------------------------------------------------------------------------
-- 2. report_definitions：报表定义
--    config = {dimensions:[列], metrics:[{column, agg}], filters:[{column, op, value}],
--              chart:'table'|'bar'|'line'|'pie'}
-- ---------------------------------------------------------------------------
create table public.report_definitions (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  source_view text not null references public.report_allowed_views (view_name),
  config      jsonb not null
              default '{"dimensions":[],"metrics":[],"filters":[],"chart":"table"}'::jsonb,
  visibility  text not null default 'private'
              constraint report_definitions_visibility_check
              check (visibility in ('private', 'public')),
  owner_id    uuid not null references public.profiles (id),
  created_by  uuid references public.profiles (id) on delete set null,
  updated_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint report_definitions_name_not_blank check (btrim(name) <> ''),
  constraint report_definitions_config_object check (jsonb_typeof(config) = 'object'),
  constraint report_definitions_chart_check
    check (coalesce(config ->> 'chart', 'table') in ('table', 'bar', 'line', 'pie'))
);

comment on table public.report_definitions is
  '自定义报表定义（custom.md 数据模型）：写入仅经 SECURITY DEFINER RPC，表级无 API 写权限；'
  'visibility=private 仅 owner（与 admin），public 全员可读，分享链接数据仍按访问者 RLS 过滤';
comment on column public.report_definitions.source_view is '数据源：report_allowed_views.view_name（白名单外视图无法保存）';
comment on column public.report_definitions.config is
  '报表配置：dimensions/metrics/filters/chart；标识符须在白名单内，筛选值执行时参数化';
comment on column public.report_definitions.visibility is '可见性：private 仅 owner/admin，public 全员可读；转 public 仅 admin（publish RPC）';
comment on column public.report_definitions.owner_id is '属主（创建者）；仅 owner/admin 可改删';

create index report_definitions_owner_idx on public.report_definitions (owner_id);
create index report_definitions_public_idx
  on public.report_definitions (visibility)
  where visibility = 'public';

create trigger report_definitions_set_updated_at
before update on public.report_definitions
for each row
execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. app.validate_report_config：结构 + 标识符白名单 + 操作符/类型校验
--    保存（save_report_definition）与执行（run_report）共用；任何不在白名单的
--    表/列/聚合/操作符一律 raise（防注入第一道闸）。
-- ---------------------------------------------------------------------------
create function app.validate_report_config(
  p_source_view text,
  p_config      jsonb
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c_types   constant text[] := array[
    'text', 'integer', 'bigint', 'numeric', 'double precision',
    'boolean', 'uuid', 'date', 'timestamptz'
  ];
  v_allowed jsonb;
  v_dims    jsonb;
  v_metrics jsonb;
  v_filters jsonb;
  v_chart   text;
  v_dim     jsonb;
  v_metric  jsonb;
  v_filter  jsonb;
  v_col     text;
  v_type    text;
  v_agg     text;
  v_op      text;
  v_outputs text[] := array[]::text[];
  v_alias   text;
begin
  if p_source_view is null then
    raise exception '数据源不能为空' using errcode = '22023';
  end if;

  select allowed_columns into v_allowed
  from public.report_allowed_views
  where view_name = p_source_view;

  if not found then
    raise exception '数据源不在白名单：%', p_source_view using errcode = '42501';
  end if;

  if p_config is null or jsonb_typeof(p_config) <> 'object' then
    raise exception 'config 必须为 jsonb 对象' using errcode = '22023';
  end if;

  v_dims    := coalesce(p_config -> 'dimensions', '[]'::jsonb);
  v_metrics := coalesce(p_config -> 'metrics', '[]'::jsonb);
  v_filters := coalesce(p_config -> 'filters', '[]'::jsonb);
  v_chart   := coalesce(p_config ->> 'chart', 'table');

  if jsonb_typeof(v_dims) <> 'array'
     or jsonb_typeof(v_metrics) <> 'array'
     or jsonb_typeof(v_filters) <> 'array' then
    raise exception 'config 的 dimensions/metrics/filters 必须为数组' using errcode = '22023';
  end if;

  if v_chart not in ('table', 'bar', 'line', 'pie') then
    raise exception '不支持的图表类型：%', v_chart using errcode = '22023';
  end if;

  if jsonb_array_length(v_dims) = 0 and jsonb_array_length(v_metrics) = 0 then
    raise exception '至少需要一个维度或度量' using errcode = '22023';
  end if;

  -- 维度：字符串且在白名单内；输出名唯一
  for v_dim in select * from jsonb_array_elements(v_dims)
  loop
    if jsonb_typeof(v_dim) <> 'string' then
      raise exception '维度必须为字符串列名' using errcode = '22023';
    end if;
    v_col := v_dim #>> '{}';
    if not (v_allowed ? v_col) then
      raise exception '维度不在白名单：%', v_col using errcode = '42501';
    end if;
    if not ((v_allowed ->> v_col) = any (c_types)) then
      raise exception '列类型不受支持：%', v_col using errcode = '22023';
    end if;
    if v_col = any (v_outputs) then
      raise exception '维度重复：%', v_col using errcode = '22023';
    end if;
    v_outputs := v_outputs || v_col;
  end loop;

  -- 度量：{column, agg}；agg ∈ count/sum/avg；sum/avg 仅数值列；别名 <agg>_<column> 唯一
  for v_metric in select * from jsonb_array_elements(v_metrics)
  loop
    if jsonb_typeof(v_metric) <> 'object' then
      raise exception '度量必须为 {column, agg} 对象' using errcode = '22023';
    end if;

    v_col := v_metric ->> 'column';
    if v_col is null or not (v_allowed ? v_col) then
      raise exception '度量列不在白名单：%', coalesce(v_col, 'NULL') using errcode = '42501';
    end if;

    v_agg := lower(coalesce(v_metric ->> 'agg', 'count'));
    if v_agg not in ('count', 'sum', 'avg') then
      raise exception '不支持的聚合：%', v_agg using errcode = '22023';
    end if;

    v_type := v_allowed ->> v_col;
    if not (v_type = any (c_types)) then
      raise exception '列类型不受支持：%', v_col using errcode = '22023';
    end if;
    if v_agg in ('sum', 'avg')
       and v_type not in ('integer', 'bigint', 'numeric', 'double precision') then
      raise exception '聚合 % 仅支持数值列：%', v_agg, v_col using errcode = '22023';
    end if;

    v_alias := v_agg || '_' || v_col;
    if v_alias = any (v_outputs) then
      raise exception '度量别名冲突：%', v_alias using errcode = '22023';
    end if;
    v_outputs := v_outputs || v_alias;
  end loop;

  -- 筛选：{column, op, value}；op ∈ =, <>, in, between, like, ilike, >, >=, <, <=
  for v_filter in select * from jsonb_array_elements(v_filters)
  loop
    if jsonb_typeof(v_filter) <> 'object' then
      raise exception '筛选条件必须为 {column, op, value} 对象' using errcode = '22023';
    end if;

    v_col := v_filter ->> 'column';
    if v_col is null or not (v_allowed ? v_col) then
      raise exception '筛选列不在白名单：%', coalesce(v_col, 'NULL') using errcode = '42501';
    end if;
    if not ((v_allowed ->> v_col) = any (c_types)) then
      raise exception '列类型不受支持：%', v_col using errcode = '22023';
    end if;

    v_op := lower(coalesce(v_filter ->> 'op', '='));
    if v_op not in ('=', '<>', 'in', 'between', 'like', 'ilike', '>', '>=', '<', '<=') then
      raise exception '不支持的筛选操作符：%', v_op using errcode = '22023';
    end if;

    if not (v_filter ? 'value') then
      raise exception '筛选条件缺少 value' using errcode = '22023';
    end if;

    if v_op = 'in' and jsonb_typeof(v_filter -> 'value') <> 'array' then
      raise exception 'in 操作符的 value 必须为数组' using errcode = '22023';
    end if;

    if v_op = 'between'
       and (jsonb_typeof(v_filter -> 'value') <> 'array'
            or jsonb_array_length(v_filter -> 'value') <> 2) then
      raise exception 'between 操作符的 value 必须为二元数组' using errcode = '22023';
    end if;
  end loop;
end;
$$;

comment on function app.validate_report_config(text, jsonb) is
  '报表 config 校验：结构/白名单列/聚合/操作符/输出名唯一；保存与执行共用（执行时复检防直改库）';

-- ---------------------------------------------------------------------------
-- 4. app.run_report：按定义执行聚合查询
--    - 权限：定义须 owner、public 或 admin（RLS SELECT 已过滤，函数内再显式复检）；
--    - 标识符：视图名来自 report_definitions.source_view（FK + 白名单），列名/类型来自
--      report_allowed_views.allowed_columns，全部经 format('%I', ...) 引用；
--    - 值：筛选值原样放进单个 jsonb 参数 $1，动态 SQL 只引用 ($1::jsonb -> 序号)，
--      不拼接任何用户输入（注入串只当值处理）；
--    - 身份：SECURITY INVOKER → 底层 security_invoker 视图的 RLS 按调用者过滤。
-- ---------------------------------------------------------------------------
create function app.run_report(p_def_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  c_max_rows constant integer := 1000; -- 结果行上限（聚合后），防超大 payload
  c_types    constant text[] := array[
    'text', 'integer', 'bigint', 'numeric', 'double precision',
    'boolean', 'uuid', 'date', 'timestamptz'
  ];
  v_uid      uuid := (select auth.uid());
  v_role     public.user_role := (select app.current_role());
  v_def      public.report_definitions;
  v_allowed  jsonb;
  v_dims     jsonb;
  v_metrics  jsonb;
  v_filters  jsonb;
  v_chart    text;
  v_selects  text[] := array[]::text[];
  v_groups   text[] := array[]::text[];
  v_where    text[] := array[]::text[];
  v_headers  text[] := array[]::text[];
  v_values   jsonb := '[]'::jsonb;
  v_dim      jsonb;
  v_metric   jsonb;
  v_filter   jsonb;
  v_col      text;
  v_type     text;
  v_agg      text;
  v_op       text;
  v_alias    text;
  v_idx      integer;
  v_sql      text;
  v_rows     jsonb;
begin
  if p_def_id is null then
    raise exception '报表 ID 不能为空' using errcode = '22023';
  end if;

  -- 定义读取：RLS（owner / public / admin）决定可见性
  select * into v_def
  from public.report_definitions
  where id = p_def_id;

  if not found then
    raise exception '报表定义不存在或无权访问' using errcode = 'P0002';
  end if;

  -- 显式复检（防御 RLS 被绕过/策略变更；函数以 definer 身份被直接调用的场景）
  if v_def.visibility <> 'public'
     and v_def.owner_id is distinct from v_uid
     and v_role is distinct from 'admin' then
    raise exception '无权执行该报表定义' using errcode = '42501';
  end if;

  -- 执行时复检：config 可能被直改库绕过保存校验；同时取回白名单
  perform app.validate_report_config(v_def.source_view, v_def.config);

  select allowed_columns into v_allowed
  from public.report_allowed_views
  where view_name = v_def.source_view;

  v_dims    := coalesce(v_def.config -> 'dimensions', '[]'::jsonb);
  v_metrics := coalesce(v_def.config -> 'metrics', '[]'::jsonb);
  v_filters := coalesce(v_def.config -> 'filters', '[]'::jsonb);
  v_chart   := coalesce(v_def.config ->> 'chart', 'table');

  -- 维度 → select/group by
  for v_dim in select * from jsonb_array_elements(v_dims)
  loop
    v_col := v_dim #>> '{}';
    v_selects := v_selects || format('%I', v_col);
    v_groups  := v_groups || format('%I', v_col);
    v_headers := v_headers || v_col;
  end loop;

  -- 度量 → agg("列") as "agg_列"
  for v_metric in select * from jsonb_array_elements(v_metrics)
  loop
    v_col   := v_metric ->> 'column';
    v_agg   := lower(coalesce(v_metric ->> 'agg', 'count'));
    v_alias := v_agg || '_' || v_col;
    v_selects := v_selects || format('%s(%I) as %I', v_agg, v_col, v_alias);
    v_headers := v_headers || v_alias;
  end loop;

  -- 筛选 → 值进 $1（jsonb 数组），标识符/类型/序号进 SQL 文本
  for v_filter in select * from jsonb_array_elements(v_filters)
  loop
    v_col  := v_filter ->> 'column';
    v_op   := lower(coalesce(v_filter ->> 'op', '='));
    v_type := v_allowed ->> v_col;

    v_values := v_values || jsonb_build_array(v_filter -> 'value');
    v_idx := jsonb_array_length(v_values) - 1;

    if v_op = 'in' then
      -- 值数组参数化：jsonb -> idx 取数组，元素文本逐个比较
      v_where := v_where || format(
        '(%I)::text = any (select jsonb_array_elements_text(($1::jsonb) -> %s))',
        v_col, v_idx
      );
    elsif v_op = 'between' then
      v_where := v_where || format(
        '(%I)::%s between ((($1::jsonb) -> %s) ->> 0)::%s'
        || ' and ((($1::jsonb) -> %s) ->> 1)::%s',
        v_col, v_type, v_idx, v_type, v_idx, v_type
      );
    elsif v_op in ('like', 'ilike') then
      v_where := v_where || format(
        '(%I)::text %s (($1::jsonb) ->> %s)', v_col, v_op, v_idx
      );
    else
      v_where := v_where || format(
        '(%I)::%s %s (($1::jsonb) ->> %s)::%s',
        v_col, v_type, v_op, v_idx, v_type
      );
    end if;
  end loop;

  -- 视图名已由 FK/白名单约束；%I 再兜一层
  v_sql := format(
    'select coalesce(jsonb_agg(row_to_json(t)), ''[]''::jsonb) from (select %s from public.%I where %s%s limit %s) t',
    array_to_string(v_selects, ', '),
    v_def.source_view,
    case when cardinality(v_where) = 0
         then 'true'
         else array_to_string(v_where, ' and ') end,
    case when cardinality(v_groups) = 0
         then ''
         else format(' group by %s order by %s',
                     array_to_string(v_groups, ', '),
                     array_to_string(v_groups, ', ')) end,
    c_max_rows
  );

  execute v_sql into v_rows using v_values;

  return jsonb_build_object(
    'columns', to_jsonb(v_headers),
    'rows', v_rows,
    'chart', to_jsonb(v_chart)
  );
end;
$$;

comment on function app.run_report(uuid) is
  '执行报表定义：维度 group by + count/sum/avg 度量，返回 {columns, rows, chart}；'
  '标识符仅取 report_allowed_views（视图名 FK + format 的 %I 转义），筛选值全部经 $1 参数化；'
  'SECURITY INVOKER：动态 SQL 以调用者身份执行，底层 security_invoker 视图 RLS 自动生效';

-- ---------------------------------------------------------------------------
-- 5. 管理 RPC（app 实现）
-- ---------------------------------------------------------------------------

-- 5.1 保存（upsert）：id 为空新建（owner=调用者，visibility 恒 private）；
--     id 存在为更新（owner/admin 才可，visibility 不变，转 public 走 publish RPC）
create function app.save_report_definition(
  p_id          uuid,
  p_name        text,
  p_source_view text,
  p_config      jsonb
)
returns public.report_definitions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_role   public.user_role := (select app.current_role());
  v_config jsonb;
  v_row    public.report_definitions;
begin
  if v_uid is null then
    raise exception '未登录，无法保存报表定义' using errcode = '42501';
  end if;

  if p_name is null or btrim(p_name) = '' then
    raise exception '报表名称不能为空' using errcode = '22023';
  end if;

  perform app.validate_report_config(p_source_view, p_config);

  -- 规范化 config（只保留契约键），防止带入任意扩展键
  v_config := jsonb_build_object(
    'dimensions', coalesce(p_config -> 'dimensions', '[]'::jsonb),
    'metrics',    coalesce(p_config -> 'metrics', '[]'::jsonb),
    'filters',    coalesce(p_config -> 'filters', '[]'::jsonb),
    'chart',      coalesce(p_config ->> 'chart', 'table')
  );

  if p_id is null then
    insert into public.report_definitions
      (name, source_view, config, visibility, owner_id, created_by, updated_by)
    values
      (btrim(p_name), p_source_view, v_config, 'private', v_uid, v_uid, v_uid)
    returning * into v_row;

    perform app.audit_log(
      'report', 'save', 'report_definition', v_row.id::text,
      jsonb_build_object('created', true, 'name', v_row.name, 'source_view', v_row.source_view)
    );
  else
    select * into v_row
    from public.report_definitions
    where id = p_id
    for update;

    if not found then
      raise exception '报表定义不存在' using errcode = 'P0002';
    end if;

    if v_row.owner_id is distinct from v_uid
       and v_role is distinct from 'admin' then
      raise exception '无权修改该报表定义' using errcode = '42501';
    end if;

    update public.report_definitions
       set name        = btrim(p_name),
           source_view = p_source_view,
           config      = v_config,
           updated_by  = v_uid
     where id = p_id
    returning * into v_row;

    perform app.audit_log(
      'report', 'save', 'report_definition', v_row.id::text,
      jsonb_build_object('updated', true, 'name', v_row.name, 'source_view', v_row.source_view)
    );
  end if;

  return v_row;
end;
$$;

comment on function app.save_report_definition(uuid, text, text, jsonb) is
  '保存/更新报表定义（登录用户）：新建 owner=调用者且 private；更新仅 owner/admin；'
  'config 白名单校验；写审计。内部实现，经 public 薄包装暴露';

-- 5.2 删除（owner/admin）
create function app.delete_report_definition(p_def_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_role public.user_role := (select app.current_role());
  v_row  public.report_definitions;
begin
  if v_uid is null then
    raise exception '未登录，无法删除报表定义' using errcode = '42501';
  end if;

  select * into v_row
  from public.report_definitions
  where id = p_def_id
  for update;

  if not found then
    raise exception '报表定义不存在' using errcode = 'P0002';
  end if;

  if v_row.owner_id is distinct from v_uid
     and v_role is distinct from 'admin' then
    raise exception '无权删除该报表定义' using errcode = '42501';
  end if;

  delete from public.report_definitions where id = p_def_id;

  perform app.audit_log(
    'report', 'delete', 'report_definition', p_def_id::text,
    jsonb_build_object('name', v_row.name, 'visibility', v_row.visibility)
  );
end;
$$;

comment on function app.delete_report_definition(uuid) is
  '删除报表定义（owner/admin）：写审计；内部实现，经 public 薄包装暴露';

-- 5.3 发布（仅 admin：private → public；已是 public 则幂等）
create function app.publish_report_definition(p_def_id uuid)
returns public.report_definitions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.report_definitions;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可发布公共报表' using errcode = '42501';
  end if;

  update public.report_definitions
     set visibility = 'public',
         updated_by = (select auth.uid())
   where id = p_def_id
  returning * into v_row;

  if not found then
    raise exception '报表定义不存在' using errcode = 'P0002';
  end if;

  perform app.audit_log(
    'report', 'publish', 'report_definition', p_def_id::text,
    jsonb_build_object('name', v_row.name, 'owner_id', v_row.owner_id)
  );

  return v_row;
end;
$$;

comment on function app.publish_report_definition(uuid) is
  '发布为公共报表（仅 admin）：visibility=public，全员可读可执行；写审计；内部实现，经 public 薄包装暴露';

-- 5.4 登记白名单视图（仅 admin）：upsert；视图须真实存在且为 v/m 视图；列类型限固定枚举
create function app.register_allowed_view(
  p_view_name       text,
  p_allowed_columns jsonb
)
returns public.report_allowed_views
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_types constant text[] := array[
    'text', 'integer', 'bigint', 'numeric', 'double precision',
    'boolean', 'uuid', 'date', 'timestamptz'
  ];
  v_key text;
  v_val text;
  v_row public.report_allowed_views;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可登记白名单视图' using errcode = '42501';
  end if;

  if p_view_name is null or p_view_name !~ '^[a-z][a-z0-9_]*$' then
    raise exception '视图名不符合 ^[a-z][a-z0-9_]*$：%', coalesce(p_view_name, 'NULL')
      using errcode = '22023';
  end if;

  if p_allowed_columns is null
     or jsonb_typeof(p_allowed_columns) <> 'object'
     or p_allowed_columns = '{}'::jsonb then
    raise exception 'allowed_columns 必须为非空对象 {"列名":"类型"}' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = p_view_name
      and c.relkind in ('v', 'm')
  ) then
    raise exception 'public.% 不存在或不是视图', p_view_name using errcode = 'P0002';
  end if;

  for v_key, v_val in
    select t.key, t.value
    from jsonb_each_text(p_allowed_columns) as t(key, value)
  loop
    if v_key !~ '^[a-z][a-z0-9_]*$' then
      raise exception '列名不合法：%', v_key using errcode = '22023';
    end if;
    if not (v_val = any (c_types)) then
      raise exception '不支持的列类型：%', v_val using errcode = '22023';
    end if;
  end loop;

  insert into public.report_allowed_views (view_name, allowed_columns, registered_by)
  values (p_view_name, p_allowed_columns, (select auth.uid()))
  on conflict (view_name) do update
    set allowed_columns = excluded.allowed_columns,
        registered_by   = excluded.registered_by
  returning * into v_row;

  perform app.audit_log(
    'report', 'register', 'report_allowed_view', p_view_name,
    jsonb_build_object('allowed_columns', p_allowed_columns)
  );

  return v_row;
end;
$$;

comment on function app.register_allowed_view(text, jsonb) is
  '登记/更新报表白名单视图（仅 admin）：校验视图真实存在（v/m）+ 列名/类型；写审计；'
  '登记后仍须在 docs/modules/INDEX.md 公开面登记（两步）';

-- ---------------------------------------------------------------------------
-- 6. public 薄包装（PostgREST 仅暴露 public schema）
--    run_report 必须 SECURITY INVOKER：定义可见性 RLS + 数据层 RLS 都依赖调用者身份；
--    其余包装为 SECURITY DEFINER（权限判定在 app 实现内显式完成）。
-- ---------------------------------------------------------------------------
create function public.run_report(p_def_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select app.run_report(p_def_id)
$$;

comment on function public.run_report(uuid) is
  'run_report Data API 薄包装（SECURITY INVOKER，保持调用者身份执行 RLS）';

create function public.save_report_definition(
  p_id          uuid,
  p_name        text,
  p_source_view text,
  p_config      jsonb
)
returns public.report_definitions
language sql
security definer
set search_path = ''
as $$
  select app.save_report_definition(p_id, p_name, p_source_view, p_config)
$$;

comment on function public.save_report_definition(uuid, text, text, jsonb) is
  'save_report_definition Data API 薄包装（owner 校验在 app 实现内）';

create function public.delete_report_definition(p_def_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  select app.delete_report_definition(p_def_id)
$$;

comment on function public.delete_report_definition(uuid) is
  'delete_report_definition Data API 薄包装（owner/admin 校验在 app 实现内）';

create function public.publish_report_definition(p_def_id uuid)
returns public.report_definitions
language sql
security definer
set search_path = ''
as $$
  select app.publish_report_definition(p_def_id)
$$;

comment on function public.publish_report_definition(uuid) is
  'publish_report_definition Data API 薄包装（admin 校验在 app 实现内）';

create function public.register_allowed_view(
  p_view_name       text,
  p_allowed_columns jsonb
)
returns public.report_allowed_views
language sql
security definer
set search_path = ''
as $$
  select app.register_allowed_view(p_view_name, p_allowed_columns)
$$;

comment on function public.register_allowed_view(text, jsonb) is
  'register_allowed_view Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 7. RLS 与授权
-- ---------------------------------------------------------------------------
alter table public.report_allowed_views enable row level security;
alter table public.report_definitions enable row level security;

-- 白名单：登录即可读（编辑器/执行层需要）；无写策略（写仅 RPC 的 admin）
create policy report_allowed_views_select
on public.report_allowed_views
for select
to authenticated
using (true);

-- 定义：owner / public / admin 三条 SELECT；无任何写策略
create policy report_definitions_select_own
on public.report_definitions
for select
to authenticated
using ((select auth.uid()) = owner_id);

create policy report_definitions_select_public
on public.report_definitions
for select
to authenticated
using (visibility = 'public');

create policy report_definitions_select_admin
on public.report_definitions
for select
to authenticated
using ((select app.current_role()) = 'admin');

-- 表级：只读授权；无 INSERT/UPDATE/DELETE（含 admin，写全经 RPC）
revoke all on public.report_allowed_views from public, anon, authenticated, service_role;
grant select on public.report_allowed_views to authenticated;

revoke all on public.report_definitions from public, anon, authenticated, service_role;
grant select on public.report_definitions to authenticated;

-- 函数授权：默认全撤，再按调用面最小开放
revoke all on function app.validate_report_config(text, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function app.run_report(uuid)
  from public, anon, authenticated, service_role;
revoke all on function app.save_report_definition(uuid, text, text, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function app.delete_report_definition(uuid)
  from public, anon, authenticated, service_role;
revoke all on function app.publish_report_definition(uuid)
  from public, anon, authenticated, service_role;
revoke all on function app.register_allowed_view(text, jsonb)
  from public, anon, authenticated, service_role;

revoke all on function public.run_report(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.save_report_definition(uuid, text, text, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function public.delete_report_definition(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.publish_report_definition(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.register_allowed_view(text, jsonb)
  from public, anon, authenticated, service_role;

-- 用户 RPC：Data API 入口
grant execute on function public.run_report(uuid) to authenticated;
grant execute on function public.save_report_definition(uuid, text, text, jsonb) to authenticated;
grant execute on function public.delete_report_definition(uuid) to authenticated;
grant execute on function public.publish_report_definition(uuid) to authenticated;
grant execute on function public.register_allowed_view(text, jsonb) to authenticated;

-- 例外：run_report 为 SECURITY INVOKER 链路，app 实现与校验 helper 必须对
-- authenticated 可见（否则 invoker 链断在 EXECUTE 权限上）；这两个函数只读/只校验。
grant execute on function app.validate_report_config(text, jsonb) to authenticated;
grant execute on function app.run_report(uuid) to authenticated;
