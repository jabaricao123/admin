// IM 登录厂商抽象（工单 im/002，ADR-003 §7：飞书先行，抽象留好企业微信 / 钉钉扩展位）。
//
// 职责边界：
// - 本文件只定义厂商契约与注册表，不碰 DB / 会话 / 审计；
// - 各厂商实现（feishu.ts，im/004 的 wecom.ts，im/005 的 dingtalk.ts）
//   负责「授权 URL 构造 → code 换 token → token 换 userid」三段纯逻辑；
// - 编排（state cookie、凭据读取、绑定匹配、session 签发、audit_logins 打点）
//   见 src/lib/im/callback.ts，对厂商无感。

import { feishuProvider } from "./feishu";

export type ImProviderId = "feishu" | "wecom" | "dingtalk";

/** 解密后的厂商凭据（字段由厂商自解释，如飞书 app_id / app_secret） */
export type ImCredentials = Record<string, string>;

export interface ImAuthorizeUrlInput {
  credentials: ImCredentials;
  /** 与厂商后台登记完全一致的回调地址 */
  redirectUri: string;
  /** 一次性防代扫 state（本系统生成并落 httpOnly cookie） */
  state: string;
}

export interface ImCodeExchangeInput {
  credentials: ImCredentials;
  code: string;
  redirectUri: string;
}

export interface ImUserIdentity {
  /**
   * 厂商内部 userid，绑定匹配键（对应 profiles.<provider>_userid）。
   * 拿不到（权限未授予等）返回 null，由编排层按失败处理。
   */
  imUserId: string | null;
}

export interface ImProvider {
  readonly id: ImProviderId;
  /** 展示名（登录页 Tab / 二维码按钮） */
  readonly label: string;
  /** 构造 PC 授权页 URL（飞书托管页内含扫码） */
  buildAuthorizeUrl(input: ImAuthorizeUrlInput): string;
  /** 授权码换用户 access_token */
  exchangeCode(input: ImCodeExchangeInput): Promise<{ accessToken: string }>;
  /** access_token 换厂商 userid */
  fetchUser(input: { accessToken: string }): Promise<ImUserIdentity>;
}

const REGISTRY: Partial<Record<ImProviderId, ImProvider>> = {
  feishu: feishuProvider,
  // im/004 企业微信、im/005 钉钉在此注册；注册即可复用
  // /auth/im/[provider]/start 与 callback 编排，无需改路由。
};

/** 按 URL 段取厂商实现；未接入 / 未知返回 null（编排层按不可用处理） */
export function getImProvider(id: string): ImProvider | null {
  return REGISTRY[id as ImProviderId] ?? null;
}
