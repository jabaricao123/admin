-- pgTAP：sync/005 —— 执行函数语义（三类目标实写 / 冲突三策略 / 人工裁决 / 并发 / 幂等 / 失败通知）
-- 运行：supabase db reset && supabase test db
-- 覆盖：departments/positions INSERT + 引用解析；profiles 仅 UPDATE 不 INSERT 且 role/status 不可写；
--       rerun 幂等（同样本第二次 insert=0，无重复写入）；skip/overwrite/manual 三策略；
--       冲突裁决 adopted=更新目标行 / ignored=仅标记、重复裁决拒绝、裁决后 run partial→success；
--       单任务并发 1（advisory lock 拒绝 + running 记录拒绝）；状态机 failed/partial/success；
--       手动触发 wrapper（admin 成功、非 admin 42501、停用任务/推送方向拒绝）；终态失败通知属主；
--       audit 摘要落 audit_operations。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(76);

-- ===========================================================================
-- 0. 夹具：源 + 任务（departments/positions/profiles/manual/empty/push/disabled）
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.upsert_sync_source(
  null, '执行语义测试源', 'api', '{"base_url":"https://exec.example.com"}'::jsonb, 'tok-exec', null
) as es \gset
select public.test_sync_source((:'es'::jsonb ->> 'id')::uuid) as esv \gset

select public.upsert_sync_task(
  null, '部门执行任务', (:'es'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"dept","target_field":"name"},{"source_field":"parent","target_field":"parent_name"},{"source_field":"sort","target_field":"sort_order"},{"source_field":"leader","target_field":"leader_email"}]'::jsonb,
  'skip', null
) as td \gset
select public.upsert_sync_task(
  null, '岗位执行任务', (:'es'::jsonb ->> 'id')::uuid, 'positions', 'pull',
  '[{"source_field":"pos_name","target_field":"name"},{"source_field":"pos_code","target_field":"code"},{"source_field":"dept","target_field":"department_name"},{"source_field":"hc","target_field":"headcount"}]'::jsonb,
  'skip', null
) as tp \gset
select public.upsert_sync_task(
  null, '档案执行任务', (:'es'::jsonb ->> 'id')::uuid, 'profiles', 'pull',
  '[{"source_field":"mail","target_field":"email"},{"source_field":"name","target_field":"full_name"},{"source_field":"dept","target_field":"department_name"},{"source_field":"pos","target_field":"position_code"}]'::jsonb,
  'overwrite', null
) as tf \gset
select public.upsert_sync_task(
  null, '人工冲突任务', (:'es'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"dept","target_field":"name"},{"source_field":"sort","target_field":"sort_order"}]'::jsonb,
  'manual', null
) as tm \gset
select public.upsert_sync_task(
  null, '空样本任务', (:'es'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"dept","target_field":"name"}]'::jsonb,
  'skip', null
) as te \gset
select public.upsert_sync_task(
  null, '锁测试任务', (:'es'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"dept","target_field":"name"}]'::jsonb,
  'skip', null
) as tl \gset
select public.upsert_sync_task(
  null, '运行中拒测任务', (:'es'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"dept","target_field":"name"}]'::jsonb,
  'skip', null
) as tr \gset

-- 推送方向任务（执行应拒绝）
select public.upsert_sync_task(
  null, '推送方向任务', (:'es'::jsonb ->> 'id')::uuid, 'departments', 'push',
  '[{"source_field":"dept","target_field":"name"}]'::jsonb,
  'skip', null
) as tpush \gset

-- 停用任务（执行应拒绝）
select public.upsert_sync_task(
  null, '停用任务', (:'es'::jsonb ->> 'id')::uuid, 'departments', 'pull',
  '[{"source_field":"dept","target_field":"name"}]'::jsonb,
  'skip', 'disabled'
) as tdis \gset

reset role;

select is((:'esv'::jsonb) ->> 'verify_status', 'verified', '夹具：数据源已验证');

-- ===========================================================================
-- 1. departments：INSERT + 引用解析 + stats/status/executed_by/audit
-- ===========================================================================
select app.execute_sync_task(
  (:'td'::jsonb ->> 'id')::uuid, 'manual',
  '[{"dept":"同步测试部门甲","parent":"总部","sort":"5","leader":"engineer@example.com"}]'::jsonb
) as run_d1 \gset

