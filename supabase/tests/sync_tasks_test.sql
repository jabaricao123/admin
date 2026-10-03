-- pgTAP：sync/003 —— sync_tasks + sync_task_versions + 映射白名单 + 版本快照 + dry-run
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构（两表列/类型/约束/外键/RLS/触发器）；函数存在性 + SECURITY DEFINER + search_path=''；
--       GRANT 面（authenticated 有管理/试跑/读取 RPC、无 validate_sync_mapping；anon 无路径）；
--       app.validate_sync_mapping 白名单（三类目标合法映射通过；目标表/目标字段越界、
--       profiles role/status、空映射、非数组、缺字段均 22023）；
--       版本快照（新建 v1、每次 upsert +1、快照内容正确、回滚生成新版本且内容回到上一版）；
--       启用守卫（未验证/已停用数据源不能建 active 任务；disabled 草稿可存）；
--       dry_run 三类目标计数（departments→name / positions→code / profiles→email；
--       profiles 未匹配计入 skip 并标注不新建用户；manual→conflict；skip→skip；overwrite→update）；
--       dry_run 只读（不改 config_version、不写目标表）；越权（engineer 读 0 行、RPC 42501；anon 无路径）。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(125);

-- ===========================================================================
-- 1. 结构：sync_tasks / sync_task_versions（30）
-- ===========================================================================
select has_table('public', 'sync_tasks', 'sync_tasks 表存在');
select has_table('public', 'sync_task_versions', 'sync_task_versions 表存在');

select col_is_pk('public', 'sync_tasks', 'id', 'sync_tasks.id 为主键');
select col_is_pk(
  'public', 'sync_task_versions', array['task_id', 'version'],
  'sync_task_versions (task_id, version) 联合主键'
);
select col_is_fk('public', 'sync_tasks', 'source_id', 'source_id 外键 → sync_sources');
select col_is_fk('public', 'sync_task_versions', 'task_id', 'task_id 外键 → sync_tasks');

select col_type_is('public', 'sync_tasks', 'source_id', 'uuid', 'source_id 为 uuid');
select col_type_is('public', 'sync_tasks', 'target_table', 'text', 'target_table 为 text');
select col_type_is('public', 'sync_tasks', 'direction', 'text', 'direction 为 text');
select col_type_is('public', 'sync_tasks', 'field_mapping', 'jsonb', 'field_mapping 为 jsonb');
select col_type_is('public', 'sync_tasks', 'conflict_policy', 'text', 'conflict_policy 为 text');
select col_type_is('public', 'sync_tasks', 'status', 'text', 'status 为 text');
select col_type_is('public', 'sync_tasks', 'config_version', 'integer', 'config_version 为 integer');
select col_type_is('public', 'sync_task_versions', 'config', 'jsonb', 'versions.config 为 jsonb');

select col_not_null('public', 'sync_tasks', 'name', 'name 非空');
select col_not_null('public', 'sync_tasks', 'source_id', 'source_id 非空');
select col_not_null('public', 'sync_tasks', 'target_table', 'target_table 非空');
select col_not_null('public', 'sync_tasks', 'field_mapping', 'field_mapping 非空');
select col_not_null('public', 'sync_tasks', 'config_version', 'config_version 非空');
select col_has_default('public', 'sync_tasks', 'direction', 'direction 有默认值');
select col_has_default('public', 'sync_tasks', 'conflict_policy', 'conflict_policy 有默认值');
select col_has_default('public', 'sync_tasks', 'status', 'status 有默认值');
select col_has_default('public', 'sync_tasks', 'config_version', 'config_version 有默认值');
select col_has_check('public', 'sync_tasks', 'target_table', 'target_table 有白名单 check 约束');
select col_has_check('public', 'sync_tasks', 'direction', 'direction 有取值 check 约束');
select col_has_check('public', 'sync_tasks', 'conflict_policy', 'conflict_policy 有取值 check 约束');
select col_has_check('public', 'sync_tasks', 'config_version', 'config_version 有 >=1 check 约束');
select has_trigger('public', 'sync_tasks', 'sync_tasks_set_updated_at', 'updated_at 触发器存在');
select is(
  (select relrowsecurity from pg_class where oid = 'public.sync_tasks'::regclass),
  true,
  'sync_tasks 已启用 RLS'
);
select is(
  (select relrowsecurity from pg_class where oid = 'public.sync_task_versions'::regclass),
  true,
  'sync_task_versions 已启用 RLS'
);

