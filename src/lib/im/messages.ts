// IM 登录回调错误码 → 用户文案（im/002；im/004 起按启用厂商渲染展示名）。
// 回调路由重定向 /login?error=<code>，登录页与登录表单共用本映射，避免两处漂移。

import { BANNED_ACCOUNT_MESSAGE } from "@/lib/dictionaries";

/** 已接入的 IM 厂商展示名；登录页据此决定是否渲染「扫码登录」Tab（im/004 企业微信、im/005 钉钉） */
export const IM_PROVIDER_LABELS: Record<string, string> = {
  feishu: "飞书",
  wecom: "企业微信",
  dingtalk: "钉钉",
};

/** 厂商未知（查询失败 / 配置刚切换）时的通用文案，不出现「未绑定 undefined 账号」 */
const GENERIC_MESSAGES: Record<string, string> = {
  im_not_bound: "账号未绑定，请联系管理员",
  im_state_invalid: "扫码登录已失效，请重新扫码",
  im_denied: "已取消授权",
  im_banned: BANNED_ACCOUNT_MESSAGE,
  im_unavailable: "当前未启用扫码登录",
  im_failed: "扫码登录失败，请稍后重试或联系管理员",
};

const LABELED_TEMPLATES: Record<string, (label: string) => string> = {
  im_not_bound: (label) => `未绑定${label}账号，请联系管理员`,
  im_state_invalid: () => "扫码登录已失效，请重新扫码",
  im_denied: (label) => `已取消${label}授权`,
  im_banned: () => BANNED_ACCOUNT_MESSAGE,
  im_unavailable: (label) => `当前未启用${label}登录`,
  im_failed: (label) => `${label}登录失败，请稍后重试或联系管理员`,
};

export function imLoginErrorMessage(
  code: string | null | undefined,
  provider?: string | null,
): string | null {
  if (!code) {
    return null;
  }
  const label = provider ? IM_PROVIDER_LABELS[provider] : undefined;
  if (!label) {
    return GENERIC_MESSAGES[code] ?? GENERIC_MESSAGES.im_failed;
  }
  const template = LABELED_TEMPLATES[code] ?? LABELED_TEMPLATES.im_failed;
  return template(label);
}
