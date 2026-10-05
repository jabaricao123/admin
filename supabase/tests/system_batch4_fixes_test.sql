-- pgTAP：system 批次 2 交付 · 批次 4 并入项（system_batch4_fixes）
-- 覆盖：
--   * publish_announcement：轻量分批结构（v_batch_size / pg_sleep(0) / notify_batches），
--     全量通知 notified=active 数、批数=ceil(active/500)（501+ 用户真实跨批），
--     合并保留批 1 的 audience 过滤（role:engineer 只发 engineer）；
--   * upsert_setting：key 级 advisory xact 锁（prosrc）防并发首建历史失真；
--     合并保留批 1 is_sensitive 语义（非 admin 读敏感键 → null，审计留 is_sensitive）。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(15);

-- ---------------------------------------------------------------------------
-- 1. publish_announcement 分批结构（3，prosrc 断言）
-- ---------------------------------------------------------------------------
select ok(
  (select p.prosrc like '%v_batch_size%'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'publish_announcement'),
  'publish_announcement 含分批常量 v_batch_size（每批 ≤500）'
);
select ok(
  (select p.prosrc like '%pg_sleep(0)%'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'publish_announcement'),
  'publish_announcement 批间 pg_sleep(0) 轻量让步'
);
select ok(
  (select p.prosrc like '%notify_batches%'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'publish_announcement'),
  'publish_announcement 记录批数（可观测）'
);

-- ---------------------------------------------------------------------------
-- 夹具：扩到 501 个额外 active 用户，使全员通知真实跨 2 批
-- （auth.users 触发器建 profiles，默认 role=engineer）
-- ---------------------------------------------------------------------------
insert into auth.users (id, email)
select gen_random_uuid(), format('pgtap.bt4.%s@example.com', g)
from generate_series(1, 501) g;

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

-- ---------------------------------------------------------------------------
-- 2. 全量通知：notified / 批数 / 站内信矩阵（4）
-- ---------------------------------------------------------------------------
select public.upsert_announcement(
  '批次二分批公告', '验证 500/批轻量分批。',
  now() - interval '1 hour', now() + interval '7 days', 'all', false
) as ann_all \gset

select public.publish_announcement((:'ann_all'::jsonb ->> 'id')::uuid, true) as pub_all \gset

-- messages 表仅本人可读（无 admin 策略）：计数断言切回 superuser
reset role;

select is(
  (:'pub_all'::jsonb ->> 'notified')::integer,
  (select count(*)::integer from public.profiles where status = 'active'),
  '全员通知 notified=active 用户数（best-effort 全成功）'
);
select is(
  (:'pub_all'::jsonb ->> 'notify_batches')::integer,
  (
    select ((count(*) + 499) / 500)::integer
    from public.profiles
    where status = 'active'
  ),
  '批数 = ceil(active/500)（501+ 用户真实跨批）'
);
select is(
  (select count(*) from public.messages
    where event_key = 'announcement.published'
      and ref_id = (:'ann_all'::jsonb ->> 'id')),
  (select count(*) from public.profiles where status = 'active'),
  '站内信条数=active 用户数（分批不丢收件人）'
);
select is(
  (select count(distinct recipient_id) from public.messages
    where event_key = 'announcement.published'
      and ref_id = (:'ann_all'::jsonb ->> 'id')),
  (select count(*) from public.profiles where status = 'active'),
  '每个 active 用户恰 1 条（无重复投递）'
);

-- ---------------------------------------------------------------------------
-- 3. audience 过滤（批 1）在合并后保持：role:engineer 只发 engineer（2）
-- ---------------------------------------------------------------------------
set local role authenticated;

select public.upsert_announcement(
  '工程师分批公告', '仅工程师。',
  now() - interval '1 hour', now() + interval '7 days', 'role:engineer', false
) as ann_eng \gset
select public.publish_announcement((:'ann_eng'::jsonb ->> 'id')::uuid, true) as pub_eng \gset

reset role;

select is(
  (:'pub_eng'::jsonb ->> 'notified')::integer,
  (
    select count(*)::integer
    from public.profiles p
    where p.status = 'active'
      and coalesce(
            (select r.code from public.roles r where r.id = p.role_id),
            p.role::text
          ) = 'engineer'
  ),
  'role:engineer 公告 notified=engineer active 数'
);
select is(
  (select count(*) from public.messages m
    join public.profiles p on p.id = m.recipient_id
   where m.event_key = 'announcement.published'
     and m.ref_id = (:'ann_eng'::jsonb ->> 'id')
     and coalesce(
           (select r.code from public.roles r where r.id = p.role_id),
           p.role::text
         ) <> 'engineer'),
  0::bigint,
  'role:engineer 公告无非 engineer 收件人（范围语义只在展示侧的缺陷已修）'
);

-- ---------------------------------------------------------------------------
-- 4. upsert_setting：advisory 锁 + is_sensitive 语义保持（6）
-- ---------------------------------------------------------------------------
reset role;

select ok(
  (select p.prosrc like '%pg_advisory_xact_lock%'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'upsert_setting'),
  'upsert_setting 含 pg_advisory_xact_lock（同 key 写串行化，防首建竞态）'
);

set local role authenticated;
select lives_ok(
  $$ select public.upsert_setting(
       'pgtap.bt4.secret', '"v"'::jsonb, '测试', 'string', '批次 4 敏感键', true
     ) $$,
  'admin 新建敏感参数成功（六参签名，is_sensitive=true）'
);
select is(
  (select public.get_setting('pgtap.bt4.secret')),
  '"v"'::jsonb,
  'admin 读敏感键返回正常值'
);
reset role;

select is(
  (select old_value from public.system_setting_history
    where key = 'pgtap.bt4.secret' order by id desc limit 1),
  null::jsonb,
  '首建历史 old_value=NULL（advisory 锁不改变首建语义）'
);
select ok(
  (select (diff ->> 'is_sensitive')::boolean
     from public.audit_operations
    where module = 'system' and action = 'upsert'
      and object_type = 'setting' and object_id = 'pgtap.bt4.secret'
    order by id desc limit 1),
  '审计记录 is_sensitive=true（批 1 语义保留）'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select public.get_setting('pgtap.bt4.secret')),
  null::jsonb,
  'engineer 读敏感键返回 NULL（批 1 准入语义保留）'
);
reset role;

select * from finish();
rollback;
