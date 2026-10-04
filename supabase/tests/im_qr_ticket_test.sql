-- pgTAP：im/007 —— PC 扫码登录真二维码（ticket 轮询）数据面
-- 覆盖（issue #13 验收相关）：
--   1) 结构与授权面：im_qr_tickets 表 / RLS / 零 API 角色授权；4 个新 RPC 存在且
--      SECURITY DEFINER + search_path=''；GRANT 面（start/poll → anon+authenticated，
--      complete/exchange → im_backend，service_role 零路径）；既有两薄包装签名未变；
--   2) ticket 生命周期：start 生成（格式 / state=ticket / secret 不出 URL / +5 分钟 / 落库 pending）
--      → poll pending → 标记 logged_in（原子 / 仅 pending 未过期）→ poll logged_in
--      → exchange 消费（一次性）→ poll consumed；重放 / 过期 / 未确认一律拒绝；
--   3) 防代扫：绑定匹配失败作废 + fail_reason 只经 poll 暴露原因；手机取消（p_code 为空）
--      作废；过期惰性作废；轮询不返回身份字段；
--   4) 分流前提：ticket 以 `qr.` 前缀（与 state cookie 值无碰撞，见 src/lib/im/qr.ts）；
--      未启用厂商 → im_unavailable（不出站）；start 清理超 1 小时旧 ticket。
-- 说明：厂商出站（extensions.http）不在 pgTAP 覆盖（本地栈无外网 mock），成功路径为
--       本地 mock 全链路证据（docs/evidence/im-007/README.md）；本文件只用「未启用 →
--       im_unavailable（不出站）」与「过期 / 作废 → 前置校验（不出站）」穿过
--       im_qr_complete_login。
-- 运行：supabase db reset && supabase test db
begin;

select plan(69);

-- ---------------------------------------------------------------------------
-- 0. 夹具清理（事务内，finish 后 rollback）：共享本地库里可能有他单 / 人工留下的
--    IM 配置与 ticket；先抹平再断言。
-- ---------------------------------------------------------------------------
delete from public.im_qr_tickets where true;
delete from public.im_auth_configs where true;

-- ===========================================================================
-- 1. 结构与授权面（18）
-- ===========================================================================
select has_table('public', 'im_qr_tickets', 'im_qr_tickets 表存在');
select ok(
  (select relrowsecurity from pg_class where oid = 'public.im_qr_tickets'::regclass),
  'im_qr_tickets 开启 RLS'
);
select ok(
  not exists (
    select 1
    from unnest(array['SELECT','INSERT','UPDATE','DELETE']) as p
    where has_table_privilege('anon', 'public.im_qr_tickets', p)
       or has_table_privilege('authenticated', 'public.im_qr_tickets', p)
       or has_table_privilege('service_role', 'public.im_qr_tickets', p)
       or has_table_privilege('im_backend', 'public.im_qr_tickets', p)
  ),
  'im_qr_tickets 零 anon / authenticated / service_role / im_backend 表权限'
);

select has_function('public', 'im_start_qr_login', array['text','text'], 'im_start_qr_login(text,text) 存在');
select has_function('public', 'im_poll_qr_login', array['text'], 'im_poll_qr_login(text) 存在');
select has_function('public', 'im_qr_complete_login', array['text','text','text','text'], 'im_qr_complete_login(text,text,text,text) 存在');
select has_function('public', 'im_exchange_qr_ticket', array['text'], 'im_exchange_qr_ticket(text) 存在');

select ok(
  (select bool_and(p.prosecdef and p.proconfig @> array['search_path=""'])
     from pg_proc p
    where p.oid in (
      'public.im_start_qr_login(text,text)'::regprocedure,
      'public.im_poll_qr_login(text)'::regprocedure,
      'public.im_qr_complete_login(text,text,text,text)'::regprocedure,
      'public.im_exchange_qr_ticket(text)'::regprocedure
    )),
  '4 个 ticket RPC 均 security definer + search_path 固定为空'
);