-- ===========================================================================
-- 2. 函数存在性 + SECURITY DEFINER + search_path + GRANT 面（22）
-- ===========================================================================
select has_function('app', 'validate_sync_mapping', array['text', 'jsonb'], 'app.validate_sync_mapping(text,jsonb) 存在');
select has_function(
  'app', 'upsert_sync_task',
  array['uuid', 'text', 'uuid', 'text', 'text', 'jsonb', 'text', 'text'],
  'app.upsert_sync_task(uuid,text,uuid,text,text,jsonb,text,text) 存在'
);
select has_function('app', 'dry_run_sync_task', array['uuid', 'jsonb'], 'app.dry_run_sync_task(uuid,jsonb) 存在');
select has_function('app', 'get_sync_tasks', array[]::text[], 'app.get_sync_tasks() 存在');
select has_function('app', 'get_sync_task_versions', array['uuid'], 'app.get_sync_task_versions(uuid) 存在');
select has_function('app', 'rollback_sync_task', array['uuid'], 'app.rollback_sync_task(uuid) 存在');
select has_function(
  'public', 'upsert_sync_task',
  array['uuid', 'text', 'uuid', 'text', 'text', 'jsonb', 'text', 'text'],
  'public.upsert_sync_task 薄包装存在'
);
select has_function('public', 'dry_run_sync_task', array['uuid', 'jsonb'], 'public.dry_run_sync_task 薄包装存在');
select has_function('public', 'get_sync_tasks', array[]::text[], 'public.get_sync_tasks 薄包装存在');
select has_function('public', 'get_sync_task_versions', array['uuid'], 'public.get_sync_task_versions 薄包装存在');
select has_function('public', 'rollback_sync_task', array['uuid'], 'public.rollback_sync_task 薄包装存在');

select ok(
  (select count(*) = 10
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
      ('app', 'upsert_sync_task'),
      ('app', 'dry_run_sync_task'),
      ('app', 'get_sync_tasks'),
      ('app', 'get_sync_task_versions'),
      ('app', 'rollback_sync_task'),
      ('public', 'upsert_sync_task'),
      ('public', 'dry_run_sync_task'),
      ('public', 'get_sync_tasks'),
      ('public', 'get_sync_task_versions'),
      ('public', 'rollback_sync_task')
    )
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '10 个管理/试跑/读取函数全部 security definer + search_path 固定为空'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.upsert_sync_task(uuid,text,uuid,text,text,jsonb,text,text)',
    'EXECUTE'
  ),
  'authenticated 可执行 upsert_sync_task'
);
select ok(
  has_function_privilege('authenticated', 'public.dry_run_sync_task(uuid,jsonb)', 'EXECUTE'),
  'authenticated 可执行 dry_run_sync_task'
);
select ok(
  has_function_privilege('authenticated', 'public.get_sync_tasks()', 'EXECUTE'),
  'authenticated 可执行 get_sync_tasks'
);
select ok(
  has_function_privilege('authenticated', 'public.get_sync_task_versions(uuid)', 'EXECUTE'),
  'authenticated 可执行 get_sync_task_versions'
);
select ok(
  has_function_privilege('authenticated', 'public.rollback_sync_task(uuid)', 'EXECUTE'),
  'authenticated 可执行 rollback_sync_task'
);
select ok(
  not has_function_privilege('authenticated', 'app.validate_sync_mapping(text,jsonb)', 'EXECUTE'),
  'authenticated 无 validate_sync_mapping 执行权（内部校验口）'
);
select ok(
  not has_function_privilege('anon', 'public.dry_run_sync_task(uuid,jsonb)', 'EXECUTE'),
  'anon 无 dry_run 执行权'
);
select ok(
  not has_function_privilege('service_role', 'public.upsert_sync_task(uuid,text,uuid,text,text,jsonb,text,text)', 'EXECUTE'),
  'service_role 无任务管理执行权（全局禁 service_role）'
);
select ok(
  has_table_privilege('authenticated', 'public.sync_tasks', 'SELECT')
    and not has_table_privilege('authenticated', 'public.sync_tasks', 'INSERT')
    and not has_table_privilege('authenticated', 'public.sync_tasks', 'UPDATE')
    and not has_table_privilege('authenticated', 'public.sync_tasks', 'DELETE'),
  'authenticated 对 sync_tasks 仅 SELECT（写仅经 RPC）'
);
select ok(
  has_table_privilege('authenticated', 'public.sync_task_versions', 'SELECT')
    and not has_table_privilege('authenticated', 'public.sync_task_versions', 'INSERT'),
  'authenticated 对 sync_task_versions 仅 SELECT'
);

