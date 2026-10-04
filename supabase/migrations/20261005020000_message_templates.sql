-- 消息中心 · 事件注册表 + 通知文案模板（工单 message/004+005）
-- 契约：docs/modules/message/templates.md：
--   * message_event_registry 事件注册表（event_key PK，available_vars 列出模板可用变量）；
--   * message_templates 版本化：(event_key, channel, version) 唯一 + message_template_current 指针；
--   * 未注册事件不可建模板；published 版本内容冻结（触发器），改动 = 发新版本 / 回滚旧版本；
--   * send_notification 按 (event_key,'inbox') 当前 published 模板渲染 {{var}}，
--     未提供变量保留占位符原文（inbox.md：缺变量降级显示占位符不报错），无模板走原 fallback。
-- INDEX 规则 2（审计摘要统一入口）、3（通知发送单通道）、8（「通知文案模板」命名区别于审批表单模板）、
--   10（register_message_event 等内部 RPC 不 GRANT authenticated）。
-- 说明：
--   * 渠道分发（email/push 实际投递）在 message/009，本期 channel 仅建模；
--   * 实现落 app schema（public 同名薄包装供 Data API）；管理 RPC 函数内显式 admin 校验；
--   * 三张新表对 API 角色仅 SELECT（RLS 再收口 admin），无任何表级写，写全经 SECURITY DEFINER RPC。
-- 依赖：20261003205454（messages + app.send_notification）、20261003205349（app.audit_log）、
--       20261003145039（profiles / app.current_role / app.set_updated_at）。

-- ---------------------------------------------------------------------------
-- 1. message_event_registry：事件注册表（各模块登记事件与可用变量）
-- ---------------------------------------------------------------------------
create table public.message_event_registry (
  event_key      text primary key,
  module         text not null,
  description    text,
  available_vars jsonb not null default '[]'::jsonb,
  registered_by  uuid,
  created_at     timestamptz not null default now(),
  constraint message_event_registry_event_key_check check (btrim(event_key) <> ''),
  constraint message_event_registry_module_check check (btrim(module) <> ''),
  constraint message_event_registry_vars_array_check check (jsonb_typeof(available_vars) = 'array')
);

comment on table public.message_event_registry is
  '通知事件注册表：各模块交付时经 app.register_message_event 登记（幂等 upsert）；未注册事件不可建模板';
comment on column public.message_event_registry.event_key is '事件 key（module.event，如 approval.pending）';
comment on column public.message_event_registry.module is '事件归属模块（approval/sync 等，事件 key 前缀）';
comment on column public.message_event_registry.available_vars is '模板可用变量名数组（字符串数组，管理界面以 Badge 展示）';
comment on column public.message_event_registry.registered_by is '登记人（auth.uid()；模块迁移内 seed 为 NULL）';

-- seed：首期事件（approval / 系统公告 / sync / webhook / report；available_vars 为模板占位符建议清单）
insert into public.message_event_registry (event_key, module, description, available_vars)
values
  ('approval.pending',        'approval',    '审批待办（新任务指派给审批人）', '["initiator","title"]'::jsonb),
  ('approval.approved',       'approval',    '审批通过（通知发起人）',         '["title","comment"]'::jsonb),
  ('approval.rejected',       'approval',    '审批驳回（通知发起人）',         '["title","comment"]'::jsonb),
  ('approval.urge',           'approval',    '审批催办（通知处理人）',         '["initiator","title"]'::jsonb),
  ('announcement.published',  'system',      '公告发布（全站可见）',           '["title","publisher"]'::jsonb),
  ('sync.run_finished',       'sync',        '同步任务执行完成',               '["task_name","status","rows","finished_at"]'::jsonb),
  ('webhook.delivery_failed', 'integration', 'Webhook 投递失败（通知创建人）', '["endpoint","event","attempt","error"]'::jsonb),
  ('report.export_ready',     'report',      '报表导出就绪（可下载）',         '["report_name","download_url"]'::jsonb);

-- ---------------------------------------------------------------------------
-- 2. app.register_message_event：事件登记唯一入口（幂等 upsert；内部 RPC，规则 10）
-- ---------------------------------------------------------------------------
create function app.register_message_event(
  p_event_key   text,
  p_module      text,
  p_description text,
  p_vars        jsonb
)
returns public.message_event_registry
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_vars jsonb := coalesce(p_vars, '[]'::jsonb);
  v_row  public.message_event_registry;
