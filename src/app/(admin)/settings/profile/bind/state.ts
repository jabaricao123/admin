// 个人中心 · IM 扫码绑定 state（工单 im/006）
//
// 与登录链路（im/002）同构的一次性 state：32 字节随机 + 签发毫秒，5 分钟过期，
// httpOnly cookie 绑定同一浏览器；差异只在 cookie 名与 path —— 绑定回调位于
// /settings/profile/bind/<provider>/callback，不能复用登录回调的 path=/auth/callback cookie。
// 生成 / 校验逻辑复用 src/lib/im/state.ts，避免两套实现漂移。

import { createImState, IM_STATE_TTL_MS, verifyImState } from "@/lib/im/state";

/** 绑定 state cookie 只随个人中心绑定路由发送 */
export const IM_BIND_STATE_COOKIE_PATH = "/settings/profile";

export const IM_BIND_STATE_TTL_MS = IM_STATE_TTL_MS;

export function imBindStateCookieName(provider: string): string {
  return `im_bind_state_${provider}`;
}

export { createImState, verifyImState };
