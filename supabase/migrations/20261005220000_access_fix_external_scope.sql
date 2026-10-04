-- 权限管理 · 安全默认修复：外部角色数据范围锁定 self（access 批次 1 / 修复项 1）
--
-- 问题：access/009 存量 seed 将全部 7 内置角色初始化为 scope='all'，外部角色
--   （supplier/customer）因此默认拥有全量 profiles 可见范围；access/010 的
--   upsert_data_scope 也未限制外部角色可配范围（可配 dept/dept_tree/all）。
-- 修复：
--   1. 存量收敛：supplier/customer 的 role_data_scopes.scope 改为 'self'（幂等）；
--   2. RPC 加固：upsert_data_scope 目标为外部角色时仅允许 'self'，其余值拒绝
--      22023；「all 仅 admin」规则保留（对内部角色仍生效）。
-- 说明：role_data_scopes 表级对 API 角色无写授权（写仅经 RPC），故加固点取 RPC；
--   存量行 update 由迁移完成，updated_at 经表触发器自动刷新。
--
-- 依赖：20261004170000（role_data_scopes / app.upsert_data_scope）。

-- ---------------------------------------------------------------------------
-- 1. 存量收敛：外部角色 scope = self
-- ---------------------------------------------------------------------------
update public.role_data_scopes
   set scope = 'self'
 where role_id in (
   select r.id
   from public.roles r
   where r.code in ('supplier', 'customer')
 )
   and scope <> 'self';

-- ---------------------------------------------------------------------------
-- 2. RPC 加固：外部角色仅 self（create or replace，签名不变）
-- ---------------------------------------------------------------------------
create or replace function app.upsert_data_scope(
  p_role_id uuid,
  p_scope   text
)
returns public.role_data_scopes
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role   public.roles;
  v_before text;
  v_row    public.role_data_scopes;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if p_scope is null or p_scope not in ('self', 'dept', 'dept_tree', 'all') then
    raise exception '非法数据范围：%', coalesce(p_scope, 'null') using errcode = '22023';
  end if;

  select * into v_role
  from public.roles
  where id = p_role_id;

  if not found then
    raise exception '角色不存在：%', p_role_id using errcode = 'P0002';
  end if;

  -- 外部角色（supplier/customer）仅允许「仅本人」（安全默认，防数据外泄）
  if v_role.code in ('supplier', 'customer') and p_scope <> 'self' then
    raise exception '外部角色仅可配置「仅本人」数据范围：%', v_role.code using errcode = '22023';
  end if;

  -- 「all」仅 admin 角色可配（data-scopes.md 功能规则）
  if p_scope = 'all' and v_role.code <> 'admin' then
    raise exception '仅系统管理员角色可配置「全部」数据范围' using errcode = '22023';
  end if;

  select scope into v_before
  from public.role_data_scopes
  where role_id = p_role_id;

  insert into public.role_data_scopes (role_id, scope, updated_by, updated_at)
  values (p_role_id, p_scope, (select auth.uid()), now())
  on conflict (role_id) do update
    set scope      = excluded.scope,
        updated_by = excluded.updated_by,
        updated_at = now()
  returning * into v_row;

  perform app.audit_log(
    'access', 'update', 'role_data_scope', p_role_id::text,
    jsonb_build_object(
      'role_code', v_role.code,
      'before', v_before,
      'after', p_scope
    )
  );

  return v_row;
end;
$$;

comment on function app.upsert_data_scope(uuid, text) is
  '数据范围配置 RPC（admin）：upsert role_data_scopes；外部角色（supplier/customer）仅 self；'
  'all 仅 admin 角色可配；写审计摘要';

-- 权限声明：create or replace 保持既有 ACL，此处显式重申口径
revoke all on function app.upsert_data_scope(uuid, text) from public, anon;
grant execute on function app.upsert_data_scope(uuid, text) to authenticated;
