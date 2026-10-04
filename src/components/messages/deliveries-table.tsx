"use client";

// 发送记录页面（message/008）：工具栏多筛选 + Table + 详情 Sheet
// （渲染快照 / 渠道响应摘要 / 失败重发）。
// 数据源：message_deliveries（RLS：admin 全量；普通用户仅本人记录）。
// 重发：resend_delivery RPC（admin；仅 failed 记录，更新原行 attempts+1）。

import * as React from "react";
import {
  BellRingIcon,
  HistoryIcon,
  InboxIcon,
  Loader2Icon,
  MailIcon,
  RotateCcwIcon,
  SendIcon,
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
import { translateErrorMessage } from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

const ALL = "all";
const PAGE_SIZE = 20;
/** 首版内存筛选：取最近 500 条（v2 数据量上来后改服务端筛选 + 分页） */
const FETCH_LIMIT = 500;

type DeliveryRow = Database["public"]["Tables"]["message_deliveries"]["Row"];
type DeliveryStatus = "success" | "failed" | "degraded";
type DeliveryChannel = "inbox" | "email" | "push" | "sms";

const STATUS_LABELS: Record<DeliveryStatus, string> = {
  success: "成功",
  failed: "失败",
  degraded: "降级",
};

/** 状态 Badge：成功绿 / 失败红 / 降级黄（history.md 界面规格） */
const STATUS_BADGE_CLASSES: Record<DeliveryStatus, string> = {
  success:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  failed:
    "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300",
  degraded:
    "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300",
};

const CHANNEL_LABELS: Record<DeliveryChannel, string> = {
  inbox: "站内信",
  email: "邮件",
  push: "推送",
  sms: "短信",
};

const CHANNEL_ICONS: Record<
  DeliveryChannel,
  React.ComponentType<React.SVGProps<SVGSVGElement>>
> = {
  inbox: InboxIcon,
  email: MailIcon,
  push: BellRingIcon,
  sms: SendIcon,
};

const STATUS_OPTIONS: DeliveryStatus[] = ["success", "failed", "degraded"];
const CHANNEL_OPTIONS: DeliveryChannel[] = ["inbox", "email", "push", "sms"];

const formatDateTime = (value: string) =>
  new Date(value).toLocaleString("zh-CN", { hour12: false });

const asStatus = (value: string): DeliveryStatus =>
  value === "success" || value === "failed" || value === "degraded"
    ? value
    : "failed";

const asChannel = (value: string): DeliveryChannel =>
  value === "inbox" || value === "email" || value === "push" || value === "sms"
    ? value
    : "inbox";

function StatusBadge({ status }: { status: string }) {
  const key = asStatus(status);
  return (
    <Badge variant="outline" className={STATUS_BADGE_CLASSES[key]}>
      {STATUS_LABELS[key]}
    </Badge>
  );
}

function ChannelBadge({ channel }: { channel: string }) {
  const key = asChannel(channel);
  const Icon = CHANNEL_ICONS[key];
  return (
    <Badge variant="outline" className="text-muted-foreground">
      <Icon className="size-3" data-icon="inline-start" />
      {CHANNEL_LABELS[key]}
    </Badge>
  );
}

function MetaItem({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-0.5">
      <span className="text-xs text-muted-foreground">{label}</span>
      <span className="text-sm break-all">{value}</span>
    </div>
  );
}

export function DeliveriesTable({ isAdmin }: { isAdmin: boolean }) {
  const isMobile = useIsMobile();

  const [rows, setRows] = React.useState<DeliveryRow[]>([]);
  const [recipientNames, setRecipientNames] = React.useState<
    Record<string, string>
  >({});
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);

  const [recipientFilter, setRecipientFilter] = React.useState(ALL);
  const [eventFilter, setEventFilter] = React.useState(ALL);
  const [channelFilter, setChannelFilter] = React.useState(ALL);
  const [statusFilter, setStatusFilter] = React.useState(ALL);
  const [dateFrom, setDateFrom] = React.useState("");
  const [dateTo, setDateTo] = React.useState("");
  const [page, setPage] = React.useState(1);

  const [detail, setDetail] = React.useState<DeliveryRow | null>(null);
  const [resending, setResending] = React.useState(false);

  const load = React.useCallback(async (options?: { silent?: boolean }) => {
    if (!options?.silent) {
      setLoading(true);
    }
    setError(null);

    const supabase = createClient();
    const { data, error: listError } = await supabase
      .from("message_deliveries")
      .select("*")
      .order("created_at", { ascending: false })
      .order("id", { ascending: false })
      .limit(FETCH_LIMIT);

    if (listError) {
      setError(listError.message);
      setRows([]);
      setLoading(false);
      return;
    }

    const list = data ?? [];
    setRows(list);

    // 收件人展示名：按需补查 profiles（RLS 允许内部角色读通讯录；仅本人时补查自身）
    const ids = Array.from(new Set(list.map((row) => row.recipient_id)));
    if (ids.length > 0) {
      const { data: profiles } = await supabase
        .from("profiles")
        .select("id, full_name")
        .in("id", ids);

      if (profiles) {
        setRecipientNames((prev) => {
          const next = { ...prev };
          for (const profile of profiles) {
            if (profile.full_name) {
              next[profile.id] = profile.full_name;
            }
          }
          return next;
        });
      }
    }
    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  React.useEffect(() => {
    setPage(1);
  }, [recipientFilter, eventFilter, channelFilter, statusFilter, dateFrom, dateTo]);

  const recipientLabel = React.useCallback(
    (id: string) => recipientNames[id]?.trim() || `${id.slice(0, 8)}…`,
    [recipientNames],
  );

  const recipientOptions = React.useMemo(
    () =>
      Array.from(new Set(rows.map((row) => row.recipient_id))).sort((a, b) =>
        recipientLabel(a).localeCompare(recipientLabel(b), "zh-CN"),
      ),
    [rows, recipientLabel],
  );

  const eventOptions = React.useMemo(
    () =>
      Array.from(new Set(rows.map((row) => row.event_key))).sort((a, b) =>
        a.localeCompare(b, "zh-CN"),
      ),
    [rows],
  );

  const filtered = React.useMemo(() => {
    const fromTime = dateFrom ? new Date(`${dateFrom}T00:00:00`).getTime() : null;
    const toTime = dateTo ? new Date(`${dateTo}T23:59:59.999`).getTime() : null;

    return rows.filter((row) => {
      if (recipientFilter !== ALL && row.recipient_id !== recipientFilter) {
        return false;
      }
      if (eventFilter !== ALL && row.event_key !== eventFilter) {
        return false;
      }
      if (channelFilter !== ALL && row.channel !== channelFilter) {
        return false;
      }
      if (statusFilter !== ALL && row.status !== statusFilter) {
        return false;
      }
      const time = new Date(row.created_at).getTime();
      if (fromTime !== null && time < fromTime) {
        return false;
      }
      if (toTime !== null && time > toTime) {
        return false;
      }
      return true;
    });
  }, [rows, recipientFilter, eventFilter, channelFilter, statusFilter, dateFrom, dateTo]);

  const pageCount = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const currentPage = Math.min(page, pageCount);
  const pagedRows = filtered.slice(
    (currentPage - 1) * PAGE_SIZE,
    currentPage * PAGE_SIZE,
  );
  const hasActiveFilters =
    recipientFilter !== ALL ||
    eventFilter !== ALL ||
    channelFilter !== ALL ||
    statusFilter !== ALL ||
    dateFrom !== "" ||
    dateTo !== "";

  const resetFilters = () => {
    setRecipientFilter(ALL);
    setEventFilter(ALL);
    setChannelFilter(ALL);
    setStatusFilter(ALL);
    setDateFrom("");
    setDateTo("");
  };

  const handleResend = async () => {
    if (!detail) {
      return;
    }
    setResending(true);
    const { data, error: resendError } = await createClient().rpc(
      "resend_delivery",
      { p_delivery_id: detail.id },
    );
    setResending(false);

    if (resendError) {
      toast.error(translateErrorMessage(resendError.message));
      return;
    }

    const updated = data as DeliveryRow | null;
    if (updated) {
      setDetail(updated);
      setRows((prev) =>
        prev.map((row) =>
          row.id === updated.id && row.created_at === updated.created_at
            ? updated
            : row,
        ),
      );
      toast.success(
        updated.status === "success"
          ? "重发成功"
          : `重发完成（当前状态：${STATUS_LABELS[asStatus(updated.status)]}）`,
      );
    }
    void load({ silent: true });
  };

  const renderList = () => {
    if (loading) {
      return (
        <div className="flex flex-col gap-2">
          {Array.from({ length: 5 }).map((_, index) => (
            <Skeleton key={index} className="h-12 w-full" />
          ))}
        </div>
      );
    }
    if (error) {
      return (
        <div className="flex flex-col items-center gap-2 py-8 text-sm">
          <p className="text-destructive">
            加载失败：{translateErrorMessage(error)}
          </p>
          <Button variant="outline" onClick={() => void load()}>
            重试
          </Button>
        </div>
      );
    }
    if (pagedRows.length === 0) {
      return (
        <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
          <HistoryIcon className="size-8 opacity-60" />
          {hasActiveFilters ? (
            <>
              <span>未找到匹配的发送记录</span>
              <Button variant="outline" size="sm" onClick={resetFilters}>
                清除筛选
              </Button>
            </>
          ) : (
            <span>暂无发送记录</span>
          )}
        </div>
      );
    }

    if (isMobile) {
      return (
        <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
          {pagedRows.map((row) => (
            <button
              key={`${row.id}-${row.created_at}`}
              type="button"
              onClick={() => setDetail(row)}
              className="flex w-full flex-col gap-2 rounded-xl border bg-card p-3 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
            >
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <div className="truncate font-medium">
                    {recipientLabel(row.recipient_id)}
                  </div>
                  <div className="truncate text-xs leading-tight text-muted-foreground">
                    {formatDateTime(row.created_at)}
                  </div>
                </div>
                <StatusBadge status={row.status} />
              </div>
              <div className="flex flex-col gap-1.5 text-sm">
                <div className="flex items-center justify-between gap-4">
                  <span className="text-muted-foreground">事件</span>
                  <span className="truncate">{row.event_key}</span>
                </div>
                <div className="flex items-center justify-between gap-4">
                  <span className="text-muted-foreground">渠道</span>
                  <ChannelBadge channel={row.channel} />
                </div>
                <div className="flex items-start justify-between gap-4">
                  <span className="shrink-0 text-muted-foreground">错误摘要</span>
                  <span className="text-right text-xs break-all">
                    {row.error ?? "—"}
                  </span>
                </div>
              </div>
            </button>
          ))}
        </div>
      );
    }

    return (
      <div className="overflow-x-auto">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="text-center">时间</TableHead>
              <TableHead className="text-center">收件人</TableHead>
              <TableHead className="text-center">事件</TableHead>
              <TableHead className="text-center">渠道</TableHead>
              <TableHead className="text-center">状态</TableHead>
              <TableHead className="text-center">错误摘要</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {pagedRows.map((row) => (
              <TableRow
                key={`${row.id}-${row.created_at}`}
                className="cursor-pointer"
                tabIndex={0}
                onClick={() => setDetail(row)}
                onKeyDown={(event) => {
                  if (event.target !== event.currentTarget) {
                    return;
                  }
                  if (event.key === "Enter" || event.key === " ") {
                    event.preventDefault();
                    setDetail(row);
                  }
                }}
              >
                <TableCell className="text-center text-xs whitespace-nowrap text-muted-foreground">
                  {formatDateTime(row.created_at)}
                </TableCell>
                <TableCell className="text-center">
                  {recipientLabel(row.recipient_id)}
                </TableCell>
                <TableCell className="text-center font-mono text-xs">
                  {row.event_key}
                </TableCell>
                <TableCell className="text-center">
                  <ChannelBadge channel={row.channel} />
                </TableCell>
                <TableCell className="text-center">
                  <StatusBadge status={row.status} />
                </TableCell>
                <TableCell className="max-w-80 text-center text-xs text-muted-foreground">
                  <span className="line-clamp-2">{row.error ?? "—"}</span>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    );
  };

  const detailChannel = detail ? asChannel(detail.channel) : null;

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-wrap items-center gap-2">
            <Select value={recipientFilter} onValueChange={setRecipientFilter}>
              <SelectTrigger
                className="h-11 w-full sm:w-36 lg:h-8"
                aria-label="按收件人筛选"
              >
                <SelectValue placeholder="全部收件人" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL}>全部收件人</SelectItem>
                {recipientOptions.map((id) => (
                  <SelectItem key={id} value={id}>
                    {recipientLabel(id)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Select value={eventFilter} onValueChange={setEventFilter}>
              <SelectTrigger
                className="h-11 w-full sm:w-44 lg:h-8"
                aria-label="按事件筛选"
              >
                <SelectValue placeholder="全部事件" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL}>全部事件</SelectItem>
                {eventOptions.map((eventKey) => (
                  <SelectItem key={eventKey} value={eventKey}>
                    {eventKey}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Select value={channelFilter} onValueChange={setChannelFilter}>
              <SelectTrigger
                className="h-11 w-full sm:w-28 lg:h-8"
                aria-label="按渠道筛选"
              >
                <SelectValue placeholder="全部渠道" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL}>全部渠道</SelectItem>
                {CHANNEL_OPTIONS.map((channel) => (
                  <SelectItem key={channel} value={channel}>
                    {CHANNEL_LABELS[channel]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Select value={statusFilter} onValueChange={setStatusFilter}>
              <SelectTrigger
                className="h-11 w-full sm:w-28 lg:h-8"
                aria-label="按状态筛选"
              >
                <SelectValue placeholder="全部状态" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL}>全部状态</SelectItem>
                {STATUS_OPTIONS.map((status) => (
                  <SelectItem key={status} value={status}>
                    {STATUS_LABELS[status]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Input
              type="date"
              value={dateFrom}
              onChange={(event) => setDateFrom(event.target.value)}
              className="h-11 w-full text-base sm:w-36 lg:h-8 lg:text-sm"
              aria-label="起始日期"
            />
            <span className="hidden text-xs text-muted-foreground sm:inline">
              至
            </span>
            <Input
              type="date"
              value={dateTo}
              onChange={(event) => setDateTo(event.target.value)}
              className="h-11 w-full text-base sm:w-36 lg:h-8 lg:text-sm"
              aria-label="结束日期"
            />
            {hasActiveFilters ? (
              <Button
                variant="ghost"
                onClick={resetFilters}
                className="h-11 lg:h-8"
              >
                清除筛选
              </Button>
            ) : null}
          </div>

          {renderList()}

          {!loading && !error && filtered.length > 0 ? (
            <div className="flex items-center justify-between gap-2 text-sm text-muted-foreground">
              <span>
                {hasActiveFilters
                  ? `匹配 ${filtered.length} 条（共 ${rows.length} 条）· 第 ${currentPage} / ${pageCount} 页`
                  : `共 ${filtered.length} 条 · 第 ${currentPage} / ${pageCount} 页`}
              </span>
              <div className="flex items-center gap-2">
                <Button
                  variant="outline"
                  disabled={currentPage <= 1}
                  onClick={() => setPage(currentPage - 1)}
                  className="h-11 px-4 lg:h-8 lg:px-3"
                >
                  上一页
                </Button>
                <Button
                  variant="outline"
                  disabled={currentPage >= pageCount}
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
            setDetail(null);
          }
        }}
      >
        <SheetContent
          side="right"
          className="w-full sm:max-w-[480px]"
        >
          <SheetHeader>
            <SheetTitle>
              {detail && detailChannel
                ? `${CHANNEL_LABELS[detailChannel]}投递 · ${STATUS_LABELS[asStatus(detail.status)]}`
                : "投递详情"}
            </SheetTitle>
            <SheetDescription>
              {detail
                ? `记录 #${detail.id} · ${formatDateTime(detail.created_at)}`
                : "发送记录详情"}
            </SheetDescription>
          </SheetHeader>
          <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-4">
            {detail ? (
              <>
                <div className="grid grid-cols-2 gap-3 rounded-lg border p-3">
                  <MetaItem
                    label="收件人"
                    value={recipientLabel(detail.recipient_id)}
                  />
                  <MetaItem label="事件" value={detail.event_key} />
                  <MetaItem
                    label="渠道"
                    value={<ChannelBadge channel={detail.channel} />}
                  />
                  <MetaItem
                    label="状态"
                    value={<StatusBadge status={detail.status} />}
                  />
                  <MetaItem label="尝试次数" value={detail.attempts} />
                  <MetaItem label="消息 ID" value={detail.message_id} />
                  <MetaItem
                    label="幂等键"
                    value={
                      <span className="font-mono text-xs">
                        {detail.idempotency_key}
                      </span>
                    }
                  />
                </div>

                <section className="flex flex-col gap-2">
                  <h3 className="text-sm font-medium">渲染快照</h3>
                  <div className="flex flex-col gap-2 rounded-lg border p-3">
                    <div className="text-sm font-medium">
                      {detail.rendered_subject || "（无标题）"}
                    </div>
                    <p className="text-sm leading-relaxed whitespace-pre-wrap text-muted-foreground">
                      {detail.rendered_body || "（无正文）"}
                    </p>
                  </div>
                </section>

                <section className="flex flex-col gap-2">
                  <h3 className="text-sm font-medium">渠道响应</h3>
                  <div className="flex flex-col gap-3 rounded-lg border p-3">
                    <MetaItem label="错误 / 降级原因" value={detail.error ?? "—"} />
                    <MetaItem label="响应摘要" value={detail.response ?? "—"} />
                  </div>
                </section>
              </>
            ) : null}
          </div>
          <SheetFooter className="flex-row flex-wrap items-center justify-end gap-2">
            {isAdmin && detail?.status === "failed" ? (
              <Button onClick={() => void handleResend()} disabled={resending}>
                {resending ? (
                  <Loader2Icon
                    className="animate-spin"
                    data-icon="inline-start"
                  />
                ) : (
                  <RotateCcwIcon data-icon="inline-start" />
                )}
                重发
              </Button>
            ) : null}
          </SheetFooter>
        </SheetContent>
      </Sheet>
    </div>
  );
}