select ok(
  has_function_privilege('anon', 'public.im_start_qr_login(text,text)', 'EXECUTE')
    and has_function_privilege('anon', 'public.im_poll_qr_login(text)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.im_start_qr_login(text,text)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.im_poll_qr_login(text)', 'EXECUTE'),
  'start / poll 对 anon + authenticated 开放（登录页未登录即可生成二维码 / 轮询）'
);
select ok(
  not has_function_privilege('anon', 'public.im_qr_complete_login(text,text,text,text)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.im_qr_complete_login(text,text,text,text)', 'EXECUTE')
    and not has_function_privilege('anon', 'public.im_exchange_qr_ticket(text)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.im_exchange_qr_ticket(text)', 'EXECUTE'),
  'complete / exchange 不对 anon / authenticated 开放（只走服务端 im_backend）'
);
select ok(
  has_function_privilege('im_backend', 'public.im_qr_complete_login(text,text,text,text)', 'EXECUTE')
    and has_function_privilege('im_backend', 'public.im_exchange_qr_ticket(text)', 'EXECUTE')
    and not has_function_privilege('im_backend', 'public.im_start_qr_login(text,text)', 'EXECUTE')
    and not has_function_privilege('im_backend', 'public.im_poll_qr_login(text)', 'EXECUTE'),
  'im_backend 仅可执行 complete / exchange'
);
select ok(
  not exists (
    select 1
    from pg_proc p
    where p.oid in (
      'public.im_start_qr_login(text,text)'::regprocedure,
      'public.im_poll_qr_login(text)'::regprocedure,
      'public.im_qr_complete_login(text,text,text,text)'::regprocedure,
      'public.im_exchange_qr_ticket(text)'::regprocedure
    )
      and has_function_privilege('service_role', p.oid, 'EXECUTE')
  ),
  'service_role 零 ticket RPC 执行权（ADR-001 全局禁令）'
);
select ok(
  not exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname in ('im_qr_new_ticket', 'im_qr_ticket_complete', 'im_qr_ticket_invalidate')
      and (
        has_function_privilege('anon', p.oid, 'EXECUTE')
        or has_function_privilege('authenticated', p.oid, 'EXECUTE')
        or has_function_privilege('service_role', p.oid, 'EXECUTE')
        or has_function_privilege('im_backend', p.oid, 'EXECUTE')
      )
  ),
  '3 个 app.im_qr_* 内部 helper 零 API 角色 / im_backend 执行权'
);

-- 既有路径保留：两薄包装签名未变（im/007 冲突规则）
select has_function('public', 'im_start_auth', array['text','text','text'],
  'public.im_start_auth(text,text,text) 签名未变');
select has_function('public', 'im_handle_callback', array['text','text','text'],
  'public.im_handle_callback(text,text,text) 签名未变');

-- 约束：ticket 格式 / 状态 / 厂商枚举
select throws_ok(
  $$ insert into public.im_qr_tickets (ticket, provider, status, expires_at)
     values ('not-a-ticket', 'feishu', 'pending', now() + interval '5 minutes') $$,
  '23514', null, 'ticket 格式约束拒绝非 qr. 前缀值'
);
select throws_ok(
  $$ insert into public.im_qr_tickets (ticket, provider, status, expires_at)
     values ('qr.' || repeat('cc', 32), 'feishu', 'unknown', now() + interval '5 minutes') $$,
  '23514', null, 'status 枚举约束拒绝未知状态'
);
select throws_ok(
  $$ insert into public.im_qr_tickets (ticket, provider, status, expires_at)
     values ('qr.' || repeat('dd', 32), 'slack', 'pending', now() + interval '5 minutes') $$,
  '23514', null, 'provider 枚举约束拒绝未知厂商'
);

-- ===========================================================================
-- 2. start：生成 ticket + 厂商授权 URL（state=ticket）（13）
-- ===========================================================================
select throws_ok(
  $$ select public.im_start_qr_login('slack', 'https://admin.example.com/auth/callback/slack') $$,
  '22023', null, '未知厂商 → 22023'
);
select throws_ok(
  $$ select public.im_start_qr_login('feishu', 'not-a-url') $$,
  '22023', null, '回调地址非法 → 22023'
);

