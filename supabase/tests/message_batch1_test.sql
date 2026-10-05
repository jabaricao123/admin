-- pgTAP：message 批次 1 修复（事件注册表修正 + 合并语义 + 模板并发/校验）
-- 运行：supabase db reset && supabase test db
-- 覆盖：
--   1. 注册表与真实发送键对齐：sync.execute_failed 登记、幽灵事件 sync.run_finished 删除、
--      report.export_ready download_url 合并补回、webhook.delivery_failed 发送方补传 vars；
--      数据驱动扫描：所有 send_notification 调用事件键 ⊆ message_event_registry；
--   2. register_message_event 并集合并不覆盖；元素字符串校验（函数 + 表 check）；
--      unregister_message_event_vars 删除变量、已发布模板引用时拒绝并列引用模板；
--   3. 模板并发锁（advisory）与占位符差集 warning（warning 不阻断保存）。
-- 说明：本文件扫描结果与硬编码清单双向锁定——新事件接入时须同步更新下方清单与注册表。
--       夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(19);

-- ---------------------------------------------------------------------------
-- A. 注册表与真实发送键对齐（4）
-- ---------------------------------------------------------------------------
select is(
  (select available_vars from public.message_event_registry where event_key = 'sync.execute_failed'),
  '["task_name","error","run_id"]'::jsonb,
  'sync.execute_failed 已登记（同步失败通知事件）'
);
select is(
  (select count(*) from public.message_event_registry where event_key = 'sync.run_finished'),
  0::bigint,
  '幽灵事件 sync.run_finished 已从注册表删除（emit_event 不经 send_notification）'
);
select is(
  (select available_vars from public.message_event_registry where event_key = 'report.export_ready'),
  '["title","body","report_name","row_count","summary","download_url"]'::jsonb,
  'report.export_ready download_url 合并补回且原变量不丢'
);
select ok(
  (select position('''endpoint'', v_hook.name' in pg_get_functiondef(p.oid)) > 0
      and position('''event'', v_event.event' in pg_get_functiondef(p.oid)) > 0
      and position('''attempt'', v_hook.failed_count' in pg_get_functiondef(p.oid)) > 0
      and position('''error'', coalesce(v_hook.last_error' in pg_get_functiondef(p.oid)) > 0
     from pg_proc p
    where p.oid = 'app.finalize_webhook_deliveries()'::regprocedure),
  'webhook 失败通知发送方补传 endpoint/event/attempt/error（注册表丰富 vars 对齐）'
);

-- ---------------------------------------------------------------------------
-- B. 数据驱动：send_notification 调用事件键 ⊆ 注册表（2，硬编码清单双向锁定）
-- ---------------------------------------------------------------------------
select is(
  (
    select coalesce(array_agg(distinct m[1] order by m[1]), '{}'::text[])
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral regexp_matches(
      p.prosrc,
      'send_notification\s*\(\s*[^,]+,\s*''([^'']+)''',
      'g'
    ) as m
    where n.nspname in ('app', 'public')
      and p.prosrc is not null
  ),
  array[
    'announcement.published', 'approval.approved', 'approval.cc', 'approval.pending',
    'approval.rejected', 'approval.urge', 'report.export_failed', 'report.export_ready',
    'report.subscription_failed', 'sync.execute_failed', 'webhook.delivery_failed'
  ],
  '扫描 send_notification 调用事件键与硬编码清单一致（新事件接入须同步更新清单与注册表）'
);
select ok(
  not exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral regexp_matches(
      p.prosrc,
      'send_notification\s*\(\s*[^,]+,\s*''([^'']+)''',
      'g'
    ) as m
    where n.nspname in ('app', 'public')
      and p.prosrc is not null
      and not exists (
        select 1 from public.message_event_registry r where r.event_key = m[1]
      )
  ),
  '所有 send_notification 事件键均已登记 message_event_registry（无未注册发送）'
);

-- ---------------------------------------------------------------------------
-- C. register_message_event：并集合并不覆盖 + 元素字符串校验（4）
-- ---------------------------------------------------------------------------
select is(
  (select available_vars from app.register_message_event(
     'smoke.batch1', 'smoke', '批次 1 测试事件', '["x","y"]'::jsonb)),
  '["x","y"]'::jsonb,
  '首次登记返回入参变量'
);
select is(
  (select available_vars from app.register_message_event(
     'smoke.batch1', 'smoke', '批次 1 测试事件', '["y","z"]'::jsonb)),
  '["x","y","z"]'::jsonb,
  '再次登记不同变量 = 并集去重（不覆盖既有变量）'
);
select throws_ok(
  $$ select app.register_message_event('smoke.batch1', 'smoke', 'x', '[1,2]'::jsonb) $$,
  '22023', 'available_vars 元素必须是字符串',
  '非字符串元素被函数入口拒绝'
);
select throws_ok(
  $$ insert into public.message_event_registry (event_key, module, available_vars)
     values ('smoke.bad.elem', 'smoke', '[1]'::jsonb) $$,
  '23514', null,
  '表 check 兜底拒绝非字符串元素直插（available_vars 纯字符串数组）'
);

-- ---------------------------------------------------------------------------
-- D. unregister_message_event_vars：注销与已发布模板引用拒绝（6）
-- ---------------------------------------------------------------------------
select is(
  (select available_vars from app.unregister_message_event_vars('smoke.batch1', '["x"]'::jsonb)),
  '["y","z"]'::jsonb,
  '注销变量返回剩余变量（x 被移除）'
);
select throws_ok(
  $$ select app.unregister_message_event_vars('smoke.batch1', '[1]'::jsonb) $$,
  '22023', '待注销变量元素必须是字符串',
  '注销入参非字符串元素被拒'
);
select throws_ok(
  $$ select app.unregister_message_event_vars('smoke.batch1', '{"a":1}'::jsonb) $$,
  '22023', '待注销变量必须是 JSON 字符串数组',
  '注销入参非数组被拒'
);
select throws_ok(
  $$ select app.unregister_message_event_vars('nope.event', '["a"]'::jsonb) $$,
  'P0002', '事件未注册：nope.event',
  '注销未注册事件报 P0002'
);

-- 已发布模板引用：approval.pending 建 inbox 模板（引用 initiator）并发布
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
select id as tpl_id
from public.upsert_message_template(
  'approval.pending', 'inbox', '待办：{{title}}', '发起人 {{initiator}} 提交的申请待你处理'
) \gset
select public.publish_message_template(:'tpl_id');

select throws_ok(
  $$ select app.unregister_message_event_vars('approval.pending', '["initiator"]'::jsonb) $$,
  '22023', '变量 initiator 仍被已发布模板引用，不可注销：approval.pending / inbox v1',
  '注销被已发布模板引用的变量被拒并列出引用模板'
);
select is(
  (select available_vars from public.message_event_registry where event_key = 'approval.pending'),
  '["initiator","title"]'::jsonb,
  '注销被拒后注册表变量保持不变'
);

-- ---------------------------------------------------------------------------
-- E. 模板并发锁 + 占位符差集 warning（3）
-- ---------------------------------------------------------------------------
select lives_ok(
  $$ select app.upsert_message_template(
       'approval.cc', 'inbox', '抄送：{{title}}', '发起人 {{initiator}} / 未知 {{nope}}') $$,
  '模板使用未登记占位符 {{nope}} 仅 warning，不阻断保存'
);
select is(
  (select body_tpl from public.message_templates
    where event_key = 'approval.cc' and channel = 'inbox'),
  '发起人 {{initiator}} / 未知 {{nope}}',
  'warning 路径下模板内容正常落库'
);
select ok(
  (select position('pg_advisory_xact_lock' in pg_get_functiondef(p.oid)) > 0
      and position('message_template:' in pg_get_functiondef(p.oid)) > 0
     from pg_proc p
    where p.oid = 'app.upsert_message_template(text,text,text,text,uuid)'::regprocedure),
  'upsert_message_template 版本计算带 (event_key, channel) 级 advisory xact 锁'
);

select * from finish();
rollback;
