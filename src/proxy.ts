import { NextResponse, type NextRequest } from "next/server";

import { detectImWebViewProvider } from "@/lib/im/provider";
import { updateSession } from "@/lib/supabase/proxy";

/**
 * Next.js 16 网络边界代理（原 middleware）：
 * 1. 刷新 Supabase 会话 Cookie
 * 2. 未登录访问受保护页面 → 重定向 /login（/auth/* 登录回调链路放行）
 * 3. 已登录访问 /login → 重定向 /
 * 4. 已停用账号 → 清会话并重定向 /login?reason=banned
 *    - Admin API ban 后 GoTrue 对 GET /user 直接返回 403 user_banned
 *      （userError 路径，主路径）；
 *    - profiles.status='inactive'（兜底，ban 未落 Auth 层时）；
 *    - 命中时经 record_denied_attempt('auth', path, 'user_banned') 留痕（best-effort）；
 *    RLS 数据侧由 app.current_role()（status='active' 才返回角色）兜底。
 * 5. IM 移动端免登（im/003 飞书；im/005 扩展钉钉）：IM 内嵌 WebView（UA 含 Lark / Feishu /
 *    DingTalk）未登录访问 H5 时，自动跳 IM OAuth 链路（WebView 内已登录 IM → 静默授权或
 *    仅确认授权，不出现登录页）；失败降级 /login 且用「失败计数 + 一次性 _im_fallback 标记」防环；
 *    登录成功后按 redirect_to cookie 跳回免登前访问的原目标。
 */
export async function proxy(request: NextRequest) {
  const { supabaseResponse, supabase, user, userError } =
    await updateSession(request);
  const { pathname } = request.nextUrl;
  const isLoginRoute = pathname.startsWith("/login");
  // IM / OAuth 回调（/auth/*）必须匿名可达；已登录会话也不拦截（扫码可换绑/重登）
  const isAuthFlowRoute = pathname.startsWith("/auth/");
  // im/003 / im/005：IM 内嵌 WebView（飞书 Lark/Feishu、钉钉 DingTalk）自动免登
  const imWebViewProvider = detectImWebViewProvider(
    request.headers.get("user-agent"),
  );

  // Auth 层封禁：GoTrue 403 user_banned（Admin API ban 的即时效果）
  const authBanned =
    userError?.code === "user_banned" ||
    (userError?.status === 403 && /banned/i.test(userError.message));

  if (!user) {
    if (authBanned) {
      // denied 留痕（audit 批次 1）：封禁账号越权访问以本人身份打点（module=auth）。
      // best-effort：会话已吊销/限流/网络失败均不影响封禁重定向。
      try {
        await supabase.rpc("record_denied_attempt", {
          p_module: "auth",
          p_route: pathname,
          p_reason: "user_banned",
        });
      } catch {
        // 忽略：denied 留痕不是安全边界
      }

      clearAuthCookies(request, supabaseResponse);
      return bannedRedirect(request, supabaseResponse, isLoginRoute);
    }

    if (!isLoginRoute && !isAuthFlowRoute) {
      // im/003 / im/005：IM WebView 未登录 → 自动免登（或命中防环后降级 /login）
      if (imWebViewProvider) {
        return imWebViewRedirect(request, supabaseResponse, imWebViewProvider);
      }

      const url = request.nextUrl.clone();
      url.pathname = "/login";
      return carryCookies(NextResponse.redirect(url), supabaseResponse);
    }

    // im/003 / im/005：免登失败（回调回跳 /login?error=im_*）→ 累计失败次数 + 补一次性降级标记
    if (isLoginRoute && imWebViewProvider && isImCallbackError(request)) {
      const tracked = trackImWebViewFailure(request, supabaseResponse);
      if (tracked) {
        return tracked;
      }
    }

    return supabaseResponse;
  }

  // 兜底：Auth 层未封禁但档案已停用（例如 ban API 未调用的历史数据）
  const { data: profile } = await supabase
    .from("profiles")
    .select("status")
    .eq("id", user.id)
    .maybeSingle();

  if (profile?.status === "inactive") {
    clearAuthCookies(request, supabaseResponse);
    return bannedRedirect(request, supabaseResponse, isLoginRoute);
  }

  // im/003：登录态就绪 → 一次性消费免登前记录的原目标（redirect_to 透传）
  const imTarget = readImWebViewTarget(request);
  if (imTarget && !isImTargetCurrent(imTarget, request.nextUrl)) {
    return clearImWebViewCookies(
      request,
      carryCookies(NextResponse.redirect(imTarget), supabaseResponse),
    );
  }

  if (isLoginRoute) {
    const url = request.nextUrl.clone();
    url.pathname = "/";
    return clearImWebViewCookies(
      request,
      carryCookies(NextResponse.redirect(url), supabaseResponse),
    );
  }

  return clearImWebViewCookies(request, supabaseResponse);
}

