// IM 扫码登录 state 防代扫（im/002，ADR-003 §4）：
// - 服务端生成一次性 state（32 字节随机 + 签发时间），随授权跳转发给厂商；
// - 同时写 httpOnly + secure + sameSite=lax cookie（同一浏览器才能完成回调）；
// - 5 分钟过期 + 回调读后立即作废（重放必失败）；不引 Redis（单实例 cookie 足够，
//   多实例部署如需共享状态再升级到 Redis，见 README 说明）。

import { randomBytes, timingSafeEqual } from "node:crypto";

/** state 有效期：5 分钟（与飞书授权码 5 分钟有效期对齐） */
export const IM_STATE_TTL_MS = 5 * 60 * 1000;

/** state cookie 只随回调路径发送，不污染其他请求 */
export const IM_STATE_COOKIE_PATH = "/auth/callback";

export function imStateCookieName(provider: string): string {
  return `im_oauth_state_${provider}`;
}

/** 生成一次性 state：<43 字符 base64url 随机>.<签发毫秒时间戳> */
export function createImState(now: number = Date.now()): string {
  return `${randomBytes(32).toString("base64url")}.${now}`;
}

/** 校验回调 state：cookie 与查询参数一致、未过期；常数时间比较防时序侧信道 */
export function verifyImState(
  cookieValue: string | undefined,
  queryState: string | null,
  now: number = Date.now(),
): boolean {
  if (!cookieValue || !queryState) {
    return false;
  }

  const separator = cookieValue.lastIndexOf(".");
  if (separator <= 0) {
    return false;
  }

  const issuedAt = Number(cookieValue.slice(separator + 1));
  if (!Number.isSafeInteger(issuedAt)) {
    return false;
  }

  const age = now - issuedAt;
  if (age < 0 || age > IM_STATE_TTL_MS) {
    return false;
  }

  const cookieState = Buffer.from(cookieValue, "utf8");
  const queryBytes = Buffer.from(queryState, "utf8");
  return (
    cookieState.length > 0 &&
    cookieState.length === queryBytes.length &&
    timingSafeEqual(cookieState, queryBytes)
  );
}
