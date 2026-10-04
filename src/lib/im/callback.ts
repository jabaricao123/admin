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
import type { ImProvider } from "./provider";
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
 */
function createAuthAdminClient(): SupabaseClient | null {
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

/**
 * 回调内使用的匿名（cookie 会话）客户端：
 * - 未登录时以 anon 身份写失败留痕；
 * - verifyOtp 成功后同一实例持有会话，继续写成功留痕；
 * - 转发浏览器 IP / UA，让 PostgREST 的 request.headers 采集到真实来源。
 */
function createRouteAuthClient(
  cookieStore: CookieStore,
  request: NextRequest,
): SupabaseClient {
  const forwarded: Record<string, string> = {};
  const forwardedFor = request.headers.get("x-forwarded-for");
  if (forwardedFor) {
    forwarded["x-forwarded-for"] = forwardedFor;
  }
  const userAgent = request.headers.get("user-agent");
  if (userAgent) {
    forwarded["user-agent"] = userAgent;
  }

  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      global: { headers: forwarded },
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

export async function handleImCallback(
  request: NextRequest,
  provider: ImProvider,
): Promise<NextResponse> {
  const { searchParams } = new URL(request.url);
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
