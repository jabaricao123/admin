// IM 扫码登录回调编排（im/002）：对厂商无感，飞书 / 企业微信 / 钉钉共用。
//
// 链路（ADR-003 §3/§4）：
//   1. 校验一次性 state cookie（5 分钟 + 读后作废，防代扫 / 重放）；
//   2. 经 im_backend 最小角色调 public.im_handle_callback：code 换 token / 取 userid /
//      预绑定匹配全部在 Postgres 内完成（厂商 secret 不出库；见迁移
//      20261006153000_im_feishu_login.sql §4）：
//      未命中 → audit_logins(via='im_<provider>', fail_reason='im_not_bound') + 回 /login；
//   3. 命中且在职 → Supabase Auth admin generateLink(magiclink) + 服务端 verifyOtp：
//      签发标准 Supabase session（与密码登录同一会话 / RLS / 登出链路，不另立体系）；
//   4. 成功写 audit_logins(via='im_<provider>', success=true)。
//
// 安全边界（im/002 修复）：厂商凭据解密与出站只在 Postgres 内（INDEX 规则 10、
// ADR-001 全局禁 service_role）；service role key 仅服务端读取，且只用于 Auth Admin
// （generateLink / getUserById），不再用于读取厂商凭据。

import { createServerClient } from "@supabase/ssr";
import {
  createClient as createSupabaseClient,
  type SupabaseClient,
} from "@supabase/supabase-js";
import { cookies } from "next/headers";
import { NextResponse, type NextRequest } from "next/server";

import { createImBackendClient } from "./backend";
import { imLoginErrorMessage } from "./messages";
import type { ImProvider } from "./provider";
import { isImQrTicket } from "./qr";
import {
  imStateCookieName,
  IM_STATE_COOKIE_PATH,
  verifyImState,
} from "./state";

/** 公网回调基址（NEXT_PUBLIC_IM_CALLBACK_BASE）；未配置时回退请求 origin（仅本地开发可接受） */
export function imCallbackBase(request: NextRequest): string {
  const configured = process.env.NEXT_PUBLIC_IM_CALLBACK_BASE?.trim();
  if (configured) {
    return configured.replace(/\/+$/, "");
  }
  if (process.env.NODE_ENV === "production") {
    console.warn(
      "[im] 未配置 NEXT_PUBLIC_IM_CALLBACK_BASE，回退请求 origin；生产环境必须配置公网回调域名",
    );
  }
  return new URL(request.url).origin;
}

/**
 * service role 客户端：仅用于 Supabase Auth Admin（generateLink / getUserById）。
 * 未配置返回 null（调用方按失败处理，不抛 500 细节）。
 * 厂商凭据读取与 OAuth 出站不经过此客户端（im/002 修复）。
 * 导出供 /auth/qr/exchange 复用（im/007）。
 */
export function createAuthAdminClient(): SupabaseClient | null {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !serviceRoleKey) {
    return null;
  }
  return createSupabaseClient(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

type CookieStore = Awaited<ReturnType<typeof cookies>>;

/** 转发浏览器 IP / UA，让 PostgREST 的 request.headers 采集到真实来源（审计留痕用） */
export function forwardedHeaders(request: NextRequest): Record<string, string> {
  const forwarded: Record<string, string> = {};
  const forwardedFor = request.headers.get("x-forwarded-for");
  if (forwardedFor) {
    forwarded["x-forwarded-for"] = forwardedFor;
  }
  const userAgent = request.headers.get("user-agent");
  if (userAgent) {
    forwarded["user-agent"] = userAgent;
  }
  return forwarded;
}

/**
 * 回调内使用的匿名（cookie 会话）客户端：
 * - 未登录时以 anon 身份写失败留痕；
 * - verifyOtp 成功后同一实例持有会话，继续写成功留痕；
 * - 转发浏览器 IP / UA，让 PostgREST 的 request.headers 采集到真实来源。
 * 导出供 /auth/qr/exchange 复用（im/007）。
 */
export function createRouteAuthClient(
  cookieStore: CookieStore,
  request: NextRequest,
): SupabaseClient {
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      global: { headers: forwardedHeaders(request) },
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet) {
          // 路由处理器允许写 cookie；会话 cookie 由这里落到响应
          cookiesToSet.forEach(({ name, value, options }) =>
            cookieStore.set(name, value, options),
          );
        },
      },
    },
  );
}

