-- pgTAP：system/009 + 字典管理页面同批 RPC —— system_dictionaries / system_dict_meta + get_dict + RLS
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构（表/列/复合主键/约束/RLS）；seed（common.status / common.yesno + 配色对齐）；
--       函数存在性 + SECURITY DEFINER + search_path=''；GRANT 面（登录可读、写仅 RPC）；
--       get_dict 仅 active 且按 sort_order；value 建后不可改（同 value 更新 label 不改 value）；
--       新增字典用途说明必填；未登记 dict_key 建项被拒；disable 幂等与存量保留；
--       engineer/anon 越权拒绝。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(81);

-- ===========================================================================
-- 1. 结构：表 / 列 / 复合主键 / 约束 / RLS（17）
-- ===========================================================================
select has_table('public', 'system_dictionaries', 'system_dictionaries 表存在');
select has_table('public', 'system_dict_meta', 'system_dict_meta 表存在');

select col_is_pk(
  'public', 'system_dictionaries', array['dict_key', 'value'],
  'system_dictionaries 复合主键 (dict_key, value)'
);
select col_is_pk('public', 'system_dict_meta', 'dict_key', 'system_dict_meta.dict_key 为主键');
select col_type_is('public', 'system_dictionaries', 'sort_order', 'integer', 'sort_order 为 integer');
select col_type_is('public', 'system_dictionaries', 'color_class', 'text', 'color_class 为 text');
select col_type_is('public', 'system_dictionaries', 'status', 'text', 'status 为 text');
select col_type_is('public', 'system_dict_meta', 'description', 'text', 'meta.description 为 text');
select col_not_null('public', 'system_dictionaries', 'label', 'label 非空');
select col_not_null('public', 'system_dictionaries', 'status', 'status 非空');
select col_not_null('public', 'system_dict_meta', 'description', 'meta.description 非空');
select col_has_default('public', 'system_dictionaries', 'sort_order', 'sort_order 有默认值');
select col_has_default('public', 'system_dictionaries', 'status', 'status 有默认值');
select col_has_default('public', 'system_dict_meta', 'created_at', 'meta.created_at 有默认值');
select col_has_check('public', 'system_dictionaries', 'status', 'status 有取值 check 约束');

select is(
  (select relrowsecurity from pg_class where oid = 'public.system_dictionaries'::regclass),
  true,
  'system_dictionaries 已启用 RLS'
);
select is(
  (select relrowsecurity from pg_class where oid = 'public.system_dict_meta'::regclass),
  true,
  'system_dict_meta 已启用 RLS'
);

-- ===========================================================================
-- 2. seed：common.status / common.yesno（5）
-- ===========================================================================
select is(
  (select count(*) from public.system_dict_meta where dict_key in ('common.status', 'common.yesno')),
  2::bigint,
  '字典登记 seed 恰 2 个 dict_key'
);
select is(
  (select count(*) from public.system_dictionaries where dict_key in ('common.status', 'common.yesno')),
  5::bigint,
  '字典项 seed 恰 5 行'
);
select is(
  (select color_class from public.system_dictionaries
    where dict_key = 'common.status' and value = 'active'),
  'border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300',
  'common.status.active 配色与 dictionaries.ts emerald Badge 类一致'
);
select is(
  (select count(*) from public.system_dictionaries where dict_key = 'common.yesno'),
  2::bigint,
  'common.yesno 有 yes/no 两项'
);
select is(
  (select label from public.system_dictionaries
    where dict_key = 'common.status' and value = 'active'),
  '启用',
  'common.status.active label=启用'
);

-- ===========================================================================
-- 3. 函数存在性 + SECURITY DEFINER + search_path=''（14）
-- ===========================================================================
select has_function('app', 'get_dict', array['text'], 'app.get_dict(text) 存在');
select has_function('public', 'get_dict', array['text'], 'public.get_dict(text) 薄包装存在');
select has_function('app', 'get_dict_catalog', 'app.get_dict_catalog() 存在');
select has_function('public', 'get_dict_catalog', 'public.get_dict_catalog() 薄包装存在');
select has_function('app', 'get_dict_items', array['text'], 'app.get_dict_items(text) 存在');
select has_function('public', 'get_dict_items', array['text'], 'public.get_dict_items(text) 薄包装存在');
select has_function('app', 'upsert_dict_meta', array['text', 'text'], 'app.upsert_dict_meta 存在');
select has_function('public', 'upsert_dict_meta', array['text', 'text'], 'public.upsert_dict_meta 薄包装存在');
select has_function(
  'app', 'upsert_dict_item', array['text', 'text', 'text', 'integer', 'text', 'text'],
  'app.upsert_dict_item 存在'
);
select has_function(
  'public', 'upsert_dict_item', array['text', 'text', 'text', 'integer', 'text', 'text'],
  'public.upsert_dict_item 薄包装存在'
);
select has_function('app', 'disable_dict_item', array['text', 'text'], 'app.disable_dict_item 存在');
select has_function('public', 'disable_dict_item', array['text', 'text'], 'public.disable_dict_item 薄包装存在');

