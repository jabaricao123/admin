-- 系统管理 · 批次 1 安全修复 3：get_setting 敏感键准入（system_settings.is_sensitive）
-- 背景：get_setting 对 authenticated 全员开放，password_login_admin_emails（密码登录应急
--       管理员名单）、im_admin_contact（管理员联系方式）等敏感键可被任意登录用户读取。
-- 方案：
--   * system_settings 加 is_sensitive（not null default false）；存量敏感键标记 true；
--   * app.get_setting 改为 plpgsql：is_sensitive=true 且 app.current_role() 非 admin →
--     返回 NULL（与缺 key 同形，不构成存在性探测面），并写 audit_log('system','denied',
--     'setting',...) 留痕（读取 side effect 使函数由 stable 改 volatile）；
--   * upsert_setting 追加 p_is_sensitive（admin，三态：true 标记 / false 取消 /
--     NULL=新键 false、存量键保持），并对 is_sensitive 变化写审计。
-- 签名变更：upsert_setting 新增尾参（default null，旧 5 参调用保持可用）；create or replace
--   不能改参数列表，故 drop 后重建 app/public 两级函数并显式恢复 ACL（authenticated EXECUTE）。
-- 依赖：20261005040000（system_settings 现状）、20261006180000（敏感键 seed）、
--       app.audit_log（audit/001）。

-- ---------------------------------------------------------------------------
-- 1. is_sensitive 列 + 存量敏感键标记
-- ---------------------------------------------------------------------------
alter table public.system_settings
  add column is_sensitive boolean not null default false;

comment on column public.system_settings.is_sensitive is
  '敏感键标记（默认 false）：true 时 get_setting 对非 admin 返回 NULL 并写 denied 审计；'
  '仅 upsert_setting（admin）可改';

update public.system_settings
   set is_sensitive = true
 where key in ('password_login_admin_emails', 'im_admin_contact');

