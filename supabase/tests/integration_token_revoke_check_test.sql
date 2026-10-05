-- pgTAP：integration 批次 1 —— 吊销/过期 key 的存量 JWT 即时失效 + 签发有效期收敛 + last_used_at 节流
-- 运行：supabase db reset && supabase test db
-- 覆盖：函数存在性与 SECURITY 属性（definer + search_path 空）；
--       签发 token → 吊销 key → 旧 token verify 返回 NULL（原 1h 窗口场景）与资源 RPC 42501；
--       过期 key 无法签发新 token、直签存量 token 也拒绝；key_id 缺失/不存在/畸形均拒绝；
--       exp = min(now()+1h, key.expires_at)（密钥剩余不足 1 小时）；expires_in 实际秒数；
--       last_used_at 1 分钟内不重复更新、超 1 分钟后恢复更新、节流不阻断签发。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。
--       now() 为事务开始时间，节流用例的「超 1 分钟」用直接 UPDATE 回拨 last_used_at 构造。

begin;

select plan(23);

-- ===========================================================================
-- 1. 函数存在性 + SECURITY 属性（3）
-- ===========================================================================
select has_function('app', 'verify_api_token', array['text'], 'app.verify_api_token(text) 存在');
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'verify_api_token'),
  'verify_api_token 为 SECURITY DEFINER + search_path 空（回查 api_keys 需跨表读）'
);
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'issue_api_token'),
  'issue_api_token 为 SECURITY DEFINER + search_path 空（读 key 有效期）'
);

-- ===========================================================================
-- 2. 夹具：admin 签发 key k1（30 天）+ 签发 token t1（anon 入口）
--     顺带覆盖 last_used_at 节流（签发复用 verify_api_key）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select public.create_api_key('即时失效测试', '["org:read"]'::jsonb, now() + interval '30 days') as k1 \gset
reset role;

set local role anon;
select public.issue_api_token((:'k1'::jsonb) ->> 'key') as t1 \gset
reset role;

select is((:'t1'::jsonb) ->> 'key_id', (:'k1'::jsonb) ->> 'id', '首次签发返回 key_id 正确');
select ok(
  (select last_used_at is not null from public.api_keys where id = (:'k1'::jsonb ->> 'id')::uuid),
  '首次签发更新 last_used_at'
);

select (select last_used_at from public.api_keys where id = (:'k1'::jsonb ->> 'id')::uuid) as lu1 \gset

set local role anon;
select public.issue_api_token((:'k1'::jsonb) ->> 'key') as t1b \gset
reset role;

select ok((:'t1b'::jsonb) ->> 'token' is not null, '1 分钟内二次签发仍成功（节流只影响用量写入）');
select is(
  (select last_used_at from public.api_keys where id = (:'k1'::jsonb ->> 'id')::uuid),
  :'lu1'::timestamptz,
  '1 分钟内二次签发不重复更新 last_used_at（节流生效）'
);

-- 回拨 last_used_at 超过 1 分钟：下一次签发恢复更新
update public.api_keys
   set last_used_at = now() - interval '2 minutes'
 where id = (:'k1'::jsonb ->> 'id')::uuid;

set local role anon;
select public.issue_api_token((:'k1'::jsonb) ->> 'key') as t1c \gset
reset role;

select ok((:'t1c'::jsonb) ->> 'token' is not null, '距上次超过 1 分钟后签发成功');
select ok(
  (select last_used_at > now() - interval '1 minute'
     from public.api_keys where id = (:'k1'::jsonb ->> 'id')::uuid),
  '距上次超过 1 分钟后 last_used_at 恢复更新'
);

