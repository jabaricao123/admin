// 钉钉扫码 / 端内 WebView 免登回调（im/005）：薄路由，编排逻辑见 src/lib/im/callback.ts。
// 钉钉开发者后台需登记（回调域名精确匹配，见 README「钉钉配置步骤」）：
//   - 「钉钉登录与分享 → 回调域名」：<NEXT_PUBLIC_IM_CALLBACK_BASE>/auth/callback/dingtalk

import type { NextRequest } from "next/server";

import { handleImCallback } from "@/lib/im/callback";
import { dingtalkProvider } from "@/lib/im/provider";

export async function GET(request: NextRequest) {
  return handleImCallback(request, dingtalkProvider);
}
