// 个人中心 · 扫码绑定起点（工单 im/006）
//
// 与登录起点的差异：bind 模式，回调指向 /settings/profile/bind/<provider>/callback，
// 成功后在回调内调 public.im_bind_self 写当前登录用户本人绑定（ADR-003 §2 自助通道）。
// 需登录（个人中心语义）；厂商凭据解密与授权 URL 构造仍在 Postgres 内（im_start_auth）。

import { NextResponse, type NextRequest } from "next/server";

import { createImBackendClient } from "@/lib/im/backend";
import { imCallbackBase } from "@/lib/im/callback";
import { getImProvider, imStartStatePrefix } from "@/lib/im/provider";
import { createClient } from "@/lib/supabase/server";

import {
  createImState,
  imBindStateCookieName,
  IM_BIND_STATE_COOKIE_PATH,
  IM_BIND_STATE_TTL_MS,
} from "../../state";

export async function GET(
  request: NextRequest,
  context: { params: Promise<{ provider: string }> },
) {
  const base = imCallbackBase(request);
  const { provider: providerId } = await context.params;
  const provider = getImProvider(providerId);

  const fail = (error: string) =>
    NextResponse.redirect(new URL(`/settings/profile?error=${error}`, base));

  // 自助绑定必须已登录（proxy 已拦截未登录，这里兜底防直连）
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    return NextResponse.redirect(new URL("/login", base));
  }

  if (!provider) {
    return fail("im_unavailable");
  }

  const backend = createImBackendClient();
  if (!backend) {
    console.error(
      `[im/${provider.id}] 缺少 IM_BACKEND_JWT（或 Supabase URL / anon key）`,
    );
    return fail("im_failed");
  }

  // 企业微信 App 内嵌 WebView → 免登授权端点（与登录链路同一前缀约定）
  const state =
    imStartStatePrefix(provider, request.headers.get("user-agent")) +
    createImState();

  const { data: authorizeUrl, error } = await backend.rpc("im_start_auth", {
    p_provider: provider.id,
    p_redirect_uri: `${base}/settings/profile/bind/${provider.id}/callback`,
    p_state: state,
  });
  if (error || !authorizeUrl) {
    console.error(
      `[im/${provider.id}] 厂商未启用或凭据缺失`,
      error?.message ?? "",
    );
    return fail("im_unavailable");
  }

  const response = NextResponse.redirect(authorizeUrl);
  response.cookies.set(imBindStateCookieName(provider.id), state, {
    httpOnly: true,
    sameSite: "lax",
    // 生产回调必为 HTTPS（ADR-003 §6）；本地 http://localhost 不做 secure
    secure: base.startsWith("https://"),
    path: IM_BIND_STATE_COOKIE_PATH,
    maxAge: Math.floor(IM_BIND_STATE_TTL_MS / 1000),
  });
  return response;
}