/**
 * 未签发会话的失败留痕（ticket 回调 / ticket 换 session 失败路径用，im/007）：
 * 匿名身份调 record_im_login_attempt（仅失败可写，身份由绑定推导）。
 */
export async function recordImLoginFailure(
  request: NextRequest,
  providerId: string,
  imUserId: string | null,
  failReason: string,
): Promise<void> {
  if (!imUserId) {
    return;
  }
  const supabase = createSupabaseClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: forwardedHeaders(request) },
    },
  );
  const { error } = await supabase.rpc("record_im_login_attempt", {
    p_provider: providerId,
    p_im_userid: imUserId,
    p_success: false,
    p_fail_reason: failReason,
  });
  if (error) {
    console.error(`[im/${providerId}] 登录留痕失败`, error.message);
  }
}

export async function handleImCallback(
  request: NextRequest,
  provider: ImProvider,
): Promise<NextResponse> {
  const { searchParams } = new URL(request.url);

  // 分流（im/007）：state 以 `qr.` 开头 = ticket 轮询路径（跨设备 PC 扫码）；
  // 其余 = 既有 state cookie 路径（同浏览器：移动端 H5 免登 / 桌面直登）。
  // 两路径无歧义：createImState 的随机段为 base64url（不含点），cookie state 不可能
  // 以 `qr.` 开头（见 src/lib/im/qr.ts 文件头）。
  const state = searchParams.get("state");
  if (isImQrTicket(state)) {
    return handleImQrCallback(request, provider, state);
  }

  const cookieStore = await cookies();
  const cookieName = imStateCookieName(provider.id);
  const redirectUri = `${imCallbackBase(request)}/auth/callback/${provider.id}`;

  // 一次性 state：读取后立即作废（无论后续成败，重放 / 过期一律拒绝）
  const stateCookie = cookieStore.get(cookieName)?.value;
  cookieStore.set(cookieName, "", { path: IM_STATE_COOKIE_PATH, maxAge: 0 });

  const fail = (error: string) => {
    const url = new URL("/login", imCallbackBase(request));
    url.searchParams.set("error", error);
    return NextResponse.redirect(url);
  };

  if (!verifyImState(stateCookie, searchParams.get("state"))) {
    console.error(`[im/${provider.id}] state 校验失败（缺失 / 不一致 / 过期）`);
    return fail("im_state_invalid");
  }
  if (searchParams.get("error") === "access_denied") {
    return fail("im_denied");
  }

  // 钉钉回调把授权码放在 authCode（官方文档示例 ?authCode=…&state=…；与 code 同值，取任一）
  const code = searchParams.get("code") ?? searchParams.get("authCode");
  if (!code) {
    return fail("im_failed");
  }

  const service = createAuthAdminClient();
  if (!service) {
    console.error(`[im/${provider.id}] 缺少 SUPABASE_SERVICE_ROLE_KEY（Auth Admin 签发会话用）`);
    return fail("im_failed");
  }

  const backend = createImBackendClient();
  if (!backend) {
    console.error(`[im/${provider.id}] 缺少 IM_BACKEND_JWT（或 Supabase URL / anon key）`);
    return fail("im_failed");
  }

  const auth = createRouteAuthClient(cookieStore, request);

  /** 登录留痕（ADR-002 通道）：失败不阻断登录交互；im_userid 来自 Postgres 已验证的厂商响应 */
  const audit = async (
    imUserId: string | null,
    success: boolean,
    failReason: string | null,
  ) => {
    if (!imUserId) {
      return;
    }
    const { error } = await auth.rpc("record_im_login_attempt", {
      p_provider: provider.id,
      p_im_userid: imUserId,
      p_success: success,
      p_fail_reason: failReason,
    });
    if (error) {
      console.error(`[im/${provider.id}] 登录留痕失败`, error.message);
    }
  };

  // Postgres 内完成：code 换 token → 取 userid → profiles 预绑定匹配
  const { data: result, error: resultError } = await backend.rpc(
    "im_handle_callback",
    {
      p_provider: provider.id,
      p_code: code,
      p_redirect_uri: redirectUri,
    },
  );
  if (resultError || !result || typeof result !== "object") {
    console.error(
      `[im/${provider.id}] 回调处理失败`,
      resultError?.message ?? "响应为空",
    );
    return fail("im_failed");
  }

  if (result.ok !== true) {
    const errorCode = typeof result.error === "string" ? result.error : "im_failed";
    const imUserId = typeof result.im_userid === "string" ? result.im_userid : null;
    if (errorCode === "im_not_bound" || errorCode === "im_banned") {
      await audit(
        imUserId,
        false,
        errorCode === "im_banned" ? "user_banned" : "im_not_bound",
      );
      return fail(errorCode);
    }
    console.error(
      `[im/${provider.id}] 厂商认证失败`,
      typeof result.detail === "string" ? result.detail : errorCode,
    );
    return fail(errorCode === "im_unavailable" ? "im_unavailable" : "im_failed");
  }

  const imUserId = typeof result.im_userid === "string" ? result.im_userid : null;
  const userId = typeof result.user_id === "string" ? result.user_id : null;
  if (!imUserId || !userId) {
    console.error(`[im/${provider.id}] 回调响应缺少 user_id / im_userid`);
    await audit(imUserId, false, "other");
    return fail("im_failed");
  }

  // 取权威邮箱 + Auth 层封禁检查（user_id 来自 Postgres 已验证的绑定匹配）
  const { data: userData, error: userError } =
    await service.auth.admin.getUserById(userId);
  const email = userData?.user?.email;
  const bannedUntil = userData?.user?.banned_until;
  if (userError || !email) {
    await audit(imUserId, false, "other");
    return fail("im_failed");
  }
  if (bannedUntil && new Date(bannedUntil).getTime() > Date.now()) {
    await audit(imUserId, false, "user_banned");
    return fail("im_banned");
  }

  // 会话签发：admin generateLink(magiclink) → 服务端 verifyOtp
  // 与密码登录同一 GoTrue 会话体系（ADR-003 §3）；service role 只用于生成链接，不直签 session。
  const { data: link, error: linkError } =
    await service.auth.admin.generateLink({ type: "magiclink", email });
  const hashedToken = link?.properties?.hashed_token;
  if (linkError || !hashedToken) {
    console.error(
      `[im/${provider.id}] 会话链接生成失败`,
      linkError?.message ?? "缺少 hashed_token",
    );
    await audit(imUserId, false, "other");
    return fail("im_failed");
  }

  const { error: verifyError } = await auth.auth.verifyOtp({
    type: "magiclink",
    token_hash: hashedToken,
  });
  if (verifyError) {
    console.error(`[im/${provider.id}] 会话签发失败`, verifyError.message);
    await audit(imUserId, false, "other");
    return fail("im_failed");
  }

  await audit(imUserId, true, null);

  return NextResponse.redirect(new URL("/", imCallbackBase(request)));
}

