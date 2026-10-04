// IM 登录回调错误码 → 用户文案（im/002）。
// 回调路由重定向 /login?error=<code>，登录页与登录表单共用本映射，避免两处漂移。
// 注：当前仅飞书接入（工单 im/002）；im/004 / im/005 接入后可改为按厂商细分文案。

import { BANNED_ACCOUNT_MESSAGE } from "@/lib/dictionaries";

export const IM_LOGIN_ERROR_MESSAGES: Record<string, string> = {
  im_not_bound: "未绑定飞书账号，请联系管理员",
  im_state_invalid: "扫码登录已失效，请重新扫码",
  im_denied: "已取消飞书授权",
  im_banned: BANNED_ACCOUNT_MESSAGE,
  im_unavailable: "当前未启用飞书登录",
  im_failed: "飞书登录失败，请稍后重试或联系管理员",
};

/** 已接入的 IM 厂商展示名；登录页据此决定是否渲染「扫码登录」Tab（im/004 起追加） */
export const IM_PROVIDER_LABELS: Record<string, string> = {
  feishu: "飞书",
};

export function imLoginErrorMessage(
  code: string | null | undefined,
): string | null {
  if (!code) {
    return null;
  }
  return IM_LOGIN_ERROR_MESSAGES[code] ?? IM_LOGIN_ERROR_MESSAGES.im_failed;
}
