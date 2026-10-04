-- pgTAP：im/001 —— IM 登录数据底座
-- 覆盖（issue #1 六类用例）：
--   1) 三家 userid 唯一性冲突拒绝（+ 格式校验）
--   2) 普通用户不能改他人绑定（直写列权限拒绝 + 自助绑定只写本人）
--   3) 非 admin 不能调 im_unbind / im_admin_set_userid / im_upsert_config
--   4) enabled=true 全局唯一（RPC 原子切换 + partial unique index 兜底）
--   5) 凭据加密往返一致（密文不含明文、null=保留、审计不落明文）
--   6) RPC 的 search_path 固定（security definer + search_path=''）
-- 另覆盖：GRANT 面（anon 仅可调 im_get_enabled_provider）、RLS 列级只读、绑定/解绑审计。
-- 运行：supabase db reset && supabase test db
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。
begin;

select plan(85);

-- ===========================================================================
-- 1. 结构与安全属性 + GRANT 面（33）
-- ===========================================================================
select has_column('public', 'profiles', 'wecom_userid', 'profiles.wecom_userid 存在');
select has_column('public', 'profiles', 'feishu_userid', 'profiles.feishu_userid 存在');
select has_column('public', 'profiles', 'dingtalk_userid', 'profiles.dingtalk_userid 存在');
select col_has_check('public', 'profiles', 'wecom_userid', 'wecom_userid 有格式 CHECK');
select col_has_check('public', 'profiles', 'feishu_userid', 'feishu_userid 有格式 CHECK');
select col_has_check('public', 'profiles', 'dingtalk_userid', 'dingtalk_userid 有格式 CHECK');

select has_table('public', 'im_auth_configs', 'im_auth_configs 表存在');
select has_column('public', 'im_auth_configs', 'provider', 'provider 列存在');
select has_column('public', 'im_auth_configs', 'enabled', 'enabled 列存在');
select has_column('public', 'im_auth_configs', 'credentials', 'credentials 列存在');
select has_column('public', 'im_auth_configs', 'updated_by', 'updated_by 列存在');
select has_column('public', 'im_auth_configs', 'updated_at', 'updated_at 列存在');
select col_is_pk('public', 'im_auth_configs', 'provider', 'provider 为主键');
select col_has_check('public', 'im_auth_configs', 'provider', 'provider 有取值 CHECK');
select has_index(
  'public', 'im_auth_configs', 'im_auth_configs_one_enabled_idx',
  'enabled=true 全局唯一 partial index 存在'
);
select is(
  (select relrowsecurity from pg_class where oid = 'public.im_auth_configs'::regclass),
  true,
  'im_auth_configs 已启用 RLS'
);

select has_function('public', 'im_bind_self', array['text', 'text'], 'im_bind_self(text,text) 存在');
select has_function('public', 'im_unbind', array['uuid', 'text'], 'im_unbind(uuid,text) 存在');
select has_function('public', 'im_admin_set_userid', array['uuid', 'text', 'text'], 'im_admin_set_userid(uuid,text,text) 存在');
select has_function('public', 'im_upsert_config', array['text', 'jsonb', 'boolean'], 'im_upsert_config(text,jsonb,boolean) 存在');
select has_function('public', 'im_get_enabled_provider', array[]::text[], 'im_get_enabled_provider() 存在');

select ok(
  (select count(*) = 5
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
            ('public', 'im_bind_self'), ('public', 'im_unbind'),
            ('public', 'im_admin_set_userid'), ('public', 'im_upsert_config'),
            ('public', 'im_get_enabled_provider')
          )
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '5 个 RPC 均 security definer + search_path 固定为空'
);

select ok(has_function_privilege('authenticated', 'public.im_bind_self(text,text)', 'EXECUTE'), 'authenticated 可执行 im_bind_self');
select ok(has_function_privilege('authenticated', 'public.im_unbind(uuid,text)', 'EXECUTE'), 'authenticated 可执行 im_unbind');
select ok(has_function_privilege('authenticated', 'public.im_admin_set_userid(uuid,text,text)', 'EXECUTE'), 'authenticated 可执行 im_admin_set_userid');
select ok(has_function_privilege('authenticated', 'public.im_upsert_config(text,jsonb,boolean)', 'EXECUTE'), 'authenticated 可执行 im_upsert_config');
select ok(has_function_privilege('anon', 'public.im_get_enabled_provider()', 'EXECUTE'), 'anon 可执行 im_get_enabled_provider');
select ok(
  not exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('im_bind_self', 'im_unbind', 'im_admin_set_userid', 'im_upsert_config')
       and has_function_privilege('anon', p.oid, 'EXECUTE')
  ),
  'anon 无 4 个非公开 RPC 执行权'
);