/** 手机端回调结果页（ticket 模式；自包含 HTML，无外部资源） */
function qrCallbackHtml(options: {
  tone: "ok" | "error";
  title: string;
  message: string;
  hint?: string;
}): NextResponse {
  const { tone, title, message, hint } = options;
  const accent = tone === "ok" ? "#16a34a" : "#dc2626";
  const icon = tone === "ok" ? "✓" : "!";
  const html = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
<title>${title}</title>
<style>
  :root { color-scheme: light; }
  body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
         background: #f4f4f5; padding: 24px; box-sizing: border-box;
         font-family: system-ui, -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif; }
  .card { background: #fff; border: 1px solid #e4e4e7; border-radius: 16px; padding: 40px 28px;
          width: 100%; max-width: 360px; text-align: center; box-shadow: 0 8px 30px rgba(0,0,0,.06); }
  .icon { width: 64px; height: 64px; border-radius: 50%; display: flex; align-items: center;
          justify-content: center; margin: 0 auto 20px; font-size: 30px; font-weight: 700;
          color: #fff; background: ${accent}; }
  h1 { font-size: 20px; margin: 0 0 10px; color: #18181b; }
  p { margin: 0; color: #52525b; font-size: 14px; line-height: 1.6; }
  .hint { margin-top: 14px; color: #a1a1aa; font-size: 12px; }
</style>
</head>
<body>
  <div class="card">
    <div class="icon">${icon}</div>
    <h1>${title}</h1>
    <p>${message}</p>
    ${hint ? `<p class="hint">${hint}</p>` : ""}
  </div>
</body>
</html>`;
  return new NextResponse(html, {
    status: 200,
    headers: { "content-type": "text/html; charset=utf-8" },
  });
}

/**
 * ticket 模式回调（im/007）：手机扫码后厂商重定向到本系统（跨设备，不依赖 state cookie）。
 * 只做「把 ticket 标记为已确认」：换 session 由 PC 端 /auth/qr/exchange 完成（ADR-003 §3）。
 * - 成功：手机看到「扫码成功，请回电脑」；
 * - 未绑定 / 停用：作废 ticket（PC 轮询得到原因）+ 匿名失败留痕；
 * - 取消授权（error=access_denied）：作废 ticket；
 * - ticket 非法 / 过期 / 已消费：拒绝且不触发出站。
 */
async function handleImQrCallback(
  request: NextRequest,
  provider: ImProvider,
  ticket: string,
): Promise<NextResponse> {
  const { searchParams } = new URL(request.url);
  const redirectUri = `${imCallbackBase(request)}/auth/callback/${provider.id}`;

  const denied = searchParams.get("error") === "access_denied";
  // 钉钉回调把授权码放在 authCode（同 code；im/005 兼容逻辑一致）
  const code = searchParams.get("code") ?? searchParams.get("authCode");

  const htmlError = (error: string) =>
    qrCallbackHtml({
      tone: "error",
      title: "扫码登录失败",
      message:
        imLoginErrorMessage(error, provider.id) ??
        "扫码登录失败，请返回电脑重试",
      hint: "请返回电脑端刷新二维码后重试",
    });

  if (!denied && !code) {
    console.error(`[im/${provider.id}] 扫码回调缺少授权码`);
    return htmlError("im_failed");
  }

  const backend = createImBackendClient();
  if (!backend) {
    console.error(
      `[im/${provider.id}] 缺少 IM_BACKEND_JWT（ticket 回调用）`,
    );
    return htmlError("im_failed");
  }

  const { data: result, error } = await backend.rpc("im_qr_complete_login", {
    p_provider: provider.id,
    p_ticket: ticket,
    // 取消授权：无 code，Postgres 侧按「手机取消」作废 ticket
    p_code: denied ? null : code,
    p_redirect_uri: redirectUri,
  });
  if (error || !result || typeof result !== "object") {
    console.error(
      `[im/${provider.id}] 扫码 ticket 回调处理失败`,
      error?.message ?? "响应为空",
    );
    return htmlError("im_failed");
  }

  if (result.ok !== true) {
    const errorCode =
      typeof result.error === "string" ? result.error : "im_failed";
    const imUserId =
      typeof result.im_userid === "string" ? result.im_userid : null;
    if (errorCode === "im_not_bound" || errorCode === "im_banned") {
      await recordImLoginFailure(
        request,
        provider.id,
        imUserId,
        errorCode === "im_banned" ? "user_banned" : "im_not_bound",
      );
    }
    if (errorCode === "im_denied") {
      return qrCallbackHtml({
        tone: "error",
        title: "已取消授权",
        message:
          imLoginErrorMessage("im_denied", provider.id) ??
          "已取消本次扫码登录",
        hint: "请返回电脑端刷新二维码后重试",
      });
    }
    return htmlError(errorCode);
  }

  return qrCallbackHtml({
    tone: "ok",
    title: "扫码成功",
    message: "请在电脑上继续完成登录",
    hint: "电脑端将自动跳转，无需刷新",
  });
}
