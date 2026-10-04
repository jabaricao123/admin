-- pgTAP：system/005 —— system_sms_templates 登记表 + CRUD RPC + RLS 越权
-- 运行：supabase db reset && supabase test db
-- 覆盖：结构（表/列/主键/约束/默认值/RLS/触发器）；函数存在性 + SECURITY DEFINER +
--       search_path=''；GRANT 面（authenticated 可执行、anon 无、表仅登录可读）；
--       RLS：engineer 读 0 行、anon 无表级 SELECT；非 admin RPC 越权 42501；
--       admin 新建/更新/停用/重新启用；字段校验（name/scene/provider_code/status）；
--       不存在 id 报 P0002；id 建后不可改（更新不提供 id 改写）；审计摘要已写。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(47);

-- ===========================================================================
-- 1. 结构：表 / 列 / 主键 / 约束 / 默认值 / RLS / 触发器（13）
-- ===========================================================================
select has_table('public', 'system_sms_templates', 'system_sms_templates 表存在');
select col_is_pk('public', 'system_sms_templates', 'id', 'id 为主键');
select col_type_is('public', 'system_sms_templates', 'name', 'text', 'name 为 text');
select col_type_is('public', 'system_sms_templates', 'scene', 'text', 'scene 为 text');
select col_type_is('public', 'system_sms_templates', 'provider_code', 'text', 'provider_code 为 text');
select col_not_null('public', 'system_sms_templates', 'name', 'name 非空');
select col_not_null('public', 'system_sms_templates', 'scene', 'scene 非空');
select col_not_null('public', 'system_sms_templates', 'provider_code', 'provider_code 非空');
select col_has_default('public', 'system_sms_templates', 'id', 'id 有默认值（gen_random_uuid）');
select col_has_default('public', 'system_sms_templates', 'status', 'status 有默认值');
select col_has_check('public', 'system_sms_templates', 'status', 'status 有取值 check 约束');
select is(
  (select relrowsecurity from pg_class where oid = 'public.system_sms_templates'::regclass),
  true,
  'system_sms_templates 已启用 RLS'
);
select has_trigger(
  'public', 'system_sms_templates', 'system_sms_templates_set_updated_at',
  'updated_at 触发器存在'
);

-- ===========================================================================
-- 2. 函数存在性 + SECURITY DEFINER + search_path=''（5）
-- ===========================================================================
select has_function('app', 'upsert_sms_template', array['uuid', 'text', 'text', 'text', 'text'], 'app.upsert_sms_template 存在');
select has_function('public', 'upsert_sms_template', array['uuid', 'text', 'text', 'text', 'text'], 'public.upsert_sms_template 薄包装存在');
select has_function('app', 'disable_sms_template', array['uuid'], 'app.disable_sms_template 存在');
select has_function('public', 'disable_sms_template', array['uuid'], 'public.disable_sms_template 薄包装存在');
select ok(
  (select count(*) = 4
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (
            ('app', 'upsert_sms_template'), ('public', 'upsert_sms_template'),
            ('app', 'disable_sms_template'), ('public', 'disable_sms_template')
          )
      and p.prosecdef
      and p.proconfig @> array['search_path=""']),
  '4 个函数均 security definer + search_path 固定为空'
);

-- ===========================================================================
-- 3. GRANT 面（7）
-- ===========================================================================
select ok(has_function_privilege('authenticated', 'public.upsert_sms_template(uuid,text,text,text,text)', 'EXECUTE'), 'authenticated 可执行 public.upsert_sms_template');
select ok(has_function_privilege('authenticated', 'public.disable_sms_template(uuid)', 'EXECUTE'), 'authenticated 可执行 public.disable_sms_template');
select ok(has_function_privilege('authenticated', 'app.upsert_sms_template(uuid,text,text,text,text)', 'EXECUTE'), 'authenticated 可执行 app.upsert_sms_template');
select ok(has_function_privilege('authenticated', 'app.disable_sms_template(uuid)', 'EXECUTE'), 'authenticated 可执行 app.disable_sms_template');
select ok(
  not exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('app', 'public')
       and p.proname in ('upsert_sms_template', 'disable_sms_template')
       and has_function_privilege('anon', p.oid, 'EXECUTE')
  ),
  'anon 无管理 RPC 执行权'
);
select ok(has_table_privilege('authenticated', 'public.system_sms_templates', 'SELECT'), 'authenticated 有表级 SELECT 权');
select ok(not has_table_privilege('anon', 'public.system_sms_templates', 'SELECT'), 'anon 无表级 SELECT 权');

