-- 系统管理 · PC 扫码登录「真二维码」数据面（工单 im/007，ticket 轮询模式）
-- 契约：docs/adr/003-im-login.md §1（PC 扫码入口形态）/§4（防代扫：短时效 + App 内二次确认 +
--        不另加 IP / 设备指纹）、docs/modules/INDEX.md 规则 10（内部入口不 GRANT API 角色）、
--       ADR-001（全局禁 service_role）。
--
-- 背景（复审 B1）：原「扫码登录」实现为同浏览器授权跳转 —— state 写入 httpOnly
-- cookie（path=/auth/callback），要求 start 与回调必须是同一浏览器。手机扫 PC 屏幕上的
-- 二维码时，回调由手机浏览器发起、没有 cookie，必然 im_state_invalid；该实现实际是
-- 「同设备授权登录」（移动端 H5 免登 / 桌面一键登录），不是 PC 扫码。
--
-- 本迁移新增 ticket 轮询路径，与既有 state cookie 路径并存（不改 im_start_auth /
-- im_handle_callback 签名与实现，不改 state cookie 逻辑）：
--   1. public.im_qr_tickets：一次性 ticket（`qr.` 前缀 + 256 位随机 hex；5 分钟过期；
--      绑定匹配失败即作废），表零 API 角色授权 + RLS，仅 SECURITY DEFINER 函数访问；
--   2. public.im_start_qr_login(p_provider, p_redirect_uri)：anon 生成 ticket，
--      经既有厂商实现（app.im_build_authorize_url / app.im_wecom_build_authorize_url /
--      app.im_dingtalk_build_authorize_url）构造 state=ticket 的授权 URL（secret 不出库）；
--   3. public.im_poll_qr_login(p_ticket)：anon 轮询，仅返回状态与失败原因，不泄露身份；
--   4. public.im_qr_complete_login(p_provider, p_ticket, p_code, p_redirect_uri)：im_backend
--      （回调路由）换 code → 绑定匹配 → 原子标记 logged_in；p_code 为空 = 手机端取消授权，
--      标记作废并记 fail_reason=im_denied；
--   5. public.im_exchange_qr_ticket(p_ticket)：im_backend（PC 换 session 路由）一次性消费
--      logged_in ticket，返回 {provider, user_id, im_userid}（重放 / 过期 / 未登录均拒绝）。
--
-- 防代扫：ticket 一次性（consumed 后不可再用）+ 5 分钟过期 + 绑定匹配失败即作废 +
--         轮询只回状态不泄露身份；session 仍由 Next.js 经 Auth admin generateLink +
--         verifyOtp 签发（ADR-003 §3，不引第二套会话体系）。
--
-- 依赖：app.im_provider_credentials / app.im_build_authorize_url（飞书）/
--       app.im_wecom_build_authorize_url（im/004）/ app.im_dingtalk_build_authorize_url（im/005）/
--       app.im_handle_callback（既有回调编排）。

-- ---------------------------------------------------------------------------
-- 1. public.im_qr_tickets：ticket 状态表（零 API 角色授权 + RLS，仅函数访问）
-- ---------------------------------------------------------------------------
create table public.im_qr_tickets (
  ticket      text primary key,
  provider    text not null,
  status      text not null default 'pending',
  user_id     uuid references auth.users (id) on delete cascade,
  im_userid   text,
  fail_reason text,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  consumed_at timestamptz,
  constraint im_qr_tickets_ticket_format
    check (ticket ~ '^qr\.[A-Za-z0-9_-]{43,64}$'),
  constraint im_qr_tickets_provider_check
    check (provider in ('wecom', 'feishu', 'dingtalk')),
  constraint im_qr_tickets_status_check
    check (status in ('pending', 'logged_in', 'expired', 'consumed')),
  constraint im_qr_tickets_logged_in_identity
    check (status <> 'logged_in' or (user_id is not null and im_userid is not null)),
  constraint im_qr_tickets_consumed_time
    check (status <> 'consumed' or consumed_at is not null)
);

