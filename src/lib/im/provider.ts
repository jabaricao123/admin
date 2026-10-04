// IM 登录厂商注册表（工单 im/002，ADR-003 §7：飞书先行；im/004 注册企业微信，钉钉留扩展位）。
//
// 厂商协议逻辑（授权 URL 构造 / code 换 token / userinfo 取 userid）不在 Next.js：
// im/002 修复后全部下沉到 Postgres（飞书 app.im_build_authorize_url / app.im_exchange_code /
// app.im_fetch_userid；企业微信 app.im_wecom_*，im/004），经 public.im_start_auth /
// public.im_handle_callback 薄包装按 provider 分派调用 —— 凭据解密与出站均不出库
// （INDEX 规则 10、ADR-001 全局禁 service_role）。
// 本文件只保留「已接入厂商」注册表：路由据此校验 URL 段，未接入一律按不可用处理。

export type ImProviderId = "feishu" | "wecom" | "dingtalk";

export interface ImProvider {
  readonly id: ImProviderId;
}

export const feishuProvider: ImProvider = { id: "feishu" };
export const wecomProvider: ImProvider = { id: "wecom" };

const REGISTRY: Partial<Record<ImProviderId, ImProvider>> = {
  feishu: feishuProvider,
  wecom: wecomProvider,
  // im/005 钉钉：在 DB 内实现对应厂商适配后在此注册。
};

/** 按 URL 段取厂商；未接入 / 未知返回 null（路由按不可用处理） */
export function getImProvider(id: string): ImProvider | null {
  return REGISTRY[id as ImProviderId] ?? null;
}

/**
 * 免登模式 state 前缀（企业微信专用）：start 路由在「IM 内嵌 WebView」时注入。
 * im_start_auth / im_handle_callback 签名不可变，客户端类型经 state 前缀传给 Postgres
 * （见迁移 20261006160000_im_wecom_login.sql 的 app.im_wecom_build_authorize_url）。
 * state 自身仍是一次性随机 + httpOnly cookie 绑定，前缀只是授权端点模式标记。
 */
const IM_MOBILE_STATE_PREFIX = "m.";

/** 企业微信内嵌 WebView（iOS / Android / 桌面客户端 UA 均含 wxwork）→ 走免登端点 */
export function isWecomWebView(userAgent: string | null): boolean {
  return /wxwork/i.test(userAgent ?? "");
}

/** state 前缀：仅企业微信在 IM 内嵌 WebView 中需要切换授权端点，其余厂商返回空串 */
export function imStartStatePrefix(
  provider: ImProvider,
  userAgent: string | null,
): string {
  return provider.id === "wecom" && isWecomWebView(userAgent)
    ? IM_MOBILE_STATE_PREFIX
    : "";
}
