"use client";

// 工作台 · 我的通知（dashboard/003）：消费 message 公开 RPC
// recent_notifications / mark_all_read / unread_count（与 /message/inbox 同源）。

import * as React from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { InboxIcon, Loader2Icon, MailOpenIcon } from "lucide-react";
import { toast } from "sonner";
import { cn } from "cn";

import { sourceModuleLabel } from "@/components/approval/approval-utils";
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
import { useIsMobile } from "@/hooks/use-mobile";
import type { Database } from "@/lib/database.types";
import { translateMessageErrorMessage } from "@/lib/dictionaries";
import { notifyUnreadCountChanged } from "@/lib/message-events";
import { createClient } from "@/lib/supabase/client";

const NOTIFICATION_LIMIT = 20;
const INBOX_ROUTE = "/message/inbox";

type MessageRow =
  Database["public"]["Functions"]["recent_notifications"]["Returns"][number];

const isUnread = (row: MessageRow) => row.read_at === null;

const sourceLabel = (module: string | null) =>
  module ? sourceModuleLabel(module) : "系统";

const formatDateTime = (value: string) =>
  new Date(value).toLocaleString("zh-CN", { hour12: false });

export function DashboardNotifications() {
  const isMobile = useIsMobile();
  const router = useRouter();
  const [rows, setRows] = React.useState<MessageRow[]>([]);
  const [unreadCount, setUnreadCount] = React.useState<number | null>(0);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [markingAll, setMarkingAll] = React.useState(false);
  const requestIdRef = React.useRef(0);

  const load = React.useCallback(async () => {
    const requestId = ++requestIdRef.current;
    setLoading(true);
    setError(null);

    const supabase = createClient();
    const [listResult, unreadResult] = await Promise.all([
      supabase.rpc("recent_notifications", { p_limit: NOTIFICATION_LIMIT }),
      supabase.rpc("unread_count"),
    ]);
    if (requestId !== requestIdRef.current) {
      return;
    }

    if (listResult.error) {
      setError(listResult.error.message);
      setRows([]);
    } else {
      setRows(listResult.data ?? []);
    }
    if (!unreadResult.error) {
      setUnreadCount(unreadResult.data ?? 0);
    } else if (!listResult.error) {
      // unread_count 单独失败：用当前页未读行兜底计数，按钮禁用状态随之同步
      setUnreadCount((listResult.data ?? []).filter(isUnread).length);
    } else {
      setUnreadCount(null);
    }
    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const handleMarkAllRead = async () => {
    setMarkingAll(true);
    const { data, error: markError } =
      await createClient().rpc("mark_all_read");
    setMarkingAll(false);

    if (markError) {
      toast.error(translateMessageErrorMessage(markError.message));
      return;
    }
    toast.success(`已将 ${data ?? 0} 条通知标记为已读`);
    setUnreadCount(0);
    notifyUnreadCountChanged();
    void load();
  };

  return (
    <div className="flex flex-col gap-2 p-0 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-sm text-muted-foreground">
              未读 {unreadCount ?? "—"} 条
            </span>
            <Button
              variant="outline"
              onClick={() => void handleMarkAllRead()}
              disabled={markingAll || unreadCount === 0}
              className="h-11 flex-1 lg:h-8 lg:flex-none"
            >
              {markingAll ? (
                <Loader2Icon className="animate-spin" data-icon="inline-start" />
              ) : (
                <MailOpenIcon data-icon="inline-start" />
              )}
              全部标已读
            </Button>
            <Button
              variant="outline"
              asChild
              className="h-11 flex-1 sm:ml-auto lg:h-8 lg:flex-none"
            >
              <Link href={INBOX_ROUTE}>前往站内信</Link>
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
                加载失败：{translateMessageErrorMessage(error)}
              </p>
              <Button
                variant="outline"
                onClick={() => void load()}
                className="h-11 lg:h-8"
              >
                重试
              </Button>
            </div>
          ) : rows.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <InboxIcon className="size-8 opacity-60" />
              <span>暂无通知</span>
            </div>
          ) : isMobile ? (
            <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
              {rows.map((row) => (
                <Link
                  key={row.id}
                  href={INBOX_ROUTE}
                  className="relative flex w-full flex-col gap-2 rounded-xl border bg-card p-3 pl-4 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                >
                  {isUnread(row) ? (
                    <span
                      aria-hidden
                      className="absolute inset-y-3 left-0 w-1 rounded-r-full bg-primary"
                    />
                  ) : null}
                  <div className="flex items-start justify-between gap-3">
                    <span
                      className={cn(
                        "line-clamp-1",
                        isUnread(row) && "font-semibold",
                      )}
                    >
                      {row.title}
                    </span>
                    {isUnread(row) ? <Badge>未读</Badge> : null}
                  </div>
                  <p className="line-clamp-2 text-sm text-muted-foreground">
                    {row.body || "—"}
                  </p>
                  <div className="flex items-center justify-between gap-4 text-xs text-muted-foreground">
                    <span>{sourceLabel(row.source_module)}</span>
                    <span>{formatDateTime(row.created_at)}</span>
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
                    <TableHead className="text-center">摘要</TableHead>
                    <TableHead className="text-center">来源模块</TableHead>
                    <TableHead className="text-center">时间</TableHead>
                    <TableHead className="text-center">状态</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {rows.map((row) => (
                    <TableRow
                      key={row.id}
                      className="cursor-pointer"
                      role="link"
                      tabIndex={0}
                      onClick={() => router.push(INBOX_ROUTE)}
                      onKeyDown={(event) => {
                        if (event.target !== event.currentTarget) {
                          return;
                        }
                        if (event.key === "Enter" || event.key === " ") {
                          event.preventDefault();
                          router.push(INBOX_ROUTE);
                        }
                      }}
                    >
                      <TableCell className="relative text-center">
                        {isUnread(row) ? (
                          <span
                            aria-hidden
                            className="absolute inset-y-1 left-0 w-1 rounded-r-full bg-primary"
                          />
                        ) : null}
                        <span
                          className={cn(
                            "line-clamp-1 inline-block max-w-72 align-middle",
                            isUnread(row) && "font-semibold",
                          )}
                        >
                          {row.title}
                        </span>
                      </TableCell>
                      <TableCell className="text-center">
                        <span className="line-clamp-1 inline-block max-w-72 align-middle text-muted-foreground">
                          {row.body || "—"}
                        </span>
                      </TableCell>
                      <TableCell className="text-center">
                        <Badge
                          variant="outline"
                          className="text-muted-foreground"
                        >
                          {sourceLabel(row.source_module)}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-center text-xs whitespace-nowrap text-muted-foreground">
                        {formatDateTime(row.created_at)}
                      </TableCell>
                      <TableCell className="text-center">
                        {isUnread(row) ? (
                          <Badge>未读</Badge>
                        ) : (
                          <Badge
                            variant="outline"
                            className="text-muted-foreground"
                          >
                            已读
                          </Badge>
                        )}
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