-- 未启用：im_unavailable，不落 ticket
select is(
  public.im_start_qr_login('feishu', 'https://admin.example.com/auth/callback/feishu'),
  jsonb_build_object('ok', false, 'error', 'im_unavailable'),
  '未启用厂商 → {ok:false, im_unavailable}'
);
select is(
  (select count(*)::integer from public.im_qr_tickets),
  0,
  '未启用时不落 ticket 行'
);

-- 启用飞书（夹具，含加密凭据）
insert into public.im_auth_configs (provider, enabled, credentials)
values ('feishu', true, app.encrypt_secret('{"app_id":"cli_qr_test","app_secret":"qr_secret"}'))
on conflict (provider) do update set enabled = true, credentials = excluded.credentials;

select public.im_start_qr_login('feishu', 'https://admin.example.com/auth/callback/feishu') as s1 \gset
select is((:'s1'::jsonb ->> 'ok')::boolean, true, '飞书 start 返回 ok');
select ok(
  (:'s1'::jsonb ->> 'ticket') ~ '^qr\.[A-Za-z0-9_-]{43,64}$',
  'ticket 符合 qr. 前缀 + 随机段格式'
);
select ok(
  (:'s1'::jsonb ->> 'authorize_url') like '%state=' || (:'s1'::jsonb ->> 'ticket') || '%',
  '授权 URL 的 state 即 ticket'
);
select ok(
  (:'s1'::jsonb ->> 'authorize_url') not like '%qr_secret%',
  '授权 URL 不含厂商 secret'
);
select ok(
  (:'s1'::jsonb ->> 'expires_at')::timestamptz between now() + interval '4 minutes' and now() + interval '6 minutes',
  'expires_at 约 +5 分钟'
);
select is(
  (select status from public.im_qr_tickets where ticket = :'s1'::jsonb ->> 'ticket'),
  'pending',
  'start 落库为 pending'
);

-- 企业微信 / 钉钉 URL 形态（调用既有厂商实现，secret 不出库）
update public.im_auth_configs set enabled = false where enabled;
insert into public.im_auth_configs (provider, enabled, credentials)
values ('wecom', true, app.encrypt_secret('{"corp_id":"ww_qr","agent_id":"1000002","secret":"wecom_sec"}'))
on conflict (provider) do update set enabled = true, credentials = excluded.credentials;
select public.im_start_qr_login('wecom', 'https://admin.example.com/auth/callback/wecom') as s2 \gset
select ok(
  (:'s2'::jsonb ->> 'authorize_url') like 'https://open.work.weixin.qq.com/wwopen/sso/qrConnect?%'
    and (:'s2'::jsonb ->> 'authorize_url') like '%state=' || (:'s2'::jsonb ->> 'ticket') || '%',
  '企业微信 start 返回 qrConnect 托管页 URL（state=ticket）'
);

update public.im_auth_configs set enabled = false where enabled;
insert into public.im_auth_configs (provider, enabled, credentials)
values ('dingtalk', true, app.encrypt_secret('{"app_key":"ding_qr","app_secret":"ding_sec"}'))
on conflict (provider) do update set enabled = true, credentials = excluded.credentials;
select public.im_start_qr_login('dingtalk', 'https://admin.example.com/auth/callback/dingtalk') as s3 \gset
select ok(
  (:'s3'::jsonb ->> 'authorize_url') like 'https://login.dingtalk.com/oauth2/auth?%'
    and (:'s3'::jsonb ->> 'authorize_url') like '%state=' || (:'s3'::jsonb ->> 'ticket') || '%',
  '钉钉 start 返回 oauth2/auth URL（state=ticket）'
);