begin
  if p_event_key is null or btrim(p_event_key) = '' then
    raise exception 'event_key 不能为空' using errcode = '22023';
  end if;
  if p_module is null or btrim(p_module) = '' then
    raise exception 'module 不能为空' using errcode = '22023';
  end if;
  if jsonb_typeof(v_vars) <> 'array' then
    raise exception 'available_vars 必须是 JSON 字符串数组' using errcode = '22023';
  end if;

  insert into public.message_event_registry
    (event_key, module, description, available_vars, registered_by)
  values
    (btrim(p_event_key), btrim(p_module), p_description, v_vars, (select auth.uid()))
  on conflict (event_key) do update
    set module         = excluded.module,
        description    = excluded.description,
        available_vars = excluded.available_vars,
        -- 保留首个登记人；seed 行为 NULL 时由首次调用者补位
        registered_by  = coalesce(public.message_event_registry.registered_by, excluded.registered_by)
  returning * into v_row;

  return v_row;
end;
$$;

comment on function app.register_message_event(text, text, text, jsonb) is
  '登记/更新通知事件（幂等 upsert）；模块交付时调用；不 GRANT authenticated（INDEX 规则 10）';

revoke all on function app.register_message_event(text, text, text, jsonb)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. message_templates：通知文案模板（版本化）+ message_template_current 当前版本指针
-- ---------------------------------------------------------------------------
create table public.message_templates (
  id          uuid primary key default gen_random_uuid(),
  event_key   text not null references public.message_event_registry (event_key) on delete restrict,
  channel     text not null
              constraint message_templates_channel_check
              check (channel in ('inbox', 'email', 'push')),
  subject_tpl text not null,
  body_tpl    text not null,
  version     integer not null default 1
              constraint message_templates_version_check
              check (version >= 1),
  status      text not null default 'draft'
              constraint message_templates_status_check
              check (status in ('draft', 'published', 'disabled')),
  updated_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint message_templates_event_channel_version_uq unique (event_key, channel, version),
  -- 供 message_template_current 复合外键引用：保证指针指向的模板与 (event_key, channel) 一致
  constraint message_templates_id_event_channel_uq unique (id, event_key, channel)
);

comment on table public.message_templates is
  '通知文案模板（版本化）：同 (event_key, channel) 递增 version；published 内容冻结，改动发新版本或回滚';
comment on column public.message_templates.channel is '投递渠道：inbox 站内信 / email 邮件 / push 推送（本期仅建模，投递在 message/009）';
comment on column public.message_templates.subject_tpl is '标题模板，支持 {{var}} 占位符（站内信/邮件主题）';
comment on column public.message_templates.body_tpl is '正文模板，支持 {{var}} 占位符';
comment on column public.message_templates.status is 'draft 可编辑 / published 可发布可渲染 / disabled 停用（非 draft 内容冻结）';
comment on column public.message_templates.updated_by is '最后编辑人（auth.uid()）';

create trigger message_templates_set_updated_at
before update on public.message_templates
for each row
execute function app.set_updated_at();

create table public.message_template_current (
  event_key   text not null,
  channel     text not null
              constraint message_template_current_channel_check
              check (channel in ('inbox', 'email', 'push')),
  template_id uuid not null,
  constraint message_template_current_pk primary key (event_key, channel),
  constraint message_template_current_event_fk
    foreign key (event_key) references public.message_event_registry (event_key) on delete restrict,
  constraint message_template_current_template_fk
    foreign key (template_id, event_key, channel)
    references public.message_templates (id, event_key, channel) on delete cascade
);

comment on table public.message_template_current is
  '当前版本指针：每 (event_key, channel) 一行，指向生效模板；发送渲染的唯一依据（不复制内容）';

-- 冻结触发器：非 draft 版本内容不可改；published 仅可流转 disabled（发新版 / 回滚替代修改）
create function app.protect_published_message_template()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status <> 'draft' then
    if new.event_key   is distinct from old.event_key
       or new.channel     is distinct from old.channel
       or new.subject_tpl is distinct from old.subject_tpl
       or new.body_tpl    is distinct from old.body_tpl
       or new.version     is distinct from old.version then
      raise exception '通知模板 % / % v% 非草稿状态，内容不可修改（请发布新版本或回滚）',
        old.event_key, old.channel, old.version
        using errcode = '22023';
    end if;
  end if;

  if old.status = 'published'
     and new.status is distinct from old.status
     and new.status <> 'disabled' then
    raise exception '已发布通知模板仅可流转为 disabled（当前状态：%）', old.status
      using errcode = '22023';
  end if;

  return new;
end;
$$;

