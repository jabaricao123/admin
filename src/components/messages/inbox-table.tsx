"use client";

import * as React from "react";
import Link from "next/link";
import {
  ArrowRightIcon,
  InboxIcon,
  Loader2Icon,
  MailIcon,
  MailOpenIcon,
  StarIcon,
} from "lucide-react";
import { toast } from "sonner";
import { cn } from "cn";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
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
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { sourceModuleLabel } from "@/components/approval/approval-utils";
import { useIsMobile } from "@/hooks/use-mobile";
import type { Database } from "@/lib/database.types";
import { translateMessageErrorMessage } from "@/lib/dictionaries";
import { notifyUnreadCountChanged } from "@/lib/message-events";
import { createClient } from "@/lib/supabase/client";

const PAGE_SIZE = 20;
const ALL = "all";

/** 来源模块下拉最多枚举条数（去重后来源数远小于此，防大表全量拉取） */
const SOURCE_OPTIONS_LIMIT = 1000;

type MessageRow = Database["public"]["Tables"]["messages"]["Row"];
type InboxTab = "all" | "unread" | "starred";

/** ref_type → 业务跳转；对应模块上线后在此登记，未登记类型不显示「去处理」 */
const REF_TYPE_ROUTES: Record<string, (refId: string) => string> = {
  approval: (refId) => `/approval/todo?highlight=${encodeURIComponent(refId)}`,
};

const formatDateTime = (value: string) =>
  new Date(value).toLocaleString("zh-CN", { hour12: false });

const isUnread = (row: MessageRow) => row.read_at === null;

/** 来源模块展示名（与审批中心共享字典）；消息侧无来源时回退「系统」 */
const sourceLabel = (module: string | null) =>
  module ? sourceModuleLabel(module) : "系统";

const getRefRoute = (row: MessageRow): string | null => {
  if (!row.ref_type || !row.ref_id) {
    return null;
  }
  const build = REF_TYPE_ROUTES[row.ref_type];
  return build ? build(row.ref_id) : null;
};

