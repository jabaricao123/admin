-- 组织管理 · profiles 部门/岗位外键（org/007）pgTAP 测试
-- 运行：supabase db reset && supabase test db
-- 覆盖：列/FK/索引/触发器存在性；文本→id 解析规则（seed 部门名匹配、同名取
--       sort_order 最小、仅 active、无匹配 NULL）；双写两向同步（含 INSERT 分支、
--       id 优先、null→null）；disable/delete_department 按 department_id 计数
--       （NULL 行文本兜底）；FK 约束兜底（不存在 id 写入被拒）；
--       authenticated 自助改文本路径不因触发器代写 department_id 失败。

begin;

select plan(37);

-- ===========================================================================
-- 1. 夹具（as postgres 写入）
--    部门：同名多 active + 同 disabled（验证 active 过滤与 sort_order 最小）；
--    用户：handle_new_user 建档（department 为 NULL）
-- ===========================================================================
insert into public.departments (id, name, sort_order, status, created_by)
values
  ('66666666-6666-4666-8666-666666660001', '测试-FK重复部', 5, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('66666666-6666-4666-8666-666666660002', '测试-FK重复部', 2, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('66666666-6666-4666-8666-666666660003', '测试-FK重复部', 1, 'disabled',
   '11111111-1111-1111-1111-111111111111'),
  ('66666666-6666-4666-8666-666666660004', '测试-FK仅停用', 1, 'disabled',
   '11111111-1111-1111-1111-111111111111'),
  ('66666666-6666-4666-8666-666666660005', '测试-FK部', 1, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('66666666-6666-4666-8666-666666660006', '测试-FK删除部', 1, 'active',
   '11111111-1111-1111-1111-111111111111'),
  ('66666666-6666-4666-8666-666666660007', '测试-FK删除部2', 1, 'active',
   '11111111-1111-1111-1111-111111111111');

insert into auth.users (id, email, raw_app_meta_data) values
  ('77777777-7777-4777-8777-777777770001', 'fk-u1@example.com', '{}'::jsonb),
  ('77777777-7777-4777-8777-777777770002', 'fk-u2@example.com', '{}'::jsonb),
  ('77777777-7777-4777-8777-777777770003', 'fk-u3@example.com', '{}'::jsonb),
  ('77777777-7777-4777-8777-777777770004', 'fk-u4@example.com', '{}'::jsonb),
  ('77777777-7777-4777-8777-777777770005', 'fk-u5@example.com', '{}'::jsonb),
  ('77777777-7777-4777-8777-777777770006', 'fk-u6@example.com', '{}'::jsonb),
  ('77777777-7777-4777-8777-777777770007', 'fk-u7@example.com', '{}'::jsonb),
  ('77777777-7777-4777-8777-777777770008', 'fk-u8@example.com', '{}'::jsonb);

-- ===========================================================================
-- 2. 结构存在性（13）
-- ===========================================================================
select has_column('public', 'profiles', 'department_id', 'profiles.department_id 列存在');
select has_column('public', 'profiles', 'position_id', 'profiles.position_id 列存在');
select col_is_null('public', 'profiles', 'department_id', 'department_id 可空（兼容期）');
select col_is_null('public', 'profiles', 'position_id', 'position_id 可空（本期无文本源）');
select ok(
  exists (
    select 1 from pg_constraint
    where conrelid = 'public.profiles'::regclass
      and contype = 'f'
      and conname = 'profiles_department_id_fkey'
  ),
  'department_id 外键 → departments.id 存在'
);
select ok(
  exists (
    select 1 from pg_constraint
    where conrelid = 'public.profiles'::regclass
      and contype = 'f'
      and conname = 'profiles_position_id_fkey'
  ),
  'position_id 外键 → positions.id 存在'
);
select is(
  (select count(*)
     from pg_constraint
    where conrelid = 'public.profiles'::regclass
      and contype = 'f'
      and confdeltype = 'r'
      and conname in ('profiles_department_id_fkey', 'profiles_position_id_fkey')),
  2::bigint,
  '两个外键均为 on delete restrict（部门逻辑删除、岗位删前计数）'
);
select has_index('public', 'profiles', 'profiles_department_id_idx', 'department_id 索引存在');
select has_index('public', 'profiles', 'profiles_position_id_idx', 'position_id 索引存在');
select has_function('app', 'sync_profile_department', 'app.sync_profile_department 存在');
select has_trigger('public', 'profiles', 'profiles_sync_department', '双写触发器存在');
select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = 'sync_profile_department'
      and p.prosecdef
      and p.proconfig = array['search_path=""']
  ),
  'app.sync_profile_department：security definer + search_path 固定为空'
);
select ok(
  (select p.prosrc like '%pg_trigger_depth%'
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app'
      and p.proname = 'sync_profile_department'),
  'sync_profile_department 含 pg_trigger_depth 守卫'
);

-- ===========================================================================
-- 3. 回填/解析规则：文本 → id（active 精确匹配、sort_order 最小、无匹配 NULL）
-- ===========================================================================
update public.profiles set department = '总部'
 where id = '77777777-7777-4777-8777-777777770001';
select is(
  (select department_id::text from public.profiles
    where id = '77777777-7777-4777-8777-777777770001'),
  '33333333-3333-3333-3333-333333330001',
  'seed 部门名「总部」解析为对应 department_id'
);
update public.profiles set department = '研发中心'
 where id = '77777777-7777-4777-8777-777777770002';
select is(
  (select department_id::text from public.profiles
    where id = '77777777-7777-4777-8777-777777770002'),
  '33333333-3333-3333-3333-333333330002',
  'seed 部门名「研发中心」解析为对应 department_id'
);
select is(
  (select department from public.profiles
    where id = '77777777-7777-4777-8777-777777770001'),
  '总部',
  '文本→id 解析不改写原文本'
);
update public.profiles set department = '测试-FK不存在部'
 where id = '77777777-7777-4777-8777-777777770003';
select is(
  (select department_id from public.profiles
    where id = '77777777-7777-4777-8777-777777770003'),
  null,
  '无匹配部门名 → department_id 留 NULL'
);
select is(
  (select count(*) from public.profiles
    where id in (
      '77777777-7777-4777-8777-777777770001',
      '77777777-7777-4777-8777-777777770002',
      '77777777-7777-4777-8777-777777770003')
      and department_id is not null),
  2::bigint,
  'seed 名匹配率：3 个 fixture 中 2 个匹配'
);
update public.profiles set department = '测试-FK重复部'
 where id = '77777777-7777-4777-8777-777777770004';
select is(
  (select department_id::text from public.profiles
    where id = '77777777-7777-4777-8777-777777770004'),
  '66666666-6666-4666-8666-666666660002',
  '同名多部门取 active 中 sort_order 最小者（disabled 更小也不取）'
);
update public.profiles set department = '测试-FK仅停用'
 where id = '77777777-7777-4777-8777-777777770005';
select is(
  (select department_id from public.profiles
    where id = '77777777-7777-4777-8777-777777770005'),
  null,
  '仅 disabled 部门名 → department_id 留 NULL（active 过滤）'
);

-- ===========================================================================
-- 4. 双写两向同步（6）
-- ===========================================================================
update public.profiles set department_id = '66666666-6666-4666-8666-666666660002'
 where id = '77777777-7777-4777-8777-777777770001';
select is(
  (select department from public.profiles
    where id = '77777777-7777-4777-8777-777777770001'),
  '测试-FK重复部',
  'department_id 变更回写部门文本'
);
update public.profiles set department = '测试-FK删除部'
 where id = '77777777-7777-4777-8777-777777770004';
select is(
  (select department_id::text from public.profiles
    where id = '77777777-7777-4777-8777-777777770004'),
  '66666666-6666-4666-8666-666666660006',
  '部门文本变更回写 department_id（更新路径）'
);
update public.profiles
   set department_id = '66666666-6666-4666-8666-666666660006',
       department    = '测试-FK重复部'
 where id = '77777777-7777-4777-8777-777777770001';
select is(
  (select department from public.profiles
    where id = '77777777-7777-4777-8777-777777770001'),
  '测试-FK删除部',
  '两列同改时以 department_id 为准（文本被 id 回写）'
);
update public.profiles set department_id = null
 where id = '77777777-7777-4777-8777-777777770001';
select is(
  (select department from public.profiles
    where id = '77777777-7777-4777-8777-777777770001'),
  null,
  'department_id 置空 → 文本同步清空（null→null）'
);
delete from public.profiles where id = '77777777-7777-4777-8777-777777770008';
insert into public.profiles (id, email, department)
values ('77777777-7777-4777-8777-777777770008', 'fk-u8@example.com', '总部');
select is(
  (select department_id::text from public.profiles
    where id = '77777777-7777-4777-8777-777777770008'),
  '33333333-3333-3333-3333-333333330001',
  'INSERT 带部门文本 → 解析 department_id'
);
delete from public.profiles where id = '77777777-7777-4777-8777-777777770008';
insert into public.profiles (id, email, department_id)
values ('77777777-7777-4777-8777-777777770008', 'fk-u8@example.com',
        '66666666-6666-4666-8666-666666660002');
select is(
  (select department from public.profiles
    where id = '77777777-7777-4777-8777-777777770008'),
  '测试-FK重复部',
  'INSERT 带 department_id → 回写部门文本'
);

-- ===========================================================================
-- 5. 不存在 id：触发器友好拒绝 + FK 约束兜底（4）
-- ===========================================================================
select throws_ok(
  $$ update public.profiles
        set department_id = '99999999-9999-4999-8999-999999999999'
      where id = '77777777-7777-4777-8777-777777770001' $$,
  'P0002', '部门不存在：99999999-9999-4999-8999-999999999999',
  '不存在的 department_id 被触发器友好拒绝（P0002）'
);
alter table public.profiles disable trigger profiles_sync_department;
select throws_ok(
  $$ update public.profiles
        set department_id = '99999999-9999-4999-8999-999999999999'
      where id = '77777777-7777-4777-8777-777777770001' $$,
  '23503', null,
  'FK 约束兜底：绕过触发器写入不存在部门 ID 被拒'
);
alter table public.profiles enable trigger profiles_sync_department;
select throws_ok(
  $$ update public.profiles
        set position_id = '99999999-9999-4999-8999-999999999999'
      where id = '77777777-7777-4777-8777-777777770001' $$,
  '23503', null,
  'position_id FK 生效：不存在岗位 ID 写入被拒'
);
delete from public.profiles where id = '77777777-7777-4777-8777-777777770008';
select throws_ok(
  $$ insert into public.profiles (id, email, department_id)
     values ('77777777-7777-4777-8777-777777770008', 'fk-u8@example.com',
             '99999999-9999-4999-8999-999999999999') $$,
  'P0002', '部门不存在：99999999-9999-4999-8999-999999999999',
  'INSERT 不存在 department_id 被拒（P0002）'
);

-- ===========================================================================
-- 6. disable/delete_department：按 department_id 计数（NULL 行文本兜底，5）
--    夹具：u6 仅 id 绑定；u7 仅文本绑定（绕过触发器制造兼容期历史行）
-- ===========================================================================
alter table public.profiles disable trigger profiles_sync_department;
update public.profiles
   set department_id = '66666666-6666-4666-8666-666666660005', department = null
 where id = '77777777-7777-4777-8777-777777770006';
update public.profiles
   set department_id = null, department = '测试-FK部'
 where id = '77777777-7777-4777-8777-777777770007';
alter table public.profiles enable trigger profiles_sync_department;

reset role;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;

select throws_ok(
  $$ select public.disable_department('66666666-6666-4666-8666-666666660005') $$,
  '22023', '该部门下仍有 2 名在职人员，无法停用',
  'disable_department 按 department_id 命中 + NULL 行文本兜底（2 人）拒绝'
);

-- 清除文本兜底行：仅 department_id 精确命中
reset role;
update public.profiles set department = null
 where id = '77777777-7777-4777-8777-777777770007';
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;
select throws_ok(
  $$ select public.disable_department('66666666-6666-4666-8666-666666660005') $$,
  '22023', '该部门下仍有 1 名在职人员，无法停用',
  'department_id 精确命中（1 人）拒绝（无文本匹配）'
);

-- 清除 id 绑定 → 停用成功
reset role;
update public.profiles set department_id = null
 where id = '77777777-7777-4777-8777-777777770006';
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;
select is(
  (select (public.disable_department('66666666-6666-4666-8666-666666660005')).status),
  'disabled',
  '清空引用后按 id 口径停用成功'
);

-- delete_department 同样按 id 计数
reset role;
update public.profiles set department_id = '66666666-6666-4666-8666-666666660007'
 where id = '77777777-7777-4777-8777-777777770006';
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;
select throws_ok(
  $$ select public.delete_department('66666666-6666-4666-8666-666666660007') $$,
  '22023', '该部门下仍有 1 名在职人员，无法删除',
  'delete_department 按 department_id 统计拒绝'
);
reset role;
update public.profiles set department_id = null
 where id = '77777777-7777-4777-8777-777777770006';
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role authenticated;
select is(
  (select (public.delete_department('66666666-6666-4666-8666-666666660007')).status),
  'deleted',
  '清空 id 引用后部门逻辑删除成功'
);

-- ===========================================================================
-- 7. authenticated 自助改文本：触发器代写 department_id 不受列级授权限制（2）
-- ===========================================================================
reset role;
update public.profiles set department_id = null
 where id = '77777777-7777-4777-8777-777777770002';
set local request.jwt.claims = '{"sub":"77777777-7777-4777-8777-777777770002","role":"authenticated"}';
set local role authenticated;
select lives_ok(
  $$ update public.profiles set department = '研发中心'
      where id = '77777777-7777-4777-8777-777777770002' $$,
  'authenticated 自助改文本路径正常（触发器代写 department_id）'
);
reset role;
select is(
  (select department_id::text from public.profiles
    where id = '77777777-7777-4777-8777-777777770002'),
  '33333333-3333-3333-3333-333333330002',
  '自助改文本后触发器已完成 department_id 同步'
);

reset role;
select * from finish();
rollback;
