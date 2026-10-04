// PC 扫码登录 ticket 轮询模式共享约定（im/007）。
//
// 分流依据：回调路由以 state 是否以 `qr.` 前缀判定 ticket 模式。该前缀与既有 state
// cookie 值无碰撞 —— createImState() 的随机段是 base64url（字母 / 数字 / - / _，不含点），
// 因此 cookie state 的首个点必然出现在第 43 位（随机段之后），或紧随 `m.` 免登前缀，
// 不可能出现 `qr.` 前缀。

/** ticket 前缀（服务端 app.im_qr_new_ticket 生成：`qr.` + 64 位随机 hex） */
export const IM_QR_TICKET_PREFIX = "qr.";

/** ticket 格式（与 public.im_qr_tickets 的 CHECK 对齐） */
export const IM_QR_TICKET_PATTERN = /^qr\.[A-Za-z0-9_-]{43,64}$/;

/** PC 端轮询间隔：验收要求手机确认后 2 秒内自动跳转，1 秒轮询留出跳转余量 */
export const IM_QR_POLL_INTERVAL_MS = 1000;

/** 轮询返回的状态（不包含任何身份信息） */
export type ImQrPollStatus =
  | "pending"
  | "logged_in"
  | "expired"
  | "consumed"
  | "invalid";

export function isImQrTicket(state: string | null | undefined): state is string {
  return typeof state === "string" && IM_QR_TICKET_PATTERN.test(state);
}

/**
 * 浏览器端回调基址：优先 NEXT_PUBLIC_IM_CALLBACK_BASE（与 server 端 imCallbackBase 对齐，
 * 隧道 / 反向代理部署时二者一致），未配置回退当前 origin（本地开发）。
 */
export function imQrCallbackBase(): string {
  const configured = process.env.NEXT_PUBLIC_IM_CALLBACK_BASE?.trim();
  if (configured) {
    return configured.replace(/\/+$/, "");
  }
  return window.location.origin;
}