select ok(
  has_column_privilege('authenticated', 'public.im_auth_configs', 'provider', 'SELECT'),
  'authenticated 有 provider 列 SELECT（admin 策略下可见）'
);
select ok(
  not has_column_privilege('authenticated', 'public.im_auth_configs', 'credentials', 'SELECT'),
  'authenticated 无 credentials 列 SELECT（凭据仅经 RPC）'
);
select ok(
  not has_table_privilege('authenticated', 'public.im_auth_configs', 'SELECT'),
  '无表级 SELECT（仅列级授权）'
);
select ok(
  not exists (
    select 1
      from unnest(array['INSERT', 'UPDATE', 'DELETE']) p
     where has_table_privilege('authenticated', 'public.im_auth_configs', p)
        or has_table_privilege('anon', 'public.im_auth_configs', p)
  ),
  'authenticated/anon 对 im_auth_configs 均无直接写权限'
);
select ok(
  not exists (
    select 1
      from unnest(array['wecom_userid', 'feishu_userid', 'dingtalk_userid']) c
     where has_column_privilege('authenticated', 'public.profiles', c, 'UPDATE')
  ),
  'authenticated 对三列无直接 UPDATE（写仅经 RPC）'
);

-- ===========================================================================
-- 2. 三家 userid 唯一性冲突与格式校验（11）
--    先以 admin 建立基线绑定：需可稳定复现 UNIQUE 冲突
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$ select public.im_admin_set_userid('22222222-2222-2222-2222-222222220001', 'wecom', 'wx_1001') $$,
  'admin 为用户 1 录入 wecom userid'
);
select throws_ok(
  $$ select public.im_admin_set_userid('22222222-2222-2222-2222-222222220002', 'wecom', 'wx_1001') $$,
  '23505', null, '同一 wecom userid 绑第二个账号被 UNIQUE 拒绝'
);
select lives_ok(
  $$ select public.im_admin_set_userid('22222222-2222-2222-2222-222222220001', 'feishu', 'fs_2001') $$,
  'admin 为用户 1 录入 feishu userid'
);
select throws_ok(
  $$ select public.im_admin_set_userid('22222222-2222-2222-2222-222222220002', 'feishu', 'fs_2001') $$,
  '23505', null, '同一 feishu userid 绑第二个账号被 UNIQUE 拒绝'
);
select lives_ok(
  $$ select public.im_admin_set_userid('22222222-2222-2222-2222-222222220002', 'feishu', 'fs_2002') $$,
  'admin 为用户 2 录入另一个 feishu userid'
);
select lives_ok(
  $$ select public.im_admin_set_userid('22222222-2222-2222-2222-222222220001', 'dingtalk', 'dt_3001') $$,
  'admin 为用户 1 录入 dingtalk userid'
);
select throws_ok(
  $$ select public.im_admin_set_userid('22222222-2222-2222-2222-222222220002', 'dingtalk', 'dt_3001') $$,
  '23505', null, '同一 dingtalk userid 绑第二个账号被 UNIQUE 拒绝'
);
select throws_ok(
  $$ select public.im_admin_set_userid('22222222-2222-2222-2222-222222220001', 'wecom', 'bad id!') $$,
  '22023', null, '非法格式 userid 报 22023'
);
select throws_ok(
  $$ select public.im_admin_set_userid('22222222-2222-2222-2222-222222220001', 'wecom', '') $$,
  '22023', null, '空 userid 报 22023'
);
select throws_ok(
  $$ select public.im_admin_set_userid('22222222-2222-2222-2222-222222220001', 'qq', 'x') $$,
  '22023', null, '未知厂商报 22023'
);
select throws_ok(
  $$ select public.im_admin_set_userid('99999999-9999-9999-9999-999999999999', 'wecom', 'wx_9') $$,
  'P0002', null, '用户不存在报 P0002'
);

