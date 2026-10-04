-- report 批次 1 安全与正确性修复
-- 工单：report 审计修复批次 1（4 项）
--   1. register_allowed_view：视图必须是 security_invoker=true 的普通视图（物化视图拒绝，
--      防 RLS 绕过）；allowed_columns 的列须真实存在于视图且类型精确一致；修复类型值为
--      json null 时绕过校验的 C-3（jsonb_each_text → SQL NULL，not (NULL = any(...)) 为 NULL）。
--   2. run_report：in 操作符按列声明类型转换两侧后比较（原两端 ::text 比较会漏掉
--      timestamptz 的 ISO 串、数值串等格式差异）；=/between/like 复核后保持既有双侧转换。
--   3. app.csv_field：CSV 公式注入中和（= + - @ Tab CR 开头前缀单引号），RFC 4180 转义不回归。
--   4. delete_report_definition：删除前预检 report_subscriptions 引用（含 is_deleted=true 行），
--      >0 以中文错误拒绝并报数（FK 兜底仍在，本预检给出可读原因）。
-- 依赖：20261005000000（report_custom_defs）、20261004210000（report_export_jobs）、
--       20261005091000（report_subscriptions）。
-- 说明：仅 create or replace 既有函数，签名与授权面不变。

-- ---------------------------------------------------------------------------
-- 1. register_allowed_view：security_invoker 守卫 + 列存在/类型校验 + null 类型修复
-- ---------------------------------------------------------------------------
create or replace function app.register_allowed_view(
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
  v_relid    oid;
  v_relkind  "char";
  v_relopts  text[];
  v_key      text;
  v_val      text;
  v_atttypid oid;
  v_row      public.report_allowed_views;
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

  select c.oid, c.relkind, c.reloptions
    into v_relid, v_relkind, v_relopts
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = p_view_name;

  if v_relid is null or v_relkind not in ('v', 'm') then
    raise exception 'public.% 不存在或不是视图', p_view_name using errcode = 'P0002';
  end if;

  -- 物化视图不继承底层 RLS：即使调用者无权读取底层表，run_report 仍可全量读出 → 直接拒绝
  if v_relkind = 'm' then
    raise exception '仅允许 security_invoker 视图，防止 RLS 绕过：public.% 是物化视图',
      p_view_name using errcode = '42501';
  end if;

  -- 普通视图默认以属主身份执行：同样绕过调用者 RLS，必须显式 security_invoker=true
  if not coalesce('security_invoker=true' = any (v_relopts), false) then
    raise exception '仅允许 security_invoker 视图，防止 RLS 绕过：public.% 未设置 security_invoker=true',
      p_view_name using errcode = '42501';
  end if;

  for v_key, v_val in
    select t.key, t.value
    from jsonb_each_text(p_allowed_columns) as t(key, value)
  loop
    if v_key !~ '^[a-z][a-z0-9_]*$' then
      raise exception '列名不合法：%', v_key using errcode = '22023';
    end if;

    -- C-3：json null 经 jsonb_each_text 得到 SQL NULL，原判断 not (v_val = any(...))
    -- 结果为 NULL（非 true），错误放行；此处显式拒绝 null 类型
    if v_val is null or not (v_val = any (c_types)) then
      raise exception '不支持的列类型：%', coalesce(v_val, 'NULL') using errcode = '22023';
    end if;

    select a.atttypid into v_atttypid
    from pg_catalog.pg_attribute a
    where a.attrelid = v_relid
      and a.attname = v_key
      and a.attnum > 0
      and not a.attisdropped;

    if v_atttypid is null then
      raise exception '列不存在：public.%.%', p_view_name, v_key using errcode = '22023';
    end if;

    if v_atttypid <> (v_val)::regtype then
      raise exception '列类型不匹配：public.%.%（视图实际 %，登记 %）',
        p_view_name, v_key, pg_catalog.format_type(v_atttypid, null), v_val
        using errcode = '22023';
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
  '登记/更新报表白名单视图（仅 admin）：须为 public 下 security_invoker=true 的普通视图'
  '（物化视图/普通视图拒绝，防 RLS 绕过）；列名须真实存在且与视图列类型精确一致；写审计；'
  '登记后仍须在 docs/modules/INDEX.md 公开面登记（两步）';

comment on column public.report_allowed_views.view_name is
  '白名单视图名（public schema，PK；须真实存在且为 security_invoker=true 普通视图）';

-- ---------------------------------------------------------------------------
-- 2. run_report：in 操作符按列声明类型比较
--    - in：列与数组元素都转换为 allowed_columns 声明的类型后比较；
--    - = / between：原有实现已双侧转换为声明类型，保持一致；
--    - like / ilike：文本模式匹配，列 ::text 与文本 pattern 比较，保持一致。
-- ---------------------------------------------------------------------------
create or replace function app.run_report(p_def_id uuid)
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

    -- 直改库可绕保存校验：类型仍须在枚举内，否则动态 SQL 无法安全拼类型
    if v_type is null or not (v_type = any (c_types)) then
      raise exception '列类型不受支持：%', v_col using errcode = '22023';
    end if;

    v_values := v_values || jsonb_build_array(v_filter -> 'value');
    v_idx := jsonb_array_length(v_values) - 1;

    if v_op = 'in' then
      -- 值数组参数化：元素按列声明类型转换后与列比较（纯文本比较会漏 timestamptz ISO 串等格式差异）
      v_where := v_where || format(
        '(%I)::%s = any (select (e)::%s from jsonb_array_elements_text(($1::jsonb) -> %s) as t(e))',
        v_col, v_type, v_type, v_idx
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
  '标识符仅取 report_allowed_views（视图名 FK + format 的 %I 转义），筛选值全部经 $1 参数化，'
  'in/=/between 两侧按列声明类型转换后比较；'
  'SECURITY INVOKER：动态 SQL 以调用者身份执行，底层 security_invoker 视图 RLS 自动生效';

-- ---------------------------------------------------------------------------
-- 3. csv_field：CSV 公式注入中和
--    以 = + - @ Tab CR 开头的字段前缀单引号（Excel/Sheets 视为文本，不再执行公式）；
--    中和后再走 RFC 4180 引号规则（含引号/逗号/CR/LF 时加双引号并翻倍内部引号）。
-- ---------------------------------------------------------------------------
create or replace function app.csv_field(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_value is null then ''
    else (
      select case
        when v ~ ('[",' || chr(13) || chr(10) || ']')
          then '"' || replace(v, '"', '""') || '"'
        else v
      end
      from (
        select case
          when left(p_value, 1) in ('=', '+', '-', '@', chr(9), chr(13))
            then '''' || p_value
          else p_value
        end as v
      ) s
    )
  end
$$;

comment on function app.csv_field(text) is
  'CSV 字段转义（RFC 4180 最小引号；NULL → 空字段）；'
  '公式注入中和：= + - @ Tab CR 开头前缀单引号；内部 helper，不 GRANT API 角色';

-- ---------------------------------------------------------------------------
-- 4. delete_report_definition：删除前预检订阅引用（含逻辑删）
-- ---------------------------------------------------------------------------
create or replace function app.delete_report_definition(p_def_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := (select auth.uid());
  v_role      public.user_role := (select app.current_role());
  v_row       public.report_definitions;
  v_sub_count bigint;
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

  -- 删除前预检：逻辑删（is_deleted=true）行仍占用 FK，一并计数，
  -- 避免裸 FK 23503 暴露；有引用时以中文错误拒绝并报数
  select count(*) into v_sub_count
  from public.report_subscriptions
  where report_def_id = p_def_id;

  if v_sub_count > 0 then
    raise exception '该报表仍有 % 条订阅记录（含已删除订阅），无法删除', v_sub_count
      using errcode = 'P0001';
  end if;

  delete from public.report_definitions where id = p_def_id;

  perform app.audit_log(
    'report', 'delete', 'report_definition', p_def_id::text,
    jsonb_build_object('name', v_row.name, 'visibility', v_row.visibility)
  );
end;
$$;

comment on function app.delete_report_definition(uuid) is
  '删除报表定义（owner/admin）：删除前预检 report_subscriptions（含逻辑删行），'
  '有引用以 P0001 拒绝并报数；无引用才物理删除；写审计；内部实现，经 public 薄包装暴露';
