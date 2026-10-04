-- 系统管理 · 参数配置（工单 system/007 表 + system/008 页面消费的 RPC）
-- 契约：docs/modules/system/settings.md（分组列表 / 按类型渲染 / 说明必填 / 历史回溯 /
--       内置参数 seed / get_setting 缺 key 返回 NULL 不报错）；docs/modules/INDEX.md
--       规则 1（跨模块只经公开面 RPC）、规则 2（审计摘要统一入口 audit_log）、
--       规则 10（内部 RPC 不 GRANT authenticated）。
--
-- 组成：
--   1. public.system_settings：参数表（key PK、group_name、value jsonb、value_type、
--      description、updated_by/updated_at）；description 非空白（防无主参数），
--      value_type 与 value 的 jsonb 类型一致性表级约束兜底（函数内给可读错误）；
--   2. public.system_setting_history：值变更历史（old_value/new_value/changed_by/changed_at，
--      由 upsert_setting 在事务内写入；key 不设外键以保留设置删除后的追溯）；
--   3. seed：page_size_default / session_remind_minutes / site_name / feature_beta（幂等）；
--   4. 读取口：get_setting（authenticated，stable，缺 key 返回 NULL）；
--      管理 RPC（admin）：upsert_setting（类型校验 + 历史 + 审计）、get_all_settings（全量列表）、
--      get_setting_history（历史回溯）；
--   5. RLS：表无任何角色表级访问（REVOKE all，读写全经 SECURITY DEFINER RPC——system/001 模式）。
--
-- 缓存契约：settings.md 要求读取口带 TTL 60s 缓存且写操作即时失效。本实现 get_setting
--   为无状态直读函数（总返回最新值，等价 TTL=0），60s 缓存由消费方（前端 / 服务端内存）
--   自行持有并在变更后失效；DB 不维护跨会话缓存，故「修改后 get_setting 即时返回新值」
--   严格成立且无失效窗口。
--
-- 依赖：app.set_updated_at()（init_profiles）、app.audit_log(text,text,text,text,jsonb)（audit/001）。

-- ---------------------------------------------------------------------------
-- 1. system_settings：全局参数表
-- ---------------------------------------------------------------------------
create table public.system_settings (
  key         text primary key,
  group_name  text not null,
  value       jsonb not null,
  value_type  text not null,
  description text not null,
  updated_by  uuid,
  updated_at  timestamptz not null default now(),
  constraint system_settings_key_check
    check (length(btrim(key)) > 0),
  constraint system_settings_group_check
    check (length(btrim(group_name)) > 0),
  constraint system_settings_description_check
    check (length(btrim(description)) > 0),
  constraint system_settings_value_type_check
    check (value_type in ('bool', 'number', 'string', 'json')),
  -- 类型一致性：bool↔boolean / number↔number / string↔string / json↔object|array
  constraint system_settings_value_matches_type_check
    check (
      case value_type
        when 'bool'   then jsonb_typeof(value) = 'boolean'
        when 'number' then jsonb_typeof(value) = 'number'
        when 'string' then jsonb_typeof(value) = 'string'
        when 'json'   then jsonb_typeof(value) in ('object', 'array')
        else false
      end
    )
);

comment on table public.system_settings is
  '全局键值参数（业务开关与阈值集中管理）；语义归消费模块，本模块只存与校验类型；'
  '无任何角色表级访问，读经 get_setting/get_all_settings，写经 upsert_setting';
comment on column public.system_settings.key is '参数键（PK，如 page_size_default）';
comment on column public.system_settings.group_name is '展示分组（如 通用/安全/集成）';
comment on column public.system_settings.value is '参数值（jsonb）；类型必须与 value_type 一致';
comment on column public.system_settings.value_type is '值类型：bool/number/string/json（json=对象或数组）';
comment on column public.system_settings.description is '说明（必填，防无主参数；空白字符串同样拒绝）';
comment on column public.system_settings.updated_by is '最近修改人（弱关联 auth.users，不设外键以保留追溯）';
comment on column public.system_settings.updated_at is '最近修改时间（触发器维护）';

create trigger system_settings_set_updated_at
before update on public.system_settings
for each row
execute function app.set_updated_at();

alter table public.system_settings enable row level security;

-- ---------------------------------------------------------------------------
-- 2. system_setting_history：值变更历史（同一事务随 upsert 写入）
-- ---------------------------------------------------------------------------
create table public.system_setting_history (
  id         bigint generated always as identity primary key,
  key        text not null,
  old_value  jsonb,
  new_value  jsonb not null,
  changed_by uuid,
  changed_at timestamptz not null default now()
);

