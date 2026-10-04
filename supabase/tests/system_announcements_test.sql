-- pgTAP：system/013 —— system_announcements + 状态机 RPC + published_announcements_v + 到期归档
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构（表/列/约束/RLS）；状态机（draft→published→offline/archived；非法跳转拒绝）；
--       发布校验（时段必填/合法、范围 all/role:<码> 校验）与审计；通知可选开关（p_notify）；
--       视图可见性（时段内 + 范围匹配；草稿/下线/未来/过期不可见）；RLS 表级直读；
--       到期自动归档（pg_cron 登记）；GRANT 面（档案 RPC 不 GRANT、写仅 RPC、anon 拒绝）。
-- 说明：夹具只在本事务内生效，finish 后 rollback。

begin;

select plan(94);

-- ===========================================================================
-- 1. 结构：表 / 列 / 约束 / RLS / 视图（16）
-- ===========================================================================
select has_table('public', 'system_announcements', 'system_announcements 表存在');
select col_is_pk('public', 'system_announcements', 'id', 'id 为主键');
select col_type_is('public', 'system_announcements', 'title', 'text', 'title 为 text');
select col_type_is('public', 'system_announcements', 'content', 'text', 'content 为 text');
select col_type_is('public', 'system_announcements', 'starts_at', 'timestamp with time zone', 'starts_at 为 timestamptz');
select col_type_is('public', 'system_announcements', 'ends_at', 'timestamp with time zone', 'ends_at 为 timestamptz');
select col_type_is('public', 'system_announcements', 'audience', 'text', 'audience 为 text');
select col_type_is('public', 'system_announcements', 'pinned', 'boolean', 'pinned 为 boolean');
select col_has_default('public', 'system_announcements', 'audience', 'audience 有默认值');
select col_has_default('public', 'system_announcements', 'pinned', 'pinned 有默认值');
select col_has_default('public', 'system_announcements', 'status', 'status 有默认值');
select col_not_null('public', 'system_announcements', 'title', 'title 非空');
select col_not_null('public', 'system_announcements', 'content', 'content 非空');
select col_has_check('public', 'system_announcements', 'status', 'status 有取值 check 约束');
select is(
  (select relrowsecurity from pg_class where oid = 'public.system_announcements'::regclass),
  true,
  'system_announcements 已启用 RLS'
);
select has_view('public', 'published_announcements_v', 'published_announcements_v 视图存在');