select is(
  (select name from public.departments where name = '同步测试部门甲'),
  '同步测试部门甲',
  'departments 样本实写 INSERT 成功'
);
select is(
  (select parent_id from public.departments where name = '同步测试部门甲'),
  (select id from public.departments where name = '总部'),
  'parent_name 解析为 departments.id'
);
select is(
  (select leader_id from public.departments where name = '同步测试部门甲'),
  (select id from public.profiles where email = 'engineer@example.com'),
  'leader_email 解析为 profiles.id'
);
select is(
  (select sort_order from public.departments where name = '同步测试部门甲'),
  5,
  'sort_order 文本转整数写入'
);
select is(
  (select (stats ->> 'insert')::int from public.sync_runs where id = :'run_d1'),
  1,
  'departments 执行 stats.insert=1'
);
select is(
  (select status from public.sync_runs where id = :'run_d1'),
  'success',
  'departments 执行 status=success'
);
select is(
  (select executed_by from public.sync_runs where id = :'run_d1'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  '手动执行 executed_by=触发人'
);
select is(
  (select trigger_type from public.sync_runs where id = :'run_d1'),
  'manual',
  '手动执行 trigger_type=manual'
);
select ok(
  (select finished_at is not null and finished_at >= started_at
     from public.sync_runs where id = :'run_d1'),
  '执行完成写入 finished_at'
);
select ok(
  exists (
    select 1 from public.audit_operations
    where module = 'sync' and action = 'execute'
      and object_type = 'sync_run' and object_id = :'run_d1'
  ),
  '执行摘要写入 audit_operations（INDEX 规则 2）'
);

-- ===========================================================================
-- 2. positions：INSERT + 部门引用解析
-- ===========================================================================
select app.execute_sync_task(
  (:'tp'::jsonb ->> 'id')::uuid, 'manual',
  '[{"pos_name":"同步测试岗位","pos_code":"SYN-P1","dept":"前端组","hc":"3"}]'::jsonb
) as run_p1 \gset

select is(
  (select count(*) from public.positions where code = 'SYN-P1'),
  1::bigint,
  'positions 样本实写 INSERT 成功'
);
select is(
  (select department_id from public.positions where code = 'SYN-P1'),
  (select id from public.departments where name = '前端组'),
  'positions.department_name 解析为 departments.id'
);
select is(
  (select headcount from public.positions where code = 'SYN-P1'),
  3,
  'positions.headcount 文本转整数写入'
);
select is(
  (select (stats ->> 'insert')::int from public.sync_runs where id = :'run_p1'),
  1,
  'positions 执行 stats.insert=1'
);

-- 同编码相同数据重跑：match 已存在 + skip 策略 → 不重复写入
select app.execute_sync_task(
  (:'tp'::jsonb ->> 'id')::uuid, 'manual',
  '[{"pos_name":"同步测试岗位","pos_code":"SYN-P1","dept":"前端组","hc":"3"}]'::jsonb
) as run_p2 \gset
select is(
  (select (stats ->> 'insert')::int from public.sync_runs where id = :'run_p2'),
  0,
  'positions 同样本重跑 insert=0（幂等）'
);
select is(
  (select (stats ->> 'skip')::int from public.sync_runs where id = :'run_p2'),
  1,
  'positions 同样本重跑计入 skip'
);
select is(
  (select count(*) from public.positions where code = 'SYN-P1'),
  1::bigint,
  'positions 重跑不产生重复行'
);

-- ===========================================================================
-- 3. profiles：仅 UPDATE 不 INSERT；字段白名单；role/status 不可写
-- ===========================================================================
select app.execute_sync_task(
  (:'tf'::jsonb ->> 'id')::uuid, 'manual',
  '[{"mail":"engineer@example.com","name":"同步改名工程师","dept":"后端组","pos":"SYN-P1"},{"mail":"nobody@example.com","name":"不存在用户"}]'::jsonb
) as run_f1 \gset

select is(
  (select full_name from public.profiles where email = 'engineer@example.com'),
  '同步改名工程师',
  'profiles 按 email 匹配 UPDATE full_name'
);
select is(
  (select department from public.profiles where email = 'engineer@example.com'),
  '后端组',
  'profiles.department_name 写入文本列'
);
select is(
  (select department_id from public.profiles where email = 'engineer@example.com'),
  (select id from public.departments where name = '后端组'),
  'profiles 部门文本→id 双写触发器生效'
);
select is(
  (select position_id from public.profiles where email = 'engineer@example.com'),
  (select id from public.positions where code = 'SYN-P1'),
  'profiles.position_code 解析为 positions.id'
);
select is(
  (select (stats ->> 'update')::int from public.sync_runs where id = :'run_f1'),
  1,
  'profiles 执行 stats.update=1'
);
select is(
  (select (stats ->> 'skip')::int from public.sync_runs where id = :'run_f1'),
  1,
  'profiles 未匹配行计入 skip（不新建用户）'
);
select is(
  (select count(*) from public.profiles where email = 'nobody@example.com'),
  0::bigint,
  'profiles 未匹配行不产生 INSERT（仅更新不新建）'
);
select is(
  (select role::text from public.profiles where email = 'engineer@example.com'),
  'engineer',
  'profiles 同步不修改 role（INDEX 规则 7）'
);
select is(
  (select status::text from public.profiles where email = 'engineer@example.com'),
  'active',
  'profiles 同步不修改 status'
);

-- 绕过页面直改任务映射加入 role → 执行期防御性拒绝 22023
update public.sync_tasks
   set field_mapping = '[{"source_field":"mail","target_field":"email"},{"source_field":"r","target_field":"role"}]'::jsonb
 where id = (:'tf'::jsonb ->> 'id')::uuid;
select throws_ok(
  format(
    'select app.execute_sync_task(%L::uuid, ''manual'', ''[{"mail":"engineer@example.com"}]''::jsonb)',
    (:'tf'::jsonb ->> 'id')
  ),
  '22023', null, '执行期映射越界（profiles.role）被拒'
);
update public.sync_tasks
   set field_mapping = '[{"source_field":"mail","target_field":"email"},{"source_field":"name","target_field":"full_name"}]'::jsonb
 where id = (:'tf'::jsonb ->> 'id')::uuid;

-- ===========================================================================
-- 4. 冲突三策略
-- ===========================================================================
-- skip：部门已存在 → skip 不写
select app.execute_sync_task(
  (:'td'::jsonb ->> 'id')::uuid, 'manual',
  '[{"dept":"同步测试部门甲","sort":"99"}]'::jsonb
) as run_d2 \gset
select is(
  (select (stats ->> 'skip')::int from public.sync_runs where id = :'run_d2'),
  1,
  'skip 策略：已存在行计入 skip'
);
select is(
  (select sort_order from public.departments where name = '同步测试部门甲'),
  5,
  'skip 策略：目标行保持不变'
);

-- overwrite：改 sort → 更新
update public.sync_tasks
   set conflict_policy = 'overwrite'
 where id = (:'td'::jsonb ->> 'id')::uuid;
select app.execute_sync_task(
  (:'td'::jsonb ->> 'id')::uuid, 'manual',
  '[{"dept":"同步测试部门甲","sort":"99"}]'::jsonb
) as run_d3 \gset
select is(
  (select (stats ->> 'update')::int from public.sync_runs where id = :'run_d3'),
  1,
  'overwrite 策略：已存在行计入 update'
);
select is(
  (select sort_order from public.departments where name = '同步测试部门甲'),
  99,
  'overwrite 策略：目标行被源值覆盖'
);
update public.sync_tasks
   set conflict_policy = 'skip'
 where id = (:'td'::jsonb ->> 'id')::uuid;

-- manual：进冲突队列，目标不变
select app.execute_sync_task(
  (:'tm'::jsonb ->> 'id')::uuid, 'manual',
  '[{"dept":"同步测试部门甲","sort":"7"}]'::jsonb
) as run_m1 \gset
select is(
  (select (stats ->> 'conflict')::int from public.sync_runs where id = :'run_m1'),
  1,
  'manual 策略：冲突计入 conflict'
);
select is(
  (select status from public.sync_runs where id = :'run_m1'),
  'partial',
  'manual 冲突执行 status=partial（待裁决）'
);
select is(
  (select row_key from public.sync_conflicts where run_id = :'run_m1'),
  '同步测试部门甲',
  '冲突 row_key=匹配键值'
);
select is(
  (select source_data ->> 'sort_order' from public.sync_conflicts where run_id = :'run_m1'),
  '7',
  '冲突 source_data 记录映射后源值'
);
select ok(
  (select target_data ? 'name' and target_data ->> 'name' = '同步测试部门甲'
     from public.sync_conflicts where run_id = :'run_m1'),
  '冲突 target_data 记录目标行快照'
);
select is(
  (select sort_order from public.departments where name = '同步测试部门甲'),
  99,
  'manual 策略：目标行保持不变'
);

-- ===========================================================================
-- 5. 人工裁决：adopted / ignored / 重复 / 越权 / 目标行不存在
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.resolve_sync_conflict(
  (select id from public.sync_conflicts where run_id = :'run_m1'), 'adopted'
) as rc1 \gset

select is((:'rc1'::jsonb) ->> 'resolution', 'adopted', '裁决返回 adopted');
select is((:'rc1'::jsonb) ->> 'run_status', 'success', '裁决后 run partial→success（无剩余 pending）');
select ok(
  (select resolution = 'adopted'
          and resolved_by = '11111111-1111-1111-1111-111111111111'::uuid
          and resolved_at is not null
     from public.sync_conflicts where run_id = :'run_m1'),
  '冲突标记 adopted + 裁决人/时间'
);
select is(
  (select sort_order from public.departments where name = '同步测试部门甲'),
  7,
  'adopted：源值更新目标行'
);
reset role;
select is(
  (select status from public.sync_runs where id = :'run_m1'),
  'success',
  '裁决后 run 状态持久化为 success'
);

-- ignored：目标不变，仅标记
select app.execute_sync_task(
  (:'tm'::jsonb ->> 'id')::uuid, 'manual',
  '[{"dept":"同步测试部门甲","sort":"123"}]'::jsonb
) as run_m2 \gset
set local role authenticated;
select public.resolve_sync_conflict(
  (select id from public.sync_conflicts where run_id = :'run_m2'), 'ignored'
) as rc2 \gset
select is((:'rc2'::jsonb) ->> 'resolution', 'ignored', '裁决返回 ignored');
select is(
  (select resolution || '|' || (resolved_by is not null)::text
     from public.sync_conflicts where run_id = :'run_m2'),
  'ignored|true',
  '冲突标记 ignored + 裁决人'
);
reset role;
select is(
  (select sort_order from public.departments where name = '同步测试部门甲'),
  7,
  'ignored：目标行保持现状'
);
select is(
  (select status from public.sync_runs where id = :'run_m2'),
  'success',
  'ignored 后 run 无 pending 冲突 → success'
);

-- 重复裁决 / 非法裁决 / 越权
set local role authenticated;
select throws_ok(
  format(
    'select public.resolve_sync_conflict(%L::uuid, ''ignored'')',
    (select id::text from public.sync_conflicts where run_id = :'run_m2')
  ),
  '22023', null, '重复裁决被拒'
);
select throws_ok(
  format(
    $q$ select public.resolve_sync_conflict(%L::uuid, 'maybe') $q$,
    (select id::text from public.sync_conflicts where run_id = :'run_m1')
  ),
  '22023', null, '非法裁决结果被拒'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
select throws_ok(
  format(
    $q$ select public.resolve_sync_conflict(%L::uuid, 'ignored') $q$,
    (select id::text from public.sync_conflicts where run_id = :'run_m1')
  ),
  '42501', null, '非 admin 裁决被拒'
);
reset role;

-- adopted 时目标行不存在 → P0002，冲突保持 pending
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
select app.execute_sync_task(
  (:'tm'::jsonb ->> 'id')::uuid, 'manual',
  '[{"dept":"同步测试部门乙","sort":"1"}]'::jsonb
) as run_m3 \gset
select app.execute_sync_task(
  (:'tm'::jsonb ->> 'id')::uuid, 'manual',
  '[{"dept":"同步测试部门乙","sort":"2"}]'::jsonb
) as run_m4 \gset
delete from public.departments where name = '同步测试部门乙';
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  format(
    $q$ select public.resolve_sync_conflict(%L::uuid, 'adopted') $q$,
    (select id::text from public.sync_conflicts where run_id = :'run_m4')
  ),
  'P0002', null, 'adopted 目标行不存在被拒'
);
reset role;
select is(
  (select resolution from public.sync_conflicts where run_id = :'run_m4'),
  'pending',
  '裁决失败后冲突保持 pending（事务回滚一致）'
);

-- ===========================================================================
-- 6. 单任务并发 1：advisory lock + running 记录
--    注：advisory 锁对同会话可重入，单会话 pgTAP 无法用二次调用触发 55006；
--    此处断言「执行确实持有任务级事务锁」（跨会话互斥由 PG 语义保证），
--    拒绝路径用 running 记录兜底覆盖。
-- ===========================================================================
select app.execute_sync_task(
  (:'tl'::jsonb ->> 'id')::uuid, 'manual', '[]'::jsonb
) as run_lock1 \gset
select ok(
  exists (
    select 1
    from pg_locks l
    where l.locktype = 'advisory'
      and l.pid = pg_backend_pid()
      and l.objsubid = 1
      and l.classid =
          ((hashtextextended((:'tl'::jsonb ->> 'id'), 0) >> 32) & 4294967295)::oid
      and l.objid =
          (hashtextextended((:'tl'::jsonb ->> 'id'), 0) & 4294967295)::oid
  ),
  '执行持有任务级 advisory 锁（单任务并发 1）'
);

-- 人为遗留 running 记录 → 拒绝（入口被绕过时的兜底）
insert into public.sync_runs (task_id, trigger_type, status)
values ((:'tr'::jsonb ->> 'id')::uuid, 'cron', 'running');
select throws_ok(
  format(
    'select app.execute_sync_task(%L::uuid, ''manual'', ''[]''::jsonb)',
    (:'tr'::jsonb ->> 'id')
  ),
  '55006', null, '已有 running 记录时拒绝触发'
);
update public.sync_runs set status = 'failed', finished_at = now()
 where task_id = (:'tr'::jsonb ->> 'id')::uuid and status = 'running';
select app.execute_sync_task(
  (:'tr'::jsonb ->> 'id')::uuid, 'manual', '[]'::jsonb
) as run_lock2 \gset
select is(
  (select (stats ->> 'insert')::int from public.sync_runs where id = :'run_lock2'),
  0,
  'running 记录收敛后可再次执行'
);

-- ===========================================================================
-- 7. 状态机：failed / partial / error 明细
-- ===========================================================================
select app.execute_sync_task(
  (:'tp'::jsonb ->> 'id')::uuid, 'manual',
  '[{"pos_name":"坏岗位","pos_code":"SYN-BAD","dept":"不存在的部门","hc":"1"}]'::jsonb
) as run_pfail \gset
select is(
  (select status from public.sync_runs where id = :'run_pfail'),
  'failed',
  '全部行失败 → status=failed'
);
select is(
  (select (stats ->> 'failed')::int from public.sync_runs where id = :'run_pfail'),
  1,
  'failed 行计数正确'
);
select ok(
  (select error like '行 SYN-BAD：%' from public.sync_runs where id = :'run_pfail'),
  'error 记录行标识与原因'
);
select is(
  (select count(*) from public.positions where code = 'SYN-BAD'),
  0::bigint,
  '失败行不产生写入'
);

select app.execute_sync_task(
  (:'tp'::jsonb ->> 'id')::uuid, 'manual',
  '[{"pos_name":"好岗位","pos_code":"SYN-OK","dept":"前端组","hc":"2"},{"pos_name":"坏岗位","pos_code":"SYN-BAD2","dept":"不存在的部门","hc":"1"}]'::jsonb
) as run_pmix \gset
select is(
  (select status from public.sync_runs where id = :'run_pmix'),
  'partial',
  '部分成功 → status=partial'
);
select is(
  (select (stats ->> 'insert')::int from public.sync_runs where id = :'run_pmix'),
  1,
  'partial 执行成功写入 1 行'
);
select is(
  (select (stats ->> 'failed')::int from public.sync_runs where id = :'run_pmix'),
  1,
  'partial 执行失败 1 行'
);
select is(
  (select count(*) from public.positions where code = 'SYN-OK'),
  1::bigint,
  'partial 执行的成功行已写入'
);
select ok(
  (select error is not null from public.sync_runs where id = :'run_pmix'),
  'partial 执行保留错误明细'
);

-- ===========================================================================
-- 8. 手动触发 wrapper / 停用 / 推送 / 空样本
-- ===========================================================================
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

select public.run_sync_task(
  (:'te'::jsonb ->> 'id')::uuid, '[]'::jsonb
) as run_wrap \gset
reset role;
select is(
  (select trigger_type from public.sync_runs where id = :'run_wrap'),
  'manual',
  'public.run_sync_task 手动触发创建 manual run'
);
select is(
  (select status from public.sync_runs where id = :'run_wrap'),
  'success',
  '空样本执行零计数 success'
);
select is(
  (select stats from public.sync_runs where id = :'run_wrap'),
  '{"insert":0,"update":0,"conflict":0,"skip":0,"failed":0}'::jsonb,
  '空样本 stats 全 0'
);

set local role authenticated;
select public.rerun_sync_task(
  (:'te'::jsonb ->> 'id')::uuid, '[]'::jsonb
) as run_rerun \gset
reset role;
select is(
  (select count(*) from public.sync_runs
    where task_id = (:'te'::jsonb ->> 'id')::uuid and trigger_type = 'manual'),
  2::bigint,
  'rerun 产生新 run（同一执行函数）'
);

-- 非 admin 拒绝
select set_config(
  'request.jwt.claims',
  '{"sub":"22222222-2222-2222-2222-222222220001","role":"authenticated"}',
  true
);
set local role authenticated;
select throws_ok(
  format(
    $q$ select public.run_sync_task(%L::uuid, '[]'::jsonb) $q$,
    (:'te'::jsonb ->> 'id')
  ),
  '42501', null, '非 admin 手动触发被拒'
);
reset role;
set local role anon;
select throws_ok(
  format(
    $q$ select public.run_sync_task(%L::uuid, '[]'::jsonb) $q$,
    (:'te'::jsonb ->> 'id')
  ),
  '42501', null, 'anon 手动触发被拒（无 GRANT）'
);
reset role;

-- 恢复 admin claims：后续直调 execute 检查停用/推送等业务校验
select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);

