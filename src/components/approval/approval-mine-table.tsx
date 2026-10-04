"use client";

import * as React from "react";
import {
  BellRingIcon,
  FileClockIcon,
  Loader2Icon,
  SearchIcon,
  Undo2Icon,
} from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetFooter,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { useIsMobile } from "@/hooks/use-mobile";
import type { Database } from "@/lib/database.types";
import {
  APPROVAL_INSTANCE_STATUS_BADGE_CLASSES,
  APPROVAL_INSTANCE_STATUS_LABELS,
  APPROVAL_INSTANCE_STATUS_OPTIONS,
  asApprovalInstanceStatus,
  translateApprovalErrorMessage,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

import { ApprovalDetailSections, useApprovalDetail } from "./approval-detail";
import {
  APPROVAL_PAGE_SIZE,
  TIME_RANGE_OPTIONS,
  formatDateTime,
  formatRemaining,
  sourceModuleLabel,
  urgeThrottleRemainingMs,
  withinTimeRange,
  type TimeRange,
} from "./approval-utils";

const ALL = "all";

type MineRow =
  Database["public"]["Functions"]["my_instances"]["Returns"][number];

function InstanceStatusBadge({ status }: { status: string }) {
  const value = asApprovalInstanceStatus(status);
  return (
    <Badge
      variant="outline"
      className={APPROVAL_INSTANCE_STATUS_BADGE_CLASSES[value]}
    >
      {APPROVAL_INSTANCE_STATUS_LABELS[value]}
    </Badge>
  );
}

function nodeLabel(row: MineRow): string {
  return row.instance_status === "running" ? `第 ${row.current_seq} 节点` : "—";
}

function assigneeLabel(row: MineRow): string {
  if (row.instance_status !== "running" || row.current_task_status !== "pending") {
    return "—";
  }
  return row.current_assignee_name ?? "未指定";
}

export function ApprovalMineTable() {
  const isMobile = useIsMobile();
  const [rows, setRows] = React.useState<MineRow[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [search, setSearch] = React.useState("");
  const [statusFilter, setStatusFilter] = React.useState(ALL);
  const [moduleFilter, setModuleFilter] = React.useState(ALL);
  const [timeRange, setTimeRange] = React.useState<TimeRange>("all");
  const [page, setPage] = React.useState(1);
  const [detailRow, setDetailRow] = React.useState<MineRow | null>(null);
  const [acting, setActing] = React.useState(false);
  const [urging, setUrging] = React.useState(false);
  const [urgedAt, setUrgedAt] = React.useState<string | null>(null);
  const requestIdRef = React.useRef(0);

  const load = React.useCallback(async (options?: { silent?: boolean }) => {
    const requestId = ++requestIdRef.current;
    if (!options?.silent) {
      setLoading(true);
    }
    setError(null);

    const { data, error: listError } = await createClient().rpc(
      "my_instances",
      { p_limit: 200 },
    );
    if (requestId !== requestIdRef.current) {
      return;
    }
    if (listError) {
      setError(listError.message);
      setRows([]);
    } else {
      setRows(data ?? []);
    }
    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  React.useEffect(() => {
    setPage(1);
  }, [search, statusFilter, moduleFilter, timeRange]);

  const moduleOptions = React.useMemo(() => {
    const options = Array.from(
      new Set(rows.map((row) => row.module).filter(Boolean)),
    );
    options.sort((a, b) => a.localeCompare(b, "zh-CN"));
    return options;
  }, [rows]);

  const filtered = React.useMemo(() => {
    const keyword = search.trim().toLowerCase();
    return rows.filter((row) => {
      if (statusFilter !== ALL && row.instance_status !== statusFilter) {
        return false;
      }
      if (moduleFilter !== ALL && row.module !== moduleFilter) {
        return false;
      }
      if (!withinTimeRange(row.created_at, timeRange)) {
        return false;
      }
      if (keyword && !row.title.toLowerCase().includes(keyword)) {
        return false;
      }
      return true;
    });
  }, [rows, search, statusFilter, moduleFilter, timeRange]);

  const pageCount = Math.max(1, Math.ceil(filtered.length / APPROVAL_PAGE_SIZE));
  const currentPage = Math.min(page, pageCount);
  const pagedRows = filtered.slice(
    (currentPage - 1) * APPROVAL_PAGE_SIZE,
    currentPage * APPROVAL_PAGE_SIZE,
  );
  const hasActiveFilters =
    search.trim() !== "" ||
    statusFilter !== ALL ||
    moduleFilter !== ALL ||
    timeRange !== "all";

  const openDetail = (row: MineRow) => {
    setDetailRow(row);
    setUrgedAt(null);
  };

  const closeDetail = () => {
    setDetailRow(null);
    setUrgedAt(null);
  };

  const { detail, loading: detailLoading, error: detailError } =
    useApprovalDetail(detailRow?.instance_id ?? null);

  const lastUrgedAt =
    urgedAt ?? detail?.last_urged_at ?? detailRow?.last_urged_at ?? null;
  const urgeRemaining = urgeThrottleRemainingMs(lastUrgedAt);
  const canOperate =
    detailRow !== null &&
    asApprovalInstanceStatus(detailRow.instance_status) === "running" &&
    detailRow.current_task_status === "pending";

  const handleWithdraw = async () => {
    if (!detailRow) {
      return;
    }
    if (
      !window.confirm(
        `确定撤回「${detailRow.title}」？撤回后流程终止且不可恢复。`,
      )
    ) {
      return;
    }

    setActing(true);
    const { error: withdrawError } = await createClient().rpc(
      "withdraw_instance",
      { p_instance_id: detailRow.instance_id },
    );
    setActing(false);

    if (withdrawError) {
      toast.error(translateApprovalErrorMessage(withdrawError.message));
      void load({ silent: true });
      return;
    }
    toast.success("已撤回");
    closeDetail();
    void load();
  };

  const handleUrge = async () => {
    if (!detailRow) {
      return;
    }
    setUrging(true);
    const { data, error: urgeError } = await createClient().rpc(
      "urge_instance",
      { p_instance_id: detailRow.instance_id },
    );
    setUrging(false);

    if (urgeError) {
      toast.error(translateApprovalErrorMessage(urgeError.message));
      return;
    }

    const nextUrgedAt = data?.last_urged_at ?? new Date().toISOString();
    setUrgedAt(nextUrgedAt);
    setRows((prev) =>
      prev.map((row) =>
        row.instance_id === detailRow.instance_id
          ? { ...row, last_urged_at: nextUrgedAt }
          : row,
      ),
    );
    toast.success("已催办，已通知当前处理人");
  };

  const emptyText = "暂无发起的审批";

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-wrap items-center gap-2">
            <div className="relative flex-1 sm:max-w-xs">
              <SearchIcon className="absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder="搜索标题"
                className="h-11 pl-8 text-base lg:h-8 lg:text-sm"
                aria-label="搜索标题"
              />
            </div>
            <Select value={statusFilter} onValueChange={setStatusFilter}>
              <SelectTrigger
                className="w-full sm:w-32 min-h-11 lg:min-h-8"
                aria-label="按状态筛选"
              >
                <SelectValue placeholder="全部状态" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL}>全部状态</SelectItem>
                {APPROVAL_INSTANCE_STATUS_OPTIONS.map((option) => (
                  <SelectItem key={option.value} value={option.value}>
                    {option.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Select value={moduleFilter} onValueChange={setModuleFilter}>
              <SelectTrigger
                className="w-full sm:w-36 min-h-11 lg:min-h-8"
                aria-label="按来源模块筛选"
              >
                <SelectValue placeholder="全部来源" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL}>全部来源</SelectItem>
                {moduleOptions.map((module) => (
                  <SelectItem key={module} value={module}>
                    {sourceModuleLabel(module)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Select
              value={timeRange}
              onValueChange={(value) => setTimeRange(value as TimeRange)}
            >
              <SelectTrigger
                className="w-full sm:w-32 min-h-11 lg:min-h-8"
                aria-label="按提交时间筛选"
              >
                <SelectValue placeholder="全部时间" />
              </SelectTrigger>
              <SelectContent>
                {TIME_RANGE_OPTIONS.map((option) => (
                  <SelectItem key={option.value} value={option.value}>
                    {option.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          {loading ? (
            <div className="flex flex-col gap-2">
              {Array.from({ length: 5 }).map((_, index) => (
                <Skeleton key={index} className="h-12 w-full" />
              ))}
            </div>
          ) : error ? (
            <div className="flex flex-col items-center gap-2 py-8 text-sm">
              <p className="text-destructive">
                加载失败：{translateApprovalErrorMessage(error)}
              </p>
              <Button variant="outline" onClick={() => void load()}>
                重试
              </Button>
            </div>
          ) : filtered.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <FileClockIcon className="size-8 opacity-60" />
              {hasActiveFilters ? (
                <>
                  <span>未找到匹配的审批</span>
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => {
                      setSearch("");
                      setStatusFilter(ALL);
                      setModuleFilter(ALL);
                      setTimeRange("all");
                    }}
                  >
                    清除筛选
                  </Button>
                </>
              ) : (
                <span>{emptyText}</span>
              )}
            </div>
          ) : isMobile ? (
            <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
              {pagedRows.map((row) => (
                <MineCard
                  key={row.instance_id}
                  row={row}
                  onOpen={() => openDetail(row)}
                />
              ))}
            </div>
          ) : (
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="text-center">标题</TableHead>
                    <TableHead className="text-center">当前节点</TableHead>
                    <TableHead className="text-center">当前处理人</TableHead>
                    <TableHead className="text-center">状态</TableHead>
                    <TableHead className="text-center">提交时间</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {pagedRows.map((row) => (
                    <TableRow
                      key={row.instance_id}
                      className="cursor-pointer"
                      tabIndex={0}
                      onClick={() => openDetail(row)}
                      onKeyDown={(event) => {
                        if (event.key === "Enter" || event.key === " ") {
                          event.preventDefault();
                          openDetail(row);
                        }
                      }}
                    >
                      <TableCell className="text-center">
                        <span className="line-clamp-1 inline-block max-w-72 align-middle font-medium">
                          {row.title}
                        </span>
                      </TableCell>
                      <TableCell className="text-center">
                        {nodeLabel(row)}
                      </TableCell>
                      <TableCell className="text-center">
                        {assigneeLabel(row)}
                      </TableCell>
                      <TableCell className="text-center">
                        <InstanceStatusBadge status={row.instance_status} />
                      </TableCell>
                      <TableCell className="text-center text-xs whitespace-nowrap text-muted-foreground">
                        {formatDateTime(row.created_at)}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}

          {!loading && !error && filtered.length > 0 ? (
            <div className="flex items-center justify-between gap-2 text-sm text-muted-foreground">
              <span>
                共 {filtered.length} 条 · 第 {currentPage} / {pageCount} 页
              </span>
              <div className="flex items-center gap-2">
                <Button
                  variant="outline"
                  disabled={currentPage <= 1 || loading}
                  onClick={() => setPage(currentPage - 1)}
                  className="h-11 px-4 lg:h-8 lg:px-3"
                >
                  上一页
                </Button>
                <Button
                  variant="outline"
                  disabled={currentPage >= pageCount || loading}
                  onClick={() => setPage(currentPage + 1)}
                  className="h-11 px-4 lg:h-8 lg:px-3"
                >
                  下一页
                </Button>
              </div>
            </div>
          ) : null}
        </CardContent>
      </Card>

      <Sheet
        open={detailRow !== null}
        onOpenChange={(open) => {
          if (!open) {
            closeDetail();
          }
        }}
      >
        <SheetContent
          side="right"
          className="w-full sm:max-w-[480px]"
        >
          {detailRow ? (
            <>
              <SheetHeader>
                <SheetTitle className="pr-8">{detailRow.title}</SheetTitle>
                <SheetDescription className="flex flex-wrap items-center gap-2 pt-1">
                  <span>{sourceModuleLabel(detailRow.module)}</span>
                  <span aria-hidden>·</span>
                  <span>{formatDateTime(detailRow.created_at)}</span>
                  <InstanceStatusBadge status={detailRow.instance_status} />
                </SheetDescription>
              </SheetHeader>
              <ApprovalDetailSections
                detail={detail}
                loading={detailLoading}
                error={detailError}
              />
              {canOperate ? (
                <SheetFooter>
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <span className="text-xs text-muted-foreground">
                      {urgeRemaining > 0
                        ? `催办节流中，剩余 ${formatRemaining(urgeRemaining)}`
                        : "同单据 2 小时内仅可催办一次"}
                    </span>
                    <div className="flex items-center gap-2">
                      <Button
                        variant="outline"
                        onClick={() => void handleWithdraw()}
                        disabled={acting || urging}
                      >
                        <Undo2Icon data-icon="inline-start" />
                        撤回
                      </Button>
                      <Button
                        onClick={() => void handleUrge()}
                        disabled={acting || urging || urgeRemaining > 0}
                      >
                        {urging ? (
                          <Loader2Icon
                            className="animate-spin"
                            data-icon="inline-start"
                          />
                        ) : (
                          <BellRingIcon data-icon="inline-start" />
                        )}
                        催办
                      </Button>
                    </div>
                  </div>
                </SheetFooter>
              ) : null}
            </>
          ) : null}
        </SheetContent>
      </Sheet>
    </div>
  );
}

function MineCard({ row, onOpen }: { row: MineRow; onOpen: () => void }) {
  return (
    <button
      type="button"
      data-slot="approval-mine-card"
      onClick={onOpen}
      className="flex w-full flex-col gap-2 rounded-xl border bg-card p-3 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
    >
      <div className="flex items-start justify-between gap-3">
        <span className="min-w-0 truncate font-medium">{row.title}</span>
        <InstanceStatusBadge status={row.instance_status} />
      </div>
      <div className="flex flex-col gap-1.5 text-sm">
        <div className="flex items-center justify-between gap-4">
          <span className="text-muted-foreground">当前节点</span>
          <span>{nodeLabel(row)}</span>
        </div>
        <div className="flex items-center justify-between gap-4">
          <span className="text-muted-foreground">当前处理人</span>
          <span>{assigneeLabel(row)}</span>
        </div>
        <div className="flex items-center justify-between gap-4">
          <span className="text-muted-foreground">提交时间</span>
          <span className="tabular-nums">{formatDateTime(row.created_at)}</span>
        </div>
      </div>
    </button>
  );
}
