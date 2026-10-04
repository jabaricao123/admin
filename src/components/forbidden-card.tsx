"use client";

// 403 守卫卡片（各 admin 守卫页复用）：挂载时经 public.record_denied_attempt
// 上报越权尝试（module + 当前路由），留痕为 best-effort，不阻塞卡片呈现。
// 说明：页面在渲染本组件前已做未登录重定向，RPC 以登录会话身份写入；
//       写入侧有 module 白名单、字段截断与同用户 1 分钟 ≤20 条限流。

import * as React from "react";
import { usePathname } from "next/navigation";
import { ShieldXIcon } from "lucide-react";

import { Card, CardContent } from "@/components/ui/card";
import { createClient } from "@/lib/supabase/client";

type ForbiddenCardProps = {
  /** 模块标识（menu_items.module：org/access/audit/system 等） */
  module: string;
  /** 守卫原因文案（例：仅管理员可访问用户管理。） */
  description: string;
};

export function ForbiddenCard({ module, description }: ForbiddenCardProps) {
  const pathname = usePathname();

  React.useEffect(() => {
    // best-effort：留痕失败（网络/限流/会话失效）不影响 403 呈现
    void (async () => {
      try {
        await createClient().rpc("record_denied_attempt", {
          p_module: module,
          p_route: pathname,
          p_reason: "forbidden",
        });
      } catch {
        // 忽略：denied 留痕不是安全边界，仅用于审计可见性
      }
    })();
  }, [module, pathname]);

  return (
    <div className="flex flex-1 items-center justify-center p-6">
      <Card className="max-w-md">
        <CardContent className="flex flex-col items-center gap-3 py-10 text-center">
          <ShieldXIcon className="size-10 text-muted-foreground" />
          <div className="text-lg font-medium">403 · 无访问权限</div>
          <p className="text-sm text-muted-foreground">{description}</p>
        </CardContent>
      </Card>
    </div>
  );
}