comment on function app.protect_published_message_template() is
  '通知模板冻结触发器：非 draft 行内容不可变；published 仅可流转 disabled';

create trigger message_templates_protect_published
before update on public.message_templates
for each row
execute function app.protect_published_message_template();

-- ---------------------------------------------------------------------------
-- 4. 管理 RPC（仅 admin；实现落 app，public 同名薄包装供 Data API）
-- ---------------------------------------------------------------------------
-- 4.1 保存草稿：p_id 为空 = 续编既有草稿（无则新建 version=max+1）；p_id 为草稿 = 更新内容
create function app.upsert_message_template(
  p_event_key   text,
  p_channel     text,
  p_subject_tpl text,
  p_body_tpl    text,
  p_id          uuid default null
)
returns public.message_templates
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_row     public.message_templates;
  v_version integer;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_event_key is null or p_channel is null then
    raise exception '事件与渠道不能为空' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.message_event_registry r where r.event_key = p_event_key
  ) then
    raise exception '事件未注册，不可创建模板：%', p_event_key using errcode = '22023';
  end if;

  if p_channel not in ('inbox', 'email', 'push') then
    raise exception '渠道不合法：%', p_channel using errcode = '22023';
  end if;

  if p_subject_tpl is null or p_body_tpl is null then
    raise exception '标题模板与正文模板不能为空' using errcode = '22023';
  end if;

  if p_id is null then
    select * into v_row
    from public.message_templates
    where event_key = p_event_key
      and channel = p_channel
      and status = 'draft'
    order by version desc
    limit 1
    for update;

    if found then
      update public.message_templates
         set subject_tpl = p_subject_tpl,
             body_tpl    = p_body_tpl,
             updated_by  = v_uid
       where id = v_row.id
      returning * into v_row;
    else
      select coalesce(max(version), 0) + 1 into v_version
      from public.message_templates
      where event_key = p_event_key
        and channel = p_channel;

      insert into public.message_templates
        (event_key, channel, subject_tpl, body_tpl, version, status, updated_by)
      values
        (p_event_key, p_channel, p_subject_tpl, p_body_tpl, v_version, 'draft', v_uid)
      returning * into v_row;
    end if;
  else
    select * into v_row
    from public.message_templates
    where id = p_id
    for update;

    if not found then
      raise exception '模板不存在' using errcode = 'P0002';
    end if;

    if v_row.status <> 'draft' then
      raise exception '该版本非草稿状态（%），不可修改：请新建草稿版本或回滚', v_row.status
        using errcode = '22023';
    end if;

    if v_row.event_key is distinct from p_event_key
       or v_row.channel is distinct from p_channel then
      raise exception '模板事件与渠道不可修改' using errcode = '22023';
    end if;

    update public.message_templates
       set subject_tpl = p_subject_tpl,
           body_tpl    = p_body_tpl,
           updated_by  = v_uid
     where id = p_id
    returning * into v_row;
  end if;

  perform app.audit_log(
    'message', 'save', 'message_template', v_row.id::text,
    jsonb_build_object(
      'event_key', v_row.event_key, 'channel', v_row.channel,
      'version', v_row.version, 'status', v_row.status
    )
  );

  return v_row;
end;
$$;

comment on function app.upsert_message_template(text, text, text, text, uuid) is
  '保存通知模板草稿（仅 admin）：未注册事件拒绝；续编既有草稿或新建 version=max+1；写审计';

-- 4.2 发布：draft → published，并更新 current 指针（指向本版本）
create function app.publish_message_template(p_id uuid)
returns public.message_templates
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.message_templates;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.message_templates
  where id = p_id
  for update;

  if not found then
    raise exception '模板不存在' using errcode = 'P0002';
  end if;

  if v_row.status = 'disabled' then
    raise exception '已停用版本不可发布' using errcode = '22023';
  end if;

  if btrim(v_row.subject_tpl) = '' then
    raise exception '标题模板不能为空，无法发布' using errcode = '22023';
  end if;

  update public.message_templates
     set status = 'published',
         updated_by = (select auth.uid())
   where id = p_id
  returning * into v_row;

  insert into public.message_template_current (event_key, channel, template_id)
  values (v_row.event_key, v_row.channel, v_row.id)
  on conflict (event_key, channel) do update
    set template_id = excluded.template_id;

  perform app.audit_log(
    'message', 'publish', 'message_template', v_row.id::text,
    jsonb_build_object(
      'event_key', v_row.event_key, 'channel', v_row.channel, 'version', v_row.version
    )
  );

  return v_row;
