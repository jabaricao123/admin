// 企业微信扫码 / App 内免登回调（im/004）：薄路由，编排逻辑见 src/lib/im/callback.ts。
// 企业微信后台需登记（均为 <NEXT_PUBLIC_IM_CALLBACK_BASE> 的域名）：
//   - 「企业微信授权登录 → Web 网页」授权回调域（PC 扫码 qrConnect 用）
//   - 「网页授权及 JS-SDK」可信域名（App 内免登 oauth2/authorize 用）

import type { NextRequest } from "next/server";

import { handleImCallback } from "@/lib/im/callback";
import { wecomProvider } from "@/lib/im/provider";

export async function GET(request: NextRequest) {
  return handleImCallback(request, wecomProvider);
}
