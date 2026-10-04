-- 系统管理 · 字典管理（工单 system/009 表 + system/008 同批页面消费的 RPC）
-- 契约：docs/modules/system/dictionaries.md（dict_key 分组 / value 建后不可改 / 停用项
--       get_dict 过滤但存量行保留 / 新增字典登记用途说明 / 配色类名对齐前端 Badge）；
--       docs/modules/INDEX.md 规则 1（跨模块只经公开面 RPC）、规则 2（审计摘要统一入口）、
--       规则 10（内部 RPC 不 GRANT authenticated）。
--
-- 组成：
--   1. public.system_dict_meta：字典登记表（dict_key PK、description 必填、created_by）——
--      新 dict_key 必须先登记用途（防无主码表）；
--   2. public.system_dictionaries：字典项（dict_key, value 复合 PK；label 必填；sort_order；
--      color_class；status active/disabled）；value 为 PK 组成，函数不提供改写通道（建后不可改）；
--   3. seed：common.status（active/disabled/deleted）与 common.yesno（yes/no）+
--      对应 meta；配色类名与 src/lib/dictionaries.ts 现有 Badge 类逐字对齐；
--   4. 读取口 get_dict（authenticated，stable，仅 active 项按 sort_order；缺 key 返回 []）；
--      管理 RPC（admin）：get_dict_catalog / get_dict_items / upsert_dict_meta /
--      upsert_dict_item / disable_dict_item；
--   5. RLS：登录可读（表级 SELECT + select 策略）；写仅经 SECURITY DEFINER RPC
--      （无表级写权限、无写策略）。停用项过滤在 get_dict 读取口，表级通道保留存量行。
--
-- 缓存契约：dictionaries.md 要求读取口带 TTL 60s 缓存。与 get_setting 同策略：
--   get_dict 无状态直读（总返回最新），60s 缓存由消费方/前端 dictionaries.ts 持有。
--
-- 依赖：app.set_updated_at()（init_profiles）、app.audit_log(text,text,text,text,jsonb)（audit/001）。

-- ---------------------------------------------------------------------------
-- 1. system_dict_meta：字典登记表（新增字典必须登记用途说明）
-- ---------------------------------------------------------------------------
create table public.system_dict_meta (
  dict_key    text primary key,
  description text not null,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  constraint system_dict_meta_key_check
    check (length(btrim(dict_key)) > 0),
  constraint system_dict_meta_description_check
    check (length(btrim(description)) > 0)
);

comment on table public.system_dict_meta is
  '字典登记表：每个 dict_key 的用途说明（必填）；新 dict_key 先登记后建项';
comment on column public.system_dict_meta.dict_key is '字典标识（PK，如 common.status；约定 <域>.<名字>）';
comment on column public.system_dict_meta.description is '用途说明（必填）';

alter table public.system_dict_meta enable row level security;

-- ---------------------------------------------------------------------------
-- 2. system_dictionaries：字典项表
-- ---------------------------------------------------------------------------
create table public.system_dictionaries (
  dict_key    text not null,
  value       text not null,
  label       text not null,
  sort_order  integer not null default 0,
  color_class text,
  status      text not null default 'active',
  updated_by  uuid,
  updated_at  timestamptz not null default now(),
  primary key (dict_key, value),
  constraint system_dictionaries_dict_key_check
    check (length(btrim(dict_key)) > 0),
  constraint system_dictionaries_value_check
    check (length(btrim(value)) > 0),
  constraint system_dictionaries_label_check
    check (length(btrim(label)) > 0),
  constraint system_dictionaries_status_check
    check (status in ('active', 'disabled'))
);

comment on table public.system_dictionaries is
  '跨模块共享码表项（dict_key + value 复合 PK）；value 建后不可改（被引用），'
  '停用项保留存量行、经 get_dict 过滤不下发；写仅经 admin RPC';
comment on column public.system_dictionaries.dict_key is '字典标识（对应 system_dict_meta.dict_key）';
comment on column public.system_dictionaries.value is '项值（复合 PK；建后不可改）';
comment on column public.system_dictionaries.label is '展示文案（可改，改后全站即时生效）';
comment on column public.system_dictionaries.sort_order is '展示排序（升序，同序按 value）';
comment on column public.system_dictionaries.color_class is 'Tailwind Badge 类名（对齐 src/lib/dictionaries.ts）';
comment on column public.system_dictionaries.status is 'active 启用 / disabled 停用（停用不下发，存量展示不破）';
comment on column public.system_dictionaries.updated_by is '最近修改人（弱关联 auth.users）';
comment on column public.system_dictionaries.updated_at is '最近修改时间（触发器维护）';