select ok(
  (select count(*) = 6
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname in ('get_dict', 'get_dict_catalog', 'get_dict_items',
                        'upsert_dict_meta', 'upsert_dict_item', 'disable_dict_item')
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  'app 侧 6 个函数均 security definer + search_path 固定为空'
);
select ok(
  (select count(*) = 6
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('get_dict', 'get_dict_catalog', 'get_dict_items',
                        'upsert_dict_meta', 'upsert_dict_item', 'disable_dict_item')
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  'public 侧 6 个薄包装均 security definer + search_path 固定为空'
);

-- ===========================================================================
-- 4. GRANT 面：登录可读、写仅 RPC（10）
-- ===========================================================================
select ok(
  has_function_privilege('authenticated', 'public.get_dict(text)', 'EXECUTE'),
  'authenticated 可执行 public.get_dict'
);
select ok(
  has_function_privilege('authenticated', 'app.get_dict(text)', 'EXECUTE'),
  'authenticated 可执行 app.get_dict'
);
select ok(
  has_function_privilege('authenticated', 'public.upsert_dict_meta(text,text)', 'EXECUTE'),
  'authenticated 可执行 public.upsert_dict_meta（函数内 admin 校验）'
);
select ok(
  has_function_privilege(
    'authenticated', 'public.upsert_dict_item(text,text,text,integer,text,text)', 'EXECUTE'),
  'authenticated 可执行 public.upsert_dict_item（函数内 admin 校验）'
);
select ok(
  has_function_privilege('authenticated', 'public.disable_dict_item(text,text)', 'EXECUTE'),
  'authenticated 可执行 public.disable_dict_item（函数内 admin 校验）'
);
select ok(
  has_table_privilege('authenticated', 'public.system_dictionaries', 'SELECT'),
  'authenticated 对 system_dictionaries 有 SELECT（登录可读）'
);
select ok(
  has_table_privilege('authenticated', 'public.system_dict_meta', 'SELECT'),
  'authenticated 对 system_dict_meta 有 SELECT（登录可读）'
);
select ok(
  not has_table_privilege('authenticated', 'public.system_dictionaries', 'INSERT'),
  'authenticated 对 system_dictionaries 无 INSERT（写仅 RPC）'
);
select ok(
  not has_function_privilege('anon', 'public.get_dict(text)', 'EXECUTE'),
  'anon 无 public.get_dict 执行权'
);
select ok(
  not has_table_privilege('anon', 'public.system_dictionaries', 'SELECT'),
  'anon 对 system_dictionaries 无 SELECT'
);

-- ===========================================================================
-- 5. get_dict 读取口：仅 active、按 sort_order（3）
-- ===========================================================================
select is(
  jsonb_array_length(app.get_dict('common.status')),
  3,
  'get_dict(common.status) 返回 3 个 active 项'
);
select is(
  app.get_dict('common.status') -> 0 ->> 'value',
  'active',
  'get_dict 按 sort_order 升序（first=active）'
);
select is(
  app.get_dict('missing.dict'),
  '[]'::jsonb,
  'get_dict 缺 key 返回空数组'
);

-- ===========================================================================
-- 6. 越权：engineer 写被拒 / 表级读可用（7）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  $$ select public.upsert_dict_meta('eng.dict', '越权注册') $$,
  '42501', null,
  'engineer 调 upsert_dict_meta 被 admin 校验拒绝'
);
select throws_ok(
  $$ select public.upsert_dict_item('common.yesno', 'maybe', '也许', 90, null, 'active') $$,
  '42501', null,
  'engineer 调 upsert_dict_item 被 admin 校验拒绝'
);
select throws_ok(
  $$ select public.disable_dict_item('common.yesno', 'no') $$,
  '42501', null,
  'engineer 调 disable_dict_item 被 admin 校验拒绝'
);
select lives_ok(
  $$ select public.get_dict('common.yesno') $$,
  'engineer 可读 get_dict（全员可读）'
);
select lives_ok(
  $$ select * from public.system_dictionaries $$,
  'engineer 表级 SELECT 可用（登录可读）'
);
select lives_ok(
  $$ select * from public.system_dict_meta $$,
  'engineer 表级读 meta 可用'
);
select throws_ok(
  $$ insert into public.system_dictionaries (dict_key, value, label)
     values ('common.yesno', 'hack', '越权') $$,
  '42501', null,
  'engineer 直写 system_dictionaries 被拒（写仅 RPC）'
);

reset role;

-- ===========================================================================
-- 7. admin 注册字典：说明必填、更新说明（4）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  $$ select public.upsert_dict_meta('test.dict', 'pgTAP 测试字典') $$,
  'admin 注册新字典成功'
);
select is(
  (select public.upsert_dict_meta('test.dict2', '第二个测试字典') ->> 'created'),
  'true',
  '新建字典返回 created=true'
);
select is(
  (select public.upsert_dict_meta('test.dict', '用途说明更新') ->> 'created'),
  'false',
  '已存在字典更新说明返回 created=false'
);
select throws_ok(
  $$ select public.upsert_dict_meta('test.blank', '   ') $$,
  '22023', null,
  '用途说明为空白被拒绝（新增字典必须登记用途）'
);