export function InboxTable() {
  const isMobile = useIsMobile();
  const [tab, setTab] = React.useState<InboxTab>("all");
  const [sourceFilter, setSourceFilter] = React.useState(ALL);
  const [page, setPage] = React.useState(1);
  const [rows, setRows] = React.useState<MessageRow[]>([]);
  const [total, setTotal] = React.useState(0);
  const [unreadCount, setUnreadCount] = React.useState(0);
  const [sourceOptions, setSourceOptions] = React.useState<string[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [detail, setDetail] = React.useState<MessageRow | null>(null);
  const [acting, setActing] = React.useState(false);
  const [markingAll, setMarkingAll] = React.useState(false);
  const requestIdRef = React.useRef(0);
  const mutatedRef = React.useRef(false);

  /** 未读数与 sidebar / dashboard 同源（unread_count RPC） */
  const refreshUnread = React.useCallback(async () => {
    const { data, error: countError } = await createClient().rpc("unread_count");
    if (!countError) {
      setUnreadCount(data ?? 0);
      notifyUnreadCountChanged();
    }
  }, []);

  const load = React.useCallback(
    async (options?: { silent?: boolean }) => {
      const requestId = ++requestIdRef.current;
      if (!options?.silent) {
        setLoading(true);
      }
      setError(null);

      const supabase = createClient();
      const from = (page - 1) * PAGE_SIZE;
      let query = supabase
        .from("messages")
        .select("*", { count: "exact" })
        .order("created_at", { ascending: false })
        .order("id", { ascending: false })
        .range(from, from + PAGE_SIZE - 1);

      if (tab === "unread") {
        query = query.is("read_at", null);
      } else if (tab === "starred") {
        // TODO(message 后续)：recent_notifications RPC 目前仅支持 p_limit，不支持 starred 过滤，
        // 星标 tab 因此直查 messages 表（RLS 仅本人行）做前端过滤；RPC 增加参数后再切回。
        query = query.eq("starred", true);
      }
      if (sourceFilter !== ALL) {
        query = query.eq("source_module", sourceFilter);
      }

      const [listResult, unreadResult, sourceResult] = await Promise.all([
        query,
        supabase.rpc("unread_count"),
        supabase.from("messages").select("source_module").limit(SOURCE_OPTIONS_LIMIT),
      ]);

      if (requestId !== requestIdRef.current) {
        return;
      }

      if (listResult.error) {
        setError(listResult.error.message);
        setRows([]);
        setTotal(0);
      } else {
        setRows(listResult.data ?? []);
        setTotal(listResult.count ?? 0);
      }

      if (!unreadResult.error) {
        setUnreadCount(unreadResult.data ?? 0);
      }

      if (!sourceResult.error) {
        const options = Array.from(
          new Set(
            (sourceResult.data ?? [])
              .map((item) => item.source_module)
              .filter((value): value is string => Boolean(value)),
          ),
        );
        options.sort((a, b) => a.localeCompare(b, "zh-CN"));
        setSourceOptions(options);
      }

      setLoading(false);
    },
    [page, sourceFilter, tab],
  );

  React.useEffect(() => {
    void load();
  }, [load]);

  const pageCount = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const currentPage = Math.min(page, pageCount);

  // 末页被清空（如批量已读）时回收到有效页
  React.useEffect(() => {
    if (!loading && page > pageCount) {
      setPage(pageCount);
    }
  }, [loading, page, pageCount]);

  const applyUpdated = (updated: MessageRow) => {
    setRows((prev) =>
      prev.map((row) => (row.id === updated.id ? updated : row)),
    );
    setDetail((prev) => (prev && prev.id === updated.id ? updated : prev));
  };

  const changeTab = (value: string) => {
    setTab(value as InboxTab);
    setPage(1);
  };

  const openDetail = (row: MessageRow) => {
    setDetail(row);
    if (isUnread(row)) {
      // 进入即标已读（RPC 幂等；成功后回写未读数）
      void (async () => {
        const { data, error: readError } = await createClient().rpc(
          "mark_notification_read",
          { p_id: row.id },
        );
        if (readError) {
          toast.error(translateMessageErrorMessage(readError.message));
          return;
        }
        if (data) {
          applyUpdated(data);
          mutatedRef.current = true;
          void refreshUnread();
        }
      })();
    }
  };

  const closeDetail = () => {
    setDetail(null);
    if (mutatedRef.current) {
      mutatedRef.current = false;
      void load({ silent: true });
      void refreshUnread();
    }
  };

  const toggleStar = async () => {
    if (!detail) {
      return;
    }
    setActing(true);
    const { data, error: starError } = await createClient().rpc(
      "toggle_notification_star",
      { p_id: detail.id },
    );
    setActing(false);

    if (starError) {
      toast.error(translateMessageErrorMessage(starError.message));
      return;
    }
    if (data) {
      applyUpdated(data);
      mutatedRef.current = true;
      toast.success(data.starred ? "已星标" : "已取消星标");
    }
  };

  const markUnread = async () => {
    if (!detail || !detail.read_at) {
      return;
    }
    setActing(true);
    const { data, error: unreadError } = await createClient().rpc(
      "mark_notification_unread",
      { p_id: detail.id },
    );
    setActing(false);

    if (unreadError) {
      toast.error(translateMessageErrorMessage(unreadError.message));
      return;
    }
    if (data) {
      applyUpdated(data);
      mutatedRef.current = true;
      void refreshUnread();
      toast.success("已标为未读");
    }
  };

  const handleMarkAllRead = async () => {
    setMarkingAll(true);
    const { data, error: markError } =
      await createClient().rpc("mark_all_read");
    setMarkingAll(false);

    if (markError) {
      toast.error(translateMessageErrorMessage(markError.message));
      return;
    }
    toast.success(`已将 ${data ?? 0} 条消息标记为已读`);
    mutatedRef.current = false;
    void load();
    void refreshUnread();
  };

  const detailRefRoute = detail ? getRefRoute(detail) : null;
  const emptyText =
    tab === "unread"
      ? "没有未读消息"
      : tab === "starred"
        ? "暂无星标消息"
        : "暂无站内信";

  return (
    <div className="flex flex-col gap-2 p-0 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
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
              aria-label="收件箱筛选"
            >
              <ToggleGroupItem
                value="all"
                className="h-11 flex-1 px-3 lg:h-8 lg:flex-none"
              >
                全部
              </ToggleGroupItem>
              <ToggleGroupItem
                value="unread"
                className="h-11 flex-1 px-3 lg:h-8 lg:flex-none"
              >
                未读
                {unreadCount > 0
                  ? sourceFilter !== ALL
                    ? `（全部 ${unreadCount}）`
                    : `（${unreadCount}）`
                  : ""}
              </ToggleGroupItem>
              <ToggleGroupItem
                value="starred"
                className="h-11 flex-1 px-3 lg:h-8 lg:flex-none"
              >
                星标
              </ToggleGroupItem>
            </ToggleGroup>
            <Select
              value={sourceFilter}
              onValueChange={(value) => {
                setSourceFilter(value);
                setPage(1);
              }}
            >
              <SelectTrigger
                className="min-h-11 w-full sm:w-44 lg:min-h-8"
                aria-label="按来源模块筛选"
              >
                <SelectValue placeholder="全部来源" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL}>全部来源</SelectItem>
                {sourceOptions.map((module) => (
                  <SelectItem key={module} value={module}>
                    {sourceLabel(module)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <div className="flex items-center gap-2 sm:ml-auto">
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
                加载失败：{translateMessageErrorMessage(error)}
              </p>
              <Button variant="outline" onClick={() => void load()}>
                重试
              </Button>
            </div>
          ) : rows.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <InboxIcon className="size-8 opacity-60" />
              {sourceFilter !== ALL ? (
                <>
                  <span>未找到该来源的消息</span>
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => {
                      setSourceFilter(ALL);
                      setPage(1);
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
              {rows.map((row) => (
                <button
                  key={row.id}
                  type="button"
                  data-slot="message-card"
                  onClick={() => openDetail(row)}
                  className="relative flex w-full flex-col gap-2 rounded-xl border bg-card p-3 pl-4 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                >
                  {isUnread(row) ? (
                    <span
                      aria-hidden
                      className="absolute inset-y-3 left-0 w-1 rounded-r-full bg-primary"
                    />
                  ) : null}
                  <div className="flex items-start justify-between gap-3">
                    <div
                      className={cn(
                        "flex min-w-0 items-center gap-1.5",
                        isUnread(row) && "font-semibold",
                      )}
                    >
                      {row.starred ? (
                        <StarIcon className="size-3.5 shrink-0 fill-current text-primary" />
                      ) : null}
                      <span className="line-clamp-1">{row.title}</span>
                    </div>
                    {isUnread(row) ? <Badge>未读</Badge> : null}
                  </div>
                  <p className="line-clamp-2 text-sm text-muted-foreground">
                    {row.body || "—"}
                  </p>
                  <div className="flex items-center justify-between gap-4 text-xs text-muted-foreground">
                    <span>{sourceLabel(row.source_module)}</span>
                    <span>{formatDateTime(row.created_at)}</span>
                  </div>
                </button>
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
                        {isUnread(row) ? (
                          <span
                            aria-hidden
                            className="absolute inset-y-1 left-0 w-1 rounded-r-full bg-primary"
                          />
                        ) : null}
                        <span
                          className={cn(
                            "inline-flex max-w-72 items-center gap-1.5",
                            isUnread(row) && "font-semibold",
                          )}
                        >
                          {row.starred ? (
                            <StarIcon className="size-3.5 shrink-0 fill-current text-primary" />
                          ) : null}
                          <span className="line-clamp-1">{row.title}</span>
                        </span>
                      </TableCell>
                      <TableCell className="text-center">
                        <span className="line-clamp-1 text-muted-foreground">
                          {row.body || "—"}
                        </span>
                      </TableCell>
                      <TableCell className="text-center">
                        <Badge variant="outline" className="text-muted-foreground">
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

          {!loading && !error && total > 0 ? (
            <div className="flex items-center justify-between gap-2 text-sm text-muted-foreground">
              <span>
                共 {total} 条 · 第 {currentPage} / {pageCount} 页
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
        open={detail !== null}
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
          {detail ? (
            <>
              <SheetHeader>
                <SheetTitle className="flex items-center gap-2 pr-8">
                  {detail.starred ? (
                    <StarIcon className="size-4 shrink-0 fill-current text-primary" />
                  ) : null}
                  <span className="min-w-0">{detail.title}</span>
                </SheetTitle>
                <SheetDescription className="flex flex-wrap items-center gap-2 pt-1">
                  <span>{sourceLabel(detail.source_module)}</span>
                  <span aria-hidden>·</span>
                  <span>{formatDateTime(detail.created_at)}</span>
                  {isUnread(detail) ? (
                    <Badge>未读</Badge>
                  ) : (
                    <Badge variant="outline" className="text-muted-foreground">
                      已读
                    </Badge>
                  )}
                </SheetDescription>
              </SheetHeader>
              <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-4">
                <p className="text-sm leading-relaxed whitespace-pre-wrap">
                  {detail.body || "（无正文）"}
                </p>
              </div>
              <SheetFooter className="flex-row flex-wrap items-center justify-between gap-2">
                <div className="flex flex-wrap items-center gap-2">
                  <Button
                    variant="outline"
                    onClick={() => void toggleStar()}
                    disabled={acting}
                    className="h-11 lg:h-8"
                  >
                    <StarIcon
                      data-icon="inline-start"
                      className={detail.starred ? "fill-current" : undefined}
                    />
                    {detail.starred ? "取消星标" : "星标"}
                  </Button>
                  <Button
                    variant="outline"
                    onClick={() => void markUnread()}
                    disabled={acting || !detail.read_at}
                    className="h-11 lg:h-8"
                  >
                    <MailIcon data-icon="inline-start" />
                    标为未读
                  </Button>
                </div>
                {detailRefRoute ? (
                  <Button asChild className="h-11 lg:h-8">
                    <Link href={detailRefRoute}>
                      去处理
                      <ArrowRightIcon data-icon="inline-end" />
                    </Link>
                  </Button>
                ) : null}
              </SheetFooter>
            </>
          ) : null}
        </SheetContent>
      </Sheet>
    </div>
  );
}
