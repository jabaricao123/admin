-- audit/006（M0 底座）：数据变更留痕底座 audit_row_versions + 白名单 + 通用触发器函数
-- 本迁移不给任何业务表挂触发器（挂载随各表迁移，如 org/011）；
-- 白名单先登记，快照由各表迁移 create trigger ... execute function app.audit_row_version_trigger() 产生。

-- ---------------------------------------------------------------------------
-- 1. audit_row_versions：关键表行版本快照（append-only）
-- ---------------------------------------------------------------------------
create table public.audit_row_versions (
  id         bigint generated always as identity primary key,
  table_name text not null,
  record_id  text not null,
  version    integer not null check (version > 0),
  data       jsonb not null,
  changed_by uuid,
  changed_at timestamptz not null default now(),
  unique (table_name, record_id, version)
);

comment on table public.audit_row_versions is '关键表行版本快照（append-only；由 app.audit_row_version_trigger 写入）';
comment on column public.audit_row_versions.record_id is '主键的文本形式（统一 text，兼容不同主键类型）';
comment on column public.audit_row_versions.data is '整行快照（to_jsonb(row)）';
comment on column public.audit_row_versions.changed_by is '变更发起人 auth.uid()；后台调用为 NULL';

-- ---------------------------------------------------------------------------
-- 2. audit_row_version_whitelist：留痕表白名单
--    新表加入 = 白名单登记 + 新迁移生成触发器（两步，触发器 DDL 无法动态生效）
-- ---------------------------------------------------------------------------
create table public.audit_row_version_whitelist (
  table_name text primary key,
  enabled    boolean not null default true,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.audit_row_version_whitelist is
  '留痕表白名单（触发器运行时闸门）；登记不代表表已存在（departments/positions 由后续迁移创建）';

create trigger audit_row_version_whitelist_set_updated_at
before update on public.audit_row_version_whitelist
for each row
execute function app.set_updated_at();

-- 首期登记（不校验表存在性；触发器挂载属各表迁移）
insert into public.audit_row_version_whitelist (table_name)
values ('profiles'), ('departments'), ('positions')
on conflict (table_name) do nothing;

-- ---------------------------------------------------------------------------
-- 3. 通用触发器函数：AFTER INSERT/UPDATE/DELETE 写快照
--    INSERT 为首版 version=1；version = 该记录当前最大 version + 1
-- ---------------------------------------------------------------------------
create function app.audit_row_version_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_table_name   text := tg_table_name;
  v_data         jsonb;
  v_record_id    text;
  v_next_version integer;
begin
  -- 白名单闸门：未登记或 enabled=false 时跳过
  if not exists (
    select 1
      from public.audit_row_version_whitelist w
     where w.table_name = v_table_name
       and w.enabled
  ) then
    return coalesce(new, old);
  end if;

  if tg_op = 'DELETE' then
    v_data := to_jsonb(old);
  else
    v_data := to_jsonb(new);
  end if;

  v_record_id := v_data ->> 'id';
  if v_record_id is null then
    raise exception 'audit_row_version_trigger：表 % 缺少 id 列，无法生成版本', v_table_name
      using errcode = 'P0001';
  end if;

  -- 同一记录串行取号，避免并发 max+1 撞唯一约束
  perform pg_advisory_xact_lock(hashtext(v_table_name), hashtext(v_record_id));

  select coalesce(max(v.version), 0) + 1
    into v_next_version
    from public.audit_row_versions v
   where v.table_name = v_table_name
     and v.record_id = v_record_id;

  insert into public.audit_row_versions
    (table_name, record_id, version, data, changed_by)
  values
    (v_table_name, v_record_id, v_next_version, v_data, (select auth.uid()));

  return coalesce(new, old);
end;
$$;

comment on function app.audit_row_version_trigger() is
  $$关键表行版本触发器：INSERT/UPDATE/DELETE 写 audit_row_versions；白名单 enabled 闸门；SECURITY DEFINER + set search_path = '' + 全限定名$$;

-- ---------------------------------------------------------------------------
-- 4. 授权：append-only；触发器函数仅系统（触发器）调用
--    实测：触发器触发不校验触发角色对函数的 EXECUTE，故可整体收回。
-- ---------------------------------------------------------------------------
revoke all on public.audit_row_versions from public, anon, authenticated, service_role;
grant select on public.audit_row_versions to authenticated, service_role;

revoke all on public.audit_row_version_whitelist from public, anon, authenticated, service_role;
grant select on public.audit_row_version_whitelist to authenticated, service_role;

revoke all on sequence public.audit_row_versions_id_seq
  from public, anon, authenticated, service_role;

revoke all on function app.audit_row_version_trigger()
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. RLS：仅 admin SELECT
-- ---------------------------------------------------------------------------
alter table public.audit_row_versions enable row level security;

create policy audit_row_versions_select_admin
on public.audit_row_versions
for select
to authenticated
using (app.current_role() = 'admin');

alter table public.audit_row_version_whitelist enable row level security;

create policy audit_row_version_whitelist_select_admin
on public.audit_row_version_whitelist
for select
to authenticated
using (app.current_role() = 'admin');