-- start 清理超 1 小时旧 ticket
insert into public.im_qr_tickets (ticket, provider, status, expires_at)
values ('qr.' || repeat('ee', 32), 'dingtalk', 'pending', now() - interval '2 hours');
select public.im_start_qr_login('dingtalk', 'https://admin.example.com/auth/callback/dingtalk') as s4 \gset
select is(
  (select count(*)::integer from public.im_qr_tickets where ticket = 'qr.' || repeat('ee', 32)),
  0,
  'start 顺手清理超 1 小时旧 ticket'
);

-- ===========================================================================
-- 3. poll：只回状态与原因，不泄露身份（6）
-- ===========================================================================
select public.im_poll_qr_login(:'s1'::jsonb ->> 'ticket') as p_pending \gset
select is((:'p_pending'::jsonb ->> 'status'), 'pending', 'poll：pending');
select ok(
  not (:'p_pending'::jsonb ? 'user_id')
    and not (:'p_pending'::jsonb ? 'im_userid')
    and not (:'p_pending'::jsonb ? 'provider')
    and (select count(*) from jsonb_object_keys(:'p_pending'::jsonb) as k where k not in ('status','reason')) = 0,
  'poll 响应只有 status / reason，不含任何身份字段'
);
select is(
  public.im_poll_qr_login('not-a-ticket'),
  jsonb_build_object('status', 'invalid'),
  'poll：格式非法 → invalid'
);
select is(
  public.im_poll_qr_login('qr.' || repeat('ff', 32)),
  jsonb_build_object('status', 'invalid'),
  'poll：不存在 → invalid'
);

insert into public.im_qr_tickets (ticket, provider, status, expires_at)
values ('qr.' || repeat('12', 32), 'feishu', 'pending', now() - interval '1 minute');
select public.im_poll_qr_login('qr.' || repeat('12', 32)) as p_expired \gset
select is((:'p_expired'::jsonb ->> 'status'), 'expired', 'poll：超时 pending 惰性作废');
select is(
  (select status from public.im_qr_tickets where ticket = 'qr.' || repeat('12', 32)),
  'expired',
  '惰性作废已落库'
);

-- ===========================================================================
-- 4. 标记 logged_in（app.im_qr_ticket_complete 原子语义）（5）
-- ===========================================================================
select is(
  app.im_qr_ticket_complete('qr.' || repeat('ff', 32), (select id from public.profiles where email = 'engineer@example.com'), 'u_x'),
  false,
  'complete：不存在 ticket → false'
);
select is(
  app.im_qr_ticket_complete('qr.' || repeat('12', 32), (select id from public.profiles where email = 'engineer@example.com'), 'u_x'),
  false,
  'complete：已过期 ticket → false'
);
select is(
  app.im_qr_ticket_complete(:'s1'::jsonb ->> 'ticket', (select id from public.profiles where email = 'engineer@example.com'), 'feishu_qr_userid'),
  true,
  'complete：pending + 未过期 → true'
);
select is(
  app.im_qr_ticket_complete(:'s1'::jsonb ->> 'ticket', (select id from public.profiles where email = 'admin@example.com'), 'u_other'),
  false,
  'complete：重复标记（并发）→ false（一次性）'
);
select public.im_poll_qr_login(:'s1'::jsonb ->> 'ticket') as p_logged \gset
select is((:'p_logged'::jsonb ->> 'status'), 'logged_in', 'poll：手机确认后 logged_in');

-- ===========================================================================
-- 5. exchange：一次性消费（7）
-- ===========================================================================
select is(
  public.im_exchange_qr_ticket('qr.' || repeat('34', 32)),
  jsonb_build_object('ok', false, 'error', 'im_state_invalid'),
  'exchange：未知 ticket → im_state_invalid'
);
insert into public.im_qr_tickets (ticket, provider, status, expires_at)
values ('qr.' || repeat('56', 32), 'feishu', 'pending', now() + interval '5 minutes');
select is(
  public.im_exchange_qr_ticket('qr.' || repeat('56', 32)),
  jsonb_build_object('ok', false, 'error', 'im_state_invalid'),
  'exchange：仅 pending（未确认）→ im_state_invalid'
);

