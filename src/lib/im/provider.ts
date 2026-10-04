// IM 登录厂商注册表（工单 im/002，ADR-003 §7：飞书先行；im/004 注册企业微信；im/005 注册钉钉）。
//
// 厂商协议逻辑（授权 URL 构造 / code 换 token / userinfo 取 userid）不在 Next.js：
// im/002 修复后全部下沉到 Postgres（飞书 app.im_build_authorize_url / app.im_exchange_code /
// app.im_fetch_userid；企业微信 app.im_wecom_*，im/004；钉钉 app.im_dingtalk_*，im/005），
// 经 public.im_start_auth / public.im_handle_callback 薄包装按 provider 分派调用 ——
// 凭据解密与出站均不出库（INDEX 规则 10、ADR-001 全局禁 service_role）。
// 本文件只保留「已接入厂商」注册表与 WebView UA 识别：路由据此校验 URL 段，
// 未接入一律按不可用处理。

export type ImProviderId = "feishu" | "wecom" | "dingtalk";

export interface ImProvider {
  readonly id: ImProviderId;
}

export const feishuProvider: ImProvider = { id: "feishu" };
export const wecomProvider: ImProvider = { id: "wecom" };
export const dingtalkProvider: ImProvider = { id: "dingtalk" };

const REGISTRY: Partial<Record<ImProviderId, ImProvider>> = {
  feishu: feishuProvider,
  wecom: wecomProvider,
  dingtalk: dingtalkProvider,
};

/** 按 URL 段取厂商；未接入 / 未知返回 null（路由按不可用处理） */
export function getImProvider(id: string): ImProvider | null {
  return REGISTRY[id as ImProviderId] ?? null;
}

/**
 * 免登模式 state 前缀（IM 端内 WebView 专用）：start 路由注入。
 * im_start_auth / im_handle_callback 签名不可变，客户端类型经 state 前缀传给 Postgres
 * （企业微信见 app.im_wecom_build_authorize_url（im/004）；钉钉端内 / 端外同一授权端点，
 * 前缀在 app.im_dingtalk_build_authorize_url（im/005）被接受并留作模式标记）。
 * state 自身仍是一次性随机 + httpOnly cookie 绑定，前缀只是授权端点模式标记。
 */
const IM_MOBILE_STATE_PREFIX = "m.";

/** 企业微信内嵌 WebView（iOS / Android / 桌面客户端 UA 均含 wxwork）→ 走免登端点 */
export function isWecomWebView(userAgent: string | null): boolean {
  return /wxwork/i.test(userAgent ?? "");
}

/** 钉钉端内 WebView（UA 形如 … AliApp(DingTalk/7.x) …）→ 端内免登，与 PC 共用授权端点 */
export function isDingTalkWebView(userAgent: string | null): boolean {
  return /\bdingtalk\b/i.test(userAgent ?? "");
}

/** state 前缀：IM 内嵌 WebView 中免登模式标记；其余厂商返回空串 */
export function imStartStatePrefix(
  provider: ImProvider,
  userAgent: string | null,
): string {
  const mobile =
    (provider.id === "wecom" && isWecomWebView(userAgent)) ||
    (provider.id === "dingtalk" && isDingTalkWebView(userAgent));
  return mobile ? IM_MOBILE_STATE_PREFIX : "";
}

/**
 * IM 内嵌 WebView 厂商识别（proxy.ts 自动免登用；仅飞书 / 钉钉）：
 * 命中返回厂商 id，否则 null。企业微信不在此列 —— App 内未登录时进登录页「扫码」Tab
 * （start 路由按 wxwork UA 自动切免登端点，im/004 设计）。
 */
export function detectImWebViewProvider(
  userAgent: string | null,
): "feishu" | "dingtalk" | null {
  const ua = userAgent ?? "";
  if (/\b(?:lark|feishu)\b/i.test(ua)) {
    return "feishu";
  }
  if (isDingTalkWebView(ua)) {
    return "dingtalk";
  }
  return null;
}
