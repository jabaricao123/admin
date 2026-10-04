-- pgTAP：system/007+008 —— system_settings 参数表 + get_setting 读取口 + 管理 RPC + 历史 + RLS
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构（表/列/约束/RLS）；说明必填（空串与空白均拒绝）；类型一致性（表 check 兜底）；
--       seed 内置参数；函数存在性 + SECURITY DEFINER + search_path=''；GRANT 面；
--       get_setting 缺 key 返回 NULL；engineer/anon 越权拒绝且全员可读成立；
--       admin 新建/改值/同值重复保存的历史语义；审计写入；类型不匹配可读报错。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(74);

-- ===========================================================================
-- 1. 结构：表 / 列 / 约束 / RLS（15）
-- ===========================================================================
select has_table('public', 'system_settings', 'system_settings 表存在');
select has_table('public', 'system_setting_history', 'system_setting_history 表存在');

select col_is_pk('public', 'system_settings', 'key', 'key 为主键');
select col_type_is('public', 'system_settings', 'value', 'jsonb', 'value 为 jsonb');
select col_type_is('public', 'system_settings', 'value_type', 'text', 'value_type 为 text');
select col_type_is('public', 'system_settings', 'description', 'text', 'description 为 text');
select col_not_null('public', 'system_settings', 'group_name', 'group_name 非空');
select col_not_null('public', 'system_settings', 'value', 'value 非空');
select col_not_null('public', 'system_settings', 'value_type', 'value_type 非空');
select col_not_null('public', 'system_settings', 'description', 'description 非空');
select col_has_default('public', 'system_settings', 'updated_at', 'updated_at 有默认值');
select has_column('public', 'system_settings', 'updated_by', 'updated_by 列存在');
select has_column('public', 'system_setting_history', 'changed_at', 'changed_at 列存在');

select is(
  (select relrowsecurity from pg_class where oid = 'public.system_settings'::regclass),
  true,
  'system_settings 已启用 RLS'
);
select is(
  (select relrowsecurity from pg_class where oid = 'public.system_setting_history'::regclass),
  true,
  'system_setting_history 已启用 RLS'
);

-- ===========================================================================
-- 2. 表级约束兜底：非法 value_type / 说明必填 / 类型一致性（7）
-- ===========================================================================
select throws_ok(
  $$ insert into public.system_settings (key, group_name, value, value_type, description)
     values ('bad_type', '通用', '"x"'::jsonb, 'text', '说明') $$,
  '23514', null,
  '非法 value_type 被 check 拒绝'
);
select throws_ok(
  $$ insert into public.system_settings (key, group_name, value, value_type, description)
     values ('empty_desc', '通用', '"x"'::jsonb, 'string', '') $$,
  '23514', null,
  'description 空串被拒绝（说明必填）'
);
select throws_ok(
  $$ insert into public.system_settings (key, group_name, value, value_type, description)
     values ('blank_desc', '通用', '"x"'::jsonb, 'string', '   ') $$,
  '23514', null,
  'description 全空白被拒绝（说明必填）'
);
select throws_ok(
  $$ insert into public.system_settings (key, group_name, value, value_type, description)
     values ('mismatch_number', '通用', 'true'::jsonb, 'number', '类型不匹配') $$,
  '23514', null,
  'value_type=number 配 boolean 值被 check 拒绝'
);
select throws_ok(
  $$ insert into public.system_settings (key, group_name, value, value_type, description)
     values ('mismatch_bool', '通用', '1'::jsonb, 'bool', '类型不匹配') $$,
  '23514', null,
  'value_type=bool 配 number 值被 check 拒绝'
);
select throws_ok(
  $$ insert into public.system_settings (key, group_name, value, value_type, description)
     values ('mismatch_json', '通用', '1'::jsonb, 'json', '类型不匹配') $$,
  '23514', null,
  'value_type=json 配标量值被 check 拒绝'
);
select lives_ok(
  $$ insert into public.system_settings (key, group_name, value, value_type, description)
     values ('zz_check_ok', '通用', '[1,2]'::jsonb, 'json', '合法 json 数组') $$,
  '合法 json 数组可插入（表约束不误伤）'
);