-- 停用任务 / 推送方向
select throws_ok(
  format(
    'select app.execute_sync_task(%L::uuid, ''manual'', ''[]''::jsonb)',
    (:'tdis'::jsonb ->> 'id')
  ),
  '22023', null, '停用任务执行被拒'
);
select throws_ok(
  format(
    'select app.execute_sync_task(%L::uuid, ''manual'', ''[]''::jsonb)',
    (:'tpush'::jsonb ->> 'id')
  ),
  '22023', null, '推送方向（push）执行被拒（v1 范围）'
);
select throws_ok(
  $$ select app.execute_sync_task('00000000-0000-0000-0000-000000000000'::uuid, 'manual', '[]'::jsonb) $$,
  'P0002', null, '不存在的任务执行被拒'
);
select throws_ok(
  format(
    'select app.execute_sync_task(%L::uuid, ''wrong'', ''[]''::jsonb)',
    (:'te'::jsonb ->> 'id')
  ),
  '22023', null, '非法触发类型被拒'
);

-- ===========================================================================
-- 9. 终态失败通知属主（ADR-001 §3）
-- ===========================================================================
select ok(
  exists (
    select 1 from public.messages m
    where m.event_key = 'sync.execute_failed'
      and m.recipient_id = '11111111-1111-1111-1111-111111111111'::uuid
      and m.ref_type = 'sync_run'
      and m.ref_id = :'run_pfail'
  ),
  '终态失败写入站内信通知任务属主'
);
select ok(
  (select body like '%岗位执行任务%'
     from public.messages
    where event_key = 'sync.execute_failed' and ref_id = :'run_pfail'),
  '失败通知携带任务名与原因摘要'
);

select * from finish();
rollback;