/** 清当前浏览器的 Supabase 会话 Cookie（含分片 .0/.1）
 *  Auth 层吊销由 ban/触发器负责；这里保证停用后本浏览器立即退出。
 *  说明：不能在 proxy 里调 auth.signOut —— @supabase/ssr 的 setAll 会重建
 *  内部 response，其 Set-Cookie 无法回传到已返回的响应对象。 */
function clearAuthCookies(request: NextRequest, response: NextResponse) {
  request.cookies.getAll().forEach(({ name }) => {
    if (name.startsWith("sb-") && name.includes("-auth-token")) {
      response.cookies.set(name, "", { maxAge: 0, path: "/" });
    }
  });
}

/** 已停用账号统一回登录页并带原因；已在提示页则不再自跳转（防环） */
function bannedRedirect(
  request: NextRequest,
  supabaseResponse: NextResponse,
  isLoginRoute: boolean,
) {
  if (isLoginRoute && request.nextUrl.searchParams.get("reason") === "banned") {
    return supabaseResponse;
  }

  const url = request.nextUrl.clone();
  url.pathname = "/login";
  url.search = "";
  url.searchParams.set("reason", "banned");
  return carryCookies(NextResponse.redirect(url), supabaseResponse);
}

/** 重定向时保留会话刷新产生的 Set-Cookie */
function carryCookies(target: NextResponse, source: NextResponse) {
  source.cookies.getAll().forEach((cookie) => {
    target.cookies.set(cookie);
  });
  return target;
}

// ===== im/003 飞书 / im/005 钉钉 移动端免登（H5 内嵌） =====
//
// 识别与安全边界：
// - 仅按 UA 标记识别内嵌 WebView（不引入 IP / 设备指纹）；Safari / Chrome 等外部
//   浏览器 UA 不含 Lark / Feishu / DingTalk，不进入本分支，仍走原密码 / 扫码登录。
// - 免登复用各厂商 OAuth 链路（/auth/im/<provider>/start + /auth/callback/<provider>）：
//   WebView 内用户已登录 IM，授权端点直接回回调（飞书静默 / 钉钉仅确认授权），
//   同样校验一次性 state，不降低安全等级。
// - 防环双保险：①失败计数 cookie 达上限后不再自动重试；②URL 一次性 _im_fallback 标记
//   （本文件补在 /login 上）出现即降级。失败计数在成功登录后清除。

/** 免登前访问的原目标（相对路径；登录成功后一次性消费，供 redirect_to 透传） */
const IM_WEBVIEW_REDIRECT_COOKIE = "im_h5_redirect_to";
/** 连续免登失败次数；达到上限后不再自动免登（防环） */
const IM_WEBVIEW_FALLBACK_COOKIE = "im_h5_fallback";
/** 一次性降级标记：补在 /login URL 上，出现即不再自动免登 */
const IM_WEBVIEW_FALLBACK_QUERY = "_im_fallback";
/** 连续失败上限：两次失败后第三次访问起直接降级 /login */
const IM_WEBVIEW_MAX_FAILURES = 2;
/** cookie 有效期：覆盖一轮 OAuth（state 5 分钟）与失败后手动登录的停留时间 */
const IM_WEBVIEW_COOKIE_MAX_AGE = 30 * 60;

/**
 * 未登录 + IM WebView（飞书 / 钉钉）：自动免登；命中防环条件则降级 `/login?_im_fallback=1`。
 * 两条路径都记录原目标，登录成功后（无论免登还是手动登录）跳回。
 */
