import { NextResponse, type NextRequest } from "next/server";

import { updateSession } from "@/lib/supabase/proxy";

/**
 * Next.js 16 网络边界代理（原 middleware）：
 * 1. 刷新 Supabase 会话 Cookie
 * 2. 未登录访问受保护页面 → 重定向 /login
 * 3. 已登录访问 /login → 重定向 /
 * 4. 已停用账号 → 清会话并重定向 /login?reason=banned
 *    - Admin API ban 后 GoTrue 对 GET /user 直接返回 403 user_banned
 *      （userError 路径，主路径）；
 *    - profiles.status='inactive'（兜底，ban 未落 Auth 层时）；
 *    RLS 数据侧由 app.current_role()（status='active' 才返回角色）兜底。
 */
export async function proxy(request: NextRequest) {
  const { supabaseResponse, supabase, user, userError } =
    await updateSession(request);
  const { pathname } = request.nextUrl;
  const isAuthRoute = pathname.startsWith("/login");

  // Auth 层封禁：GoTrue 403 user_banned（Admin API ban 的即时效果）
  const authBanned =
    userError?.code === "user_banned" ||
    (userError?.status === 403 && /banned/i.test(userError.message));

  if (!user) {
    if (authBanned) {
      clearAuthCookies(request, supabaseResponse);
      return bannedRedirect(request, supabaseResponse, isAuthRoute);
    }

    if (!isAuthRoute) {
      const url = request.nextUrl.clone();
      url.pathname = "/login";
      return carryCookies(NextResponse.redirect(url), supabaseResponse);
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
    return bannedRedirect(request, supabaseResponse, isAuthRoute);
  }

  if (isAuthRoute) {
    const url = request.nextUrl.clone();
    url.pathname = "/";
    return carryCookies(NextResponse.redirect(url), supabaseResponse);
  }

  return supabaseResponse;
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
  isAuthRoute: boolean,
) {
  if (isAuthRoute && request.nextUrl.searchParams.get("reason") === "banned") {
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

export const config = {
  matcher: [
    // 排除静态资源与图片
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)",
  ],
};