select public.im_exchange_qr_ticket(:'s1'::jsonb ->> 'ticket') as ex1 \gset
select is((:'ex1'::jsonb ->> 'ok')::boolean, true, 'exchange：logged_in + 未过期 → ok');
select is((:'ex1'::jsonb ->> 'provider'), 'feishu', 'exchange 返回 provider');
select is(
  (:'ex1'::jsonb ->> 'user_id'),
  (select id::text from public.profiles where email = 'engineer@example.com'),
  'exchange 返回绑定 user_id'
);
select is(
  public.im_exchange_qr_ticket(:'s1'::jsonb ->> 'ticket'),
  jsonb_build_object('ok', false, 'error', 'im_state_invalid'),
  'exchange：重放（已 consumed）→ im_state_invalid'
);
select public.im_poll_qr_login(:'s1'::jsonb ->> 'ticket') as p_consumed \gset
select is((:'p_consumed'::jsonb ->> 'status'), 'consumed', 'poll：消费后 consumed');

-- ===========================================================================
-- 6. 过期 logged_in 不可 exchange（2）
-- ===========================================================================
insert into public.im_qr_tickets (ticket, provider, status, user_id, im_userid, expires_at)
values (
  'qr.' || repeat('78', 32), 'dingtalk', 'logged_in',
  (select id from public.profiles where email = 'engineer@example.com'),
  'ding_userid', now() - interval '1 second'
);
select is(
  public.im_exchange_qr_ticket('qr.' || repeat('78', 32)),
  jsonb_build_object('ok', false, 'error', 'im_state_invalid'),
  'exchange：logged_in 但已过期 → im_state_invalid'
);
select public.im_poll_qr_login('qr.' || repeat('78', 32)) as p_logged_expired \gset
select is((:'p_logged_expired'::jsonb ->> 'status'), 'expired', 'poll：过期 logged_in 惰性作废');

-- ===========================================================================
-- 7. 作废语义：绑定失败 / 取消授权（app.im_qr_ticket_invalidate）（5）
-- ===========================================================================
select public.im_start_qr_login('dingtalk', 'https://admin.example.com/auth/callback/dingtalk') as s5 \gset
select is(
  app.im_qr_ticket_invalidate(:'s5'::jsonb ->> 'ticket', 'im_not_bound', 'ding_unbound_userid'),
  true,
  'invalidate：pending → 作废成功'
);
select public.im_poll_qr_login(:'s5'::jsonb ->> 'ticket') as p_bound_fail \gset
select is((:'p_bound_fail'::jsonb ->> 'status'), 'expired', 'poll：绑定失败 → expired');
select is((:'p_bound_fail'::jsonb ->> 'reason'), 'im_not_bound', 'poll：expired 暴露 fail_reason 供 PC 展示');
select is(
  (select im_userid from public.im_qr_tickets where ticket = :'s5'::jsonb ->> 'ticket'),
  'ding_unbound_userid',
  'invalidate：保留未绑定 userid 线索（审计）'
);
select is(
  app.im_qr_ticket_invalidate(:'s5'::jsonb ->> 'ticket', 'im_denied'),
  false,
  'invalidate：已作废 ticket 不再命中（不可恢复）'
);

-- ===========================================================================
-- 8. im_qr_complete_login：回调侧校验（13）
-- ===========================================================================
select throws_ok(
  $$ select public.im_qr_complete_login('slack', 'qr.' || repeat('90', 32), 'c', 'https://admin.example.com/auth/callback/slack') $$,
  '22023', null, 'complete：未知厂商 → 22023'
);
select throws_ok(
  $$ select public.im_qr_complete_login('feishu', 'qr.' || repeat('90', 32), 'c', 'not-a-url') $$,
  '22023', null, 'complete：回调地址非法 → 22023'
);
select is(
  public.im_qr_complete_login('feishu', 'not-a-ticket', 'c', 'https://admin.example.com/auth/callback/feishu'),
  jsonb_build_object('ok', false, 'error', 'im_state_invalid'),
  'complete：ticket 格式非法 → im_state_invalid（不触发出站）'
);
select is(
  public.im_qr_complete_login('feishu', 'qr.' || repeat('90', 32), 'c', 'https://admin.example.com/auth/callback/feishu'),
  jsonb_build_object('ok', false, 'error', 'im_state_invalid'),
  'complete：ticket 不存在 → im_state_invalid（不触发出站）'
);