-- ===========================================================================
-- 3. 越权边界：普通用户不能改他人绑定；自助绑定只写本人（12）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
-- 角色仍是上一节的 authenticated（claims 已切换为 engineer）

select throws_ok(
  $$ select public.im_unbind('11111111-1111-1111-1111-111111111111', 'wecom') $$,
  '42501', null, 'engineer 调 im_unbind 被 admin 校验拒绝'
);
select throws_ok(
  $$ select public.im_admin_set_userid('11111111-1111-1111-1111-111111111111', 'wecom', 'wx_hack') $$,
  '42501', null, 'engineer 调 im_admin_set_userid 被 admin 校验拒绝'
);
select throws_ok(
  $$ select public.im_upsert_config('feishu', '{"app_id":"x"}', true) $$,
  '42501', null, 'engineer 调 im_upsert_config 被 admin 校验拒绝'
);
select throws_ok(
  $$ update public.profiles set wecom_userid = 'wx_hack'
      where id = '11111111-1111-1111-1111-111111111111' $$,
  '42501', null, 'engineer 直改他人绑定被列权限拒绝'
);
select throws_ok(
  $$ select public.im_bind_self('feishu', 'fs_2002') $$,
  '23505', null, '自助绑定他人已占用的 userid 被拒'
);
select lives_ok(
  $$ select public.im_bind_self('feishu', 'fs_self_2002') $$,
  'engineer 自助绑定本人 feishu userid'
);
reset role;

select is(
  (select feishu_userid from public.profiles where id = '22222222-2222-2222-2222-222222220001'),
  'fs_self_2002',
  '自助绑定写入本人行'
);
select is(
  (select feishu_userid from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  null,
  '他人（admin）绑定未被改动'
);
select is(
  (select updated_by from public.profiles where id = '22222222-2222-2222-2222-222222220001'),
  '22222222-2222-2222-2222-222222220001'::uuid,
  '自助绑定写 updated_by = 本人'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'bind' and object_type = 'im_binding'
      and object_id = '22222222-2222-2222-2222-222222220001'
      and actor_id = '22222222-2222-2222-2222-222222220001'::uuid
  ),
  '自助绑定已写 audit（actor = 本人）'
);

set local role anon;
select throws_ok(
  $$ select public.im_bind_self('feishu', 'fs_anon') $$,
  '42501', null, 'anon 调 im_bind_self 无执行权'
);
select throws_ok(
  $$ select public.im_upsert_config('feishu', '{}', true) $$,
  '42501', null, 'anon 调 im_upsert_config 无执行权'
);
reset role;

-- ===========================================================================
-- 4. enabled=true 全局唯一（15）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$ select public.im_upsert_config('feishu', '{"app_id":"cli_x","app_secret":"fs-secret-9876"}', true) $$,
  'admin 保存 feishu 凭据并启用'
);
reset role;
select is(
  (select count(*) from public.im_auth_configs where enabled),
  1::bigint,
  '启用 feishu 后 enabled 行数为 1'
);
select is(
  (select enabled from public.im_auth_configs where provider = 'feishu'),
  true,
  'feishu enabled=true'
);
select is(
  (select credentials is not null from public.im_auth_configs where provider = 'feishu'),
  true,
  'feishu 凭据非空'
);

set local role authenticated;
select lives_ok(
  $$ select public.im_upsert_config(
       'wecom', '{"corp_id":"ww_x","agent_id":"1001","secret":"wecom-secret-1234"}', true
     ) $$,
  'admin 启用 wecom（自动停用 feishu）'
);
select is(
  public.im_get_enabled_provider(),
  'wecom',
  '启用 wecom 后 im_get_enabled_provider() = wecom'
);
reset role;
select is(
  (select count(*) from public.im_auth_configs where enabled),
  1::bigint,
  '切换后仍至多一行 enabled'
);
select is(
  (select enabled from public.im_auth_configs where provider = 'feishu'),
  false,
  'feishu 被原子停用'
);
select is(
  (select enabled from public.im_auth_configs where provider = 'wecom'),
  true,
  'wecom enabled=true'
);

set local role anon;
select is(
  public.im_get_enabled_provider(),
  'wecom',
  'anon 可读当前启用厂商（不泄凭据）'
);
reset role;

