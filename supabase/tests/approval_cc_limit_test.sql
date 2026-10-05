-- pgTAP：message 批次 2 修复项 2 — approval cc 上限（submit_instance p_cc_user_ids ≤ 20）
-- 运行：supabase db reset && supabase test db
-- 覆盖：21 人被拒（22023）且不产生实例；20 人边界成功；NULL cc 成功；
--       签名保持 6 参；收口后 authenticated 仅经 public 包装可达。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(8);

-- ---------------------------------------------------------------------------
-- 夹具：u1 工程师（发起人）/ u2 管理员（审批人）；单节点流程
-- ---------------------------------------------------------------------------
\set u1 'ffffffff-ffff-4fff-8fff-ffffffff0001'
\set u2 'ffffffff-ffff-4fff-8fff-ffffffff0002'
\set tpl 'ffffffff-ffff-4fff-8fff-ffffffffff01'
\set flow 'ffffffff-ffff-4fff-8fff-ffffffffff02'

insert into auth.users (id, email, raw_app_meta_data, raw_user_meta_data) values
  (:'u1', 'cc-limit-eng@example.com',
   '{"provider":"email","providers":["email"],"role":"engineer"}', '{"full_name":"上限发起人"}'),
  (:'u2', 'cc-limit-admin@example.com',
   '{"provider":"email","providers":["email"],"role":"admin"}', '{"full_name":"上限管理员"}');

update public.profiles
   set created_at = '2026-02-01T00:00:00Z'
 where id in (:'u1', :'u2');

insert into public.approval_form_templates (id, name, code, module, version, schema, status) values
  (:'tpl', 'cc 上限测试', 'cc.limit', 'demo', 1,
   '{"fields":[{"key":"title","label":"标题","type":"text","required":true}]}'::jsonb, 'published');

insert into public.approval_flows (id, name, template_id, version, nodes, status) values
  (:'flow', 'cc 上限流程', :'tpl', 1,
   jsonb_build_array(
     jsonb_build_object('seq', 1,
       'approver_rule', jsonb_build_object('type', 'user', 'value', :'u2'))
   ), 'published');

-- ---------------------------------------------------------------------------
-- A. 结构 / 授权（3）
-- ---------------------------------------------------------------------------
select has_function(
  'app', 'submit_instance', array['text', 'text', 'text', 'text', 'jsonb', 'uuid[]'],
  'app.submit_instance 6 参签名保持（新增校验不改签名）'
);
select ok(
  not has_function_privilege(
    'authenticated', 'app.submit_instance(text,text,text,text,jsonb,uuid[])', 'EXECUTE'
  ),
  'authenticated 不可直调 app.submit_instance（批次 4 收口）'
);
select ok(
  has_function_privilege(
    'authenticated', 'public.submit_instance(text,text,text,text,jsonb,uuid[])', 'EXECUTE'
  ),
  'public.submit_instance 包装保持 authenticated 可达'
);

-- ---------------------------------------------------------------------------
-- B. 上限行为（5）
-- ---------------------------------------------------------------------------
select set_config(
  'request.jwt.claims',
  '{"sub":"ffffffff-ffff-4fff-8fff-ffffffff0001","role":"authenticated"}',
  true
);
set local role authenticated;

select throws_ok(
  format(
    $$ select public.submit_instance(
         'demo', 'cc-limit', 'ref-21', 'cc.limit', '{"title":"超限"}'::jsonb,
         array(select ('f0000000-0000-4000-a000-' || lpad(i::text, 12, '0'))::uuid
                 from generate_series(1, 21) i)
       ) $$
  ),
  '22023', '抄送人不能超过 20 人（当前：21）',
  'cc 21 人被拒（22023）'
);

reset role;

select is(
  (select count(*) from public.approval_instances
    where module = 'demo' and ref_type = 'cc-limit' and ref_id = 'ref-21'),
  0::bigint,
  '21 人被拒时不产生审批实例（校验先于落库）'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"ffffffff-ffff-4fff-8fff-ffffffff0001","role":"authenticated"}',
  true
);
set local role authenticated;

select lives_ok(
  format(
    $$ select public.submit_instance(
         'demo', 'cc-limit', 'ref-20', 'cc.limit', '{"title":"边界20"}'::jsonb,
         array(select ('f0000000-0000-4000-a000-' || lpad(i::text, 12, '0'))::uuid
                 from generate_series(1, 20) i)
       ) $$
  ),
  'cc 20 人边界允许提交'
);
select lives_ok(
  $$ select public.submit_instance(
       'demo', 'cc-limit', 'ref-null', 'cc.limit', '{"title":"无cc"}'::jsonb) $$,
  'p_cc_user_ids 省略 / NULL 允许提交（旧 5 参兼容）'
);

reset role;

select is(
  (select count(*) from public.approval_instances
    where module = 'demo' and ref_type = 'cc-limit'
      and ref_id in ('ref-20', 'ref-null')
      and status = 'running'),
  2::bigint,
  '20 人与 NULL cc 的实例均已落库为 running'
);

select * from finish();
rollback;
