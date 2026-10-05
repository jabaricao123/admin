-- 系统管理 · 批次 1 安全修复 1：公告通知按 audience 过滤 + 单用户失败不阻断发布
-- 背景（system/013 遗留）：
--   1. publish_announcement 的 p_notify=true 分支对全部 active 用户发站内信，不按
--      audience 过滤——role:<code> 公告同样发给全员，范围语义只在展示侧生效；
--   2. 逐用户 send_notification 无异常隔离：任一用户投递失败会使整单发布回滚，
--      公告状态与站内信不一致（发布应尽力投递，失败计数返回）。
-- 方案：
--   * 收件人查询补 audience 过滤：all → 全部 active；role:<code> → roles.code 匹配
--     profiles.role_id（role_id 为空的兼容期历史行回退 role 枚举，与 app.current_role 同口径）；
--   * 循环内单用户投递包 exception：失败计入 failed 并 raise warning，不中断其余投递、
--     不阻断发布事务；返回与审计摘要补充 failed 计数。
-- 签名不变（create or replace），ACL 与 public 薄包装不动。
-- 依赖：20261005081000（publish_announcement 现状）、20261004100000（role_id + 枚举兜底）。

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
  v_row        public.system_announcements;
  v_publisher  text;
  v_recipient  uuid;
  v_notified   integer := 0;
  v_failed     integer := 0;
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
    end loop;
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
      'failed', v_failed
    )
  );

  return jsonb_build_object(
    'id', v_row.id,
    'status', v_row.status,
    'published_at', v_row.published_at,
    'notified', v_notified,
    'failed', v_failed
  );
end;
$$;

comment on function app.publish_announcement(uuid, boolean) is
  '公告发布 RPC（admin）：draft→published（校验时段）；p_notify=true 时按 audience 过滤'
  '收件人（all=全部 active / role:<code>=角色匹配，role_id 优先、枚举兜底）逐个调 '
  'app.send_notification（announcement.published，INDEX 规则 3）；单用户投递失败计入 '
  'failed 不阻断发布；写审计摘要（含 notified/failed）';