-- ===========================================================================
-- 3. validate_sync_mapping 白名单（13，superuser 直调）
-- ===========================================================================
select lives_ok(
  $$ select app.validate_sync_mapping('departments',
       '[{"source_field":"dept_name","target_field":"name"},{"source_field":"order","target_field":"sort_order"}]'::jsonb) $$,
  'departments 合法映射通过'
);
select lives_ok(
  $$ select app.validate_sync_mapping('positions',
       '[{"source_field":"pos_code","target_field":"code"},{"source_field":"dept","target_field":"department_name"}]'::jsonb) $$,
  'positions 合法映射通过'
);
select lives_ok(
  $$ select app.validate_sync_mapping('profiles',
       '[{"source_field":"mail","target_field":"email"},{"source_field":"dept","target_field":"department_name"}]'::jsonb) $$,
  'profiles 合法映射通过（不含 role/status）'
);
select throws_ok(
  $$ select app.validate_sync_mapping('users', '[{"source_field":"x","target_field":"name"}]'::jsonb) $$,
  '22023', null, '目标表不在白名单被拒'
);
select throws_ok(
  $$ select app.validate_sync_mapping('departments', '{"source_field":"x"}'::jsonb) $$,
  '22023', null, '映射非数组被拒'
);
select throws_ok(
  $$ select app.validate_sync_mapping('departments', '[]'::jsonb) $$,
  '22023', null, '空映射被拒'
);
select throws_ok(
  $$ select app.validate_sync_mapping('departments', '["name"]'::jsonb) $$,
  '22023', null, '映射项非对象被拒'
);
select throws_ok(
  $$ select app.validate_sync_mapping('departments', '[{"target_field":"name"}]'::jsonb) $$,
  '22023', null, '缺 source_field 被拒'
);
select throws_ok(
  $$ select app.validate_sync_mapping('departments', '[{"source_field":"n"}]'::jsonb) $$,
  '22023', null, '缺 target_field 被拒'
);
select throws_ok(
  $$ select app.validate_sync_mapping('profiles', '[{"source_field":"r","target_field":"role"}]'::jsonb) $$,
  '22023', null, 'profiles 映射 role 被拒（INDEX 规则 7）'
);
select throws_ok(
  $$ select app.validate_sync_mapping('profiles', '[{"source_field":"s","target_field":"status"}]'::jsonb) $$,
  '22023', null, 'profiles 映射 status 被拒（INDEX 规则 7）'
);
select throws_ok(
  $$ select app.validate_sync_mapping('departments', '[{"source_field":"x","target_field":"leader_id"}]'::jsonb) $$,
  '22023', null, '目标字段不在白名单被拒（departments.leader_id）'
);
select throws_ok(
  $$ select app.validate_sync_mapping('positions', '[{"source_field":"x","target_field":"status"}]'::jsonb) $$,
  '22023', null, '目标字段不在白名单被拒（positions.status）'
);

-- ===========================================================================
-- 4. admin：数据源与任务夹具 + 版本快照 + 回滚（18）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.upsert_sync_source(
  null, 'CRM 接口', 'api', '{"base_url":"https://crm.example.com"}'::jsonb, 'tok-1234', null
) as s1 \gset
select public.test_sync_source((:'s1'::jsonb ->> 'id')::uuid) as s1v \gset

select public.upsert_sync_task(
  null,
  '组织同步',
  (:'s1'::jsonb ->> 'id')::uuid,
  'departments',
  'pull',
  '[{"source_field":"dept_name","target_field":"name"},{"source_field":"parent","target_field":"parent_name"}]'::jsonb,
  'skip',
  null
) as t1 \gset
reset role;