-- ===========================================================================
-- 2. 函数存在性 + SECURITY DEFINER + GRANT 面（24）
-- ===========================================================================
select has_function(
  'app', 'upsert_announcement', array['text', 'text', 'timestamp with time zone', 'timestamp with time zone', 'text', 'boolean', 'uuid'],
  'app.upsert_announcement 存在'
);
select has_function(
  'public', 'upsert_announcement', array['text', 'text', 'timestamp with time zone', 'timestamp with time zone', 'text', 'boolean', 'uuid'],
  'public.upsert_announcement 薄包装存在'
);
select has_function('app', 'publish_announcement', array['uuid', 'boolean'], 'app.publish_announcement 存在');
select has_function('public', 'publish_announcement', array['uuid', 'boolean'], 'public.publish_announcement 薄包装存在');
select has_function('app', 'offline_announcement', array['uuid'], 'app.offline_announcement 存在');
select has_function('public', 'offline_announcement', array['uuid'], 'public.offline_announcement 薄包装存在');
select has_function('app', 'archive_expired_announcements', 'app.archive_expired_announcements 存在');
select has_function('app', 'get_announcements', 'app.get_announcements 存在');
select has_function('public', 'get_announcements', 'public.get_announcements 薄包装存在');
select ok(
  (select count(*) = 6
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname in ('upsert_announcement', 'publish_announcement', 'offline_announcement',
                        'archive_expired_announcements', 'get_announcements',
                        'validate_announcement_audience')
      and p.proconfig @> array['search_path=""']
      and (p.proname = 'validate_announcement_audience' or p.prosecdef)),
  'app 侧 6 函数 search_path 固定为空（validate helper 为纯校验非 DEFINER）'
);
select ok(
  (select count(*) = 4
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('upsert_announcement', 'publish_announcement',
                        'offline_announcement', 'get_announcements')
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  'public 侧 4 薄包装均 security definer + search_path 固定为空'
);
select ok(
  has_function_privilege(
    'authenticated',
    'public.upsert_announcement(text,text,timestamp with time zone,timestamp with time zone,text,boolean,uuid)',
    'EXECUTE'),
  'authenticated 可执行 public.upsert_announcement（函数内 admin 校验）'
);
select ok(
  has_function_privilege('authenticated', 'public.publish_announcement(uuid,boolean)', 'EXECUTE'),
  'authenticated 可执行 public.publish_announcement（函数内 admin 校验）'
);
select ok(
  has_function_privilege('authenticated', 'public.offline_announcement(uuid)', 'EXECUTE'),
  'authenticated 可执行 public.offline_announcement（函数内 admin 校验）'
);
select ok(
  has_function_privilege('authenticated', 'public.get_announcements()', 'EXECUTE'),
  'authenticated 可执行 public.get_announcements（函数内 admin 校验）'
);
select ok(
  not has_function_privilege('authenticated', 'app.archive_expired_announcements()', 'EXECUTE'),
  'authenticated 无 archive_expired_announcements 执行权（规则 10）'
);
select ok(
  not has_function_privilege('authenticated', 'app.validate_announcement_audience(text)', 'EXECUTE'),
  'authenticated 无内部范围校验 helper 执行权'
);
select ok(
  not has_function_privilege(
    'anon',
    'public.upsert_announcement(text,text,timestamp with time zone,timestamp with time zone,text,boolean,uuid)',
    'EXECUTE'),
  'anon 无 public.upsert_announcement 执行权'
);
select ok(
  has_table_privilege('authenticated', 'public.system_announcements', 'SELECT'),
  'authenticated 对 system_announcements 有 SELECT'
);
select ok(
  not has_table_privilege('authenticated', 'public.system_announcements', 'INSERT'),
  'authenticated 对 system_announcements 无 INSERT（写仅 RPC）'
);
select ok(
  not has_table_privilege('authenticated', 'public.system_announcements', 'UPDATE'),
  'authenticated 对 system_announcements 无 UPDATE（写仅 RPC）'
);
select ok(
  not has_table_privilege('authenticated', 'public.system_announcements', 'DELETE'),
  'authenticated 对 system_announcements 无 DELETE（写仅 RPC）'
);
select ok(
  has_table_privilege('authenticated', 'public.published_announcements_v', 'SELECT'),
  'authenticated 对 published_announcements_v 有 SELECT'
);
select ok(
  not has_table_privilege('anon', 'public.published_announcements_v', 'SELECT'),
  'anon 对 published_announcements_v 无 SELECT'
);

-- ===========================================================================
-- 3. admin 状态机：草稿 CRUD / 发布校验 / 下线（26）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

-- 夹具：ann_a 草稿 → 编辑 → 发布（全员生效中）；ann_b 角色 engineer 生效中（发布）
select public.upsert_announcement(
  '年度巡检通知', '请各部门按时完成巡检。',
  now() - interval '1 hour', now() + interval '7 days', 'all', true
) as ann_a \gset
select is((:'ann_a'::jsonb ->> 'status'), 'draft', '新建公告为 draft');
select is((:'ann_a'::jsonb ->> 'audience'), 'all', '新建公告范围 all');
select is((:'ann_a'::jsonb ->> 'pinned'), 'true', '新建公告置顶标记保留');

-- 编辑：仅草稿可改
select public.upsert_announcement(
  '年度巡检通知（改）', '请各部门于本周五前完成巡检。',
  now() - interval '1 hour', now() + interval '7 days', 'all', true,
  (:'ann_a'::jsonb ->> 'id')::uuid
) as ann_a_edit \gset
select is((:'ann_a_edit'::jsonb ->> 'title'), '年度巡检通知（改）', '草稿状态可编辑');

select public.publish_announcement((:'ann_a'::jsonb ->> 'id')::uuid) as pub_a \gset
select is((:'pub_a'::jsonb ->> 'status'), 'published', '发布成功返回 published');
select is((:'pub_a'::jsonb ->> 'notified'), '0', '默认不发送站内信（notified=0）');
select ok((:'pub_a'::jsonb ->> 'published_at') is not null, '发布写入 published_at');

select public.upsert_announcement(
  '工程师专属公告', '仅工程师可见。',
  now() - interval '1 hour', now() + interval '7 days', 'role:engineer', false
) as ann_b \gset
select public.publish_announcement((:'ann_b'::jsonb ->> 'id')::uuid) as pub_b \gset
select is((:'pub_b'::jsonb ->> 'status'), 'published', '角色范围公告发布成功');

select public.upsert_announcement(
  '未来公告', '尚未开始生效。',
  now() + interval '2 days', now() + interval '3 days', 'all', false
) as ann_future \gset
select public.publish_announcement((:'ann_future'::jsonb ->> 'id')::uuid) as pub_future \gset
select is((:'pub_future'::jsonb ->> 'status'), 'published', '未来生效时段可发布（时段内才展示）');

select throws_ok(
  format(
    $q$ select public.upsert_announcement('已发布改', 'x', now(), now() + interval '1 day', 'all', false, %L::uuid) $q$,
    (:'ann_b'::jsonb ->> 'id')
  ),
  '22023', null,
  '已发布公告不可编辑（仅草稿可编辑）'
);

-- 发布校验：无时段 / 非法时段 / 非法范围
select public.upsert_announcement('未设时段', '草稿内容', null, null, 'all', false) as ann_x \gset
select is((:'ann_x'::jsonb ->> 'audience'), 'all', '范围缺省归一为 all');
select throws_ok(
  format($q$ select public.publish_announcement(%L::uuid) $q$, (:'ann_x'::jsonb ->> 'id')),
  '22023', null,
  '发布缺生效时段被拒'
);
select throws_ok(
  $$ select public.upsert_announcement('非法时段', 'x', now(), now() - interval '1 hour', 'all', false) $$,
  '22023', null,
  '结束早于开始的时段被拒'
);
select throws_ok(
  $$ select public.upsert_announcement('非法范围', 'x', now(), now() + interval '1 day', 'everyone', false) $$,
  '22023', null,
  '非法范围（everyone）被拒'
);
select throws_ok(
  $$ select public.upsert_announcement('未知角色', 'x', now(), now() + interval '1 day', 'role:ghost', false) $$,
  '22023', null,
  '范围角色不存在被拒'
);
select throws_ok(
  $$ select public.upsert_announcement('   ', 'x', now(), now() + interval '1 day', 'all', false) $$,
  '22023', null,
  '标题空白被拒'
);
select throws_ok(
  $$ select public.upsert_announcement('空正文', '   ', now(), now() + interval '1 day', 'all', false) $$,
  '22023', null,
  '正文空白被拒'
);

-- 非法跳转：draft 不能直接下线；published 不能重复发布
select throws_ok(
  format($q$ select public.offline_announcement(%L::uuid) $q$, (:'ann_x'::jsonb ->> 'id')),
  '22023', null,
  'draft 直接下线被拒（状态机）'
);
select throws_ok(
  format($q$ select public.publish_announcement(%L::uuid) $q$, (:'ann_a'::jsonb ->> 'id')),
  '22023', null,
  'published 重复发布被拒（状态机）'
);

-- 下线：published→offline；offline 为终态
select public.upsert_announcement(
  '即将下线公告', '下线测试。',
  now() - interval '1 hour', now() + interval '7 days', 'all', false
) as ann_off \gset
select public.publish_announcement((:'ann_off'::jsonb ->> 'id')::uuid) as pub_off \gset
select public.offline_announcement((:'ann_off'::jsonb ->> 'id')::uuid) as off_res \gset
select is((:'off_res'::jsonb ->> 'status'), 'offline', 'published→offline 成功');
select throws_ok(
  format($q$ select public.offline_announcement(%L::uuid) $q$, (:'ann_off'::jsonb ->> 'id')),
  '22023', null,
  'offline 重复下线被拒（终态）'
);
select throws_ok(
  format($q$ select public.publish_announcement(%L::uuid) $q$, (:'ann_off'::jsonb ->> 'id')),
  '22023', null,
  'offline 不可再发布（终态）'
);

-- 未发布/不存在：不存在报 P0002
select throws_ok(
  $$ select public.publish_announcement(gen_random_uuid()) $$,
  'P0002', null,
  '发布不存在的公告报 P0002'
);

select is(
  (select count(*) from public.get_announcements()
    where id = (:'ann_a'::jsonb ->> 'id')::uuid and publisher_name is not null),
  1::bigint,
  'get_announcements 返回发布人姓名'
);

reset role;

select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and object_type = 'announcement'
      and object_id = (:'ann_a'::jsonb ->> 'id') and action = 'publish'
  ),
  '发布写审计摘要（system/publish/announcement）'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and object_type = 'announcement'
      and object_id = (:'ann_off'::jsonb ->> 'id') and action = 'offline'
  ),
  '下线写审计摘要（system/offline/announcement）'
);