end;
$$;

comment on function app.publish_message_template(uuid) is
  '发布通知模板（仅 admin）：draft → published 并把 current 指针指向本版本；写审计';

-- 4.3 回滚：复制指定旧版本为新版本（version=max+1）并置 current
create function app.rollback_message_template(p_id uuid)
returns public.message_templates
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_src     public.message_templates;
  v_new     public.message_templates;
  v_version integer;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_src
  from public.message_templates
  where id = p_id
  for update;

  if not found then
    raise exception '模板不存在' using errcode = 'P0002';
  end if;

  select coalesce(max(version), 0) + 1 into v_version
  from public.message_templates
  where event_key = v_src.event_key
    and channel = v_src.channel;

  insert into public.message_templates
    (event_key, channel, subject_tpl, body_tpl, version, status, updated_by)
  values
    (v_src.event_key, v_src.channel, v_src.subject_tpl, v_src.body_tpl,
     v_version, 'published', (select auth.uid()))
  returning * into v_new;

  insert into public.message_template_current (event_key, channel, template_id)
  values (v_new.event_key, v_new.channel, v_new.id)
  on conflict (event_key, channel) do update
    set template_id = excluded.template_id;

  perform app.audit_log(
    'message', 'rollback', 'message_template', v_new.id::text,
    jsonb_build_object(
      'event_key', v_new.event_key, 'channel', v_new.channel,
      'version', v_new.version, 'rollback_from', v_src.id, 'rollback_from_version', v_src.version
    )
  );

  return v_new;
end;
$$;

comment on function app.rollback_message_template(uuid) is
  '回滚通知模板（仅 admin）：复制指定旧版本为 max+1 新版本并置 current；历史保留；写审计';

-- 4.4 public 薄包装（PostgREST 仅暴露 public schema；权限判定在 app 实现内）
create function public.upsert_message_template(
  p_event_key   text,
  p_channel     text,
  p_subject_tpl text,
  p_body_tpl    text,
  p_id          uuid default null
)
returns public.message_templates
language sql
security definer
set search_path = ''
as $$
  select app.upsert_message_template(p_event_key, p_channel, p_subject_tpl, p_body_tpl, p_id)
$$;

create function public.publish_message_template(p_id uuid)
returns public.message_templates
language sql
security definer
set search_path = ''
as $$
  select app.publish_message_template(p_id)
$$;

create function public.rollback_message_template(p_id uuid)
returns public.message_templates
language sql
security definer
set search_path = ''
as $$
  select app.rollback_message_template(p_id)
$$;

comment on function public.upsert_message_template(text, text, text, text, uuid) is
  'upsert_message_template Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.publish_message_template(uuid) is
  'publish_message_template Data API 薄包装（admin 校验在 app 实现内）';
comment on function public.rollback_message_template(uuid) is
  'rollback_message_template Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 5. 模板渲染 + send_notification 升级（保持签名，create or replace）
-- ---------------------------------------------------------------------------
-- 5.1 渲染 helper：{{var}} replace 链；未提供（或 JSON null）变量保留占位符原文
create function app.render_message_template(
  p_template text,
  p_vars     jsonb
)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_text text := coalesce(p_template, '');
  v_vars jsonb := coalesce(p_vars, '{}'::jsonb);
  v_kv   record;
begin
  if jsonb_typeof(v_vars) <> 'object' then
    return v_text;
  end if;

  for v_kv in
    select key, value from jsonb_each_text(v_vars) as e(key, value)
  loop
    if v_kv.value is not null then
      v_text := replace(v_text, '{{' || v_kv.key || '}}', v_kv.value);
    end if;
  end loop;

  return v_text;
end;
$$;

comment on function app.render_message_template(text, jsonb) is
  '模板渲染：遍历 p_vars 键值 replace {{key}}；未提供变量保留占位符原文（不报错）；内部 helper';

revoke all on function app.render_message_template(text, jsonb)
  from public, anon, authenticated, service_role;