select is((:'s1v'::jsonb) ->> 'verify_status', 'verified', '夹具：数据源已验证');
select is((:'t1'::jsonb) ->> 'status', 'active', '新建任务默认 active');
select is((:'t1'::jsonb) ->> 'config_version', '1', '新建任务 config_version=1');
select is(
  (select count(*) from public.sync_task_versions where task_id = (:'t1'::jsonb ->> 'id')::uuid),
  1::bigint,
  '新建写入 1 条版本快照'
);
select is(
  (select config -> 'field_mapping' from public.sync_task_versions
    where task_id = (:'t1'::jsonb ->> 'id')::uuid and version = 1),
  '[{"source_field":"dept_name","target_field":"name"},{"source_field":"parent","target_field":"parent_name"}]'::jsonb,
  'v1 快照记录完整映射'
);
select is(
  (select config ->> 'conflict_policy' from public.sync_task_versions
    where task_id = (:'t1'::jsonb ->> 'id')::uuid and version = 1),
  'skip',
  'v1 快照记录冲突策略'
);

-- 版本 +1
set local role authenticated;
select public.upsert_sync_task(
  (:'t1'::jsonb ->> 'id')::uuid,
  '组织同步',
  (:'s1'::jsonb ->> 'id')::uuid,
  'departments',
  'pull',
  '[{"source_field":"dept_name","target_field":"name"}]'::jsonb,
  'overwrite',
  null
) as t1u \gset
reset role;
select is((:'t1u'::jsonb) ->> 'config_version', '2', '第二次 upsert config_version=2');
select is(
  (select count(*) from public.sync_task_versions where task_id = (:'t1'::jsonb ->> 'id')::uuid),
  2::bigint,
  '第二次 upsert 追加 1 条快照（共 2）'
);
select is(
  (select config ->> 'conflict_policy' from public.sync_task_versions
    where task_id = (:'t1'::jsonb ->> 'id')::uuid and version = 2),
  'overwrite',
  'v2 快照记录新冲突策略'
);

-- 回滚到上一版
set local role authenticated;
select public.rollback_sync_task((:'t1'::jsonb ->> 'id')::uuid) as t1r \gset
reset role;
select is((:'t1r'::jsonb) ->> 'config_version', '3', '回滚生成新版本 config_version=3');
select is((:'t1r'::jsonb) ->> 'conflict_policy', 'skip', '回滚后冲突策略回到上一版（skip）');
select is(
  (select config from public.sync_task_versions
    where task_id = (:'t1'::jsonb ->> 'id')::uuid
    order by version asc limit 1),
  (select config from public.sync_task_versions
    where task_id = (:'t1'::jsonb ->> 'id')::uuid and version = 3),
  'v3 快照内容与 v1 一致（回滚 = 重放上一版）'
);
select is(
  (select count(*) from public.sync_task_versions where task_id = (:'t1'::jsonb ->> 'id')::uuid),
  3::bigint,
  '历史行 append-only（回滚后共 3 条）'
);

-- v1 任务不可回滚
set local role authenticated;
select public.upsert_sync_task(
  null, '无历史任务', (:'s1'::jsonb ->> 'id')::uuid, 'positions', 'pull',
  '[{"source_field":"code","target_field":"code"}]'::jsonb, 'skip', 'disabled'
) as t2 \gset
select throws_ok(
  format($$ select public.rollback_sync_task(%L::uuid) $$, (:'t2'::jsonb ->> 'id')),
  '22023', null, '仅 v1 的任务回滚被拒（没有历史版本）'
);
reset role;

-- 读取口
set local role authenticated;
select is(
  (select source_name from public.get_sync_tasks() where id = (:'t1'::jsonb ->> 'id')::uuid),
  'CRM 接口',
  'get_sync_tasks 联表返回数据源名称'
);
select is(
  (select count(*) from public.get_sync_task_versions((:'t1'::jsonb ->> 'id')::uuid)),
  3::bigint,
  'get_sync_task_versions 返回 3 个版本'
);
reset role;

-- 审计摘要
select ok(
  (select count(*) >= 3 from public.audit_operations
    where module = 'sync' and object_type = 'sync_task' and action = 'upsert'),
  '任务 upsert 写入审计摘要'
);
select ok(
  not exists (
    select 1 from public.audit_operations
     where module = 'sync' and object_type = 'sync_task'
       and diff::text like '%sync-secret%'
  ),
  '任务审计不含凭据类明文'
);

