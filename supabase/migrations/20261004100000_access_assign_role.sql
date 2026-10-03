-- 权限管理 · assign_role RPC + 存量角色迁移（access/003，阶段 1-3）
-- 工单：access/003（assign_role + admin_update_profile 收窄 + handle_new_user 改写 +
--       app.current_role 兼容）
--
-- 存量迁移分阶段（docs/modules/access/roles.md「存量迁移」）：
--   阶段 1（本迁移）：profiles.role_id → roles.id（nullable）+ 索引 + 回填内置角色；
--   阶段 2（本迁移）：app.current_role()/app.is_internal() 优先读 role_id，枚举兜底；
--   阶段 3（本迁移）：admin_update_profile 的 p_role 转调 assign_role（签名保留兼容，
--                     下版本删参数）；handle_new_user 注册时 role/role_id 双写；
--   阶段 4（同工单）：前端 users-table 角色保存改调 public.assign_role；
--   删旧枚举列不在本期（另立工单）。
--
-- 兼容期不变量：
--   1. role 枚举列仍 NOT NULL，role_id 与 role 由触发器双写一致；
--   2. role_id 不得指向枚举无法表达的自定义角色——assign_role 与双写触发器都拒绝
--      （22023），切换删除枚举后本限制随角色分配 UI 一并放开；
--   3. 写路径单通道：profile 角色变更只经 app.assign_role（admin_update_profile 转调）。
--
-- 依赖：20261003145513（admin_update_profile 现状）、20261004090000（updated_by 列）、
--       20261003211025（roles 表 + 7 内置角色）。

-- ---------------------------------------------------------------------------
-- 1. 阶段 1：profiles.role_id 列 + 外键 + 索引 + 回填
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column role_id uuid references public.roles (id) on delete restrict;

comment on column public.profiles.role_id is
  '角色外键（access/003 引入）：兼容期与 role 枚举双写，删枚举后为唯一事实来源';

create index profiles_role_id_idx on public.profiles (role_id);

-- 回填：枚举值 → roles.code 文本匹配（7 内置角色 seed 保证全覆盖）
update public.profiles p
   set role_id = r.id
  from public.roles r
 where r.code = p.role::text
   and p.role_id is null;

-- 回填完整性哨兵：任一枚举值在 roles 中缺行则迁移失败，避免带病上线
do $$
declare
  v_missing bigint;
begin
  select count(*) into v_missing
  from public.profiles
  where role_id is null;

  if v_missing > 0 then
    raise exception '角色回填不完整：% 行 profiles.role_id 为空', v_missing;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. 兼容期双写：role_id ⇄ role 枚举（BEFORE 触发器，改 NEW 不产生嵌套 UPDATE）
--    优先级：本语句改了哪列以哪列为准；两列同改时 role_id 优先（目标模型为事实源）。
--    防递归：BEFORE 触发器只改 NEW 不会递归，pg_trigger_depth() 守卫为将来改型兜底；
--    嵌套（handle_new_user 等外层触发器内插入）由调用方自行保证双写一致。
-- ---------------------------------------------------------------------------
create function app.sync_profile_role()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
begin
  if pg_catalog.pg_trigger_depth() > 1 then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.role_id is not null then
      select r.code into v_code
      from public.roles r
      where r.id = new.role_id;

      if v_code is null then
        raise exception '角色不存在：%', new.role_id using errcode = 'P0002';
      end if;
      if not exists (
        select 1
        from pg_catalog.unnest(pg_catalog.enum_range(null::public.user_role)) e
        where e::text = v_code
      ) then
        raise exception '兼容期 role 枚举无法表示自定义角色：%', v_code using errcode = '22023';
      end if;

      new.role := v_code::public.user_role;
    else
      select r.id into new.role_id
      from public.roles r
      where r.code = new.role::text;
    end if;

    return new;
  end if;

  -- UPDATE
  if new.role_id is distinct from old.role_id then
    if new.role_id is null then
      -- role_id 被清空：兼容期按枚举回填，保持双写不变量
      select r.id into new.role_id
      from public.roles r
      where r.code = new.role::text;
    else
      select r.code into v_code
      from public.roles r
      where r.id = new.role_id;

      if v_code is null then
        raise exception '角色不存在：%', new.role_id using errcode = 'P0002';
      end if;
      if not exists (
        select 1
        from pg_catalog.unnest(pg_catalog.enum_range(null::public.user_role)) e
        where e::text = v_code
      ) then
        raise exception '兼容期 role 枚举无法表示自定义角色：%', v_code using errcode = '22023';
      end if;

      new.role := v_code::public.user_role;
    end if;
  elsif new.role is distinct from old.role then
    select r.id into new.role_id
    from public.roles r
    where r.code = new.role::text;
  end if;

  return new;
