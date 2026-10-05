"use client"

import * as React from "react"
import { CircleAlertIcon } from "lucide-react"

import { cn } from "cn"
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover"

/**
 * 标题后的「说明」图标：点击弹出描述。
 * 描述从卡片内联文字改为收进此弹窗，标题保持可见（DESIGN.md v2.7）。
 */
export function InfoHint({
  children,
  className,
  contentClassName,
}: {
  children: React.ReactNode
  className?: string
  contentClassName?: string
}) {
  return (
    <Popover>
      <PopoverTrigger asChild>
        <button
          type="button"
          aria-label="查看说明"
          onClick={(event) => event.stopPropagation()}
          className={cn(
            "inline-flex size-4 shrink-0 cursor-pointer items-center justify-center rounded-full text-muted-foreground transition-colors hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none",
            className
          )}
        >
          <CircleAlertIcon className="size-3.5" />
        </button>
      </PopoverTrigger>
      <PopoverContent align="start" className={cn("text-muted-foreground", contentClassName)}>
        {children}
      </PopoverContent>
    </Popover>
  )
}
