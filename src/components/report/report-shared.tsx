"use client";

// 报表中心 · 预置报表共享 UI：图表/表格切换、加载/错误/空态。
// 空态显式（图标 + 文案），移动端图表降级为表格（各报表内用 useIsMobile 强制 table）。

import type { LucideIcon } from "lucide-react";
import { InboxIcon, RefreshCwIcon } from "lucide-react";

import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";

export type ReportViewMode = "chart" | "table";

/** 图表/表格切换（移动端建议由调用方强制 table） */
export function ViewToggle({
  value,
  onChange,
}: {
  value: ReportViewMode;
  onChange: (value: ReportViewMode) => void;
}) {
  return (
    <ToggleGroup
      type="single"
      value={value}
      onValueChange={(next) => {
        if (next === "chart" || next === "table") {
          onChange(next);
        }
      }}
      variant="outline"
      className="w-full sm:w-auto"
      aria-label="图表 / 表格切换"
    >
      <ToggleGroupItem
        value="chart"
        className="h-11 flex-1 px-3 lg:h-8 lg:flex-none"
      >
        图表
      </ToggleGroupItem>
      <ToggleGroupItem
        value="table"
        className="h-11 flex-1 px-3 lg:h-8 lg:flex-none"
      >
        表格
      </ToggleGroupItem>
    </ToggleGroup>
  );
}

/** 加载骨架 */
export function ReportLoadingSkeleton({ rows = 5 }: { rows?: number }) {
  return (
    <div className="flex flex-col gap-2">
      {Array.from({ length: rows }).map((_, index) => (
        <Skeleton key={index} className="h-12 w-full" />
      ))}
    </div>
  );
}

/** 查询错误 + 重试 */
export function ReportErrorState({
  message,
  onRetry,
}: {
  message: string;
  onRetry: () => void;
}) {
  return (
    <div className="flex flex-col items-center gap-2 py-8 text-sm">
      <p className="text-destructive">加载失败：{message}</p>
      <Button variant="outline" onClick={onRetry}>
        <RefreshCwIcon data-icon="inline-start" />
        重试
      </Button>
    </div>
  );
}

/** 显式空态 */
export function ReportEmptyState({
  icon: Icon = InboxIcon,
  title,
  description,
}: {
  icon?: LucideIcon;
  title: string;
  description?: string;
}) {
  return (
    <div className="flex flex-col items-center gap-2 py-12 text-center text-sm text-muted-foreground">
      <Icon className="size-8 opacity-60" />
      <span>{title}</span>
      {description ? (
        <span className="max-w-md text-xs">{description}</span>
      ) : null}
    </div>
  );
}
