-- pgTAP：message 批次 2 修复项 1 — messages 保留策略（已读 12 个月清理 + 未读/星标豁免 + cron 登记）
-- 运行：supabase db reset && supabase test db
-- 覆盖：cleanup_messages 结构/权限（security invoker + 撤销 API 角色）；
--       13 个月前已读删除、未读保留、星标保留、保留期内保留；自定义月数；参数校验；幂等；
--       cron.schedule + register_cron_job 登记。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(17);

-- ---------------------------------------------------------------------------
-- 夹具：u1；五类消息（13 月前已读/未读/星标、11 月前已读、12 月边界已读）
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-4000-a000-000000000061', 'msg-ret-u1@example.com');

insert into public.messages (id, recipient_id, event_key, title, body, read_at, starred, created_at)
overriding system value
values
  (9800061, '00000000-0000-4000-a000-000000000061', 'retention.test', '13月前已读', 'b',
   now() - interval '13 months', false, now() - interval '13 months'),
  (9800062, '00000000-0000-4000-a000-000000000061', 'retention.test', '13月前未读', 'b',
   null, false, now() - interval '13 months'),
  (9800063, '00000000-0000-4000-a000-000000000061', 'retention.test', '13月前星标', 'b',
   now() - interval '13 months', true, now() - interval '13 months'),
  (9800064, '00000000-0000-4000-a000-000000000061', 'retention.test', '11月前已读', 'b',
   now() - interval '11 months', false, now() - interval '11 months'),
  (9800065, '00000000-0000-4000-a000-000000000061', 'retention.test', '12月边界已读', 'b',
   now() - interval '12 months' + interval '1 day', false,
   now() - interval '12 months' + interval '1 day');

-- ---------------------------------------------------------------------------
-- A. 结构 / 授权（7）
-- ---------------------------------------------------------------------------
select has_function('app', 'cleanup_messages', array['integer'], 'app.cleanup_messages 存在');
select ok(
  (select not p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'cleanup_messages'),
  'cleanup_messages = SECURITY INVOKER + search_path 固定为空（cron/owner 可达）'
);
select ok(
  not has_function_privilege('authenticated', 'app.cleanup_messages(integer)', 'EXECUTE'),
  'authenticated 无清理执行权（INDEX 规则 10）'
);
select ok(
  not has_function_privilege('anon', 'app.cleanup_messages(integer)', 'EXECUTE'),
  'anon 无清理执行权'
);
select ok(
  not has_function_privilege('service_role', 'app.cleanup_messages(integer)', 'EXECUTE'),
  'service_role 无清理执行权'
);
select ok(
  (select count(*) = 1
     from public.system_cron_registry r
    where r.job_name = 'message-cleanup-inbox'
      and r.module = 'message'
      and r.cron_expr = '40 3 * * *'
      and r.owner_route = '/message/inbox'
      and r.status = 'active'),
  'register_cron_job 登记 message-cleanup-inbox（module=message，每日 03:40）'
);
select ok(
  (select count(*) = 1 from cron.job where jobname = 'message-cleanup-inbox'),
  'pg_cron 调度已注册（cron.job 同名 job）'
);

-- ---------------------------------------------------------------------------
-- B. 行为：清理边界（10）
-- ---------------------------------------------------------------------------
select is(app.cleanup_messages(), 1, '默认 12 个月：恰删除 1 条（13 月前已读）');
select is(
  (select count(*) from public.messages where id = 9800061),
  0::bigint,
  '13 个月前已读消息已删除'
);
select is(
  (select count(*) from public.messages where id = 9800062),
  1::bigint,
  '13 个月前未读保留（read_at 为未读唯一事实源）'
);
select is(
  (select count(*) from public.messages where id = 9800063),
  1::bigint,
  '13 个月前星标保留（starred 豁免）'
);
select is(
  (select count(*) from public.messages where id = 9800064),
  1::bigint,
  '11 个月前已读保留（未到 12 个月）'
);
select is(
  (select count(*) from public.messages where id = 9800065),
  1::bigint,
  '12 个月边界（12 月前 + 1 天）已读保留'
);
select is(app.cleanup_messages(), 0, '重复清理幂等（无更多可删）');
select is(
  app.cleanup_messages(24),
  0,
  '自定义保留 24 个月：13 个月前的已读（已删）与存量均不动'
);
select throws_ok(
  'select app.cleanup_messages(0)',
  '22023', '保留月数必须 >= 1：0',
  '保留月数 < 1 被拒（22023）'
);
select throws_ok(
  'select app.cleanup_messages(-1)',
  '22023', '保留月数必须 >= 1：-1',
  '负数保留月数被拒（22023）'
);

select * from finish();
rollback;
