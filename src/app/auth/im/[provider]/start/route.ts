// IM 扫码登录起点（im/002）：服务端生成一次性 state → 经 im_backend 最小角色调
// public.im_start_auth（厂商凭据解密与授权 URL 构造在 Postgres 内完成，secret 不出库）
// → 302 到厂商授权页（飞书托管页内含扫码；企业微信 PC 扫码 / App 内免登两形态）。
//
// 为什么不在 Next.js 读凭据构造 URL：secret 不允许离开 Postgres（INDEX 规则 10、
// ADR-001 全局禁 service_role）；im_backend JWT 仅能执行 im_start_auth /
// im_handle_callback 两个包装（详见 src/lib/im/backend.ts）。
// URL 形如 /auth/im/feishu/start，[provider] 段由 src/lib/im/provider.ts 注册表解析。

import { NextResponse, type NextRequest } from "next/server";

import { createImBackendClient } from "@/lib/im/backend";
import { imCallbackBase } from "@/lib/im/callback";
import { getImProvider, imStartStatePrefix } from "@/lib/im/provider";
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

  const backend = createImBackendClient();
  if (!backend) {
    console.error(
      `[im/${provider.id}] 缺少 IM_BACKEND_JWT（或 Supabase URL / anon key）`,
    );
    return fail("im_failed");
  }

  const base = imCallbackBase(request);
  // 企业微信 App 内嵌 WebView（UA 含 wxwork）→ 免登授权端点；PC 浏览器 → 扫码端点。
  // im_start_auth 签名不变，模式经 state 的 `m.` 前缀传入 Postgres（im/004）。
  const state =
    imStartStatePrefix(provider, request.headers.get("user-agent")) +
    createImState();

  // Postgres 内构造授权 URL（含凭据解密；未启用 / 凭据缺失返回 im_unavailable）
  const { data: authorizeUrl, error } = await backend.rpc("im_start_auth", {
    p_provider: provider.id,
    p_redirect_uri: `${base}/auth/callback/${provider.id}`,
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