end;
$$;

comment on function app.sync_profile_role() is
  '兼容期双写触发器：role_id 变化回写 role 枚举，role 枚举变化回写 role_id；pg_trigger_depth 防递归';

create trigger profiles_sync_role
before insert or update on public.profiles
for each row
execute function app.sync_profile_role();

-- ---------------------------------------------------------------------------
-- 3. 阶段 2：current_role / is_internal 优先读 role_id，枚举兜底
-- ---------------------------------------------------------------------------
create or replace function app.current_role()
returns public.user_role
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    -- 优先：role_id → roles.code（目标事实源）
    (
      select r.code::public.user_role
      from public.profiles p
      join public.roles r on r.id = p.role_id
      where p.id = (select auth.uid())
        and p.status = 'active'
    ),
    -- 兜底：role_id 为空的历史行读枚举列（兼容期）
    (
      select p.role
      from public.profiles p
      where p.id = (select auth.uid())
        and p.status = 'active'
        and p.role_id is null
    )
  )
$$;

comment on function app.current_role() is
  '当前登录用户角色：优先 role_id → roles.code，role_id 为空回退枚举；security definer 避免 RLS 递归';

create or replace function app.is_internal()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    app.current_role() in ('admin', 'engineer', 'planner', 'buyer', 'quality'),
    false
  )
$$;

-- ---------------------------------------------------------------------------
-- 4. 阶段 3a：handle_new_user 双写（raw_app_meta_data.role 仍读枚举，兼容邀请流）
-- ---------------------------------------------------------------------------
create or replace function app.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role    public.user_role := 'engineer';
  v_role_id uuid;
begin
  if new.raw_app_meta_data ? 'role' then
    begin
      v_role := (new.raw_app_meta_data ->> 'role')::public.user_role;
    exception when others then
      v_role := 'engineer';
    end;
  end if;

  -- 同步解析 role_id：切换删枚举后本查询即为唯一映射
  select r.id into v_role_id
  from public.roles r
  where r.code = v_role::text;

  insert into public.profiles (id, email, full_name, role, role_id)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
    v_role,
    v_role_id
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

comment on function app.handle_new_user() is
  '注册自动建档：raw_app_meta_data.role（枚举兼容）解析后 role/role_id 双写';

-- ---------------------------------------------------------------------------
-- 5. 阶段 3b：assign_role（角色写入单通道，INDEX 规则 7）
-- ---------------------------------------------------------------------------
create function app.assign_role(
  p_target_user uuid,
  p_new_role    text
)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role_id  uuid;
  v_target   public.profiles;
  v_old_role public.user_role;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_new_role is null or pg_catalog.btrim(p_new_role) = '' then
    raise exception '角色标识不能为空' using errcode = '22023';
  end if;

  -- 自保护：沿用 admin_update_profile 语义，不能修改自己的管理员角色
  if p_target_user = (select auth.uid()) and p_new_role is distinct from 'admin' then
    raise exception '不能修改自己的管理员角色' using errcode = '22023';
  end if;

  -- 目标角色必须存在
  select r.id into v_role_id
  from public.roles r
  where r.code = p_new_role;

  if v_role_id is null then
    raise exception '角色不存在：%', p_new_role using errcode = 'P0002';
  end if;

  -- 兼容期：role 枚举列无法表达自定义角色，暂不可分配（删枚举后放开）
  if not exists (
    select 1
    from pg_catalog.unnest(pg_catalog.enum_range(null::public.user_role)) e
    where e::text = p_new_role
  ) then
    raise exception '角色不可分配（兼容期仅支持内置角色）：%', p_new_role using errcode = '22023';
  end if;

  -- 目标角色必须是 active 行
  if not exists (
    select 1 from public.roles r where r.id = v_role_id and r.status = 'active'
  ) then
    raise exception '角色已停用，无法分配：%', p_new_role using errcode = '22023';
  end if;

  select * into v_target
  from public.profiles
  where id = p_target_user
  for update;

  if not found then
    raise exception '用户不存在：%', p_target_user using errcode = 'P0002';
  end if;

  v_old_role := v_target.role;

  update public.profiles
     set role_id    = v_role_id,
         updated_by = (select auth.uid())
   where id = p_target_user
  returning * into v_target;

  perform app.audit_log(
    'access', 'assign', 'profile_role', p_target_user::text,
    jsonb_build_object(
      'before', v_old_role,
      'after', v_target.role,
      'role_id', v_role_id
    )
  );

  return v_target;
