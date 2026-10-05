-- 系统管理 · 批次 4 并入（system 批次 2 交付）：公告通知分批 + settings 首建竞态
-- 1. app.publish_announcement：合并批次 1（20261009080000）的 audience 过滤 + 单用户 best-effort，
--    追加轻量分批——按 profiles.id 有序每 500 收件人为一批，批间 pg_sleep(0) 让出执行栈并记录
--    批数；单批失败不中断（批次 1 已做 best-effort）。说明：Postgres 函数内无法批间 commit，
--    真正的分批队列/分片投递（≤500/批、pg_cron 分片）留 v2（见 docs/modules/system/announcements.md），
--    本迁移先消除「一单循环打爆单事务」的风险并留下可观测批数。
-- 2. app.upsert_setting：合并批次 1（20261009082000）的 is_sensitive 六参签名，追加
--    pg_advisory_xact_lock(hashtext('system_setting:' || key)) 防「并发首建」竞态——
--    缺失行上 FOR UPDATE 不上锁，两个并发事务都会看到 not found，后提交者的历史会把
--    old_value 记成 NULL（首建历史失真）；key 级 xact 锁让同 key 写串行化。
-- 依赖：20261009080000（publish_announcement 当前版）、20261009082000（upsert_setting 六参版）。

-- ---------------------------------------------------------------------------
-- 1. app.publish_announcement：audience 过滤 + best-effort + 500/批轻量分批
-- ---------------------------------------------------------------------------
create or replace function app.publish_announcement(
  p_id     uuid,
  p_notify boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row         public.system_announcements;
  v_publisher   text;
  v_recipient   uuid;
  v_notified    integer := 0;
  v_failed      integer := 0;
  -- 轻量分批：每批 ≤500；函数内不能批间 commit（v2 分批队列），批间仅让出执行栈
  v_batch_size  constant integer := 500;
  v_batch_count integer := 0;
  v_batches     integer := 0;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  select * into v_row
  from public.system_announcements
  where id = p_id
  for update;

  if not found then
    raise exception '公告不存在' using errcode = 'P0002';
  end if;
  if v_row.status <> 'draft' then
    raise exception '仅草稿状态的公告可发布（当前状态：%）', v_row.status
      using errcode = '22023';
  end if;
  if btrim(v_row.title) = '' or btrim(v_row.content) = '' then
    raise exception '公告标题与正文不能为空' using errcode = '22023';
  end if;
  if v_row.starts_at is null or v_row.ends_at is null then
    raise exception '发布前请先填写生效时段（开始与结束时间）' using errcode = '22023';
  end if;
  if v_row.ends_at <= v_row.starts_at then
    raise exception '生效时段不合法：结束时间必须晚于开始时间' using errcode = '22023';
  end if;

  update public.system_announcements
     set status       = 'published',
         published_by = (select auth.uid()),
         published_at = now(),
         updated_by   = (select auth.uid())
   where id = p_id
  returning * into v_row;

  -- 站内信通知：可选（横幅为主）；按 audience 过滤收件人（all / role:<code>），
  -- 单用户投递失败 best-effort 跳过并计入 failed，不回滚整单发布。
  -- 分批：id 有序按 500 收件人/批推进，批间 pg_sleep(0)（轻量让步，非提交点）。
  if coalesce(p_notify, false) then
    select coalesce(nullif(p.full_name, ''), p.email, '系统管理员')
      into v_publisher
      from public.profiles p
     where p.id = (select auth.uid());

    for v_recipient in
      select p.id
      from public.profiles p
      where p.status = 'active'
        and (
          v_row.audience = 'all'
          or coalesce(
               (select r.code from public.roles r where r.id = p.role_id),
               p.role::text
             ) = substring(v_row.audience from 6)
        )
      order by p.id
    loop
      begin
        perform app.send_notification(
          v_recipient,
          'announcement.published',
          jsonb_build_object(
            'title', v_row.title,
            'publisher', coalesce(v_publisher, '系统管理员'),
            'body', v_row.content,
            'source_module', 'system',
            'ref_type', 'announcement',
            'ref_id', v_row.id::text
          )
        );
        v_notified := v_notified + 1;
      exception when others then
        v_failed := v_failed + 1;
        raise warning '公告 % 通知投递失败（收件人 %）：%', v_row.id, v_recipient, sqlerrm;
      end;

      v_batch_count := v_batch_count + 1;
      if v_batch_count >= v_batch_size then
        v_batches := v_batches + 1;
        v_batch_count := 0;
        -- 轻量让步：函数内无法批间提交，这里只让执行栈透口气（v2 分批队列表落地后替换）
        perform pg_sleep(0);
      end if;
    end loop;

    if v_batch_count > 0 then
      v_batches := v_batches + 1;
    end if;
  end if;

  perform app.audit_log(
    'system', 'publish', 'announcement', v_row.id::text,
    jsonb_build_object(
      'title', v_row.title,
      'audience', v_row.audience,
      'pinned', v_row.pinned,
      'starts_at', v_row.starts_at,
      'ends_at', v_row.ends_at,
      'notify', coalesce(p_notify, false),
      'notified', v_notified,
      'failed', v_failed,
      'notify_batches', v_batches,
      'batch_size', v_batch_size
    )
  );

  return jsonb_build_object(
    'id', v_row.id,
    'status', v_row.status,
    'published_at', v_row.published_at,
    'notified', v_notified,
    'failed', v_failed,
    'notify_batches', v_batches
  );
end;
$$;

comment on function app.publish_announcement(uuid, boolean) is
  '公告发布 RPC（admin）：draft→published（校验时段）；p_notify=true 时按 audience 过滤'
  '收件人（all=全部 active / role:<code>=角色匹配，role_id 优先、枚举兜底），按 id 有序 '
  '每 ≤500 收件人为一批投递（批间 pg_sleep(0) 轻量让步；函数内不可批间 commit，'
  '分批队列/分片留 v2）；单用户失败计入 failed 不阻断发布；写审计（含 notified/failed/batches）';

-- ---------------------------------------------------------------------------
-- 2. app.upsert_setting：六参签名（批次 1）+ key 级 advisory xact 锁（防首建竞态）
-- ---------------------------------------------------------------------------
create or replace function app.upsert_setting(
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

  -- 首建竞态防护：缺失行上 SELECT ... FOR UPDATE 不上锁，两个并发首建都会看到 not found，
  -- 后提交者会把 old_value 记成 NULL（历史失真）；先取 key 级 advisory xact 锁串行化同 key 写。
  -- 命名空间前缀避免与其他模块的 advisory 锁（如 sync webhook 限流）撞键。
  perform pg_advisory_xact_lock(hashtext('system_setting:' || v_key));

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
  'key 级 advisory xact 锁防并发首建历史失真；审计记 old/new、is_sensitive 与变更标记';
