-- pgTAP：message/004+005 — 事件注册表 + 通知文案模板 + 版本化 + send_notification 模板渲染
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构（表/列/约束/RLS/指针复合外键）；registry seed（8 事件）；register_message_event 幂等；
--       未注册事件拒绝；版本唯一；published 冻结（触发器 + RPC）；草稿续编 / 发布 / 回滚
--       （复制旧版为 max+1 新版本 + current 指针）；渲染（替换、缺变量保留占位符、JSON null）；
--       send_notification 走模板渲染与无模板 fallback；权限面（public 薄包装 authenticated 可执行、
--       app 实现与内部 RPC 不 GRANT、anon/service_role 无）。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(75);

-- ---------------------------------------------------------------------------
-- 夹具：admin（031）+ engineer（032，越权校验）
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-4000-a000-000000000031', 'msg-tpl-admin@example.com'),
  ('00000000-0000-4000-a000-000000000032', 'msg-tpl-eng@example.com');

update public.profiles set role = 'admin'::public.user_role
 where id = '00000000-0000-4000-a000-000000000031';

-- ---------------------------------------------------------------------------
-- A. 结构：表 / 列 / 约束 / RLS / 授权面（19）
-- ---------------------------------------------------------------------------
select has_table('public', 'message_event_registry', 'message_event_registry 表存在');
select has_table('public', 'message_templates', 'message_templates 表存在');
select has_table('public', 'message_template_current', 'message_template_current 表存在');

select col_is_pk('public', 'message_event_registry', 'event_key', 'registry.event_key 主键');
select col_type_is('public', 'message_event_registry', 'available_vars', 'jsonb', 'available_vars 为 jsonb');
select col_not_null('public', 'message_event_registry', 'available_vars', 'available_vars 非空');
select col_has_default('public', 'message_event_registry', 'available_vars', 'available_vars 有默认值');
select col_has_check('public', 'message_event_registry', 'available_vars', 'available_vars 有数组 check');

select col_is_pk(
  'public', 'message_template_current', array['event_key', 'channel'],
  'current 复合主键 (event_key, channel)'
);
select col_has_check('public', 'message_templates', 'channel', 'channel 有取值 check');
select col_has_check('public', 'message_templates', 'status', 'status 有取值 check');
select col_has_check('public', 'message_templates', 'version', 'version 有 >=1 check');
select has_index(
  'public', 'message_templates', 'message_templates_event_channel_version_uq',
  '(event_key, channel, version) 唯一约束存在'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.message_event_registry'::regclass)
  and (select relrowsecurity from pg_class where oid = 'public.message_templates'::regclass)
  and (select relrowsecurity from pg_class where oid = 'public.message_template_current'::regclass),
  '三张新表均启用 RLS'
);
select is(
  (select count(*) from pg_policies where schemaname = 'public' and tablename = 'message_templates'),
  1::bigint, 'templates 恰 1 条策略（admin SELECT）'
);
select is(
  (select count(*) from pg_policies
    where schemaname = 'public' and tablename in ('message_event_registry', 'message_template_current')),
  2::bigint, 'registry / current 各 1 条策略'
);
select ok(
  has_table_privilege('authenticated', 'public.message_event_registry', 'select')
  and has_table_privilege('authenticated', 'public.message_templates', 'select')
  and has_table_privilege('authenticated', 'public.message_template_current', 'select'),
  'authenticated 对三表仅有 SELECT'
);
select ok(
  not has_table_privilege('authenticated', 'public.message_templates', 'insert')
  and not has_table_privilege('authenticated', 'public.message_templates', 'update')
  and not has_table_privilege('authenticated', 'public.message_templates', 'delete'),
  'authenticated 无 templates 写权限（写全经 SECURITY DEFINER RPC）'
);
select ok(
  not has_table_privilege('anon', 'public.message_templates', 'select')
  and not has_table_privilege('service_role', 'public.message_templates', 'select'),
  'anon / service_role 无模板表读权限'
);

-- ---------------------------------------------------------------------------
-- B. registry seed（4）
-- ---------------------------------------------------------------------------
select is(
  (select count(*) from public.message_event_registry),
  8::bigint, 'seed 恰 8 个事件'
);
select is(
  (select array_agg(event_key order by event_key) from public.message_event_registry),
  array[
    'announcement.published', 'approval.approved', 'approval.pending',
    'approval.rejected', 'approval.urge', 'report.export_ready',
    'sync.run_finished', 'webhook.delivery_failed'
  ], 'seed 事件清单与规格一致'
);
select is(
  (select available_vars from public.message_event_registry where event_key = 'approval.pending'),
  '["initiator","title"]'::jsonb, 'approval.pending 变量清单 = initiator,title'
);
select is(
  (select count(*) from public.message_event_registry where registered_by is null),
  8::bigint, 'seed 行 registered_by 为 NULL（迁移内系统预置）'
);

