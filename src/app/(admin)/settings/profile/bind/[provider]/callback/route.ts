// 个人中心 · 扫码绑定回调（工单 im/006）
//
// 链路：一次性 state 校验 → im_handle_callback（Postgres 内换 token / 取 userid / 绑定匹配）
//   - 未绑定（im_not_bound）：拿到 im_userid → 以当前登录用户身份调 im_bind_self 写本人绑定；
//   - 已绑定本人：幂等成功（重新扫码不报错）；
//   - 已绑定他人：拒绝（im_bound_other）。
// 解绑不在本流程（ADR-003 §2：用户不可自助解绑，仅 admin 在用户管理操作）。

import { cookies } from "next/headers";
import { NextResponse, type NextRequest } from "next/server";

import { createImBackendClient } from "@/lib/im/backend";
import { imCallbackBase } from "@/lib/im/callback";
import { getImProvider } from "@/lib/im/provider";
import { createClient } from "@/lib/supabase/server";

import {
  imBindStateCookieName,
  IM_BIND_STATE_COOKIE_PATH,
  verifyImState,
} from "../../state";

export async function GET(
  request: NextRequest,
  context: { params: Promise<{ provider: string }> },
) {
  const base = imCallbackBase(request);
  const { provider: providerId } = await context.params;
  const provider = getImProvider(providerId);
  const { searchParams } = new URL(request.url);

  const fail = (error: string) =>
    NextResponse.redirect(new URL(`/settings/profile?error=${error}`, base));

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    return NextResponse.redirect(new URL("/login", base));
  }

  // 一次性 state：读取后立即作废（无论后续成败，重放 / 过期一律拒绝）
  const cookieStore = await cookies();
  const cookieName = imBindStateCookieName(providerId);
  const stateCookie = cookieStore.get(cookieName)?.value;
  cookieStore.set(cookieName, "", {
    path: IM_BIND_STATE_COOKIE_PATH,
    maxAge: 0,
  });

  if (!verifyImState(stateCookie, searchParams.get("state"))) {
    console.error(`[im/${providerId}] 绑定 state 校验失败（缺失 / 不一致 / 过期）`);
    return fail("im_state_invalid");
  }
  if (searchParams.get("error") === "access_denied") {
    return fail("im_denied");
  }

  const code = searchParams.get("code");
  if (!code) {
    return fail("im_failed");
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

  const redirectUri = `${base}/settings/profile/bind/${provider.id}/callback`;
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
      `[im/${provider.id}] 绑定回调处理失败`,
      resultError?.message ?? "响应为空",
    );
    return fail("im_failed");
  }

  if (result.ok === true) {
    // 该 userid 已存在绑定：本人 = 幂等成功，他人 = 拒绝
    return result.user_id === user.id
      ? NextResponse.redirect(new URL(`/settings/profile?bound=${provider.id}`, base))
      : fail("im_bound_other");
  }

  if (
    result.error === "im_not_bound" &&
    typeof result.im_userid === "string"
  ) {
    // 自助绑定（ADR-003 §2）：只写当前登录用户本人行；UNIQUE 冲突由 RPC 返回 23505
    const { error: bindError } = await supabase.rpc("im_bind_self", {
      p_provider: provider.id,
      p_userid: result.im_userid,
    });
    if (bindError) {
      console.error(`[im/${provider.id}] 自助绑定失败`, bindError.message);
      return fail(
        bindError.message.includes("已被其他账号绑定")
          ? "im_bound_other"
          : "im_failed",
      );
    }
    return NextResponse.redirect(
      new URL(`/settings/profile?bound=${provider.id}`, base),
    );
  }

  const errorCode =
    typeof result.error === "string" ? result.error : "im_failed";
  if (errorCode === "im_banned") {
    return fail("im_banned");
  }
  console.error(`[im/${provider.id}] 绑定失败`, errorCode);
  return fail(errorCode === "im_unavailable" ? "im_unavailable" : "im_failed");
}