comment on table public.im_qr_tickets is
  'PC 扫码登录 ticket（im/007）：pending → logged_in → consumed，或 pending → expired；'
  '5 分钟过期；绑定匹配失败即 expired（fail_reason=im_not_bound / im_banned）；'
  '表零 API 角色授权 + RLS，仅经 public.im_* SECURITY DEFINER 函数读写';
comment on column public.im_qr_tickets.ticket is
  '一次性 ticket：`qr.` 前缀 + 64 位随机 hex（与 state cookie 值无前缀碰撞，见 im_qr_new_ticket）';
comment on column public.im_qr_tickets.status is
  'pending=等待扫码 / logged_in=手机已确认（待 PC 换取）/ consumed=PC 已换 session / expired=过期或作废';
comment on column public.im_qr_tickets.fail_reason is
  '作废原因（expired 时有值，如 im_not_bound / im_banned / im_denied）；供 PC 轮询展示，不含身份信息';
comment on column public.im_qr_tickets.im_userid is
  '手机确认的厂商 userid（未绑定拒绝时也保留线索，用于审计）；不随轮询返回';

-- 清理（start 内顺手删除超 1 小时的旧 ticket）走 expires_at
create index im_qr_tickets_expires_at_idx on public.im_qr_tickets (expires_at);

alter table public.im_qr_tickets enable row level security;

-- Supabase 默认把新建表 GRANT 给 API 角色；显式收回，仅 SECURITY DEFINER 函数可达
revoke all on table public.im_qr_tickets from public, anon, authenticated, service_role, im_backend;

-- ---------------------------------------------------------------------------
-- 2. app 内部 helper（零授权，仅经 PUBLIC SECURITY DEFINER 包装调用）
-- ---------------------------------------------------------------------------

-- 2.1 ticket 生成：`qr.` + 256 位随机 hex（两个 UUIDv4 的 128 位随机段拼接）。
--     前缀与 state cookie 无碰撞：cookie state 的随机段是 base64url（不含点），其首个点
--     必然出现在第 43 位（或 m. 免登前缀后的第 1 位），不可能出现 `qr.` 前缀。
create function app.im_qr_new_ticket()
returns text
language sql
volatile
set search_path = ''
as $$
  select 'qr.' || replace(gen_random_uuid()::text, '-', '')
       || replace(gen_random_uuid()::text, '-', '')
$$;

comment on function app.im_qr_new_ticket() is
  'ticket 生成（纯内部 helper，不 GRANT 任何角色）：`qr.` 前缀 + 256 位随机 hex；'
  '前缀不与 state cookie 值碰撞（cookie 随机段为不含点的 base64url）';

