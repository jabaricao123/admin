// IM 登录厂商注册表（工单 im/002，ADR-003 §7：飞书先行，企业微信 / 钉钉留扩展位）。
//
// 厂商协议逻辑（授权 URL 构造 / code 换 token / userinfo 取 userid）不在 Next.js：
// im/002 修复后全部下沉到 Postgres（app.im_build_authorize_url / app.im_exchange_code /
// app.im_fetch_userid，经 public.im_start_auth / public.im_handle_callback 薄包装调用）——
// 凭据解密与出站均不出库（INDEX 规则 10、ADR-001 全局禁 service_role）。
// 本文件只保留「已接入厂商」注册表：路由据此校验 URL 段，未接入一律按不可用处理。

export type ImProviderId = "feishu" | "wecom" | "dingtalk";

export interface ImProvider {
  readonly id: ImProviderId;
}

export const feishuProvider: ImProvider = { id: "feishu" };

const REGISTRY: Partial<Record<ImProviderId, ImProvider>> = {
  feishu: feishuProvider,
  // im/004 企业微信、im/005 钉钉：在 DB 内实现对应厂商适配后在此注册。
};

/** 按 URL 段取厂商；未接入 / 未知返回 null（路由按不可用处理） */
export function getImProvider(id: string): ImProvider | null {
  return REGISTRY[id as ImProviderId] ?? null;
}