end;
$$;

comment on function app.assign_role(uuid, text) is
  '角色分配单通道（admin）：写 role_id 并由触发器同步枚举；校验角色存在/active/兼容期内置；自保护；写审计摘要';

create function public.assign_role(
  p_target_user uuid,
  p_new_role    text
)
returns public.profiles
language sql
security definer
set search_path = ''
as $$
  select app.assign_role(p_target_user, p_new_role)
$$;

comment on function public.assign_role(uuid, text) is
  'assign_role Data API 薄包装（PostgREST 仅暴露 public schema）';

-- ---------------------------------------------------------------------------
-- 6. 阶段 3b：admin_update_profile 收窄（签名保留，p_role 转调 assign_role）
-- ---------------------------------------------------------------------------
create or replace function public.admin_update_profile(
  p_user_id    uuid,
  p_full_name  text default null,
  p_department text default null,
  p_role       public.user_role default null,
  p_status     public.profile_status default null
)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.profiles;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_user_id = (select auth.uid()) then
    if p_role is not null and p_role is distinct from 'admin' then
      raise exception '不能修改自己的管理员角色' using errcode = '22023';
    end if;
    if p_status = 'inactive' then
      raise exception '不能停用自己的账号' using errcode = '22023';
    end if;
  end if;

  -- 角色不再直接写：本更新只负责姓名/部门/状态（role 列由 assign_role 单通道写）
  update public.profiles
     set full_name  = coalesce(p_full_name, full_name),
         department = coalesce(p_department, department),
         status     = coalesce(p_status, status),
         updated_by = (select auth.uid())
   where id = p_user_id
  returning * into v_row;

  if v_row.id is null then
    raise exception '用户不存在：%', p_user_id using errcode = 'P0002';
  end if;

  -- 兼容期：p_role 仍在签名中（前端旧版本调用不中断），内部转调 assign_role；
  -- 本函数角色路径已废弃，下次签名变更（删 p_role）独立迁移。
  if p_role is not null then
    raise warning 'admin_update_profile(p_role) 已废弃：请改用 assign_role 分配角色';
    v_row := app.assign_role(p_user_id, p_role::text);
  end if;

  return v_row;
end;
$$;

comment on function public.admin_update_profile(uuid, text, text, public.user_role, public.profile_status) is
  '管理员更新用户档案（姓名/部门/状态）：p_role 兼容期转调 app.assign_role 并 warning，后续版本删参';

-- ---------------------------------------------------------------------------
-- 7. 授权：最小化（表级无变化；新函数仅 authenticated）
-- ---------------------------------------------------------------------------
revoke all on function app.sync_profile_role() from public, anon;
grant execute on function app.sync_profile_role() to authenticated;

revoke all on function app.assign_role(uuid, text) from public, anon;
grant execute on function app.assign_role(uuid, text) to authenticated;

revoke all on function public.assign_role(uuid, text) from public, anon;
grant execute on function public.assign_role(uuid, text) to authenticated;

-- admin_update_profile：create or replace 保留既有授权，此处重申保持迁移自洽
revoke all on function
  public.admin_update_profile(uuid, text, text, public.user_role, public.profile_status)
  from public, anon;
grant execute on function
  public.admin_update_profile(uuid, text, text, public.user_role, public.profile_status)
  to authenticated;