comment on table public.system_setting_history is
  '参数值变更历史（append-only；仅 upsert_setting 写）；新建记录 old_value=NULL';
comment on column public.system_setting_history.old_value is '变更前值；新建时为 NULL';
comment on column public.system_setting_history.changed_by is '操作人 auth.uid()；后台调用为 NULL';

create index system_setting_history_key_changed_idx
  on public.system_setting_history (key, changed_at desc);

alter table public.system_setting_history enable row level security;

-- ---------------------------------------------------------------------------
-- 3. seed：内置参数（幂等；settings.md 功能需求 5）
-- ---------------------------------------------------------------------------
insert into public.system_settings (key, group_name, value, value_type, description)
values
  ('page_size_default',      '通用', to_jsonb(20),                  'number',
   '列表分页默认每页条数'),
  ('session_remind_minutes', '安全', to_jsonb(30),                  'number',
   '会话到期前提醒阈值（分钟）'),
  ('site_name',              '通用', to_jsonb('企业管理系统'::text), 'string',
   '系统名称（浏览器标题 / 登录页展示）'),
  ('feature_beta',           '通用', to_jsonb(false),               'bool',
   '灰度功能总开关（开启后展示 beta 功能入口）')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 4. 读取口：get_setting（全员可读，缺 key 返回 NULL）