-- ---------------------------------------------------------------------------
-- C. 函数存在 / 安全属性 / 授权面（12）
-- ---------------------------------------------------------------------------
select has_function(
  'app', 'register_message_event', array['text', 'text', 'text', 'jsonb'],
  'app.register_message_event 存在'
);
select has_function(
  'app', 'render_message_template', array['text', 'jsonb'],
  'app.render_message_template 存在'
);
select has_function(
  'app', 'upsert_message_template', array['text', 'text', 'text', 'text', 'uuid'],
  'app.upsert_message_template 存在'
);
select has_function(
  'public', 'upsert_message_template', array['text', 'text', 'text', 'text', 'uuid'],
  'public.upsert_message_template 薄包装存在'
);
select has_function('app', 'publish_message_template', array['uuid'], 'app.publish_message_template 存在');
select has_function('public', 'publish_message_template', array['uuid'], 'public.publish_message_template 薄包装存在');
select has_function('app', 'rollback_message_template', array['uuid'], 'app.rollback_message_template 存在');
select has_function('public', 'rollback_message_template', array['uuid'], 'public.rollback_message_template 薄包装存在');

select ok(
  (select count(*) = 8
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
      ('app', 'register_message_event'),
      ('app', 'upsert_message_template'), ('public', 'upsert_message_template'),
      ('app', 'publish_message_template'), ('public', 'publish_message_template'),
      ('app', 'rollback_message_template'), ('public', 'rollback_message_template'),
      ('app', 'protect_published_message_template')
    )
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '模板 RPC / 冻结触发器 = SECURITY DEFINER + search_path 固定为空'
);
select ok(
  (select count(*) = 1
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = 'render_message_template'
      and not p.prosecdef
      and p.proconfig @> array['search_path=""']),
  'render_message_template = SECURITY INVOKER + search_path 固定为空'
);
select ok(
  has_function_privilege('authenticated', 'public.upsert_message_template(text,text,text,text,uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.publish_message_template(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.rollback_message_template(uuid)', 'EXECUTE'),
  'authenticated 可执行 3 个 public 管理 RPC'
);
select ok(
  not has_function_privilege('authenticated', 'app.upsert_message_template(text,text,text,text,uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.publish_message_template(uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.rollback_message_template(uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.register_message_event(text,text,text,jsonb)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.render_message_template(text,jsonb)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'app.send_notification(uuid,text,jsonb)', 'EXECUTE'),
  'app 实现 / 内部 RPC / send_notification 不对 authenticated 开放（INDEX 规则 10）'
);
select ok(
  not has_function_privilege('anon', 'public.upsert_message_template(text,text,text,text,uuid)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.upsert_message_template(text,text,text,text,uuid)', 'EXECUTE'),
  'anon / service_role 无管理 RPC 执行权'
);

-- ---------------------------------------------------------------------------
-- D. register_message_event：幂等 upsert（4，postgres 直调，函数无 GRANT）
-- ---------------------------------------------------------------------------
select is(
  (select module from app.register_message_event('demo.manual', 'demo', '演示事件', '["a","b"]'::jsonb)),
  'demo', '首次登记返回 module'
);
select is(
  (select available_vars from app.register_message_event('demo.manual', 'demo2', '演示事件 2', '["c"]'::jsonb)),
  '["c"]'::jsonb, '重复登记幂等更新 available_vars'
);
select is(
  (select count(*) from public.message_event_registry where event_key = 'demo.manual'),
  1::bigint, '重复登记不产生新行'
);
select throws_ok(
  $$ select app.register_message_event('demo.bad', 'demo', 'x', '{"a":1}'::jsonb) $$,
  '22023', 'available_vars 必须是 JSON 字符串数组', 'available_vars 非数组被拒'
);

-- ---------------------------------------------------------------------------
-- E. 渲染 helper（3，postgres 直调）
-- ---------------------------------------------------------------------------
select is(
  app.render_message_template('你好 {{a}}，{{b}}', '{"a":"张三"}'::jsonb),
  '你好 张三，{{b}}', '替换已提供变量，缺变量保留占位符原文'
);
select is(
  app.render_message_template('{{x}}-{{x}}', '{"x":"1"}'::jsonb),
  '1-1', '同一变量多处引用全部替换'
);
select is(
  app.render_message_template('{{x}}', '{"x":null}'::jsonb),
  '{{x}}', 'JSON null 变量保留占位符原文'
);

-- ---------------------------------------------------------------------------
-- F. 管理流程：admin（031）经 public RPC（18）
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-000000000031","role":"authenticated"}',
  true
);
set local role authenticated;

