-- audit/001-002（M0 底座）：操作日志 audit_operations + 唯一写入入口 app.audit_log
-- 契约：INDEX 规则 2（audit_log 5 参签名）、规则 10（内部 RPC 不 GRANT authenticated）
-- 表 append-only：任何 API 角色无 INSERT/UPDATE/DELETE，写入仅经 SECURITY DEFINER 函数。

-- ---------------------------------------------------------------------------
-- 1. audit_operations：合规操作日志（谁、何时、哪个模块、对什么对象、做了什么）
-- ---------------------------------------------------------------------------
create table public.audit_operations (
  id          bigint generated always as identity primary key,
  actor_id    uuid,
  module      text not null,
  action      text not null,
  object_type text not null,
  object_id   text,
  diff        jsonb,
  ip          inet,
  ua          text,
  created_at  timestamptz not null default now()
);

comment on table public.audit_operations is '合规操作日志（append-only；唯一写入入口 app.audit_log）';
comment on column public.audit_operations.actor_id is '操作人 auth.uid()；无会话/后台调用为 NULL';
comment on column public.audit_operations.diff is '字段级前后差异（jsonb）；action=denied 时含 reason';

create index audit_operations_module_created_idx
  on public.audit_operations (module, created_at);
create index audit_operations_object_idx
  on public.audit_operations (object_type, object_id);
create index audit_operations_actor_idx
  on public.audit_operations (actor_id);

-- ---------------------------------------------------------------------------
-- 2. 唯一写入入口：app.audit_log(module, action, object_type, object_id, diff)
--    actor / ip / ua 由函数自动采集；返回新记录 id。
-- ---------------------------------------------------------------------------
create function app.audit_log(
  p_module      text,
  p_action      text,
  p_object_type text,
  p_object_id   text,
  p_diff        jsonb
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id      bigint;
  v_headers jsonb;
  v_ip      inet;
  v_ua      text;
begin
  -- PostgREST 请求内注入 request.headers（JSON、键小写）；pgTAP/后台无该设置
  begin
    v_headers := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then
    v_headers := null;
  end;

  if v_headers is not null then
    v_ua := v_headers ->> 'user-agent';
    begin
      -- X-Forwarded-For 可能是多段「客户端, 代理...」，取第一段
      v_ip := nullif(trim(both from split_part(v_headers ->> 'x-forwarded-for', ',', 1)), '')::inet;
    exception when others then
      v_ip := null;
    end;
  end if;

  insert into public.audit_operations
    (actor_id, module, action, object_type, object_id, diff, ip, ua)
  values
    ((select auth.uid()), p_module, p_action, p_object_type, p_object_id, p_diff, v_ip, v_ua)
  returning id into v_id;

  return v_id;
end;
$$;

comment on function app.audit_log(text, text, text, text, jsonb) is
  '合规日志唯一写入入口（5 参）；自动填充 actor/ip/ua；不 GRANT anon/authenticated（INDEX 规则 10）';

-- ---------------------------------------------------------------------------
-- 3. 授权：append-only（API 角色只读，RLS 再收口 admin；写仅经函数）
-- ---------------------------------------------------------------------------
revoke all on public.audit_operations from public, anon, authenticated, service_role;
grant select on public.audit_operations to authenticated, service_role;

-- 函数：收回 PostgreSQL 默认的 PUBLIC EXECUTE；不 GRANT anon/authenticated。
-- 后端通道：SECURITY DEFINER wrapper（属主 postgres）天然可执行；生产接入专用写入角色
-- 时在此显式 GRANT，本地栈不预置通道（INDEX 规则 10）。
revoke all on function app.audit_log(text, text, text, text, jsonb)
  from public, anon, authenticated;

-- identity 序列不暴露给 API 角色
revoke all on sequence public.audit_operations_id_seq
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. RLS：仅 admin SELECT；无写策略（无 INSERT/UPDATE/DELETE 策略 = 拒绝）
-- ---------------------------------------------------------------------------
alter table public.audit_operations enable row level security;

create policy audit_operations_select_admin
on public.audit_operations
for select
to authenticated
using (app.current_role() = 'admin');

-- ---------------------------------------------------------------------------
-- 5. 公开视图（INDEX 登记：access 权限审计 / report 操作活跃度 / audit 合规报告）
-- ---------------------------------------------------------------------------
create view public.audit_operations_v
with (security_invoker = true)
as
select
  o.id,
  o.actor_id,
  p.full_name as actor_name,
  o.module,
  o.action,
  o.object_type,
  o.object_id,
  o.diff,
  o.ip,
  o.ua,
  o.created_at
from public.audit_operations o
left join public.profiles p on p.id = o.actor_id;

comment on view public.audit_operations_v is
  '操作日志公开视图：actor 姓名 join profiles；security_invoker 随底层 RLS 仅 admin 可见';

-- 越权尝试视图：object_type='route'、object_id=route、diff.reason
create view public.audit_denied_v
with (security_invoker = true)
as
select
  o.actor_id as user_id,
  p.full_name as user_name,
  o.module,
  o.object_id as route,
  o.diff ->> 'reason' as reason,
  o.created_at as time
from public.audit_operations o
left join public.profiles p on p.id = o.actor_id
where o.action = 'denied';

comment on view public.audit_denied_v is
  '越权尝试视图：action=denied 记录映射 user/module/route/reason/time';

revoke all on public.audit_operations_v from public, anon, authenticated, service_role;
revoke all on public.audit_denied_v from public, anon, authenticated, service_role;
grant select on public.audit_operations_v to authenticated, service_role;
grant select on public.audit_denied_v to authenticated, service_role;