-- ===========================================================================
-- 4. 越权拒绝（5）
-- ===========================================================================
-- 先由 admin 建一行，供 RLS 读测试
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select lives_ok(
  $$ select public.upsert_sms_template(
       null, '验证码通知', 'login_code', 'SMS_100001', 'active'
     ) $$,
  'admin 创建短信模板'
);
reset role;

-- engineer：RLS 下读 0 行；管理 RPC 被拒
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select is(
  (select count(*) from public.system_sms_templates),
  0::bigint,
  'engineer 受 RLS 限制读不到模板行'
);
select throws_ok(
  $$ select public.upsert_sms_template(
       null, '越权模板', 'login_code', 'SMS_999999', 'active'
     ) $$,
  '42501', null, 'engineer 调 upsert_sms_template 被 admin 校验拒绝'
);
select throws_ok(
  $$ select public.disable_sms_template('00000000-0000-0000-0000-000000000000'::uuid) $$,
  '42501', null, 'engineer 调 disable_sms_template 被 admin 校验拒绝'
);
reset role;

set local role anon;
select throws_ok(
  $$ select count(*) from public.system_sms_templates $$,
  '42501', null, 'anon 直查表被拒（无表级 SELECT）'
);
reset role;

-- ===========================================================================
-- 5. admin CRUD 与校验（16）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);

-- 字段校验（先于写库）
set local role authenticated;
select throws_ok(
  $$ select public.upsert_sms_template(null, '', 'login_code', 'SMS_1', 'active') $$,
  '22023', null, '模板名称为空报 22023'
);
select throws_ok(
  $$ select public.upsert_sms_template(null, '通知', '', 'SMS_1', 'active') $$,
  '22023', null, '模板场景为空报 22023'
);
select throws_ok(
  $$ select public.upsert_sms_template(null, '通知', 'login_code', '', 'active') $$,
  '22023', null, '模板 code 为空报 22023'
);
select throws_ok(
  $$ select public.upsert_sms_template(null, '通知', 'login_code', 'SMS_1', 'archived') $$,
  '22023', null, '非法模板状态报 22023'
);
reset role;

-- 已建行内容核对（admin 直查；id 由 test 事务内唯一行获取）
select is(
  (select name from public.system_sms_templates limit 1),
  '验证码通知',
  '模板名称正确落库'
);
select is(
  (select scene from public.system_sms_templates limit 1),
  'login_code',
  '模板场景正确落库'
);
select is(
  (select provider_code from public.system_sms_templates limit 1),
  'SMS_100001',
  '模板 code 正确落库'
);
select is(
  (select status from public.system_sms_templates limit 1),
  'active',
  '新建模板默认 active'
);
select ok(
  (select created_by = '11111111-1111-1111-1111-111111111111'::uuid
     from public.system_sms_templates limit 1),
  'created_by 记录创建人'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'upsert'
      and object_type = 'sms_template' and diff ->> 'created' = 'true'
  ),
  '新建写审计摘要（created=true）'
);

-- 更新：id 为定位键，仅更新字段
set local role authenticated;
select is(
  (select (public.upsert_sms_template(
     (select id from public.system_sms_templates limit 1),
     '登录验证码', 'login_code_v2', 'SMS_100002', 'disabled'
   )) ->> 'name'),
  '登录验证码',
  'admin 按 id 更新模板（返回新名称）'
);
select throws_ok(
  $$ select public.upsert_sms_template(
       '00000000-0000-0000-0000-000000000000'::uuid,
       '不存在', 'scene', 'SMS_X', 'active'
     ) $$,
  'P0002', null, '更新不存在的模板报 P0002'
);

-- 重新启用
select is(
  (select (public.upsert_sms_template(
     (select id from public.system_sms_templates limit 1),
     '登录验证码', 'login_code_v2', 'SMS_100002', 'active'
   )) ->> 'status'),
  'active',
  'upsert 可重新启用模板'
);

-- 停用 RPC
select is(
  (select (public.disable_sms_template(
     (select id from public.system_sms_templates limit 1)
   )) ->> 'status'),
  'disabled',
  'disable_sms_template 返回 disabled'
);
select throws_ok(
  $$ select public.disable_sms_template('00000000-0000-0000-0000-000000000000'::uuid) $$,
  'P0002', null, '停用不存在的模板报 P0002'
);
reset role;

select is(
  (select status from public.system_sms_templates limit 1),
  'disabled',
  '停用状态落库'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'system' and action = 'disable'
      and object_type = 'sms_template'
  ),
  '停用写审计摘要'
);

select * from finish();
rollback;