-- ===========================================================================
-- 5. 启用守卫：任务启停与数据源验证状态（8）
-- ===========================================================================
set local role authenticated;
select public.upsert_sync_source(
  null, '草稿源', 'api', '{}'::jsonb, null, null
) as sd \gset
select throws_ok(
  format(
    $$ select public.upsert_sync_task(null, '草稿源任务', %L::uuid, 'positions', 'pull',
         '[{"source_field":"code","target_field":"code"}]'::jsonb, 'skip', null) $$,
    (:'sd'::jsonb ->> 'id')
  ),
  '22023', null, '未验证数据源不能创建 active 任务'
);
select public.upsert_sync_task(
  null, '草稿源任务', (:'sd'::jsonb ->> 'id')::uuid, 'positions', 'pull',
  '[{"source_field":"code","target_field":"code"}]'::jsonb, 'skip', 'disabled'
) as td \gset
reset role;
select is((:'td'::jsonb) ->> 'status', 'disabled', '未验证数据源可保存 disabled 草稿任务');

set local role authenticated;
select throws_ok(
  format(
    $$ select public.upsert_sync_task(%L::uuid, '草稿源任务', %L::uuid, 'positions', 'pull',
         '[{"source_field":"code","target_field":"code"}]'::jsonb, 'skip', 'active') $$,
    (:'td'::jsonb ->> 'id'), (:'sd'::jsonb ->> 'id')
  ),
  '22023', null, 'disabled→active 时数据源未验证被拒'
);

-- 验证草稿源后启用成功
select public.upsert_sync_source(
  (:'sd'::jsonb ->> 'id')::uuid, '草稿源', 'api',
  '{"base_url":"https://draft.example.com"}'::jsonb, null, null
) as sdu \gset
select public.test_sync_source((:'sd'::jsonb ->> 'id')::uuid) as sdv \gset
select public.upsert_sync_task(
  (:'td'::jsonb ->> 'id')::uuid, '草稿源任务', (:'sd'::jsonb ->> 'id')::uuid, 'positions', 'pull',
  '[{"source_field":"code","target_field":"code"}]'::jsonb, 'skip', 'active'
) as tda \gset
reset role;
select is((:'sdv'::jsonb) ->> 'verify_status', 'verified', '草稿源补全并测试后 verified');
select is((:'tda'::jsonb) ->> 'status', 'active', 'disabled→active 成功');
select is((:'tda'::jsonb) ->> 'config_version', '2', '启停操作同样生成版本（+1）');

-- 已停用数据源不能启用任务
set local role authenticated;
select public.upsert_sync_source(
  null, '待停用源', 'api', '{"base_url":"https://x.example.com"}'::jsonb, null, null
) as s3 \gset
select public.test_sync_source((:'s3'::jsonb ->> 'id')::uuid) as s3v \gset
select public.disable_sync_source((:'s3'::jsonb ->> 'id')::uuid) as s3d \gset
select throws_ok(
  format(
    $$ select public.upsert_sync_task(null, '停用源任务', %L::uuid, 'positions', 'pull',
         '[{"source_field":"code","target_field":"code"}]'::jsonb, 'skip', 'active') $$,
    (:'s3'::jsonb ->> 'id')
  ),
  '22023', null, '已停用数据源不能创建 active 任务'
);
reset role;
select is((:'s3d'::jsonb) ->> 'status', 'disabled', '数据源无任务引用时停用成功');

-- ===========================================================================
-- 6. dry_run：三类目标 + 冲突策略 + 备注（24）
-- ===========================================================================
-- 夹具：positions 目标行（由 superuser 写入，本事务 rollback）
insert into public.positions (name, code, headcount)
values ('同步测试岗', 'SYNC-TEST-1', 1);

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

-- departments（t1 当前 policy=skip，映射 name/parent_name）
select public.dry_run_sync_task(
  (:'t1'::jsonb ->> 'id')::uuid,
  '[{"dept_name":"研发中心"},{"dept_name":"新部门X"}]'::jsonb
) as dr1 \gset
select is((:'dr1'::jsonb) ->> 'insert', '1', 'departments skip 策略：未匹配行 insert=1');
select is((:'dr1'::jsonb) ->> 'skip', '1', 'departments skip 策略：已存在行 skip=1');
select is((:'dr1'::jsonb) ->> 'match_field', 'name', 'departments 匹配键为 name');