-- 2.2 原子标记：pending + 未过期 → logged_in（并发回调只有一个成功）
create function app.im_qr_ticket_complete(
  p_ticket   text,
  p_user_id  uuid,
  p_im_userid text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.im_qr_tickets t
     set status = 'logged_in',
         user_id = p_user_id,
         im_userid = p_im_userid
   where t.ticket = p_ticket
     and t.status = 'pending'
     and t.expires_at > now();
  return found;
end;
$$;

comment on function app.im_qr_ticket_complete(text, uuid, text) is
  'ticket 原子标记 logged_in（pending + 未过期才成功；返回是否命中）；不 GRANT 任何角色';

-- 2.3 绑定匹配失败 / 手机取消：pending → expired + fail_reason（作废不可恢复）
create function app.im_qr_ticket_invalidate(
  p_ticket      text,
  p_fail_reason text,
  p_im_userid   text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.im_qr_tickets t
     set status = 'expired',
         fail_reason = nullif(btrim(p_fail_reason), ''),
         im_userid = coalesce(nullif(btrim(p_im_userid), ''), t.im_userid)
   where t.ticket = p_ticket
     and t.status = 'pending';
  return found;
end;
$$;

comment on function app.im_qr_ticket_invalidate(text, text, text) is
  'ticket 作废（pending → expired + fail_reason，如 im_not_bound / im_banned / im_denied）；'
  '不触碰 logged_in / consumed（PC 已确认的 ticket 由过期与消费语义处理）；不 GRANT 任何角色';

-- ---------------------------------------------------------------------------
-- 3. public.im_start_qr_login：anon 生成 ticket + 厂商授权 URL（state=ticket）
-- ---------------------------------------------------------------------------
create function public.im_start_qr_login(
  p_provider     text,
  p_redirect_uri text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_provider text := lower(btrim(coalesce(p_provider, '')));
  v_ticket   text;
  v_url      text;
  v_expires  timestamptz := now() + interval '5 minutes';
begin
  if v_provider not in ('wecom', 'feishu', 'dingtalk') then
    raise exception '未知 IM 厂商：%', coalesce(p_provider, '(null)') using errcode = '22023';
  end if;
  if p_redirect_uri is null or p_redirect_uri !~ '^https?://[^[:space:]]+$' then
    raise exception '回调地址非法' using errcode = '22023';
  end if;

  -- 顺手清理超 1 小时的旧 ticket（过期 / 完成 / 作废），避免表无界增长
  delete from public.im_qr_tickets t
   where t.expires_at < now() - interval '1 hour';

  v_ticket := app.im_qr_new_ticket();

  -- 授权 URL 经既有厂商实现构造（state=ticket；secret 不出库）。
  -- 未启用 / 凭据缺失 / 凭据不完整一律映射 im_unavailable（与同浏览器路径文案一致）
  begin
    if v_provider = 'feishu' then
      v_url := app.im_build_authorize_url(v_provider, p_redirect_uri, v_ticket);
    elsif v_provider = 'wecom' then
      v_url := app.im_wecom_build_authorize_url(p_redirect_uri, v_ticket);
    else
      v_url := app.im_dingtalk_build_authorize_url(p_redirect_uri, v_ticket);
    end if;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'im_unavailable');
  end;

  insert into public.im_qr_tickets (ticket, provider, status, expires_at)
  values (v_ticket, v_provider, 'pending', v_expires);

  return jsonb_build_object(
    'ok', true,
    'ticket', v_ticket,
    'authorize_url', v_url,
    'expires_at', v_expires
  );
end;
$$;

comment on function public.im_start_qr_login(text, text) is
  'PC 扫码 ticket 起点（anon/authenticated）：生成一次性 ticket 并返回厂商授权 URL'
  '（state=ticket，供二维码 / iframe 渲染）与 expires_at（+5 分钟）；未启用 / 凭据缺失'
  '返回 {ok:false,error:im_unavailable}；secret 不出库；start 时顺手清理超 1 小时旧 ticket';

-- ---------------------------------------------------------------------------
-- 4. public.im_poll_qr_login：anon 轮询（只返回状态与失败原因，不泄露身份）
-- ---------------------------------------------------------------------------
create function public.im_poll_qr_login(p_ticket text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ticket text := btrim(coalesce(p_ticket, ''));
  v_row    public.im_qr_tickets;
begin
  -- 格式不符与不存在同回 invalid（轮询不是 ticket 存在性探测口）
  if v_ticket !~ '^qr\.[A-Za-z0-9_-]{43,64}$' then
    return jsonb_build_object('status', 'invalid');
  end if;

  -- 惰性过期：pending / logged_in 超过 expires_at 即作废
  update public.im_qr_tickets t
     set status = 'expired'
   where t.ticket = v_ticket
     and t.status in ('pending', 'logged_in')
     and t.expires_at <= now();

  select * into v_row
  from public.im_qr_tickets t
  where t.ticket = v_ticket;

  if v_row.ticket is null then
    return jsonb_build_object('status', 'invalid');
  end if;

  return jsonb_build_object(
    'status', v_row.status,
    'reason', case when v_row.status = 'expired' then v_row.fail_reason end
  );
end;
$$;

comment on function public.im_poll_qr_login(text) is
  'PC 扫码轮询（anon/authenticated）：仅返回 {status: pending|logged_in|consumed|expired|invalid'
  '[,reason]}；不返回 user_id / im_userid / provider（轮询不泄露身份）；'
  '惰性把超时 pending / logged_in 置为 expired';

-- ---------------------------------------------------------------------------
-- 5. public.im_qr_complete_login：手机回调（im_backend）换 code → 标记 logged_in
-- ---------------------------------------------------------------------------
create function public.im_qr_complete_login(
  p_provider     text,
  p_ticket       text,
  p_code         text,
  p_redirect_uri text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_provider  text := lower(btrim(coalesce(p_provider, '')));
  v_ticket    text := btrim(coalesce(p_ticket, ''));
  v_code      text := nullif(btrim(coalesce(p_code, '')), '');
  v_row       public.im_qr_tickets;
  v_result    jsonb;
  v_error     text;
  v_im_userid text;
begin
  if v_provider not in ('wecom', 'feishu', 'dingtalk') then
    raise exception '未知 IM 厂商：%', coalesce(p_provider, '(null)') using errcode = '22023';
  end if;
  if p_redirect_uri is null or p_redirect_uri !~ '^https?://[^[:space:]]+$' then
    raise exception '回调地址非法' using errcode = '22023';
  end if;
  if v_ticket !~ '^qr\.[A-Za-z0-9_-]{43,64}$' then
    return jsonb_build_object('ok', false, 'error', 'im_state_invalid');
  end if;

  -- 先锁定并校验 ticket（存在 / 归属厂商 / pending / 未过期），不合法不触发出站
  select * into v_row
  from public.im_qr_tickets t
  where t.ticket = v_ticket
  for update;

  if v_row.ticket is null or v_row.provider <> v_provider then
    return jsonb_build_object('ok', false, 'error', 'im_state_invalid');
  end if;
  if v_row.status <> 'pending' then
    return jsonb_build_object('ok', false, 'error', 'im_state_invalid');
  end if;
  if v_row.expires_at <= now() then
    update public.im_qr_tickets t
       set status = 'expired'
     where t.ticket = v_ticket
       and t.status = 'pending';
    return jsonb_build_object('ok', false, 'error', 'im_state_invalid');
  end if;

  -- 手机端取消授权（回调带 error=access_denied，无 code）：作废 ticket，PC 端停止轮询
  if v_code is null then
    perform app.im_qr_ticket_invalidate(v_ticket, 'im_denied');
    return jsonb_build_object('ok', false, 'error', 'im_denied');
  end if;

  -- 厂商换 code → 取 userid → 预绑定匹配（public 薄包装按 provider 分派；secret / 出站均不出库）
  v_result := public.im_handle_callback(v_provider, v_code, p_redirect_uri);
  if not coalesce((v_result ->> 'ok')::boolean, false) then
    v_error := coalesce(v_result ->> 'error', 'im_failed');
    v_im_userid := nullif(v_result ->> 'im_userid', '');

    -- 绑定匹配失败即作废（防反复试探 / 代扫）；出站类失败保留 pending，允许同一二维码重扫
    if v_error in ('im_not_bound', 'im_banned') then
      perform app.im_qr_ticket_invalidate(v_ticket, v_error, v_im_userid);
    end if;

    return jsonb_build_object(
      'ok', false,
      'error', v_error,
      'im_userid', v_im_userid,
      'detail', v_result ->> 'detail'
    );
  end if;

  if not app.im_qr_ticket_complete(
    v_ticket, (v_result ->> 'user_id')::uuid, v_result ->> 'im_userid'
  ) then
    -- 行锁竞争下已被并发回调抢先标记 / 作废
    return jsonb_build_object('ok', false, 'error', 'im_state_invalid');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

comment on function public.im_qr_complete_login(text, text, text, text) is
  'PC 扫码手机回调（仅 im_backend）：校验 ticket（存在 / 同厂商 / pending / 未过期）→ '
  'app.im_handle_callback（换 token / userid / 预绑定匹配）→ 原子标记 logged_in；'
  'im_not_bound / im_banned 即作废 ticket（fail_reason 供 PC 轮询展示）；p_code 为空 = '
  '手机取消授权（expired + im_denied）；出站失败保留 pending 允许重扫；不签发 session'
  '（PC 经 im_exchange_qr_ticket + Auth admin 签发，ADR-003 §3）';

-- ---------------------------------------------------------------------------
-- 6. public.im_exchange_qr_ticket：PC 换 session（im_backend，一次性消费）
-- ---------------------------------------------------------------------------
create function public.im_exchange_qr_ticket(p_ticket text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ticket text := btrim(coalesce(p_ticket, ''));
  v_row    public.im_qr_tickets;
begin
  if v_ticket !~ '^qr\.[A-Za-z0-9_-]{43,64}$' then
    return jsonb_build_object('ok', false, 'error', 'im_state_invalid');
  end if;

  -- 惰性过期：超时的 pending / logged_in 先作废，再尝试消费
  update public.im_qr_tickets t
     set status = 'expired'
   where t.ticket = v_ticket
     and t.status in ('pending', 'logged_in')
     and t.expires_at <= now();

  -- 一次性消费：只有 logged_in 且未过期可换，重放 / 过期 / 未确认一律不命中
  update public.im_qr_tickets t
     set status = 'consumed',
         consumed_at = now()
   where t.ticket = v_ticket
     and t.status = 'logged_in'
  returning t.* into v_row;

  if v_row.ticket is null then
    return jsonb_build_object('ok', false, 'error', 'im_state_invalid');
  end if;

  return jsonb_build_object(
    'ok', true,
    'provider', v_row.provider,
    'user_id', v_row.user_id,
    'im_userid', v_row.im_userid
  );
end;
$$;

comment on function public.im_exchange_qr_ticket(text) is
  'PC 扫码换取登录身份（仅 im_backend）：把 logged_in 且未过期的 ticket 原子置为 consumed，'
  '返回 {ok:true,provider,user_id,im_userid}；未知 / pending / expired / consumed（重放）'
  '一律 {ok:false,error:im_state_invalid}；不签发 session（Next.js 路由内经 Auth admin 签发）';

-- ---------------------------------------------------------------------------
-- 7. 授权：start / poll 对匿名开放；complete / exchange 仅 im_backend；内部 helper 零授权
-- ---------------------------------------------------------------------------
revoke all on function public.im_start_qr_login(text, text)
  from public, anon, authenticated, service_role, im_backend;
grant execute on function public.im_start_qr_login(text, text)
  to anon, authenticated;

revoke all on function public.im_poll_qr_login(text)
  from public, anon, authenticated, service_role, im_backend;
grant execute on function public.im_poll_qr_login(text)
  to anon, authenticated;

revoke all on function public.im_qr_complete_login(text, text, text, text)
  from public, anon, authenticated, service_role, im_backend;
grant execute on function public.im_qr_complete_login(text, text, text, text)
  to im_backend;

revoke all on function public.im_exchange_qr_ticket(text)
  from public, anon, authenticated, service_role, im_backend;
grant execute on function public.im_exchange_qr_ticket(text)
  to im_backend;

revoke all on function app.im_qr_new_ticket()
  from public, anon, authenticated, service_role, im_backend;
revoke all on function app.im_qr_ticket_complete(text, uuid, text)
  from public, anon, authenticated, service_role, im_backend;
revoke all on function app.im_qr_ticket_invalidate(text, text, text)
  from public, anon, authenticated, service_role, im_backend;
