// 飞书厂商实现（im/002）。端点以飞书开放平台现行文档为准（2026-10）：
// - 授权页：https://accounts.feishu.cn/open-apis/authen/v1/authorize（OAuth 2.0，client_id + response_type=code）
// - 换 token：https://accounts.feishu.cn/oauth/v3/token（v2 已弃用；v3 为 x-www-form-urlencoded）
// - 用户信息：https://open.feishu.cn/open-apis/authen/v1/user_info（Bearer user_access_token）
//
// 说明：工单正文里的 `open.feishu.cn/open-apis/authen/v1/authorize?app_id=...` 为旧版形态
// （已标记 deprecated），此处按官方现行形态实现；user_info 返回 user_id 需要
// 应用申请权限 `contact:user.employee_id:readonly`（授权 scope 同步声明）。

import type {
  ImAuthorizeUrlInput,
  ImCodeExchangeInput,
  ImCredentials,
  ImProvider,
  ImUserIdentity,
} from "./provider";

const AUTHORIZE_ENDPOINT =
  "https://accounts.feishu.cn/open-apis/authen/v1/authorize";
const TOKEN_ENDPOINT = "https://accounts.feishu.cn/oauth/v3/token";
const USER_INFO_ENDPOINT =
  "https://open.feishu.cn/open-apis/authen/v1/user_info";

/** user_info 返回 user_id（绑定匹配键）所需权限；授权页同步声明 */
export const FEISHU_USER_ID_SCOPE = "contact:user.employee_id:readonly";

function readCredential(credentials: ImCredentials, key: string): string {
  const value = credentials[key];
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`飞书凭据缺少 ${key}，请在 im_auth_configs 中重新配置`);
  }
  return value.trim();
}

async function readJsonBody(
  response: Response,
): Promise<Record<string, unknown> | null> {
  try {
    return (await response.json()) as Record<string, unknown>;
  } catch {
    return null;
  }
}

/** 错误信息只带业务 code/描述，绝不回显 token / secret */
function describeFailure(
  stage: string,
  response: Response,
  body: Record<string, unknown> | null,
): string {
  const code = body?.code ?? response.status;
  const detail =
    body?.error_description ?? body?.msg ?? response.statusText ?? "未知错误";
  return `飞书${stage}失败（code=${String(code)}）：${String(detail)}`;
}

export const feishuProvider: ImProvider = {
  id: "feishu",
  label: "飞书",

  buildAuthorizeUrl({ credentials, redirectUri, state }: ImAuthorizeUrlInput) {
    const url = new URL(AUTHORIZE_ENDPOINT);
    url.searchParams.set("client_id", readCredential(credentials, "app_id"));
    url.searchParams.set("response_type", "code");
    url.searchParams.set("redirect_uri", redirectUri);
    url.searchParams.set("scope", FEISHU_USER_ID_SCOPE);
    url.searchParams.set("state", state);
    return url.toString();
  },

  async exchangeCode({ credentials, code, redirectUri }: ImCodeExchangeInput) {
    const appId = readCredential(credentials, "app_id");
    const appSecret = readCredential(credentials, "app_secret");

    const response = await fetch(TOKEN_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "authorization_code",
        client_id: appId,
        client_secret: appSecret,
        code,
        redirect_uri: redirectUri,
      }),
      cache: "no-store",
    });
    const body = await readJsonBody(response);

    if (!response.ok || !body || body.code !== 0) {
      throw new Error(describeFailure("授权码换 token", response, body));
    }

    const accessToken = body.access_token;
    if (typeof accessToken !== "string" || accessToken === "") {
      throw new Error("飞书授权码换 token 失败：响应缺少 access_token");
    }
    return { accessToken };
  },

  async fetchUser({ accessToken }: { accessToken: string }) {
    const response = await fetch(USER_INFO_ENDPOINT, {
      headers: { Authorization: `Bearer ${accessToken}` },
      cache: "no-store",
    });
    const body = await readJsonBody(response);

    if (!response.ok || !body || body.code !== 0) {
      throw new Error(describeFailure("获取用户信息", response, body));
    }

    const data = (body.data ?? {}) as Record<string, unknown>;
    const userId = data.user_id;
    const identity: ImUserIdentity = {
      imUserId:
        typeof userId === "string" && userId.trim() !== ""
          ? userId.trim()
          : null,
    };
    return identity;
  },
};