-- ===========================================================================
-- 8. admin 建项/编辑：未登记被拒、value 不可改、类型校验、审计（11）
-- ===========================================================================
select throws_ok(
  $$ select public.upsert_dict_item('missing.dict', 'a', '甲', 10, null, 'active') $$,
  'P0002', null,
  '未登记 dict_key 建项被拒（先登记用途说明）'
);
select lives_ok(
  $$ select public.upsert_dict_item('test.dict', 'a', '甲', 20, null, 'active') $$,
  'admin 新建字典项成功'
);
select is(
  (select count(*) from public.get_dict_items('test.dict')),
  1::bigint,
  'get_dict_items 返回 1 项'
);
select lives_ok(
  $$ select public.upsert_dict_item('test.dict', 'a', '甲改名', 30,
       'border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-900/60 dark:bg-blue-950/60 dark:text-blue-300', 'active') $$,
  '同 value upsert 更新 label/排序/配色成功'
);
select is(
  (select label from public.system_dictionaries where dict_key = 'test.dict' and value = 'a'),
  '甲改名',
  '同 value 更新后 label 已改'
);
select is(
  (select count(*) from public.system_dictionaries where dict_key = 'test.dict'),
  1::bigint,
  '同 value 更新不新增行（value 为定位键，未变）'
);
select throws_ok(
  $$ select public.upsert_dict_item('test.dict', 'a', '甲', 10, null, 'gone') $$,
  '22023', null,
  '非法 status 被拒绝'
);
select throws_ok(
  $$ select public.upsert_dict_item('test.dict', 'a', '   ', 10, null, 'active') $$,
  '22023', null,
  'label 为空白被拒绝'
);
select throws_ok(
  $$ select public.upsert_dict_item('test.dict', '  ', '甲', 10, null, 'active') $$,
  '22023', null,
  'value 为空白被拒绝'
);
select lives_ok(
  $$ select public.upsert_dict_item('test.dict', 'b', '乙', 10, null, 'active') $$,
  'admin 新建第二项（更小 sort_order）成功'
);
select is(
  (select value from public.get_dict_items('test.dict') limit 1),
  'b',
  'get_dict_items 按 sort_order 升序（b 在前）'
);

reset role;

select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and object_type = 'dict_item' and object_id = 'test.dict/b'
  ),
  '字典项审计已写入（system/upsert/dict_item/test.dict/b）'
);

-- ===========================================================================
-- 9. disable：不存在报错、幂等、存量保留（5）
-- ===========================================================================
set local role authenticated;

select throws_ok(
  $$ select public.disable_dict_item('test.dict', 'missing') $$,
  'P0002', null,
  '停用不存在的字典项报 P0002'
);
select lives_ok(
  $$ select public.disable_dict_item('test.dict', 'b') $$,
  'admin 停用字典项成功'
);
select is(
  (select public.disable_dict_item('test.dict', 'b') ->> 'status'),
  'disabled',
  '重复停用幂等返回 disabled'
);
select is(
  (select count(*) from public.system_dictionaries where dict_key = 'test.dict'),
  2::bigint,
  '停用后存量行保留（2 行，不物理删除）'
);

reset role;

select is(
  (select status from public.system_dictionaries where dict_key = 'test.dict' and value = 'b'),
  'disabled',
  '停用项 status=disabled'
);

-- ===========================================================================
-- 10. 停用项 get_dict 过滤（2）
-- ===========================================================================
select is(
  jsonb_array_length(app.get_dict('test.dict')),
  1,
  'get_dict 过滤停用项（test.dict 只剩 1 项）'
);
select is(
  app.get_dict('test.dict') -> 0 ->> 'value',
  'a',
  'get_dict 过滤后仅剩 active 项 a'
);

-- ===========================================================================
-- 11. anon 无路径（2）
-- ===========================================================================
set local role anon;

select throws_ok(
  $$ select public.get_dict('common.status') $$,
  '42501', null,
  'anon 调 public.get_dict 被拒（无 GRANT）'
);
select throws_ok(
  $$ select * from public.system_dictionaries $$,
  '42501', null,
  'anon 直查 system_dictionaries 被拒（无表权限）'
);

reset role;

select * from finish();
rollback;