create trigger system_dictionaries_set_updated_at
before update on public.system_dictionaries
for each row
execute function app.set_updated_at();

alter table public.system_dictionaries enable row level security;

-- ---------------------------------------------------------------------------
-- 3. seed：通用状态 / 通用是否（幂等）
--    配色类名与 dictionaries.ts 现有 Badge 类逐字对齐：emerald=启用、zinc=停用、red=删除。
-- ---------------------------------------------------------------------------
insert into public.system_dict_meta (dict_key, description)
values
  ('common.status',
   '通用状态：active 启用 / disabled 停用 / deleted 已删除；跨模块共享的状态语义与配色'),
  ('common.yesno',
   '通用是否：yes 是 / no 否；替代散落的布尔字样硬编码')
on conflict (dict_key) do nothing;

insert into public.system_dictionaries (dict_key, value, label, sort_order, color_class, status)
values
  ('common.status', 'active',   '启用',   10,
   'border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300',
   'active'),
  ('common.status', 'disabled', '停用',   20,
   'border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400',
   'active'),
  ('common.status', 'deleted',  '已删除', 30,
   'border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300',
   'active'),
  ('common.yesno',  'yes',      '是',     10,
   'border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300',
   'active'),
  ('common.yesno',  'no',       '否',     20,
   'border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400',
   'active')
on conflict (dict_key, value) do nothing;

-- ---------------------------------------------------------------------------
-- 4. 读取口：get_dict（全员可读，仅 active，按 sort_order）
-- ---------------------------------------------------------------------------
create function app.get_dict(p_dict_key text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'value', d.value,
        'label', d.label,
        'sort_order', d.sort_order,
        'color_class', d.color_class,
        'status', d.status
      )
      order by d.sort_order, d.value
    ),
    '[]'::jsonb
  )
  from public.system_dictionaries d
  where d.dict_key = p_dict_key
    and d.status = 'active'
$$;

comment on function app.get_dict(text) is
  '字典读取口（全员，stable）：仅返回 active 项（停用项过滤），按 sort_order、value 升序；'
  'dict_key 不存在或全部停用返回空数组 []；60s TTL 缓存由消费方持有';