-- ===========================================================================
-- 4. 通知可选开关：p_notify=true 逐 active 用户投递 announcement.published（5）
-- ===========================================================================
reset role;

select is(
  (select count(*) from public.messages where event_key = 'announcement.published'),
  0::bigint,
  '默认发布（p_notify 缺省）不产生站内信'
);

set local role authenticated;

select public.upsert_announcement(
  '全员通知公告', '本公告同时发送站内信。',
  now() - interval '1 hour', now() + interval '7 days', 'all', false
) as ann_notify \gset
select public.publish_announcement((:'ann_notify'::jsonb ->> 'id')::uuid, true) as pub_notify \gset

select is(
  (:'pub_notify'::jsonb ->> 'notified')::integer,
  (select count(*)::integer from public.profiles where status = 'active'),
  'p_notify=true 时 notified=active 用户数'
);

reset role;

select is(
  (select count(*) from public.messages where event_key = 'announcement.published'),
  (select count(*) from public.profiles where status = 'active'),
  '站内信条数=active 用户数'
);
select is(
  (select count(distinct recipient_id) from public.messages where event_key = 'announcement.published'),
  (select count(*) from public.profiles where status = 'active'),
  '每个 active 用户收到 1 条'
);
select is(
  (select count(*) from public.messages
    where event_key = 'announcement.published'
      and ref_type = 'announcement'
      and ref_id = (:'ann_notify'::jsonb ->> 'id')),
  (select count(*) from public.profiles where status = 'active'),
  '站内信 ref 指向公告 id（ref_type=announcement）'
);

