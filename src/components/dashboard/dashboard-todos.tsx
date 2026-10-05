"use client";

// 工作台 · 我的待办（dashboard/002）：消费 approval 公开 RPC my_todos（不直查内部表）。
// 「去处理」跳 /approval/todo 并携带 highlight（与站内信 REF_TYPE_ROUTES 同一约定）。

import * as React from "react";
import Link from "next/link";
import { ArrowRightIcon, ListTodoIcon, ShieldCheckIcon } from "lucide-react";

import {
  formatDateTime,
  formatWaiting,
  isOverdue48h,
  sourceModuleLabel,
} from "@/components/approval/approval-utils";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
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
  APPROVAL_TASK_STATUS_BADGE_CLASSES,
  APPROVAL_TASK_STATUS_LABELS,
  asApprovalInstanceStatus,
  asApprovalTaskStatus,
  translateApprovalErrorMessage,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

const TODO_LIMIT = 20;

type TodoRow = Database["public"]["Functions"]["my_todos"]["Returns"][number];
type TodoTab = "pending" | "done";

const overdueBadgeClass =
  "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300";

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

function TaskStatusBadge({ status }: { status: string }) {
  const value = asApprovalTaskStatus(status);
  return (
    <Badge
      variant="outline"
      className={APPROVAL_TASK_STATUS_BADGE_CLASSES[value]}
    >
      {APPROVAL_TASK_STATUS_LABELS[value]}
    </Badge>
  );
}

function todoHref(row: TodoRow): string {
  return `/approval/todo?highlight=${encodeURIComponent(row.instance_id)}`;
}

export function DashboardTodos() {
  const isMobile = useIsMobile();
  const [tab, setTab] = React.useState<TodoTab>("pending");
  const [rows, setRows] = React.useState<TodoRow[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const requestIdRef = React.useRef(0);

  const load = React.useCallback(async () => {
    const requestId = ++requestIdRef.current;
    setLoading(true);
    setError(null);

    const { data, error: listError } = await createClient().rpc("my_todos", {
      p_pending: tab === "pending",
      p_limit: TODO_LIMIT,
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
  }, [tab]);

  React.useEffect(() => {
    void load();
  }, [load]);

  const emptyText = tab === "pending" ? "暂无待办" : "暂无已办记录";

  return (
    <div className="flex flex-col gap-0.5 p-0 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-wrap items-center gap-2">
            <ToggleGroup
              type="single"
              value={tab}
              onValueChange={(value) => {
                if (value === "pending" || value === "done") {
                  setTab(value);
                }
              }}
              variant="outline"
              className="w-full sm:w-auto"
              aria-label="待办筛选"
            >
              <ToggleGroupItem
                value="pending"
                className="h-11 flex-1 px-3 lg:h-8 lg:flex-none"
              >
                待办
              </ToggleGroupItem>
              <ToggleGroupItem
                value="done"
                className="h-11 flex-1 px-3 lg:h-8 lg:flex-none"
              >
                已办
              </ToggleGroupItem>
            </ToggleGroup>
            <div className="flex items-center gap-2 sm:ml-auto">
              <Button
                variant="outline"
                asChild
                className="h-11 flex-1 lg:h-8 lg:flex-none"
              >
                <Link href="/approval/todo">
                  <ShieldCheckIcon data-icon="inline-start" />
                  前往审批中心
                </Link>
              </Button>
            </div>
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
          ) : rows.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <ListTodoIcon className="size-8 opacity-60" />
              <span>{emptyText}</span>
            </div>
          ) : isMobile ? (
            <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
              {rows.map((row) => (
                <Link
                  key={row.task_id}
                  href={todoHref(row)}
                  className="flex w-full flex-col gap-2 rounded-xl border bg-card p-3 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                >
                  <div className="flex items-start justify-between gap-3">
                    <span className="line-clamp-1 font-medium">{row.title}</span>
                    {tab === "pending" ? (
                      <InstanceStatusBadge status={row.instance_status} />
                    ) : (
                      <TaskStatusBadge status={row.task_status} />
                    )}
                  </div>
                  <div className="flex flex-col gap-1.5 text-sm">
                    <div className="flex items-center justify-between gap-4">
                      <span className="text-muted-foreground">来源模块</span>
                      <span>{sourceModuleLabel(row.module)}</span>
                    </div>
                    <div className="flex items-center justify-between gap-4">
                      <span className="text-muted-foreground">发起人</span>
                      <span>{row.initiator_name ?? "—"}</span>
                    </div>
                    <div className="flex items-center justify-between gap-4">
                      <span className="text-muted-foreground">
                        {tab === "pending" ? "等待时长" : "处理时间"}
                      </span>
                      {tab === "pending" ? (
                        <span className="inline-flex items-center gap-1.5">
                          {formatWaiting(row.created_at)}
                          {isOverdue48h(row.created_at) ? (
                            <Badge
                              variant="outline"
                              className={overdueBadgeClass}
                            >
                              超48h
                            </Badge>
                          ) : null}
                        </span>
                      ) : (
                        <span className="tabular-nums">
                          {formatDateTime(row.acted_at)}
                        </span>
                      )}
                    </div>
                  </div>
                </Link>
              ))}
            </div>
          ) : (
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="text-center">标题</TableHead>
                    <TableHead className="text-center">来源模块</TableHead>
                    <TableHead className="text-center">发起人</TableHead>
                    <TableHead className="text-center">
                      {tab === "pending" ? "等待时长" : "处理时间"}
                    </TableHead>
                    <TableHead className="text-center">
                      {tab === "pending" ? "状态" : "结果"}
                    </TableHead>
                    <TableHead className="text-center">
                      {tab === "pending" ? "操作" : null}
                    </TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {rows.map((row) => (
                    <TableRow key={row.task_id}>
                      <TableCell className="text-center">
                        <Link
                          href={todoHref(row)}
                          className="line-clamp-1 inline-block max-w-72 align-middle font-medium hover:text-primary hover:underline"
                        >
                          {row.title}
                        </Link>
                      </TableCell>
                      <TableCell className="text-center">
                        <Badge
                          variant="outline"
                          className="text-muted-foreground"
                        >
                          {sourceModuleLabel(row.module)}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-center">
                        {row.initiator_name ?? "—"}
                      </TableCell>
                      <TableCell className="text-center">
                        {tab === "pending" ? (
                          <span className="inline-flex items-center gap-1.5 whitespace-nowrap">
                            {formatWaiting(row.created_at)}
                            {isOverdue48h(row.created_at) ? (
                              <Badge
                                variant="outline"
                                className={overdueBadgeClass}
                              >
                                超48h
                              </Badge>
                            ) : null}
                          </span>
                        ) : (
                          <span className="text-xs whitespace-nowrap text-muted-foreground">
                            {formatDateTime(row.acted_at)}
                          </span>
                        )}
                      </TableCell>
                      <TableCell className="text-center">
                        {tab === "pending" ? (
                          <InstanceStatusBadge status={row.instance_status} />
                        ) : (
                          <TaskStatusBadge status={row.task_status} />
                        )}
                      </TableCell>
                      <TableCell className="text-center">
                        {tab === "pending" ? (
                          <Button variant="outline" size="sm" asChild>
                            <Link href={todoHref(row)}>
                              去处理
                              <ArrowRightIcon data-icon="inline-end" />
                            </Link>
                          </Button>
                        ) : null}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
