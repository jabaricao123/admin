"use client";

import * as React from "react";
import { InboxIcon, RefreshCwIcon } from "lucide-react";
import { toast } from "sonner";
import { cn } from "cn";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
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
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { useIsMobile } from "@/hooks/use-mobile";
import type { Database } from "@/lib/database.types";
import {
  APPROVAL_INSTANCE_STATUS_BADGE_CLASSES,
  APPROVAL_INSTANCE_STATUS_LABELS,
  asApprovalInstanceStatus,
  translateApprovalErrorMessage,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

import { ApprovalDetailSections, useApprovalDetail } from "./approval-detail";
import {
  APPROVAL_PAGE_SIZE,
  formatDateTime,
  sourceModuleLabel,
} from "./approval-utils";

const ALL = "all";

type CcRow = Database["public"]["Functions"]["my_ccs"]["Returns"][number];
type CcTab = "unread" | "all";

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

function nodeLabel(row: CcRow): string {
  if (row.instance_status !== "running") {
    return "—";
  }
  const base = `第 ${row.current_seq} 节点`;
  return row.current_assignee_name ? `${base} · ${row.current_assignee_name}` : base;
}

export function ApprovalCcTable() {
  const isMobile = useIsMobile();
  const [tab, setTab] = React.useState<CcTab>("all");
  const [rows, setRows] = React.useState<CcRow[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [moduleFilter, setModuleFilter] = React.useState(ALL);
  const [page, setPage] = React.useState(1);
  const [detailRow, setDetailRow] = React.useState<CcRow | null>(null);
  const requestIdRef = React.useRef(0);
  const mutatedRef = React.useRef(false);

  const load = React.useCallback(
    async (options?: { silent?: boolean }) => {
      const requestId = ++requestIdRef.current;
      if (!options?.silent) {
        setLoading(true);
      }
      setError(null);

      const { data, error: listError } = await createClient().rpc("my_ccs", {
        p_unread: tab === "unread",
      });
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
    },
    [tab],
  );

  React.useEffect(() => {
    void load();
  }, [load]);

  React.useEffect(() => {
    setPage(1);
  }, [tab, moduleFilter]);

  const moduleOptions = React.useMemo(() => {
    const options = Array.from(
      new Set(rows.map((row) => row.module).filter(Boolean)),
    );
    options.sort((a, b) => a.localeCompare(b, "zh-CN"));
    return options;
  }, [rows]);

  const filtered = React.useMemo(
    () =>
      rows.filter(
        (row) => moduleFilter === ALL || row.module === moduleFilter,
      ),
    [rows, moduleFilter],
  );

  const pageCount = Math.max(1, Math.ceil(filtered.length / APPROVAL_PAGE_SIZE));
  const currentPage = Math.min(page, pageCount);
  const pagedRows = filtered.slice(
    (currentPage - 1) * APPROVAL_PAGE_SIZE,
    currentPage * APPROVAL_PAGE_SIZE,
  );

  const changeTab = (value: string) => {
    if (value === "unread" || value === "all") {
      setTab(value);
    }
  };

  /** 进入详情即标记已读（RPC 幂等；同时同步本人通知消息，与 message 未读同源） */
  const openDetail = (row: CcRow) => {
    setDetailRow(row);
    if (row.cc_read_at !== null) {
      return;
    }
    void (async () => {
      const { data, error: readError } = await createClient().rpc(
        "mark_cc_read",
        { p_instance_id: row.instance_id },
      );
      if (readError) {
        toast.error(translateApprovalErrorMessage(readError.message));
        return;
      }
      const readAt = data ?? new Date().toISOString();
      mutatedRef.current = true;
      setRows((prev) =>
        prev.map((item) =>
          item.instance_id === row.instance_id
            ? { ...item, cc_read_at: readAt }
            : item,
        ),
      );
      setDetailRow((prev) =>
        prev && prev.instance_id === row.instance_id
          ? { ...prev, cc_read_at: readAt }
          : prev,
      );
    })();
  };

  const closeDetail = () => {
    setDetailRow(null);
    if (mutatedRef.current) {
      mutatedRef.current = false;
      void load({ silent: true });
    }
  };

  const { detail, loading: detailLoading, error: detailError } =
    useApprovalDetail(detailRow?.instance_id ?? null);

  const emptyText = tab === "unread" ? "没有未读抄送" : "暂无抄送记录";

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardHeader>
          <CardTitle>抄送我的</CardTitle>
          <CardDescription>
            知会类审批只读跟踪，进入详情自动标记已读
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-wrap items-center gap-2">
            <ToggleGroup
              type="single"
              value={tab}
              onValueChange={(value) => {
                if (value) {
                  changeTab(value);
                }
              }}
              variant="outline"
              className="w-full sm:w-auto"
              aria-label="抄送筛选"
            >
              <ToggleGroupItem
                value="unread"
                className="h-11 flex-1 px-3 lg:h-8 lg:flex-none"
              >
                未读
              </ToggleGroupItem>
              <ToggleGroupItem
                value="all"
                className="h-11 flex-1 px-3 lg:h-8 lg:flex-none"
              >
                全部
              </ToggleGroupItem>
            </ToggleGroup>
            <Select value={moduleFilter} onValueChange={setModuleFilter}>
              <SelectTrigger
                className="h-11 w-full sm:w-40 lg:h-8"
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
            <Button
              variant="outline"
              size="icon"
              onClick={() => void load()}
              disabled={loading}
              aria-label="刷新抄送列表"
              className="h-11 w-11 lg:h-8 lg:w-8"
            >
              <RefreshCwIcon className={loading ? "animate-spin" : undefined} />
            </Button>
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
              <InboxIcon className="size-8 opacity-60" />
              {moduleFilter !== ALL ? (
                <>
                  <span>未找到该来源的抄送</span>
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => setModuleFilter(ALL)}
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
              {pagedRows.map((row) => {
                const unread = row.cc_read_at === null;
                return (
                  <button
                    key={row.instance_id}
                    type="button"
                    data-slot="approval-cc-card"
                    onClick={() => openDetail(row)}
                    className="relative flex w-full flex-col gap-2.5 rounded-xl border bg-card p-4 pl-5 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                  >
                    {unread ? (
                      <span
                        aria-hidden
                        className="absolute inset-y-3 left-0 w-1 rounded-r-full bg-primary"
                      />
                    ) : null}
                    <div className="flex items-start justify-between gap-3">
                      <span
                        className={cn(
                          "min-w-0 truncate",
                          unread ? "font-semibold" : "font-medium",
                        )}
                      >
                        {row.title}
                      </span>
                      {unread ? <Badge>未读</Badge> : null}
                    </div>
                    <div className="flex flex-col gap-1.5 text-sm">
                      <div className="flex items-center justify-between gap-4">
                        <span className="text-muted-foreground">发起人</span>
                        <span>{row.initiator_name ?? "—"}</span>
                      </div>
                      <div className="flex items-center justify-between gap-4">
                        <span className="text-muted-foreground">当前节点</span>
                        <span>{nodeLabel(row)}</span>
                      </div>
                      <div className="flex items-center justify-between gap-4">
                        <span className="text-muted-foreground">抄送时间</span>
                        <span className="tabular-nums">
                          {formatDateTime(row.cc_created_at)}
                        </span>
                      </div>
                      <div className="flex items-center justify-between gap-4">
                        <span className="text-muted-foreground">状态</span>
                        <InstanceStatusBadge status={row.instance_status} />
                      </div>
                    </div>
                  </button>
                );
              })}
            </div>
          ) : (
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="text-center">标题</TableHead>
                    <TableHead className="text-center">发起人</TableHead>
                    <TableHead className="text-center">当前节点</TableHead>
                    <TableHead className="text-center">抄送时间</TableHead>
                    <TableHead className="text-center">状态</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {pagedRows.map((row) => {
                    const unread = row.cc_read_at === null;
                    return (
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
                        <TableCell className="relative text-center">
                          {unread ? (
                            <span
                              aria-hidden
                              className="absolute inset-y-1 left-0 w-1 rounded-r-full bg-primary"
                            />
                          ) : null}
                          <span
                            className={cn(
                              "line-clamp-1 inline-block max-w-72 align-middle",
                              unread ? "font-semibold" : "font-medium",
                            )}
                          >
                            {row.title}
                          </span>
                          {unread ? (
                            <Badge className="ml-2 align-middle">未读</Badge>
                          ) : null}
                        </TableCell>
                        <TableCell className="text-center">
                          {row.initiator_name ?? "—"}
                        </TableCell>
                        <TableCell className="text-center">
                          {nodeLabel(row)}
                        </TableCell>
                        <TableCell className="text-center text-xs whitespace-nowrap text-muted-foreground">
                          {formatDateTime(row.cc_created_at)}
                        </TableCell>
                        <TableCell className="text-center">
                          <InstanceStatusBadge status={row.instance_status} />
                        </TableCell>
                      </TableRow>
                    );
                  })}
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
          className="w-[35vw] min-w-[320px] max-w-[480px]"
        >
          {detailRow ? (
            <>
              <SheetHeader>
                <SheetTitle className="pr-8">{detailRow.title}</SheetTitle>
                <SheetDescription className="flex flex-wrap items-center gap-2 pt-1">
                  <span>发起人：{detailRow.initiator_name ?? "—"}</span>
                  <span aria-hidden>·</span>
                  <span>{formatDateTime(detailRow.cc_created_at)}</span>
                  <InstanceStatusBadge status={detailRow.instance_status} />
                </SheetDescription>
              </SheetHeader>
              <ApprovalDetailSections
                detail={detail}
                loading={detailLoading}
                error={detailError}
              />
            </>
          ) : null}
        </SheetContent>
      </Sheet>
    </div>
  );
}