-- ---------------------------------------------------------------------------
-- 5. 管理 RPC（admin；公开面为 public 同名薄包装）
-- ---------------------------------------------------------------------------
create function app.get_dict_catalog()
returns table (
  dict_key     text,
  description  text,
  item_count   integer,
  active_count integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  return query
  select
    m.dict_key,
    m.description,
    coalesce(count(d.value), 0)::integer as item_count,
    (count(d.value) filter (where d.status = 'active'))::integer as active_count
  from public.system_dict_meta m
  left join public.system_dictionaries d on d.dict_key = m.dict_key
  group by m.dict_key, m.description
  order by m.dict_key;
end;
$$;

comment on function app.get_dict_catalog() is
  '字典目录 RPC（admin）：左侧导航用；返回全部 dict_key、用途说明与项数统计（含停用项）';

create function app.get_dict_items(p_dict_key text)
returns table (
  value       text,
  label       text,
  sort_order  integer,
  color_class text,
  status      text,
  updated_by  uuid,
  updated_at  timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  return query
  select
    d.value,
    d.label,
    d.sort_order,
    d.color_class,
    d.status,
    d.updated_by,
    d.updated_at
  from public.system_dictionaries d
  where d.dict_key = p_dict_key
  order by d.sort_order, d.value;
end;
$$;

comment on function app.get_dict_items(text) is
  '字典项全量 RPC（admin）：右侧管理表格用；含 disabled 项（存量维护），按 sort_order、value 升序';

create function app.upsert_dict_meta(
  p_dict_key    text,
  p_description text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key        text := btrim(p_dict_key);
  v_desc       text := btrim(p_description);
  v_prev       public.system_dict_meta;
  v_row        public.system_dict_meta;
  v_created    boolean;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if v_key is null or v_key = '' then
    raise exception '字典标识不能为空' using errcode = '22023';
  end if;
  if v_desc is null or v_desc = '' then
    raise exception '字典用途说明不能为空' using errcode = '22023';
  end if;

  select * into v_prev
  from public.system_dict_meta
  where dict_key = v_key
  for update;

  v_created := not found;

  insert into public.system_dict_meta (dict_key, description, created_by)
  values (v_key, v_desc, (select auth.uid()))
  on conflict (dict_key) do update
    set description = excluded.description
  returning * into v_row;

  perform app.audit_log(
    'system', 'upsert', 'dict_meta', v_key,
    jsonb_build_object(
      'created', v_created,
      'description_changed',
        case when v_created then true else v_prev.description is distinct from v_desc end
    )
  );

  return jsonb_build_object(
    'dict_key', v_row.dict_key,
    'description', v_row.description,
    'created', v_created
  );
end;
$$;

comment on function app.upsert_dict_meta(text, text) is
  '字典登记 RPC（admin）：新增 dict_key 必须登记用途说明（必填）；已存在时仅更新说明';

create function app.upsert_dict_item(
  p_dict_key    text,
  p_value       text,
  p_label       text,
  p_sort_order  integer,
  p_color_class text,
  p_status      text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key     text := btrim(p_dict_key);
  v_value   text := btrim(p_value);
  v_label   text := btrim(p_label);
  v_color   text := nullif(btrim(p_color_class), '');
  v_status  text := coalesce(nullif(btrim(p_status), ''), 'active');
  v_order   integer := coalesce(p_sort_order, 0);
  v_prev    public.system_dictionaries;
  v_row     public.system_dictionaries;
  v_created boolean;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if v_key is null or v_key = '' then
    raise exception '字典标识不能为空' using errcode = '22023';
  end if;
  if v_value is null or v_value = '' then
    raise exception '字典项 value 不能为空' using errcode = '22023';
  end if;
  if v_label is null or v_label = '' then
    raise exception '字典项 label 不能为空' using errcode = '22023';
  end if;
  if v_status not in ('active', 'disabled') then
    raise exception '非法字典项状态：%', v_status using errcode = '22023';
  end if;

  if not exists (select 1 from public.system_dict_meta m where m.dict_key = v_key) then
    raise exception '字典 % 尚未登记用途说明，请先新增字典', v_key using errcode = 'P0002';
  end if;

  select * into v_prev
  from public.system_dictionaries
  where dict_key = v_key and value = v_value
  for update;

  v_created := not found;

  -- value 为复合 PK 组成：本函数无「新 value」参数，已存在项只更新
  -- label / sort_order / color_class / status，value 本身不可改。
  insert into public.system_dictionaries
    (dict_key, value, label, sort_order, color_class, status, updated_by)
  values
    (v_key, v_value, v_label, v_order, v_color, v_status, (select auth.uid()))
  on conflict (dict_key, value) do update
    set label       = excluded.label,
        sort_order  = excluded.sort_order,
        color_class = excluded.color_class,
        status      = excluded.status,
        updated_by  = excluded.updated_by
  returning * into v_row;

  perform app.audit_log(
    'system', 'upsert', 'dict_item', v_key || '/' || v_value,
    jsonb_build_object(
      'created', v_created,
      'label', v_label,
      'sort_order', v_order,
      'color_class', v_color,
      'status_before', case when v_created then null else v_prev.status end,
      'status_after', v_status
    )
  );

  return jsonb_build_object(
    'dict_key', v_row.dict_key,
    'value', v_row.value,
    'label', v_row.label,
    'sort_order', v_row.sort_order,
    'color_class', v_row.color_class,
    'status', v_row.status,
    'updated_at', v_row.updated_at
  );
end;
$$;

comment on function app.upsert_dict_item(text, text, text, integer, text, text) is
  '字典项新建/编辑 RPC（admin）：dict_key 必须已登记说明（否则 P0002）；'
  'value 建后不可改（定位键，无改写通道）；label/排序/配色/状态可改';

create function app.disable_dict_item(
  p_dict_key text,
  p_value    text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev public.system_dictionaries;
  v_row  public.system_dictionaries;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_prev
  from public.system_dictionaries
  where dict_key = btrim(p_dict_key)
    and value = btrim(p_value)
  for update;

  if not found then
    raise exception '字典项不存在：%/%', coalesce(btrim(p_dict_key), '(null)'),
      coalesce(btrim(p_value), '(null)')
      using errcode = 'P0002';
  end if;

  update public.system_dictionaries
     set status = 'disabled',
         updated_by = (select auth.uid())
   where dict_key = v_prev.dict_key
     and value = v_prev.value
  returning * into v_row;

  perform app.audit_log(
    'system', 'disable', 'dict_item', v_row.dict_key || '/' || v_row.value,
    jsonb_build_object('status_before', v_prev.status, 'status_after', v_row.status)
  );

  return jsonb_build_object(
    'dict_key', v_row.dict_key,
    'value', v_row.value,
    'status', v_row.status,
    'updated_at', v_row.updated_at
  );
end;
$$;

comment on function app.disable_dict_item(text, text) is
  '字典项停用 RPC（admin）：置 status=disabled（幂等）；停用项不再经 get_dict 下发，'
  '存量行保留供历史数据展示';

-- ---------------------------------------------------------------------------
-- 6. public 薄包装（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.get_dict(p_dict_key text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select app.get_dict(p_dict_key)
$$;

create function public.get_dict_catalog()
returns table (
  dict_key     text,
  description  text,
  item_count   integer,
  active_count integer
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.get_dict_catalog()
$$;

create function public.get_dict_items(p_dict_key text)
returns table (
  value       text,
  label       text,
  sort_order  integer,
  color_class text,
  status      text,
  updated_by  uuid,
  updated_at  timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.get_dict_items(p_dict_key)
$$;

create function public.upsert_dict_meta(
  p_dict_key    text,
  p_description text
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.upsert_dict_meta(p_dict_key, p_description)
$$;

create function public.upsert_dict_item(
  p_dict_key    text,
  p_value       text,
  p_label       text,
  p_sort_order  integer,
  p_color_class text,
  p_status      text
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.upsert_dict_item(p_dict_key, p_value, p_label, p_sort_order, p_color_class, p_status)
$$;

create function public.disable_dict_item(
  p_dict_key text,
  p_value    text
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.disable_dict_item(p_dict_key, p_value)
$$;

comment on function public.get_dict(text) is
  'get_dict Data API 薄包装（全员可读，仅 active 项）';
comment on function public.get_dict_catalog() is
  'get_dict_catalog Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.get_dict_items(text) is
  'get_dict_items Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.upsert_dict_meta(text, text) is
  'upsert_dict_meta Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.upsert_dict_item(text, text, text, integer, text, text) is
  'upsert_dict_item Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.disable_dict_item(text, text) is
  'disable_dict_item Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 7. 授权：登录可读（表级 SELECT + select 策略）；写仅 RPC；读取口全员、管理 RPC 登录可调
-- ---------------------------------------------------------------------------
revoke all on public.system_dictionaries from public, anon, authenticated, service_role;
revoke all on public.system_dict_meta from public, anon, authenticated, service_role;

grant select on public.system_dictionaries to authenticated;
grant select on public.system_dict_meta to authenticated;

-- RLS 策略：登录可读。表级通道保留停用项（存量数据展示/审计需要）；
-- 「停用项不下发」由 get_dict 读取口过滤保证。
create policy system_dictionaries_select_authenticated
on public.system_dictionaries
for select
to authenticated
using (true);

create policy system_dict_meta_select_authenticated
on public.system_dict_meta
for select
to authenticated
using (true);

revoke all on function app.get_dict(text) from public, anon;
revoke all on function app.get_dict_catalog() from public, anon;
revoke all on function app.get_dict_items(text) from public, anon;
revoke all on function app.upsert_dict_meta(text, text) from public, anon;
revoke all on function app.upsert_dict_item(text, text, text, integer, text, text) from public, anon;
revoke all on function app.disable_dict_item(text, text) from public, anon;

grant execute on function app.get_dict(text) to authenticated;
grant execute on function app.get_dict_catalog() to authenticated;
grant execute on function app.get_dict_items(text) to authenticated;
grant execute on function app.upsert_dict_meta(text, text) to authenticated;
grant execute on function app.upsert_dict_item(text, text, text, integer, text, text) to authenticated;
grant execute on function app.disable_dict_item(text, text) to authenticated;

revoke all on function public.get_dict(text) from public, anon;
revoke all on function public.get_dict_catalog() from public, anon;
revoke all on function public.get_dict_items(text) from public, anon;
revoke all on function public.upsert_dict_meta(text, text) from public, anon;
revoke all on function public.upsert_dict_item(text, text, text, integer, text, text) from public, anon;
revoke all on function public.disable_dict_item(text, text) from public, anon;

grant execute on function public.get_dict(text) to authenticated;
grant execute on function public.get_dict_catalog() to authenticated;
grant execute on function public.get_dict_items(text) to authenticated;
grant execute on function public.upsert_dict_meta(text, text) to authenticated;
grant execute on function public.upsert_dict_item(text, text, text, integer, text, text) to authenticated;
grant execute on function public.disable_dict_item(text, text) to authenticated;