function imWebViewRedirect(
  request: NextRequest,
  supabaseResponse: NextResponse,
  provider: "feishu" | "dingtalk",
): NextResponse {
  const { searchParams } = request.nextUrl;
  const shouldFallback =
    searchParams.has(IM_WEBVIEW_FALLBACK_QUERY) ||
    imWebViewFailureCount(request) >= IM_WEBVIEW_MAX_FAILURES;

  const url = shouldFallback
    ? new URL("/login", request.nextUrl)
    : new URL(`/auth/im/${provider}/start`, request.nextUrl);
  if (shouldFallback) {
    url.searchParams.set(IM_WEBVIEW_FALLBACK_QUERY, "1");
  }

  const response = carryCookies(NextResponse.redirect(url), supabaseResponse);
  return rememberImWebViewTarget(request, response);
}

/**
 * 免登失败到达 `/login?error=im_*`（im/003 / im/005）：累计失败次数并补一次性降级标记。
 * 回调路由保持原样（不在本单改动范围）只带 error；标记由这里补上，
 * 带标记的后续请求直接放行，不重复计数（避免重定向环）。
 */
function trackImWebViewFailure(
  request: NextRequest,
  supabaseResponse: NextResponse,
): NextResponse | null {
  if (request.nextUrl.searchParams.has(IM_WEBVIEW_FALLBACK_QUERY)) {
    return null;
  }

  const failures = Math.min(
    imWebViewFailureCount(request) + 1,
    IM_WEBVIEW_MAX_FAILURES,
  );
  const url = request.nextUrl.clone();
  url.searchParams.set(IM_WEBVIEW_FALLBACK_QUERY, "1");
  const response = carryCookies(NextResponse.redirect(url), supabaseResponse);
  response.cookies.set(IM_WEBVIEW_FALLBACK_COOKIE, String(failures), {
    httpOnly: true,
    sameSite: "lax",
    secure: url.protocol === "https:",
    path: "/",
    maxAge: IM_WEBVIEW_COOKIE_MAX_AGE,
  });
  return response;
}

/** 记录免登前访问的原目标（相对路径，剔除防环标记），供登录成功后跳回 */
function rememberImWebViewTarget(
  request: NextRequest,
  response: NextResponse,
): NextResponse {
  const target = new URL(request.nextUrl);
  target.searchParams.delete(IM_WEBVIEW_FALLBACK_QUERY);
  response.cookies.set(
    IM_WEBVIEW_REDIRECT_COOKIE,
    `${target.pathname}${target.search}`,
    {
      httpOnly: true,
      sameSite: "lax",
      secure: request.nextUrl.protocol === "https:",
      path: "/",
      maxAge: IM_WEBVIEW_COOKIE_MAX_AGE,
    },
  );
  return response;
}

/**
 * 读取免登原目标 cookie → 同源 URL；非法值（绝对地址 / 协议相对 / 跨源）返回 null。
 * cookie 虽为 httpOnly，仍按不可信输入处理，防止开放重定向。
 */
function readImWebViewTarget(request: NextRequest): URL | null {
  const raw = request.cookies.get(IM_WEBVIEW_REDIRECT_COOKIE)?.value;
  if (!raw) {
    return null;
  }

  try {
    const target = new URL(raw, request.nextUrl);
    return target.origin === request.nextUrl.origin ? target : null;
  } catch {
    return null;
  }
}

/** 原目标是否就是当前请求路径（相同则免一跳，直接渲染） */
function isImTargetCurrent(target: URL, current: URL): boolean {
  return (
    target.pathname === current.pathname && target.search === current.search
  );
}

/** 登录态就绪后清免登 cookie（原目标已消费 / 失败计数已失效） */
function clearImWebViewCookies(
  request: NextRequest,
  response: NextResponse,
): NextResponse {
  [IM_WEBVIEW_REDIRECT_COOKIE, IM_WEBVIEW_FALLBACK_COOKIE].forEach((name) => {
    if (request.cookies.has(name)) {
      response.cookies.set(name, "", { maxAge: 0, path: "/" });
    }
  });
  return response;
}

/** 读取连续免登失败次数（非法 / 负数 / 超限一律归一） */
function imWebViewFailureCount(request: NextRequest): number {
  const value = Number(request.cookies.get(IM_WEBVIEW_FALLBACK_COOKIE)?.value);
  return Number.isInteger(value) && value > 0
    ? Math.min(value, IM_WEBVIEW_MAX_FAILURES)
    : 0;
}

/** 是否回调失败错误（`/login?error=im_*`） */
function isImCallbackError(request: NextRequest): boolean {
  return /^im_/.test(request.nextUrl.searchParams.get("error") ?? "");
}

export const config = {
  matcher: [
    // 排除静态资源与图片
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)",
  ],
};