-- ---------------------------------------------------------------------------
create function app.get_setting(p_key text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select s.value
  from public.system_settings s
  where s.key = p_key
$$;

comment on function app.get_setting(text) is
  '参数读取口（全员，stable）：返回最新值；key 不存在返回 NULL 不报错；'
  '60s TTL 缓存由消费方持有（见迁移头注释），DB 侧无缓存故写入即时可见';

-- ---------------------------------------------------------------------------
-- 5. 管理 RPC（admin；公开面为 public 同名薄包装）
-- ---------------------------------------------------------------------------
create function app.upsert_setting(
  p_key         text,
  p_value       jsonb,
  p_group_name  text,
  p_value_type  text,
  p_description text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev          public.system_settings;
  v_row           public.system_settings;
  v_key           text := btrim(p_key);
  v_group         text := btrim(p_group_name);
  v_description   text := btrim(p_description);
  v_created       boolean;
  v_value_changed boolean;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if v_key is null or v_key = '' then
    raise exception '参数 key 不能为空' using errcode = '22023';
  end if;
  if v_group is null or v_group = '' then
    raise exception '参数分组不能为空' using errcode = '22023';
  end if;
  if v_description is null or v_description = '' then
    raise exception '参数说明不能为空（防无主参数）' using errcode = '22023';
  end if;
  if p_value_type is null or p_value_type not in ('bool', 'number', 'string', 'json') then
    raise exception '未知参数类型：%', coalesce(p_value_type, '(null)') using errcode = '22023';
  end if;
  if p_value is null then
    raise exception '参数值不能为 NULL' using errcode = '22023';
  end if;

  -- 类型校验（表 check 兜底；此处给可读错误）
  if (case p_value_type
        when 'bool'   then jsonb_typeof(p_value) <> 'boolean'
        when 'number' then jsonb_typeof(p_value) <> 'number'
        when 'string' then jsonb_typeof(p_value) <> 'string'
        when 'json'   then jsonb_typeof(p_value) not in ('object', 'array')
        else true
      end) then
    raise exception '参数值类型与 value_type=% 不匹配（实际 %）',
      p_value_type, coalesce(jsonb_typeof(p_value), '(null)')
      using errcode = '22023';
  end if;

  select * into v_prev
  from public.system_settings
  where key = v_key
  for update;

  v_created := not found;

  insert into public.system_settings
    (key, group_name, value, value_type, description, updated_by)
  values
    (v_key, v_group, p_value, p_value_type, v_description, (select auth.uid()))
  on conflict (key) do update
    set group_name  = excluded.group_name,
        value       = excluded.value,
        value_type  = excluded.value_type,
        description = excluded.description,
        updated_by  = excluded.updated_by
  returning * into v_row;

  -- 历史只在首次创建或值实际变化时写入（重复保存同值不产生噪声历史）
  v_value_changed := v_created or v_prev.value is distinct from p_value;
  if v_value_changed then
    insert into public.system_setting_history (key, old_value, new_value, changed_by)
    values (
      v_key,
      case when v_created then null else v_prev.value end,
      p_value,
      (select auth.uid())
    );
  end if;

  perform app.audit_log(
    'system', 'upsert', 'setting', v_key,
    jsonb_build_object(
      'created', v_created,
      'group_name', v_group,
      'value_type', p_value_type,
      'value_changed', v_value_changed,
      'old_value', case when v_created then null else v_prev.value end,
      'new_value', p_value,
      'description_changed',
        case when v_created then true else v_prev.description is distinct from v_description end
    )
  );

  return jsonb_build_object(
    'key', v_row.key,
    'group_name', v_row.group_name,
    'value', v_row.value,
    'value_type', v_row.value_type,
    'description', v_row.description,
    'updated_by', v_row.updated_by,
    'updated_at', v_row.updated_at
  );
end;
$$;

comment on function app.upsert_setting(text, jsonb, text, text, text) is
  '参数新建/编辑 RPC（admin）：类型一致性校验（bool/number/string/json）；说明必填；'
  '值变化写 system_setting_history；审计记 old/new 与变更标记';

create function app.get_all_settings()
returns table (
  key         text,
  group_name  text,
  value       jsonb,
  value_type  text,
  description text,
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
    s.key,
    s.group_name,
    s.value,
    s.value_type,
    s.description,
    s.updated_by,
    s.updated_at
  from public.system_settings s
  order by s.group_name, s.key;
end;
$$;

comment on function app.get_all_settings() is
  '参数全量列表 RPC（admin）：供 /system/settings 管理页分组展示；按 group_name、key 升序';

create function app.get_setting_history(p_key text)
returns table (
  id              bigint,
  key             text,
  old_value       jsonb,
  new_value       jsonb,
  changed_by      uuid,
  changed_by_name text,
  changed_at      timestamptz
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
    h.id,
    h.key,
    h.old_value,
    h.new_value,
    h.changed_by,
    p.full_name as changed_by_name,
    h.changed_at
  from public.system_setting_history h
  left join public.profiles p on p.id = h.changed_by
  where h.key = p_key
  order by h.changed_at desc, h.id desc;
end;
$$;

comment on function app.get_setting_history(text) is
  '参数变更历史 RPC（admin）：按时间倒序返回该 key 的 old/new/操作人（profiles 姓名）';

-- ---------------------------------------------------------------------------
-- 6. public 薄包装（PostgREST 仅暴露 public schema）
-- ---------------------------------------------------------------------------
create function public.get_setting(p_key text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select app.get_setting(p_key)
$$;

create function public.upsert_setting(
  p_key         text,
  p_value       jsonb,
  p_group_name  text,
  p_value_type  text,
  p_description text
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.upsert_setting(p_key, p_value, p_group_name, p_value_type, p_description)
$$;

create function public.get_all_settings()
returns table (
  key         text,
  group_name  text,
  value       jsonb,
  value_type  text,
  description text,
  updated_by  uuid,
  updated_at  timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.get_all_settings()
$$;

create function public.get_setting_history(p_key text)
returns table (
  id              bigint,
  key             text,
  old_value       jsonb,
  new_value       jsonb,
  changed_by      uuid,
  changed_by_name text,
  changed_at      timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select * from app.get_setting_history(p_key)
$$;

comment on function public.get_setting(text) is
  'get_setting Data API 薄包装（全员可读）';
comment on function public.upsert_setting(text, jsonb, text, text, text) is
  'upsert_setting Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.get_all_settings() is
  'get_all_settings Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.get_setting_history(text) is
  'get_setting_history Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 7. 授权：表全 revoke（无策略=拒绝）；读取口全员、管理 RPC 登录可调（函数内 admin）
-- ---------------------------------------------------------------------------
revoke all on public.system_settings from public, anon, authenticated, service_role;
revoke all on public.system_setting_history from public, anon, authenticated, service_role;

revoke all on function app.get_setting(text) from public, anon;
revoke all on function app.upsert_setting(text, jsonb, text, text, text) from public, anon;
revoke all on function app.get_all_settings() from public, anon;
revoke all on function app.get_setting_history(text) from public, anon;

grant execute on function app.get_setting(text) to authenticated;
grant execute on function app.upsert_setting(text, jsonb, text, text, text) to authenticated;
grant execute on function app.get_all_settings() to authenticated;
grant execute on function app.get_setting_history(text) to authenticated;

revoke all on function public.get_setting(text) from public, anon;
revoke all on function public.upsert_setting(text, jsonb, text, text, text) from public, anon;
revoke all on function public.get_all_settings() from public, anon;
revoke all on function public.get_setting_history(text) from public, anon;

grant execute on function public.get_setting(text) to authenticated;
grant execute on function public.upsert_setting(text, jsonb, text, text, text) to authenticated;
grant execute on function public.get_all_settings() to authenticated;
grant execute on function public.get_setting_history(text) to authenticated;
