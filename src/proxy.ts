import { NextResponse, type NextRequest } from "next/server";

import { updateSession } from "@/lib/supabase/proxy";

/**
 * Next.js 16 网络边界代理（原 middleware）：
 * 1. 刷新 Supabase 会话 Cookie
 * 2. 未登录访问受保护页面 → 重定向 /login
 * 3. 已登录访问 /login → 重定向 /
 */
export async function proxy(request: NextRequest) {
  const { supabaseResponse, user } = await updateSession(request);
  const { pathname } = request.nextUrl;
  const isAuthRoute = pathname.startsWith("/login");

  if (!user && !isAuthRoute) {
    const url = request.nextUrl.clone();
    url.pathname = "/login";
    return carryCookies(NextResponse.redirect(url), supabaseResponse);
  }

  if (user && isAuthRoute) {
    const url = request.nextUrl.clone();
    url.pathname = "/";
    return carryCookies(NextResponse.redirect(url), supabaseResponse);
  }

  return supabaseResponse;
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