-- ===========================================================================
-- 5. 到期归档：pg_cron 手动触发（archived 为终态，不可再展示）（5）
-- ===========================================================================
select public.upsert_announcement(
  '已过期公告', '过期内容。',
  now() - interval '2 days', now() - interval '1 hour', 'all', false
) as ann_expired \gset
select public.publish_announcement((:'ann_expired'::jsonb ->> 'id')::uuid) as pub_expired \gset
select is((:'pub_expired'::jsonb ->> 'status'), 'published', '过期时段公告仍可发布（展示侧时段过滤）');

reset role;

select is(
  app.archive_expired_announcements(),
  1,
  'archive_expired_announcements 归档 1 条到期公告'
);

select is(
  (select status from public.system_announcements
    where id = (:'ann_expired'::jsonb ->> 'id')::uuid),
  'archived',
  '到期公告状态 archived'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and object_type = 'announcement' and action = 'archive'
  ),
  '批量归档写审计摘要（system/archive/announcement）'
);
select is(
  app.archive_expired_announcements(),
  0,
  '重复归档幂等（无到期公告返回 0）'
);

-- ===========================================================================
-- 6. 视图可见性 + RLS 直读：范围匹配 / 时段内（12）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;

select is(
  (select count(*) from public.published_announcements_v),
  3::bigint,
  'engineer 视图可见 3 条（all×2 + role:engineer×1）'
);
select ok(
  exists (
    select 1 from public.published_announcements_v
    where id = (:'ann_b'::jsonb ->> 'id')::uuid
  ),
  'engineer 可见 role:engineer 公告'
);
select ok(
  not exists (
    select 1 from public.published_announcements_v
    where id = (:'ann_future'::jsonb ->> 'id')::uuid
  ),
  '未来生效公告不可见'
);
select ok(
  not exists (
    select 1 from public.published_announcements_v
    where id = (:'ann_expired'::jsonb ->> 'id')::uuid
  ),
  '归档公告不可见'
);
select ok(
  not exists (
    select 1 from public.published_announcements_v
    where id = (:'ann_x'::jsonb ->> 'id')::uuid
  ),
  '草稿不进入公开视图'
);
select is(
  (select count(*) from public.system_announcements),
  3::bigint,
  'engineer 表级直读受 RLS 收窄（与视图一致 3 条）'
);
select throws_ok(
  $$ insert into public.system_announcements (title, content, audience, status)
     values ('engineer 越权', 'x', 'all', 'draft') $$,
  '42501', null,
  'engineer 直写 system_announcements 被拒（写仅 RPC）'
);
select throws_ok(
  $$ update public.system_announcements set pinned = true $$,
  '42501', null,
  'engineer 直改 system_announcements 被拒（写仅 RPC）'
);

reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220002","role":"authenticated"}',
  true
);
set local role authenticated;

select is(
  (select count(*) from public.published_announcements_v),
  2::bigint,
  'planner 视图可见 2 条（all×2，不含 role:engineer）'
);
select ok(
  not exists (
    select 1 from public.published_announcements_v
    where id = (:'ann_b'::jsonb ->> 'id')::uuid
  ),
  'planner 不可见 role:engineer 公告'
);

reset role;

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select is(
  (select count(*) from public.system_announcements),
  7::bigint,
  'admin 表级直读可见全部 7 条（含草稿/下线/归档）'
);

reset role;

set local role anon;

select throws_ok(
  $$ select * from public.published_announcements_v $$,
  '42501', null,
  'anon 读公开公告视图被拒（无 GRANT）'
);

reset role;

-- ===========================================================================
-- 7. 越权 + pg_cron 登记（6）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$ select public.upsert_announcement('越权创建', 'x', now(), now() + interval '1 day', 'all', false) $$,
  '42501', null,
  'engineer 调 upsert_announcement 被 admin 校验拒绝'
);
select throws_ok(
  format($q$ select public.publish_announcement(%L::uuid) $q$, (:'ann_x'::jsonb ->> 'id')),
  '42501', null,
  'engineer 调 publish_announcement 被 admin 校验拒绝'
);
select throws_ok(
  format($q$ select public.offline_announcement(%L::uuid) $q$, (:'ann_a'::jsonb ->> 'id')),
  '42501', null,
  'engineer 调 offline_announcement 被 admin 校验拒绝'
);
select throws_ok(
  $$ select * from public.get_announcements() $$,
  '42501', null,
  'engineer 调 get_announcements 被 admin 校验拒绝'
);

reset role;

select is(
  (select schedule from cron.job where jobname = 'archive-expired-announcements'),
  '15 4 * * *',
  'pg_cron 每日归档 job 已注册'
);
select is(
  (select module || '|' || owner_route from public.system_cron_registry
    where job_name = 'archive-expired-announcements'),
  'system|/system/announcements',
  '归档 job 已登记到 pg_cron 平台登记处'
);

select * from finish();
rollback;