-- ---------------------------------------------------------------------------
-- 2. app.get_setting：敏感键对非 admin 返回 NULL + denied 审计
-- ---------------------------------------------------------------------------
create or replace function app.get_setting(p_key text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.system_settings;
begin
  select s.* into v_row
  from public.system_settings s
  where s.key = p_key;

  if not found then
    return null;
  end if;

  if v_row.is_sensitive
     and (select app.current_role()) is distinct from 'admin' then
    -- 与缺 key 同形（NULL）避免探测放大；denied 审计留痕
    perform app.audit_log(
      'system', 'denied', 'setting', v_row.key,
      jsonb_build_object('reason', 'sensitive', 'is_sensitive', true)
    );
    return null;
  end if;

  return v_row.value;
end;
$$;

comment on function app.get_setting(text) is
  '参数读取口（authenticated）：返回最新值；缺 key 返回 NULL 不报错；is_sensitive=true 且'
  '调用者非 admin 时同样返回 NULL 并写 denied 审计；读取含审计 side effect 故为 volatile';

-- ---------------------------------------------------------------------------
-- 3. 重建 app.upsert_setting（+ p_is_sensitive 三态）
-- ---------------------------------------------------------------------------
drop function app.upsert_setting(text, jsonb, text, text, text);
drop function public.upsert_setting(text, jsonb, text, text, text);

create function app.upsert_setting(
  p_key          text,
  p_value        jsonb,
  p_group_name   text,
  p_value_type   text,
  p_description  text,
  p_is_sensitive boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev          public.system_settings;
  v_row           public.system_settings;
  v_key           text := btrim(p_key);
  v_group         text := btrim(p_group_name);
  v_description   text := btrim(p_description);
  v_created       boolean;
  v_value_changed boolean;
  v_sensitive     boolean;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if v_key is null or v_key = '' then
    raise exception '参数 key 不能为空' using errcode = '22023';
  end if;
  if v_group is null or v_group = '' then
    raise exception '参数分组不能为空' using errcode = '22023';
  end if;
  if v_description is null or v_description = '' then
    raise exception '参数说明不能为空（防无主参数）' using errcode = '22023';
  end if;
  if p_value_type is null or p_value_type not in ('bool', 'number', 'string', 'json') then
    raise exception '未知参数类型：%', coalesce(p_value_type, '(null)') using errcode = '22023';
  end if;
  if p_value is null then
    raise exception '参数值不能为 NULL' using errcode = '22023';
  end if;

  -- 类型校验（表 check 兜底；此处给可读错误）
  if (case p_value_type
        when 'bool'   then jsonb_typeof(p_value) <> 'boolean'
        when 'number' then jsonb_typeof(p_value) <> 'number'
        when 'string' then jsonb_typeof(p_value) <> 'string'
        when 'json'   then jsonb_typeof(p_value) not in ('object', 'array')
        else true
      end) then
    raise exception '参数值类型与 value_type=% 不匹配（实际 %）',
      p_value_type, coalesce(jsonb_typeof(p_value), '(null)')
      using errcode = '22023';
  end if;

  select * into v_prev
  from public.system_settings
  where key = v_key
  for update;

  v_created := not found;
  -- 敏感标记三态：显式 true/false 覆盖；NULL=新键 false / 存量键保持原值
  v_sensitive := coalesce(p_is_sensitive, v_prev.is_sensitive, false);

  insert into public.system_settings
    (key, group_name, value, value_type, description, is_sensitive, updated_by)
  values
    (v_key, v_group, p_value, p_value_type, v_description, v_sensitive,
     (select auth.uid()))
  on conflict (key) do update
    set group_name   = excluded.group_name,
        value        = excluded.value,
        value_type   = excluded.value_type,
        description  = excluded.description,
        is_sensitive = excluded.is_sensitive,
        updated_by   = excluded.updated_by
  returning * into v_row;

  -- 历史只在首次创建或值实际变化时写入（重复保存同值不产生噪声历史）
  v_value_changed := v_created or v_prev.value is distinct from p_value;
  if v_value_changed then
    insert into public.system_setting_history (key, old_value, new_value, changed_by)
    values (
      v_key,
      case when v_created then null else v_prev.value end,
      p_value,
      (select auth.uid())
    );
  end if;

  perform app.audit_log(
    'system', 'upsert', 'setting', v_key,
    jsonb_build_object(
      'created', v_created,
      'group_name', v_group,
      'value_type', p_value_type,
      'value_changed', v_value_changed,
      'old_value', case when v_created then null else v_prev.value end,
      'new_value', p_value,
      'is_sensitive', v_row.is_sensitive,
      'description_changed',
        case when v_created then true else v_prev.description is distinct from v_description end
    )
  );

  return jsonb_build_object(
    'key', v_row.key,
    'group_name', v_row.group_name,
    'value', v_row.value,
    'value_type', v_row.value_type,
    'description', v_row.description,
    'is_sensitive', v_row.is_sensitive,
    'updated_by', v_row.updated_by,
    'updated_at', v_row.updated_at
  );
end;
$$;

comment on function app.upsert_setting(text, jsonb, text, text, text, boolean) is
  '参数新建/编辑 RPC（admin）：类型一致性校验（bool/number/string/json）；说明必填；'
  '值变化写 system_setting_history；p_is_sensitive 三态（true 标记 / false 取消 / NULL 保持）；'
  '审计记 old/new、is_sensitive 与变更标记';

-- ---------------------------------------------------------------------------
-- 4. public 薄包装（新签名）
-- ---------------------------------------------------------------------------
create function public.upsert_setting(
  p_key          text,
  p_value        jsonb,
  p_group_name   text,
  p_value_type   text,
  p_description  text,
  p_is_sensitive boolean default null
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select app.upsert_setting(
    p_key, p_value, p_group_name, p_value_type, p_description, p_is_sensitive
  )
$$;

comment on function public.upsert_setting(text, jsonb, text, text, text, boolean) is
  'upsert_setting Data API 薄包装（admin 校验在 app 实现内）';

-- ---------------------------------------------------------------------------
-- 5. 授权：重建的 upsert_setting 恢复 authenticated EXECUTE，清零其他角色；
--    get_setting 同签名 replace 保留原 ACL（仍显式再收口 authenticated）
-- ---------------------------------------------------------------------------
revoke all on function app.get_setting(text) from public, anon, service_role;
grant execute on function app.get_setting(text) to authenticated;

revoke all on function app.upsert_setting(text, jsonb, text, text, text, boolean)
  from public, anon, service_role;
grant execute on function app.upsert_setting(text, jsonb, text, text, text, boolean)
  to authenticated;

revoke all on function public.get_setting(text) from public, anon, service_role;
grant execute on function public.get_setting(text) to authenticated;

revoke all on function public.upsert_setting(text, jsonb, text, text, text, boolean)
  from public, anon, service_role;
grant execute on function public.upsert_setting(text, jsonb, text, text, text, boolean)
  to authenticated;