-- F1 保存草稿：新建 v1；重复保存续编同一草稿；带 id 更新内容
select is(
  (select status || '-v' || version
     from public.upsert_message_template(
       'approval.pending', 'inbox',
       '待办：{{title}}', '发起人 {{initiator}} 提交的申请待你处理')),
  'draft-v1', '首次保存新建 draft v1'
);
select is(
  (select status || '-v' || version
     from public.upsert_message_template(
       'approval.pending', 'inbox',
       '待办：{{title}}', '发起人 {{initiator}} 提交的申请待你处理')),
  'draft-v1', '重复保存续编同一草稿而非新建版本'
);
select is(
  (select count(*) from public.message_templates where event_key = 'approval.pending' and channel = 'inbox'),
  1::bigint, '草稿续编后仍仅 1 个版本'
);
select is(
  (select subject_tpl
     from public.upsert_message_template(
       'approval.pending', 'inbox',
       '待办：{{title}}（来自 {{initiator}}）',
       '发起人 {{initiator}} 提交的申请待你处理',
       (select id from public.message_templates
         where event_key = 'approval.pending' and channel = 'inbox' and version = 1))),
  '待办：{{title}}（来自 {{initiator}}）', '带 id 保存更新草稿标题'
);
select is(
  (select subject_tpl from public.upsert_message_template(
     'approval.pending', 'email', '标题 {{title}}', '正文')),
  '标题 {{title}}', 'public 包装默认参数（p_id 省略）可用'
);

-- F2 未注册事件 / 非法渠道 / 非 admin 拒绝
select throws_ok(
  $$ select public.upsert_message_template('nope.event', 'inbox', 'x', 'y') $$,
  '22023', '事件未注册，不可创建模板：nope.event', '未注册事件建模板被拒'
);
select throws_ok(
  $$ select public.upsert_message_template('approval.pending', 'sms', 'x', 'y') $$,
  '22023', '渠道不合法：sms', '非法渠道被拒（本期仅 inbox/email/push）'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-000000000032","role":"authenticated"}',
  true
);
select throws_ok(
  $$ select public.upsert_message_template('approval.pending', 'email', 'x', 'y') $$,
  '42501', '仅管理员可执行此操作', '非 admin 保存草稿被拒'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-000000000031","role":"authenticated"}',
  true
);

-- F3 发布 v1 + current 指针
select is(
  (select status || '-v' || version
     from public.publish_message_template(
       (select id from public.message_templates
         where event_key = 'approval.pending' and channel = 'inbox' and version = 1))),
  'published-v1', '发布 draft v1 → published'
);
select is(
  (select t.version
     from public.message_template_current c
     join public.message_templates t on t.id = c.template_id
    where c.event_key = 'approval.pending' and c.channel = 'inbox'),
  1, 'current 指针指向 v1'
);
select is(
  (select count(*) from public.message_templates where event_key = 'approval.pending' and channel = 'inbox'),
  1::bigint, '发布不产生额外行'
);

-- F4 发布后不可改：RPC 拒绝；保存 = 新草稿 v2
select throws_ok(
  $$ select public.upsert_message_template(
       'approval.pending', 'inbox', 'hack', 'hack',
       (select id from public.message_templates
         where event_key = 'approval.pending' and channel = 'inbox' and version = 1)) $$,
  '22023', '该版本非草稿状态（published），不可修改：请新建草稿版本或回滚',
  'published 版本经 RPC 修改被拒'
);
select is(
  (select version
     from public.upsert_message_template(
       'approval.pending', 'inbox',
       '待办：{{title}}（来自 {{initiator}}）',
       '发起人 {{initiator}} 提交的申请待你处理')),
  2, '发布后保存自动新建草稿 v2'
);
select is(
  (select status from public.message_templates
    where event_key = 'approval.pending' and channel = 'inbox' and version = 1),
  'published', 'v1 保持 published 不可变（历史保留）'
);

-- F5 发布 v2，current 指向 v2
select is(
  (select status || '-v' || version
     from public.publish_message_template(
       (select id from public.message_templates
         where event_key = 'approval.pending' and channel = 'inbox' and version = 2))),
  'published-v2', '发布 v2'
);
select is(
  (select t.version
     from public.message_template_current c
     join public.message_templates t on t.id = c.template_id
    where c.event_key = 'approval.pending' and c.channel = 'inbox'),
  2, 'current 指针更新为 v2'
);