-- ===========================================================================
-- 3. seed 内置参数（5）
-- ===========================================================================
select is(
  (select count(*) from public.system_settings where key in (
     'page_size_default', 'session_remind_minutes', 'site_name', 'feature_beta')),
  4::bigint,
  '内置参数 seed 恰 4 行'
);
select is(
  (select value from public.system_settings where key = 'page_size_default'),
  '20'::jsonb,
  'page_size_default=20'
);
select is(
  (select value_type from public.system_settings where key = 'page_size_default'),
  'number',
  'page_size_default 类型为 number'
);
select is(
  (select value from public.system_settings where key = 'site_name'),
  '"企业管理系统"'::jsonb,
  'site_name=企业管理系统'
);
select is(
  (select value from public.system_settings where key = 'feature_beta'),
  'false'::jsonb,
  'feature_beta=false'
);

-- ===========================================================================
-- 4. 函数存在性 + SECURITY DEFINER + search_path=''（10）
-- ===========================================================================
select has_function('app', 'get_setting', array['text'], 'app.get_setting(text) 存在');
select has_function('public', 'get_setting', array['text'], 'public.get_setting(text) 薄包装存在');
select has_function(
  'app', 'upsert_setting', array['text', 'jsonb', 'text', 'text', 'text'],
  'app.upsert_setting 存在'
);
select has_function(
  'public', 'upsert_setting', array['text', 'jsonb', 'text', 'text', 'text'],
  'public.upsert_setting 薄包装存在'
);
select has_function('app', 'get_all_settings', 'app.get_all_settings() 存在');
select has_function('public', 'get_all_settings', 'public.get_all_settings() 薄包装存在');
select has_function('app', 'get_setting_history', array['text'], 'app.get_setting_history(text) 存在');
select has_function('public', 'get_setting_history', array['text'], 'public.get_setting_history(text) 薄包装存在');

select ok(
  (select count(*) = 4
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname in ('get_setting', 'upsert_setting', 'get_all_settings', 'get_setting_history')
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  'app 侧 4 个函数均 security definer + search_path 固定为空'
);
select ok(
  (select count(*) = 4
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('get_setting', 'upsert_setting', 'get_all_settings', 'get_setting_history')
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  'public 侧 4 个薄包装均 security definer + search_path 固定为空'
);

-- ===========================================================================
-- 5. GRANT 面（8）
-- ===========================================================================
select ok(
  has_function_privilege('authenticated', 'app.get_setting(text)', 'EXECUTE'),
  'authenticated 可执行 app.get_setting'
);
select ok(
  has_function_privilege('authenticated', 'public.get_setting(text)', 'EXECUTE'),
  'authenticated 可执行 public.get_setting'
);
select ok(
  has_function_privilege('authenticated', 'app.upsert_setting(text,jsonb,text,text,text)', 'EXECUTE'),
  'authenticated 可执行 app.upsert_setting（函数内 admin 校验）'
);
select ok(
  has_function_privilege('authenticated', 'public.upsert_setting(text,jsonb,text,text,text)', 'EXECUTE'),
  'authenticated 可执行 public.upsert_setting（函数内 admin 校验）'
);
select ok(
  not has_function_privilege('anon', 'public.get_setting(text)', 'EXECUTE'),
  'anon 无 public.get_setting 执行权'
);
select ok(
  not has_table_privilege('authenticated', 'public.system_settings', 'SELECT'),
  'authenticated 对 system_settings 无 SELECT（全经 RPC）'
);
select ok(
  not has_table_privilege('authenticated', 'public.system_settings', 'INSERT'),
  'authenticated 对 system_settings 无 INSERT'
);
select ok(
  not has_table_privilege('anon', 'public.system_settings', 'SELECT'),
  'anon 对 system_settings 无 SELECT'
);

-- ===========================================================================
-- 6. 读取口：get_setting 缺 key 返回 NULL（2）
-- ===========================================================================
select is(
  app.get_setting('page_size_default'),
  '20'::jsonb,
  'get_setting 返回已存参数值'
);
select is(
  app.get_setting('missing_key_007'),
  null::jsonb,
  '缺 key 返回 NULL 不报错'
);

-- ===========================================================================
-- 7. 越权：engineer 读写分离（5）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$ select * from public.system_settings $$,
  '42501', null,
  'engineer 直查 system_settings 被拒'
);
select throws_ok(
  $$ select public.upsert_setting('x', '1'::jsonb, '通用', 'number', '说明') $$,
  '42501', null,
  'engineer 调 upsert_setting 被 admin 校验拒绝'
);
select throws_ok(
  $$ select * from public.get_all_settings() $$,
  '42501', null,
  'engineer 调 get_all_settings 被 admin 校验拒绝'
);
select throws_ok(
  $$ select * from public.get_setting_history('page_size_default') $$,
  '42501', null,
  'engineer 调 get_setting_history 被 admin 校验拒绝'
);
select lives_ok(
  $$ select public.get_setting('page_size_default') $$,
  'engineer 可读 get_setting（全员可读）'
);

reset role;

-- ===========================================================================
-- 8. admin 写路径：新建 / 历史 / 同值重复保存 / 改值 / 类型与说明校验 / 审计（15）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$ select public.upsert_setting('test_pg_007', '42'::jsonb, '测试', 'number', '测试参数') $$,
  'admin 新建 number 参数成功'
);
select is(
  (select public.get_setting('test_pg_007')),
  '42'::jsonb,
  '新建后 get_setting 即时返回新值'
);