-- ===========================================================================
-- 3. 吊销即时失效：存量 token 立即不可用（原 1h 窗口场景）
-- ===========================================================================
select is(
  app.verify_api_token((:'t1'::jsonb) ->> 'token') ->> 'key_id',
  (:'k1'::jsonb) ->> 'id',
  '吊销前存量 token verify 通过'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select public.revoke_api_key((:'k1'::jsonb ->> 'id')::uuid) as rev \gset
reset role;

select is((:'rev'::jsonb) ->> 'status', 'revoked', '吊销返回 status=revoked');
select is(
  app.verify_api_token((:'t1'::jsonb) ->> 'token'),
  null::jsonb,
  '吊销后存量 token verify 返回 NULL（即时失效，不再等 1h 过期）'
);
select app.api_departments((:'t1'::jsonb) ->> 'token') as d_revoked \gset
select is(
  (:'d_revoked'::jsonb ->> 'status')::integer,
  401,
  '吊销后存量 token 调资源 RPC 返回 401 状态包（批次 2 契约）'
);
select throws_ok(
  format('select app.issue_api_token(%L)', (:'k1'::jsonb) ->> 'key'),
  '42501', null, '吊销后原 key 无法签发新 token'
);

-- ===========================================================================
-- 4. 过期 key：无法签发新 token；存量 token 同样即时失效
-- ===========================================================================
insert into public.api_keys (name, key_prefix, key_hash, scopes, status, expires_at)
values (
  '已过期密钥', 'ak_deadbeef',
  encode(extensions.digest('ak_expired_revoke_check', 'sha256'), 'hex'),
  '["org:read"]'::jsonb, 'active', now() - interval '1 day'
)
returning id as kexp \gset

select throws_ok(
  $$ select app.issue_api_token('ak_expired_revoke_check') $$,
  '42501', null, '过期 key 无法签发新 token（42501）'
);

select extensions.sign(
  json_build_object(
    'iss', 'admin-api',
    'role', 'api_client_role',
    'key_id', :'kexp',
    'scopes', '["org:read"]'::jsonb,
    'exp', floor(extract(epoch from now() + interval '1 hour'))::bigint
  ),
  (select key from app.encryption_key where key_id = 1)
) as t_expired_key \gset

select is(
  app.verify_api_token(:'t_expired_key'),
  null::jsonb,
  '签名有效但 key 已过期的存量 token verify 返回 NULL'
);

-- ===========================================================================
-- 5. claims.key_id 防御：缺失/不存在/畸形一律拒绝（不抛错）
-- ===========================================================================
select extensions.sign(
  json_build_object(
    'iss', 'admin-api',
    'role', 'api_client_role',
    'key_id', gen_random_uuid()::text,
    'scopes', '["org:read"]'::jsonb,
    'exp', floor(extract(epoch from now() + interval '1 hour'))::bigint
  ),
  (select key from app.encryption_key where key_id = 1)
) as t_nokey \gset

select is(app.verify_api_token(:'t_nokey'), null::jsonb, 'key_id 不存在于 api_keys：拒绝');

select extensions.sign(
  json_build_object(
    'iss', 'admin-api',
    'role', 'api_client_role',
    'key_id', 'not-a-uuid',
    'scopes', '[]'::jsonb,
    'exp', floor(extract(epoch from now() + interval '1 hour'))::bigint
  ),
  (select key from app.encryption_key where key_id = 1)
) as t_badkey \gset

select is(app.verify_api_token(:'t_badkey'), null::jsonb, 'key_id 畸形（非 UUID）：拒绝且不抛错');

select extensions.sign(
  json_build_object(
    'iss', 'admin-api',
    'role', 'api_client_role',
    'scopes', '[]'::jsonb,
    'exp', floor(extract(epoch from now() + interval '1 hour'))::bigint
  ),
  (select key from app.encryption_key where key_id = 1)
) as t_nokeyclaim \gset

select is(app.verify_api_token(:'t_nokeyclaim'), null::jsonb, '缺少 key_id claim：拒绝');

-- ===========================================================================
-- 6. exp 收敛：min(now()+1h, key.expires_at)；expires_in 为实际秒数
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select public.create_api_key('短期密钥', '["org:read"]'::jsonb, now() + interval '10 minutes') as kshort \gset
reset role;

set local role anon;
select public.issue_api_token((:'kshort'::jsonb) ->> 'key') as tshort \gset
reset role;

select is((:'tshort'::jsonb) ->> 'expires_in', '600', 'key 剩余 10 分钟：expires_in=600（不再固定 3600）');

select ok(
  (app.verify_api_token((:'tshort'::jsonb) ->> 'token') ->> 'exp')::bigint
    - extract(epoch from now())::bigint between 590 and 600,
  'claims.exp 约为 10 分钟后（key 有效期为硬上界）'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select public.create_api_key('常规密钥', '["org:read"]'::jsonb, now() + interval '30 days') as klong \gset
reset role;

set local role anon;
select public.issue_api_token((:'klong'::jsonb) ->> 'key') as tlong \gset
reset role;

select is((:'tlong'::jsonb) ->> 'expires_in', '3600', 'key 剩余 30 天：expires_in=3600（1 小时上界不变）');

-- 有效 token 仍可正常读资源（吊销检查不破坏正常链路）
select app.api_departments((:'tlong'::jsonb) ->> 'token') as d_ok \gset
select ok(
  (:'d_ok'::jsonb ->> 'ok')::boolean
    and jsonb_array_length(:'d_ok'::jsonb -> 'data') >= 6,
  '有效 key 的 token 仍可读取部门数据（{ok:true,data} 端到端 sanity）'
);

select * from finish();
rollback;