-- 覆盖策略：先 upsert 改策略，再 dry-run
select public.upsert_sync_task(
  (:'t1'::jsonb ->> 'id')::uuid, '组织同步', (:'s1'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"dept_name","target_field":"name"}]'::jsonb, 'overwrite', null
) as t1o \gset
select public.dry_run_sync_task(
  (:'t1'::jsonb ->> 'id')::uuid,
  '[{"dept_name":"研发中心"},{"dept_name":"新部门X"}]'::jsonb
) as dr2 \gset
select is((:'dr2'::jsonb) ->> 'update', '1', 'departments overwrite 策略：已存在行 update=1');
select is((:'dr2'::jsonb) ->> 'insert', '1', 'departments overwrite 策略：未匹配行 insert=1');

-- positions（overwrite）
select public.upsert_sync_task(
  null, '岗位同步', (:'s1'::jsonb ->> 'id')::uuid, 'positions', 'pull',
  '[{"source_field":"pos_code","target_field":"code"},{"source_field":"pos_name","target_field":"name"}]'::jsonb,
  'overwrite', null
) as tp \gset
select public.dry_run_sync_task(
  (:'tp'::jsonb ->> 'id')::uuid,
  '[{"pos_code":"SYNC-TEST-1"},{"pos_code":"SYNC-NEW-1"}]'::jsonb
) as pr1 \gset
select is((:'pr1'::jsonb) ->> 'update', '1', 'positions overwrite：code 已存在 update=1');
select is((:'pr1'::jsonb) ->> 'insert', '1', 'positions overwrite：code 未匹配 insert=1');
select is((:'pr1'::jsonb) ->> 'match_field', 'code', 'positions 匹配键为 code');

-- profiles（overwrite → 已存在 update；未匹配 skip + 不新建备注）
select public.upsert_sync_task(
  null, '档案同步', (:'s1'::jsonb ->> 'id')::uuid, 'profiles', 'pull',
  '[{"source_field":"mail","target_field":"email"},{"source_field":"nm","target_field":"full_name"}]'::jsonb,
  'overwrite', null
) as tf \gset
select public.dry_run_sync_task(
  (:'tf'::jsonb ->> 'id')::uuid,
  '[{"mail":"engineer@example.com"},{"mail":"nobody@example.com"}]'::jsonb
) as fr1 \gset
select is((:'fr1'::jsonb) ->> 'update', '1', 'profiles overwrite：email 已存在 update=1（仅更新不新建）');
select is((:'fr1'::jsonb) ->> 'insert', '0', 'profiles 未匹配行不产生 insert');
select is((:'fr1'::jsonb) ->> 'skip', '1', 'profiles 未匹配行计入 skip');
select is((:'fr1'::jsonb) ->> 'match_field', 'email', 'profiles 匹配键为 email');
select is(
  (:'fr1'::jsonb) -> 'notes' -> 0 ->> 'code',
  'profiles_no_insert',
  'profiles 未匹配备注 code=profiles_no_insert（不新建用户）'
);
select ok(
  (:'fr1'::jsonb) -> 'notes' -> 0 ->> 'message' like '%不新建%',
  'profiles 备注文案含「不新建用户」'
);

-- profiles（manual → conflict）
select public.upsert_sync_task(
  (:'tf'::jsonb ->> 'id')::uuid, '档案同步', (:'s1'::jsonb ->> 'id')::uuid, 'profiles', 'pull',
  '[{"source_field":"mail","target_field":"email"}]'::jsonb, 'manual', null
) as tfm \gset
select public.dry_run_sync_task(
  (:'tf'::jsonb ->> 'id')::uuid,
  '[{"mail":"engineer@example.com"},{"mail":"nobody@example.com"}]'::jsonb
) as fr2 \gset
select is((:'fr2'::jsonb) ->> 'conflict', '1', 'profiles manual 策略：已存在行 conflict=1');
select is((:'fr2'::jsonb) ->> 'skip', '1', 'profiles manual 策略：未匹配行仍 skip=1（不新建）');

