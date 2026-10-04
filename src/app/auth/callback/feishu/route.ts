// 飞书扫码登录回调（im/002）：薄路由，编排逻辑见 src/lib/im/callback.ts。
// 飞书开发者后台需登记 Redirect URL：<NEXT_PUBLIC_IM_CALLBACK_BASE>/auth/callback/feishu

import type { NextRequest } from "next/server";

import { handleImCallback } from "@/lib/im/callback";
import { feishuProvider } from "@/lib/im/provider";

export async function GET(request: NextRequest) {
  return handleImCallback(request, feishuProvider);
}