reset role;

select is(
  (select count(*) from public.system_setting_history where key = 'test_pg_007'),
  1::bigint,
  '新建写 1 条历史'
);
select is(
  (select old_value from public.system_setting_history where key = 'test_pg_007'),
  null::jsonb,
  '新建历史 old_value=NULL'
);
select is(
  (select new_value from public.system_setting_history where key = 'test_pg_007'),
  '42'::jsonb,
  '新建历史 new_value=42'
);

set local role authenticated;

select lives_ok(
  $$ select public.upsert_setting('test_pg_007', '42'::jsonb, '测试', 'number', '测试参数（改名）') $$,
  '同值重复保存成功（仅说明变化）'
);

reset role;

select is(
  (select count(*) from public.system_setting_history where key = 'test_pg_007'),
  1::bigint,
  '同值重复保存不新增历史（值未变）'
);

set local role authenticated;

select lives_ok(
  $$ select public.upsert_setting('test_pg_007', '43'::jsonb, '测试', 'number', '测试参数') $$,
  'admin 改值成功'
);

reset role;

select is(
  (select count(*) from public.system_setting_history where key = 'test_pg_007'),
  2::bigint,
  '改值新增 1 条历史（共 2 条）'
);
select is(
  (select old_value from public.system_setting_history
    where key = 'test_pg_007' order by id desc limit 1),
  '42'::jsonb,
  '最新历史 old_value=42'
);
select is(
  (select new_value from public.system_setting_history
    where key = 'test_pg_007' order by id desc limit 1),
  '43'::jsonb,
  '最新历史 new_value=43'
);

set local role authenticated;

select throws_ok(
  $$ select public.upsert_setting('test_pg_007', '"not-number"'::jsonb, '测试', 'number', '说明') $$,
  '22023', null,
  '值类型与 value_type 不匹配被函数拒绝'
);
select throws_ok(
  $$ select public.upsert_setting('test_pg_007', '1'::jsonb, '测试', 'number', '   ') $$,
  '22023', null,
  '说明为空白被函数拒绝'
);
select throws_ok(
  $$ select public.upsert_setting('test_pg_007', '1'::jsonb, '测试', 'text', '说明') $$,
  '22023', null,
  '未知 value_type 被函数拒绝'
);
select lives_ok(
  $$ select public.upsert_setting('test_pg_007_json', '{"a":1}'::jsonb, '测试', 'json', 'json 参数') $$,
  'admin 新建 json 对象参数成功'
);

reset role;

select is(
  app.get_setting('test_pg_007_json'),
  '{"a":1}'::jsonb,
  'json 参数读回一致'
);
select is(
  (select changed_by from public.system_setting_history
    where key = 'test_pg_007' order by id desc limit 1),
  '11111111-1111-1111-1111-111111111111'::uuid,
  '历史 changed_by 记录操作人 auth.uid()'
);
select is(
  (select count(*) from public.get_setting_history('test_pg_007')
    where changed_by = '11111111-1111-1111-1111-111111111111'::uuid),
  2::bigint,
  'get_setting_history 返回该 key 的 2 条变更'
);
select is(
  (select count(*) from public.get_setting_history('missing_key_007')),
  0::bigint,
  'get_setting_history 对无历史 key 返回 0 行'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'upsert'
      and object_type = 'setting' and object_id = 'test_pg_007'
  ),
  '审计已写入（system/upsert/setting/test_pg_007）'
);

-- ===========================================================================
-- 9. anon 无路径（2）
-- ===========================================================================
set local role anon;

select throws_ok(
  $$ select public.get_setting('page_size_default') $$,
  '42501', null,
  'anon 调 public.get_setting 被拒（无 GRANT）'
);
select throws_ok(
  $$ select public.upsert_setting('x', '1'::jsonb, '通用', 'number', '说明') $$,
  '42501', null,
  'anon 调 public.upsert_setting 被拒（无 GRANT）'
);

reset role;

select * from finish();
rollback;
