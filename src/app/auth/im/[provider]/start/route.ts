// IM 扫码登录起点（im/002）：服务端生成一次性 state → 读启用厂商凭据（仅后端解密）
// → 302 到厂商授权页（飞书托管页内含扫码）。
//
// 为什么不把 appid 交给前端构造 URL：state 必须由服务端生成并落 httpOnly cookie
// （前端拿不到、也写不了 httpOnly），凭据解密后只在后端进程内使用（ADR-003 §4）。
// URL 形如 /auth/im/feishu/start，[provider] 段由 src/lib/im/provider.ts 注册表解析。

import { createClient as createSupabaseClient } from "@supabase/supabase-js";
import { NextResponse, type NextRequest } from "next/server";

import { imCallbackBase } from "@/lib/im/callback";
import { getImProvider, type ImCredentials } from "@/lib/im/provider";
import {
  createImState,
  imStateCookieName,
  IM_STATE_COOKIE_PATH,
  IM_STATE_TTL_MS,
} from "@/lib/im/state";

export async function GET(
  request: NextRequest,
  context: { params: Promise<{ provider: string }> },
) {
  const { provider: providerId } = await context.params;
  const provider = getImProvider(providerId);

  const fail = (error: string) => {
    const url = new URL("/login", imCallbackBase(request));
    url.searchParams.set("error", error);
    return NextResponse.redirect(url);
  };

  if (!provider) {
    return fail("im_unavailable");
  }

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !serviceRoleKey) {
    console.error(`[im/${provider.id}] 缺少 SUPABASE_SERVICE_ROLE_KEY`);
    return fail("im_failed");
  }

  // 后端凭据读取口（security definer 内解密；secret 不出后端）
  const service = createSupabaseClient(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: config, error } = await service.rpc("im_get_provider_config", {
    p_provider: provider.id,
  });
  if (error || !config || config.enabled !== true || !config.credentials) {
    console.error(
      `[im/${provider.id}] 厂商未启用或凭据缺失`,
      error?.message ?? "",
    );
    return fail("im_unavailable");
  }

  const base = imCallbackBase(request);
  const state = createImState();
  const authorizeUrl = provider.buildAuthorizeUrl({
    credentials: config.credentials as ImCredentials,
    redirectUri: `${base}/auth/callback/${provider.id}`,
    state,
  });

  const response = NextResponse.redirect(authorizeUrl);
  response.cookies.set(imStateCookieName(provider.id), state, {
    httpOnly: true,
    sameSite: "lax",
    // 生产回调必为 HTTPS（ADR-003 §6）；本地 http://localhost 不做 secure
    secure: base.startsWith("https://"),
    path: IM_STATE_COOKIE_PATH,
    maxAge: Math.floor(IM_STATE_TTL_MS / 1000),
  });
  return response;
}
