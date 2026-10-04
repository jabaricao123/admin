// PC 扫码登录 ticket 换 session（im/007）。
//
// 链路：PC 轮询到 logged_in → 整页跳本路由 → im_backend 调 public.im_exchange_qr_ticket
// （一次性消费，重放 / 过期 / 未确认一律 im_state_invalid）→ 取权威邮箱 + Auth 层封禁检查
// → Auth admin generateLink(magiclink) + 服务端 verifyOtp 签发标准 Supabase session
// （与密码登录 / 同浏览器 IM 回调同一会话体系，ADR-003 §3）→ 302 工作台。
//
// 安全边界：ticket 是唯一凭据（随机 256 位、5 分钟、一次性）；本路由只暴露「用 ticket 换
// session」，不返回任何 ticket 内部信息；service role 仅用于 Auth Admin（ADR-001 禁直签）。

import { cookies } from "next/headers";
import { NextResponse, type NextRequest } from "next/server";

import { createImBackendClient } from "@/lib/im/backend";
import {
  createAuthAdminClient,
  createRouteAuthClient,
  imCallbackBase,
  recordImLoginFailure,
} from "@/lib/im/callback";
import { isImQrTicket } from "@/lib/im/qr";

export async function GET(request: NextRequest) {
  const { searchParams } = new URL(request.url);
  const ticket = searchParams.get("ticket");
  const base = imCallbackBase(request);

  const fail = (error: string) =>
    NextResponse.redirect(new URL(`/login?error=${error}`, base));

  if (!isImQrTicket(ticket)) {
    return fail("im_state_invalid");
  }

  const backend = createImBackendClient();
  if (!backend) {
    console.error("[im/qr] 缺少 IM_BACKEND_JWT（ticket 换 session 用）");
    return fail("im_failed");
  }

  const { data: result, error } = await backend.rpc("im_exchange_qr_ticket", {
    p_ticket: ticket,
  });
  if (error || !result || typeof result !== "object") {
    console.error("[im/qr] ticket 换取失败", error?.message ?? "响应为空");
    return fail("im_failed");
  }
  if (result.ok !== true) {
    // 未知 / 过期 / 重放（已 consumed）/ 尚未确认：统一按失效处理，不区分（探测面收敛）
    return fail("im_state_invalid");
  }

  const userId = typeof result.user_id === "string" ? result.user_id : null;
  const imUserId =
    typeof result.im_userid === "string" ? result.im_userid : null;
  const provider =
    typeof result.provider === "string" ? result.provider : null;
  if (!userId || !imUserId || !provider) {
    console.error("[im/qr] ticket 响应缺少 provider / user_id / im_userid");
    return fail("im_failed");
  }

  const service = createAuthAdminClient();
  if (!service) {
    console.error("[im/qr] 缺少 SUPABASE_SERVICE_ROLE_KEY（Auth Admin 签发会话用）");
    return fail("im_failed");
  }

  // 取权威邮箱 + Auth 层封禁检查（user_id 来自 Postgres 已验证的绑定匹配）
  const { data: userData, error: userError } =
    await service.auth.admin.getUserById(userId);
  const email = userData?.user?.email;
  const bannedUntil = userData?.user?.banned_until;
  if (userError || !email) {
    await recordImLoginFailure(request, provider, imUserId, "other");
    return fail("im_failed");
  }
  if (bannedUntil && new Date(bannedUntil).getTime() > Date.now()) {
    await recordImLoginFailure(request, provider, imUserId, "user_banned");
    return fail("im_banned");
  }

  // 会话签发：admin generateLink(magiclink) → 服务端 verifyOtp（会话 cookie 落到本响应）
  const { data: link, error: linkError } =
    await service.auth.admin.generateLink({ type: "magiclink", email });
  const hashedToken = link?.properties?.hashed_token;
  if (linkError || !hashedToken) {
    console.error(
      "[im/qr] 会话链接生成失败",
      linkError?.message ?? "缺少 hashed_token",
    );
    await recordImLoginFailure(request, provider, imUserId, "other");
    return fail("im_failed");
  }

  const cookieStore = await cookies();
  const auth = createRouteAuthClient(cookieStore, request);
  const { error: verifyError } = await auth.auth.verifyOtp({
    type: "magiclink",
    token_hash: hashedToken,
  });
  if (verifyError) {
    console.error("[im/qr] 会话签发失败", verifyError.message);
    await recordImLoginFailure(request, provider, imUserId, "other");
    return fail("im_failed");
  }

  // 成功留痕：此时会话已建立，RPC 以本人身份写入并校验 userid 与绑定一致
  const { error: auditError } = await auth.rpc("record_im_login_attempt", {
    p_provider: provider,
    p_im_userid: imUserId,
    p_success: true,
    p_fail_reason: null,
  });
  if (auditError) {
    console.error("[im/qr] 登录留痕失败", auditError.message);
  }

  return NextResponse.redirect(new URL("/", base));
}