-- 缺匹配键 / 非数组样本 / NULL 样本 / 不存在任务
select public.dry_run_sync_task(
  (:'tp'::jsonb ->> 'id')::uuid,
  '[{"other":"x"},{"pos_code":"SYNC-NEW-2"}]'::jsonb
) as pr2 \gset
select is((:'pr2'::jsonb) ->> 'skip', '1', '缺匹配键行计入 skip');
select is(
  (:'pr2'::jsonb) -> 'notes' -> 0 ->> 'code',
  'missing_match_key',
  '缺匹配键备注 code=missing_match_key'
);
select is(
  (select (public.dry_run_sync_task((:'tp'::jsonb ->> 'id')::uuid, null)) ->> 'sample_rows'),
  '0',
  '样本 NULL 视为空数组（sample_rows=0）'
);
select throws_ok(
  format($$ select public.dry_run_sync_task(%L::uuid, '{"a":1}'::jsonb) $$, (:'tp'::jsonb ->> 'id')),
  '22023', null, '样本非数组被拒'
);
select throws_ok(
  $$ select public.dry_run_sync_task('00000000-0000-0000-0000-000000000000'::uuid, '[]'::jsonb) $$,
  'P0002', null, '任务不存在报 P0002'
);
reset role;

-- dry-run 只读：不改版本、不写目标表
select is(
  (select config_version from public.sync_tasks where id = (:'t1'::jsonb ->> 'id')::uuid),
  (:'t1o'::jsonb ->> 'config_version')::int,
  'dry-run 不改变任务版本'
);
select is(
  (select count(*) from public.departments where name = '新部门X'),
  0::bigint,
  'dry-run 不写目标表（未匹配部门未落库）'
);
select is(
  (select count(*) from public.profiles where email = 'nobody@example.com'),
  0::bigint,
  'dry-run 不新建用户档案'
);

-- ===========================================================================
-- 7. 越权：engineer 读 0 行 / RPC 被拒；anon 无路径（10）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;

select is(
  (select count(*) from public.sync_tasks),
  0::bigint,
  'engineer 直查 sync_tasks：RLS 过滤后 0 行'
);
select is(
  (select count(*) from public.sync_task_versions),
  0::bigint,
  'engineer 直查 sync_task_versions：RLS 过滤后 0 行'
);
select throws_ok(
  $$ select public.upsert_sync_task(null, 'x', '00000000-0000-0000-0000-000000000000'::uuid,
       'departments', 'pull', '[{"source_field":"a","target_field":"name"}]'::jsonb, 'skip', null) $$,
  '42501', null, 'engineer 调 upsert 被 admin 校验拒绝'
);
select throws_ok(
  $$ select public.dry_run_sync_task('00000000-0000-0000-0000-000000000000'::uuid, '[]'::jsonb) $$,
  '42501', null, 'engineer 调 dry-run 被 admin 校验拒绝'
);
select throws_ok(
  $$ select public.rollback_sync_task('00000000-0000-0000-0000-000000000000'::uuid) $$,
  '42501', null, 'engineer 调回滚被 admin 校验拒绝'
);
select throws_ok(
  $$ select public.get_sync_tasks() $$,
  '42501', null, 'engineer 调任务列表被 admin 校验拒绝'
);
select throws_ok(
  $$ select app.validate_sync_mapping('departments', '[{"source_field":"a","target_field":"name"}]'::jsonb) $$,
  '42501', null, 'engineer 无 validate_sync_mapping 执行权'
);
select throws_ok(
  $$ insert into public.sync_tasks (name, source_id, target_table, field_mapping)
     values ('x', '00000000-0000-0000-0000-000000000000'::uuid, 'departments', '[]'::jsonb) $$,
  '42501', null, 'engineer 直写任务表被拒'
);

reset role;
set local role anon;

select throws_ok(
  $$ select public.get_sync_tasks() $$,
  '42501', null, 'anon 调任务列表被拒（无 GRANT）'
);
select throws_ok(
  $$ select public.dry_run_sync_task('00000000-0000-0000-0000-000000000000'::uuid, '[]'::jsonb) $$,
  '42501', null, 'anon 调 dry-run 被拒（无 GRANT）'
);

reset role;

select * from finish();
rollback;