-- 厂商不匹配：钉钉 ticket 用飞书回调
insert into public.im_qr_tickets (ticket, provider, status, expires_at)
values ('qr.' || repeat('91', 32), 'dingtalk', 'pending', now() + interval '5 minutes');
select is(
  public.im_qr_complete_login('feishu', 'qr.' || repeat('91', 32), 'c', 'https://admin.example.com/auth/callback/feishu'),
  jsonb_build_object('ok', false, 'error', 'im_state_invalid'),
  'complete：ticket 厂商与回调厂商不匹配 → im_state_invalid'
);

-- 未启用厂商 + 有 code：im_unavailable（不出站），ticket 保持 pending 允许重扫
update public.im_auth_configs set enabled = false where enabled;
insert into public.im_qr_tickets (ticket, provider, status, expires_at)
values ('qr.' || repeat('92', 32), 'wecom', 'pending', now() + interval '5 minutes');
select public.im_qr_complete_login('wecom', 'qr.' || repeat('92', 32), 'c', 'https://admin.example.com/auth/callback/wecom') as c_disabled \gset
select is((:'c_disabled'::jsonb ->> 'error'), 'im_unavailable', 'complete：未启用厂商（有 code）→ im_unavailable（不出站）');
select is(
  (select status from public.im_qr_tickets where ticket = 'qr.' || repeat('92', 32)),
  'pending',
  'complete：im_unavailable 不消费 ticket，允许同一二维码重扫'
);

-- 过期 ticket：前置校验拒绝，不触发出站
insert into public.im_qr_tickets (ticket, provider, status, expires_at)
values ('qr.' || repeat('93', 32), 'feishu', 'pending', now() - interval '1 minute');
select public.im_qr_complete_login('feishu', 'qr.' || repeat('93', 32), 'c', 'https://admin.example.com/auth/callback/feishu') as c_expired \gset
select is((:'c_expired'::jsonb ->> 'error'), 'im_state_invalid', 'complete：过期 ticket → im_state_invalid（不出站）');
select is(
  (select status from public.im_qr_tickets where ticket = 'qr.' || repeat('93', 32)),
  'expired',
  'complete：过期 ticket 落库为 expired'
);

-- 已消费 ticket（重放）：拒绝
select public.im_qr_complete_login('feishu', :'s1'::jsonb ->> 'ticket', 'c', 'https://admin.example.com/auth/callback/feishu') as c_consumed \gset
select is((:'c_consumed'::jsonb ->> 'error'), 'im_state_invalid', 'complete：已 consumed ticket → im_state_invalid（重放拒绝）');

-- 手机取消授权（p_code 为空）：作废并记录原因
insert into public.im_qr_tickets (ticket, provider, status, expires_at)
values ('qr.' || repeat('94', 32), 'feishu', 'pending', now() + interval '5 minutes');
select public.im_qr_complete_login('feishu', 'qr.' || repeat('94', 32), null, 'https://admin.example.com/auth/callback/feishu') as c_denied \gset
select is((:'c_denied'::jsonb ->> 'error'), 'im_denied', 'complete：p_code 为空（手机取消）→ im_denied');
select is(
  (select status || ':' || coalesce(fail_reason, '-')
     from public.im_qr_tickets where ticket = 'qr.' || repeat('94', 32)),
  'expired:im_denied',
  'complete：取消授权落库 expired + fail_reason=im_denied'
);
select public.im_poll_qr_login('qr.' || repeat('94', 32)) as p_denied \gset
select is((:'p_denied'::jsonb ->> 'reason'), 'im_denied', 'poll：取消后 PC 端可见 im_denied');

select * from finish();
rollback;
