// IM 扫码登录回调编排（im/002）：对厂商无感，飞书 / 企业微信 / 钉钉共用。
//
// 链路（ADR-003 §3/§4）：
//   1. 校验一次性 state cookie（5 分钟 + 读后作废，防代扫 / 重放）；
//   2. 后端读 im_auth_configs 凭据（im_get_provider_config，仅 service_role，secret 不出后端）；
//   3. code 换 user_access_token → user_info 取 IM userid（provider 实现）；
//   4. 按 profiles.<provider>_userid 预绑定匹配：
//      未命中 → audit_logins(via='im_<provider>', fail_reason='im_not_bound') + 回 /login 提示；
//   5. 命中且在职 → Supabase Auth admin generateLink(magiclink) + 服务端 verifyOtp：
//      签发标准 Supabase session（与密码登录同一会话 / RLS / 登出链路，不另立体系）；
//   6. 成功写 audit_logins(via='im_<provider>', success=true)。
//
// 安全边界：service role key 仅服务端读取；session cookie 经 @supabase/ssr 正常写入；
// 凭据明文只在本函数作用域内出现，绝不进入响应体 / 日志。

import { createServerClient } from "@supabase/ssr";
import {
  createClient as createSupabaseClient,
  type SupabaseClient,
} from "@supabase/supabase-js";
import { cookies } from "next/headers";
import { NextResponse, type NextRequest } from "next/server";

import type { ImCredentials, ImProvider } from "./provider";
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

/** service role 客户端：未配置返回 null（调用方按失败处理，不抛 500 细节） */
function createServiceRoleClient(): SupabaseClient | null {
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

  const code = searchParams.get("code");
  if (!code) {
    return fail("im_failed");
  }

  const service = createServiceRoleClient();
  if (!service) {
    console.error(`[im/${provider.id}] 缺少 SUPABASE_SERVICE_ROLE_KEY`);
    return fail("im_failed");
  }

  const auth = createRouteAuthClient(cookieStore, request);

  const { data: config, error: configError } = await service.rpc(
    "im_get_provider_config",
    { p_provider: provider.id },
  );
  if (
    configError ||
    !config ||
    config.enabled !== true ||
    !config.credentials
  ) {
    console.error(
      `[im/${provider.id}] 厂商配置不可用`,
      configError?.message ?? "未启用或凭据缺失",
    );
    return fail("im_unavailable");
  }

  let accessToken: string;
  try {
    ({ accessToken } = await provider.exchangeCode({
      credentials: config.credentials as ImCredentials,
      code,
      redirectUri,
    }));
  } catch (error) {
    console.error(`[im/${provider.id}] code 换 token 失败`, error);
    return fail("im_failed");
  }

  let imUserId: string | null;
  try {
    ({ imUserId } = await provider.fetchUser({ accessToken }));
  } catch (error) {
    console.error(`[im/${provider.id}] 获取用户信息失败`, error);
    return fail("im_failed");
  }
  if (!imUserId) {
    console.error(
      `[im/${provider.id}] 未取得 userid（检查应用权限是否包含 user_id 字段）`,
    );
    return fail("im_failed");
  }

  /** 登录留痕（ADR-002 通道）：失败不阻断登录交互 */
  const audit = async (success: boolean, failReason: string | null) => {
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

  // 预绑定匹配：只认 profiles.<provider>_userid，不按邮箱 / 手机号兜底（ADR-003 §1）
  const { data: profile, error: profileError } = await service
    .from("profiles")
    .select("id, status")
    .eq(`${provider.id}_userid`, imUserId)
    .maybeSingle();

  if (profileError) {
    console.error(`[im/${provider.id}] 绑定查询失败`, profileError.message);
    return fail("im_failed");
  }
  if (!profile) {
    await audit(false, "im_not_bound");
    return fail("im_not_bound");
  }
  if (profile.status !== "active") {
    await audit(false, "user_banned");
    return fail("im_banned");
  }

  // 取权威邮箱 + Auth 层封禁检查（profiles.status 之外的兜底）
  const { data: userData, error: userError } =
    await service.auth.admin.getUserById(profile.id);
  const email = userData?.user?.email;
  const bannedUntil = userData?.user?.banned_until;
  if (userError || !email) {
    await audit(false, "other");
    return fail("im_failed");
  }
  if (bannedUntil && new Date(bannedUntil).getTime() > Date.now()) {
    await audit(false, "user_banned");
    return fail("im_banned");
  }

  // 会话签发：admin generateLink(magiclink) → 服务端 verifyOtp
  // 与密码登录同一 GoTrue 会话体系；service role 只用于生成链接，不直签 session。
  const { data: link, error: linkError } =
    await service.auth.admin.generateLink({ type: "magiclink", email });
  const hashedToken = link?.properties?.hashed_token;
  if (linkError || !hashedToken) {
    console.error(
      `[im/${provider.id}] 会话链接生成失败`,
      linkError?.message ?? "缺少 hashed_token",
    );
    await audit(false, "other");
    return fail("im_failed");
  }

  const { error: verifyError } = await auth.auth.verifyOtp({
    type: "magiclink",
    token_hash: hashedToken,
  });
  if (verifyError) {
    console.error(`[im/${provider.id}] 会话签发失败`, verifyError.message);
    await audit(false, "other");
    return fail("im_failed");
  }

  await audit(true, null);

  return NextResponse.redirect(new URL("/", imCallbackBase(request)));
}