-- F6 回滚 v1 → 新 v3（内容=旧版）+ current 指向 v3
select is(
  (select version || '/' || status
     from public.rollback_message_template(
       (select id from public.message_templates
         where event_key = 'approval.pending' and channel = 'inbox' and version = 1))),
  '3/published', '回滚 v1 → 新建 v3 published'
);
select is(
  (select subject_tpl from public.message_templates
    where event_key = 'approval.pending' and channel = 'inbox' and version = 3),
  (select subject_tpl from public.message_templates
    where event_key = 'approval.pending' and channel = 'inbox' and version = 1),
  '回滚新版本内容 = 旧版 v1 内容'
);
select is(
  (select t.version
     from public.message_template_current c
     join public.message_templates t on t.id = c.template_id
    where c.event_key = 'approval.pending' and c.channel = 'inbox'),
  3, '回滚后 current 指向新行 v3'
);
select is(
  (select count(*) from public.message_templates where event_key = 'approval.pending' and channel = 'inbox'),
  3::bigint, '回滚后 v1/v2/v3 历史全部保留'
);

-- F7 非 admin 读模板：RLS 收口（2）
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-4000-a000-000000000032","role":"authenticated"}',
  true
);
select is(
  (select count(*) from public.message_templates),
  0::bigint, '非 admin 经 RLS 看不到任何模板'
);
select is(
  (select count(*) from public.message_event_registry),
  0::bigint, '非 admin 经 RLS 看不到事件注册表'
);

reset role;

-- ---------------------------------------------------------------------------
-- G. 约束与触发器（postgres 直查，4）
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ insert into public.message_templates (event_key, channel, subject_tpl, body_tpl, version)
     values ('approval.pending', 'inbox', 'x', 'y', 1) $$,
  '23505', null, '(event_key, channel, version) 唯一约束拒绝重复版本'
);
select throws_ok(
  $$ update public.message_templates set subject_tpl = 'hack'
      where event_key = 'approval.pending' and channel = 'inbox' and version = 1 $$,
  '22023', '通知模板 approval.pending / inbox v1 非草稿状态，内容不可修改（请发布新版本或回滚）',
  'published 版本直接 UPDATE 被冻结触发器拒绝'
);
select throws_ok(
  $$ insert into public.message_template_current (event_key, channel, template_id)
     values (
       'approval.pending', 'email',
       (select id from public.message_templates
         where event_key = 'approval.pending' and channel = 'inbox' and version = 1)
     ) $$,
  '23503', null, 'current 指针复合外键拒绝跨渠道指向'
);
select throws_ok(
  $$ insert into public.message_templates (event_key, channel, subject_tpl, body_tpl)
     values ('nope.event', 'inbox', 'x', 'y') $$,
  '23503', null, 'templates.event_key 外键指向 registry（未注册事件直插被拒）'
);

-- ---------------------------------------------------------------------------
-- H. send_notification 模板渲染（postgres 直调；current=v3，内容=v1）（7）
-- ---------------------------------------------------------------------------
select app.send_notification(
  '00000000-0000-4000-a000-000000000032',
  'approval.pending',
  '{"title":"请假申请","initiator":"李雷","source_module":"approval","ref_type":"approval_instance","ref_id":"7"}'::jsonb
);
select is(
  (select title from public.messages
    where recipient_id = '00000000-0000-4000-a000-000000000032' and event_key = 'approval.pending'
    order by id desc limit 1),
  '待办：请假申请（来自 李雷）', 'send_notification 标题 = 模板渲染结果（非 vars fallback）'
);
select is(
  (select body from public.messages
    where recipient_id = '00000000-0000-4000-a000-000000000032' and event_key = 'approval.pending'
    order by id desc limit 1),
  '发起人 李雷 提交的申请待你处理', 'send_notification 正文 = 模板渲染结果'
);
select is(
  (select ref_id from public.messages
    where recipient_id = '00000000-0000-4000-a000-000000000032' and event_key = 'approval.pending'
    order by id desc limit 1),
  '7', '模板渲染仍保留 vars 的 ref 回填'
);

select app.send_notification(
  '00000000-0000-4000-a000-000000000032',
  'approval.pending',
  '{"title":"第二条"}'::jsonb
);
select is(
  (select body from public.messages
    where recipient_id = '00000000-0000-4000-a000-000000000032' and event_key = 'approval.pending'
    order by id desc limit 1),
  '发起人 {{initiator}} 提交的申请待你处理', '未提供变量保留占位符原文（缺变量降级不报错）'
);

select app.send_notification(
  '00000000-0000-4000-a000-000000000032',
  'sync.run_finished',
  '{"title":"同步完成","body":"3 行"}'::jsonb
);
select is(
  (select title from public.messages
    where recipient_id = '00000000-0000-4000-a000-000000000032' and event_key = 'sync.run_finished'),
  '同步完成', '无模板事件走原 vars fallback（title）'
);
select is(
  (select body from public.messages
    where recipient_id = '00000000-0000-4000-a000-000000000032' and event_key = 'sync.run_finished'),
  '3 行', '无模板事件走原 vars fallback（body）'
);

select * from finish();
rollback;
