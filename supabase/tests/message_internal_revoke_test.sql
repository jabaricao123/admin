-- pgTAP：message 批次 4 并入项 3 — app 内部函数 EXECUTE 收口
-- 运行：supabase db reset && supabase test db
-- 覆盖：app.submit_instance / act_task / urge_instance / publish_announcement 对
--       public/anon/authenticated/service_role 零执行权；对应 public 薄包装保持
--       authenticated 可达（调用面不缩水）。
-- 说明：无夹具，纯权限面断言；finish 后 rollback。

begin;

select plan(12);

-- ---------------------------------------------------------------------------
-- A. app 实现层：authenticated 零执行权（4）
-- ---------------------------------------------------------------------------
select ok(
  not has_function_privilege(
    'authenticated', 'app.submit_instance(text,text,text,text,jsonb,uuid[])', 'EXECUTE'
  ),
  'authenticated 无 app.submit_instance 执行权'
);
select ok(
  not has_function_privilege('authenticated', 'app.act_task(uuid,text,text)', 'EXECUTE'),
  'authenticated 无 app.act_task 执行权'
);
select ok(
  not has_function_privilege('authenticated', 'app.urge_instance(uuid)', 'EXECUTE'),
  'authenticated 无 app.urge_instance 执行权'
);
select ok(
  not has_function_privilege('authenticated', 'app.publish_announcement(uuid,boolean)', 'EXECUTE'),
  'authenticated 无 app.publish_announcement 执行权'
);

-- ---------------------------------------------------------------------------
-- B. app 实现层：service_role / anon 零执行权（2）
-- ---------------------------------------------------------------------------
select ok(
  not has_function_privilege('service_role', 'app.submit_instance(text,text,text,text,jsonb,uuid[])', 'EXECUTE')
  and not has_function_privilege('service_role', 'app.act_task(uuid,text,text)', 'EXECUTE')
  and not has_function_privilege('service_role', 'app.urge_instance(uuid)', 'EXECUTE')
  and not has_function_privilege('service_role', 'app.publish_announcement(uuid,boolean)', 'EXECUTE'),
  'service_role 无四个 app 实现执行权'
);
select ok(
  not has_function_privilege('anon', 'app.submit_instance(text,text,text,text,jsonb,uuid[])', 'EXECUTE')
  and not has_function_privilege('anon', 'app.act_task(uuid,text,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'app.urge_instance(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'app.publish_announcement(uuid,boolean)', 'EXECUTE'),
  'anon 无四个 app 实现执行权'
);

-- ---------------------------------------------------------------------------
-- C. public 薄包装：authenticated 保持可达（4）
-- ---------------------------------------------------------------------------
select ok(
  has_function_privilege(
    'authenticated', 'public.submit_instance(text,text,text,text,jsonb,uuid[])', 'EXECUTE'
  ),
  'authenticated 仍可经 public.submit_instance 提交（包装面不受收口影响）'
);
select ok(
  has_function_privilege('authenticated', 'public.act_task(uuid,text,text)', 'EXECUTE'),
  'authenticated 仍可经 public.act_task 审批'
);
select ok(
  has_function_privilege('authenticated', 'public.urge_instance(uuid)', 'EXECUTE'),
  'authenticated 仍可经 public.urge_instance 催办'
);
select ok(
  has_function_privilege('authenticated', 'public.publish_announcement(uuid,boolean)', 'EXECUTE'),
  'authenticated 仍可经 public.publish_announcement 发布公告（admin 校验在实现内）'
);

-- ---------------------------------------------------------------------------
-- D. public 包装：anon 无执行权（2）
-- ---------------------------------------------------------------------------
select ok(
  not has_function_privilege('anon', 'public.submit_instance(text,text,text,text,jsonb,uuid[])', 'EXECUTE')
  and not has_function_privilege('anon', 'public.act_task(uuid,text,text)', 'EXECUTE'),
  'anon 无审批提交 / 审批执行权'
);
select ok(
  not has_function_privilege('anon', 'public.urge_instance(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.publish_announcement(uuid,boolean)', 'EXECUTE'),
  'anon 无催办 / 公告发布执行权'
);

select * from finish();
rollback;