-- 5.2 send_notification：优先 (event_key,'inbox') 当前 published 模板；无模板走原 fallback
create or replace function app.send_notification(
  p_recipient uuid,
  p_event_key text,
  p_vars      jsonb
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_vars          jsonb := coalesce(p_vars, '{}'::jsonb);
  v_id            bigint;
  v_title         text;
  v_body          text;
  v_source_module text;
  v_subject_tpl   text;
  v_body_tpl      text;
begin
  if p_recipient is null then
    raise exception '收件人不能为空' using errcode = '22023';
  end if;
  if p_event_key is null or btrim(p_event_key) = '' then
    raise exception 'event_key 不能为空' using errcode = '22023';
  end if;

  -- message/005：按 (event_key,'inbox') 当前 published 模板渲染；
  -- 无模板（或指针指向非 published）走原 fallback（vars 直传文案）
  select t.subject_tpl, t.body_tpl
    into v_subject_tpl, v_body_tpl
    from public.message_template_current c
    join public.message_templates t
      on t.id = c.template_id
   where c.event_key = p_event_key
     and c.channel = 'inbox'
     and t.status = 'published';

  if v_subject_tpl is not null then
    v_title := app.render_message_template(v_subject_tpl, v_vars);
    v_body  := app.render_message_template(v_body_tpl, v_vars);
  else
    v_title := coalesce(nullif(v_vars ->> 'title', ''), p_event_key);
    v_body  := coalesce(v_vars ->> 'body', '');
  end if;

  v_source_module := coalesce(
    nullif(v_vars ->> 'source_module', ''),
    nullif(split_part(p_event_key, '.', 1), p_event_key)
  );

  insert into public.messages (
    recipient_id, event_key, title, body, source_module, ref_type, ref_id
  )
  values (
    p_recipient,
    p_event_key,
    v_title,
    v_body,
    v_source_module,
    nullif(v_vars ->> 'ref_type', ''),
    nullif(v_vars ->> 'ref_id', '')
  )
  returning id into v_id;

  -- 审计摘要：audit/001 并行开发中，用 to_regprocedure 软依赖（未合入则跳过，合入后自动生效）。
  -- 落点兼容 app/public 两种可能，audit/001 合入后由后续工单收敛为单一路径。
  if to_regprocedure('app.audit_log(text,text,text,text,jsonb)') is not null then
    perform app.audit_log(
      'message',
      'send_notification',
      'message',
      v_id::text,
      jsonb_build_object('recipient_id', p_recipient, 'event_key', p_event_key)
    );
  elsif to_regprocedure('public.audit_log(text,text,text,text,jsonb)') is not null then
    perform public.audit_log(
      'message',
      'send_notification',
      'message',
      v_id::text,
      jsonb_build_object('recipient_id', p_recipient, 'event_key', p_event_key)
    );
  end if;

  return v_id;
end;
$$;

comment on function app.send_notification(uuid, text, jsonb) is
  '通知发送唯一入口（INDEX 规则 3）：message/005 起按 (event_key,''inbox'') 当前 published 模板渲染，'
  '缺变量保留占位符；无模板走 vars fallback。不 GRANT API 角色，仅 SECURITY DEFINER wrapper 调用';

-- ---------------------------------------------------------------------------
-- 6. 授权与 RLS（三张表仅 admin SELECT；写全经 SECURITY DEFINER RPC，规则 10）
-- ---------------------------------------------------------------------------
revoke all on public.message_event_registry from public, anon, authenticated, service_role;
revoke all on public.message_templates from public, anon, authenticated, service_role;
revoke all on public.message_template_current from public, anon, authenticated, service_role;

grant select on public.message_event_registry to authenticated;
grant select on public.message_templates to authenticated;
grant select on public.message_template_current to authenticated;

alter table public.message_event_registry enable row level security;
alter table public.message_templates enable row level security;
alter table public.message_template_current enable row level security;

create policy message_event_registry_select_admin
on public.message_event_registry
for select
to authenticated
using (app.current_role() = 'admin');

create policy message_templates_select_admin
on public.message_templates
for select
to authenticated
using (app.current_role() = 'admin');

create policy message_template_current_select_admin
on public.message_template_current
for select
to authenticated
using (app.current_role() = 'admin');

-- 管理 RPC：登录用户可执行（函数内再做 admin 校验）；app 实现不直接 GRANT API 角色
revoke all on function app.upsert_message_template(text, text, text, text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function app.publish_message_template(uuid)
  from public, anon, authenticated, service_role;
revoke all on function app.rollback_message_template(uuid)
  from public, anon, authenticated, service_role;

revoke all on function public.upsert_message_template(text, text, text, text, uuid) from public, anon, service_role;
revoke all on function public.publish_message_template(uuid) from public, anon, service_role;
revoke all on function public.rollback_message_template(uuid) from public, anon, service_role;

grant execute on function public.upsert_message_template(text, text, text, text, uuid) to authenticated;
grant execute on function public.publish_message_template(uuid) to authenticated;
grant execute on function public.rollback_message_template(uuid) to authenticated;