set local role authenticated;
select lives_ok(
  $$ select public.im_upsert_config('wecom', null, false) $$,
  'admin 停用 wecom（不传凭据 = 保留）'
);
select is(
  public.im_get_enabled_provider(),
  null,
  '无启用厂商时 im_get_enabled_provider() 返回 NULL'
);
reset role;
select is(
  (select count(*) from public.im_auth_configs where enabled),
  0::bigint,
  '停用后无 enabled 行'
);
select is(
  (select credentials is not null from public.im_auth_configs where provider = 'wecom'),
  true,
  '停用不清除凭据'
);

-- 约束兜底：绕过 RPC 直插第二行 enabled=true 也被 partial unique index 拒绝
delete from public.im_auth_configs;
insert into public.im_auth_configs (provider, enabled) values ('feishu', true);
select throws_ok(
  $$ insert into public.im_auth_configs (provider, enabled) values ('dingtalk', true) $$,
  '23505', null, 'partial unique index 拒绝第二行 enabled=true'
);

-- ===========================================================================
-- 5. 凭据加密往返一致（10）
-- ===========================================================================
delete from public.im_auth_configs;

set local role authenticated;
select lives_ok(
  $$ select public.im_upsert_config('feishu', '{"app_id":"cli_abc","app_secret":"fs-secret-9876"}', true) $$,
  'admin 写入 feishu 凭据'
);
reset role;

select ok(
  (select credentials::text not like '%fs-secret-9876%'
     from public.im_auth_configs where provider = 'feishu'),
  '库内密文不含凭据明文'
);
select is(
  app.decrypt_secret((select credentials from public.im_auth_configs where provider = 'feishu'))::jsonb ->> 'app_secret',
  'fs-secret-9876',
  'app_secret 加密往返一致'
);
select is(
  app.decrypt_secret((select credentials from public.im_auth_configs where provider = 'feishu'))::jsonb ->> 'app_id',
  'cli_abc',
  'app_id 加密往返一致'
);

set local role authenticated;
select lives_ok(
  $$ select public.im_upsert_config('feishu', null, true) $$,
  'admin 仅改开关不传凭据（null = 保留原值）'
);
reset role;
select is(
  app.decrypt_secret((select credentials from public.im_auth_configs where provider = 'feishu'))::jsonb ->> 'app_secret',
  'fs-secret-9876',
  '不传凭据时保留原凭据'
);

set local role authenticated;
select lives_ok(
  $$ select public.im_upsert_config('feishu', '{"app_id":"cli_new","app_secret":"fs-secret-0001"}', true) $$,
  'admin 整体替换 feishu 凭据'
);
reset role;
select is(
  app.decrypt_secret((select credentials from public.im_auth_configs where provider = 'feishu'))::jsonb ->> 'app_secret',
  'fs-secret-0001',
  '替换后解密为新值'
);

select ok(
  not exists (
    select 1 from public.audit_operations
    where module = 'system' and object_type = 'im_auth_config'
      and diff::text like '%fs-secret-9876%'
  ),
  '配置审计摘要不落凭据明文'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'upsert' and object_type = 'im_auth_config'
      and object_id = 'feishu'
      and (diff ->> 'enabled_after')::boolean
  ),
  '配置 upsert 已写 audit（含启用状态）'
);

-- ===========================================================================
-- 6. 解绑与审计（5）
-- ===========================================================================
set local role authenticated;
select lives_ok(
  $$ select public.im_unbind('22222222-2222-2222-2222-222222220001', 'feishu') $$,
  'admin 解绑用户 1 的飞书绑定'
);
select is(
  (select (public.im_unbind('22222222-2222-2222-2222-222222220001', 'feishu')) ->> 'userid_before'),
  null,
  '重复解绑幂等（userid_before = null）'
);
reset role;

select is(
  (select feishu_userid from public.profiles where id = '22222222-2222-2222-2222-222222220001'),
  null,
  '解绑后 feishu_userid 置空'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'unbind' and object_type = 'im_binding'
      and object_id = '22222222-2222-2222-2222-222222220001'
      and actor_id = '11111111-1111-1111-1111-111111111111'::uuid
      and diff ->> 'userid_before' = 'fs_self_2002'
  ),
  '解绑已写 audit（含前值）'
);

select * from finish();
rollback;
