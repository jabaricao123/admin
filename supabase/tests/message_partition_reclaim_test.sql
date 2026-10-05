-- pgTAP：message 批次 4 并入项 2 — 投递明细过期分区 DETACH+DROP + 明细清理
-- 运行：supabase db reset && supabase test db
-- 覆盖：整月过期的 message_deliveries 分区 DETACH+DROP（父表与磁盘均不再持有）；
--       未过期分区按行删除保留期边界；返回删除行数不含 drop 分区；
--       message_delivery_attempts 同保留期清理；权限面（security invoker + 撤销 API 角色）。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(15);

-- ---------------------------------------------------------------------------
-- 夹具：u1 + 一条 messages（delivery FK 主体）；过期分区 202501 / 边界分区 202607 / 当月
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-4000-a000-000000000071', 'msg-reclaim-u1@example.com');

insert into public.messages (id, recipient_id, event_key, title, body)
overriding system value
values (9800071, '00000000-0000-4000-a000-000000000071', 'reclaim.test', '回收夹具', 'b');

select app.ensure_message_partition('2025-01-15'::date);
select app.ensure_message_partition((now() - interval '91 days')::date);

insert into public.message_deliveries
  (message_id, recipient_id, event_key, channel, status, idempotency_key, created_at)
values
  (9800071, '00000000-0000-4000-a000-000000000071', 'reclaim.test', 'inbox', 'success',
   'reclaim:dropped', '2025-01-15T00:00:00Z'),
  (9800071, '00000000-0000-4000-a000-000000000071', 'reclaim.test', 'inbox', 'success',
   'reclaim:deleted', now() - interval '91 days'),
  (9800071, '00000000-0000-4000-a000-000000000071', 'reclaim.test', 'inbox', 'success',
   'reclaim:fresh', now());

insert into public.message_delivery_attempts (delivery_id, attempt_no, status, attempted_at)
values
  (9800071, 1, 'failed', now() - interval '91 days'),
  (9800071, 2, 'queued', now());

-- ---------------------------------------------------------------------------
-- A. 结构与授权（4）
-- ---------------------------------------------------------------------------
select has_function(
  'app', 'cleanup_message_deliveries', array['integer'], 'app.cleanup_message_deliveries 存在'
);
select ok(
  (select not p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'cleanup_message_deliveries'),
  'cleanup_message_deliveries = SECURITY INVOKER + search_path 固定为空（cron/owner 可达）'
);
select ok(
  not has_function_privilege('authenticated', 'app.cleanup_message_deliveries(integer)', 'EXECUTE'),
  'authenticated 无分区清理执行权（INDEX 规则 10）'
);
select ok(
  not has_function_privilege('anon', 'app.cleanup_message_deliveries(integer)', 'EXECUTE')
  and not has_function_privilege('service_role', 'app.cleanup_message_deliveries(integer)', 'EXECUTE'),
  'anon / service_role 无分区清理执行权'
);

-- ---------------------------------------------------------------------------
-- B. 分区 DETACH+DROP 与行级边界（8）
-- ---------------------------------------------------------------------------
select ok(
  to_regclass('public.message_deliveries_202501') is not null
  and (select count(*) from public.message_deliveries where idempotency_key = 'reclaim:dropped') = 1,
  '夹具：202501 过期分区存在且含 1 行（drop 前 sanity）'
);
select is(
  app.cleanup_message_deliveries(),
  1,
  '清理返回 1（仅保留分区中 91 天前 1 行；drop 分区行不计入）'
);
select ok(
  to_regclass('public.message_deliveries_202501') is null,
  '整月过期的 202501 分区已 DETACH+DROP（父表不再持有）'
);
select is(
  (select count(*) from pg_inherits
    where inhparent = 'public.message_deliveries'::regclass
      and inhrelid::regclass::text = 'public.message_deliveries_202501'),
  0::bigint,
  '202501 已从父表分区列表移除（未留在 pg_inherits）'
);
select is(
  (select count(*) from public.message_deliveries where idempotency_key = 'reclaim:dropped'),
  0::bigint,
  'drop 分区内数据从父表视图消失'
);
select ok(
  to_regclass('public.message_deliveries_202607') is not null,
  '未整月过期的 202607 分区保留（仅行级删除）'
);
select is(
  (select count(*) from public.message_deliveries where idempotency_key = 'reclaim:deleted'),
  0::bigint,
  '保留分区中 91 天前的行已删除（保留期边界精确）'
);
select is(
  (select count(*) from public.message_deliveries where idempotency_key = 'reclaim:fresh'),
  1::bigint,
  '保留期内新行不受影响'
);

-- ---------------------------------------------------------------------------
-- C. 明细清理与幂等（2）
-- ---------------------------------------------------------------------------
select is(
  (select count(*) from public.message_delivery_attempts
    where delivery_id = 9800071 and attempted_at < now() - interval '90 days'),
  0::bigint,
  '91 天前的重发明细随保留期清理'
);
select is(app.cleanup_message_deliveries(), 0, '重复清理幂等（无更多可删行）');
select is(
  (select count(*) from public.message_delivery_attempts where delivery_id = 9800071),
  1::bigint,
  '保留期内明细（queued 第 2 次尝试）不受影响'
);

select * from finish();
rollback;
