"use client";

// 调用日志页面（integration/008）：技术排障明细列表 + 筛选（类型/状态码/时间段）
// + 详情 Sheet（request/response excerpt 双栏）+ 导出（report 统一管道，admin 独占源）。
// 数据源 integration_call_logs（按月分区、30 天明细、RLS 仅 admin）；服务端分页/筛选。

import * as React from "react";
import {
  AlertTriangleIcon,
  ArrowDownIcon,
  ArrowUpDownIcon,
  ArrowUpIcon,
  CopyIcon,
  DownloadIcon,
  Loader2Icon,
  ScrollTextIcon,
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
  asCallLogKind,
  CALL_LOG_KIND_BADGE_CLASSES,
  CALL_LOG_KIND_LABELS,
  CALL_STATUS_FILTER_OPTIONS,
  callStatusLabel,
  callStatusCodeBadgeClass,
  translateIntegrationLogsErrorMessage,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type LogRow = Database["public"]["Tables"]["integration_call_logs"]["Row"];
/** 列表不拉 2KB excerpt 列，仅详情按需补拉 */
type LogListRow = Pick<
  LogRow,
  | "id"
  | "created_at"
  | "kind"
  | "key_id"
  | "webhook_id"
  | "method_event"
  | "status_code"
  | "duration_ms"
  | "error"
>;
type LogDetailRow = LogListRow &
  Pick<LogRow, "request_excerpt" | "response_excerpt">;
type ApiKeyRow = Pick<
  Database["public"]["Tables"]["api_keys"]["Row"],
  "id" | "name" | "key_prefix"
>;
type WebhookRow = Pick<
  Database["public"]["Tables"]["webhooks"]["Row"],
  "id" | "name" | "url"
>;

const ALL = "all";
const PAGE_SIZE = 20;
const LOG_LIST_COLUMNS =
  "id,created_at,kind,key_id,webhook_id,method_event,status_code,duration_ms,error";

type DurationSort = "none" | "desc" | "asc";

const formatDateTime = (value: string | null) =>
  value
    ? new Date(value).toLocaleString("zh-CN", { hour12: false })
    : "—";

const formatDuration = (value: number | null) =>
  value === null ? "—" : `${value} ms`;

function KindBadge({ kind }: { kind: string }) {
  const normalized = asCallLogKind(kind);
  return (
    <Badge
      variant="outline"
      className={CALL_LOG_KIND_BADGE_CLASSES[normalized]}
    >
      {CALL_LOG_KIND_LABELS[normalized]}
    </Badge>
  );
}

function StatusBadge({ code }: { code: number | null }) {
  return (
    <Badge variant="outline" className={callStatusCodeBadgeClass(code)}>
      {callStatusLabel(code)}
    </Badge>
  );
}

function MetaItem({
  label,
  value,
}: {
  label: string;
  value: React.ReactNode;
}) {
  return (
    <div className="flex flex-col gap-0.5">
      <span className="text-xs text-muted-foreground">{label}</span>
      <span className="text-sm break-all">{value}</span>
    </div>
  );
}

function ExcerptPanel({
  title,
  content,
  onCopy,
}: {
  title: string;
  content: string | null;
  onCopy: (content: string) => void;
}) {
  return (
    <section className="flex min-w-0 flex-col gap-2">
      <div className="flex items-center justify-between gap-2">
        <h3 className="text-sm font-medium">{title}</h3>
        <Button
          variant="ghost"
          size="icon"
          className="size-11 lg:size-7"
          disabled={!content}
          onClick={() => content && onCopy(content)}
          aria-label={`复制${title}`}
        >
          <CopyIcon className="size-3.5" />
        </Button>
      </div>
      <pre className="max-h-72 min-h-24 overflow-auto rounded-lg border bg-muted/40 p-3 font-mono text-xs break-all whitespace-pre-wrap">
        {content ?? "—"}
      </pre>
    </section>
  );
}

export function LogsTable() {
  const isMobile = useIsMobile();

  const [rows, setRows] = React.useState<LogListRow[]>([]);
  const [total, setTotal] = React.useState(0);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [page, setPage] = React.useState(1);

  const [kindFilter, setKindFilter] = React.useState(ALL);
  const [statusFilter, setStatusFilter] =
    React.useState<(typeof CALL_STATUS_FILTER_OPTIONS)[number]["value"]>(ALL);
  const [referenceFilter, setReferenceFilter] = React.useState("");
  const [durationSort, setDurationSort] =
    React.useState<DurationSort>("none");
  const [dateFrom, setDateFrom] = React.useState("");
  const [dateTo, setDateTo] = React.useState("");

  const [apiKeys, setApiKeys] = React.useState<Map<string, string>>(new Map());
  const [webhooks, setWebhooks] = React.useState<Map<string, string>>(
    new Map(),
  );
  // 筛选用的映射走 ref：避免参考数据加载完成后触发整页二次拉取
  const apiKeysRef = React.useRef<Map<string, string>>(new Map());
  const webhooksRef = React.useRef<Map<string, string>>(new Map());
  const [detail, setDetail] = React.useState<LogDetailRow | null>(null);
  const [exporting, setExporting] = React.useState(false);

  const loadRefs = React.useCallback(async () => {
    const supabase = createClient();
    const [keysRes, hooksRes] = await Promise.all([
      supabase.from("api_keys").select("id, name, key_prefix").limit(1000),
      supabase.from("webhooks").select("id, name, url").limit(1000),
    ]);

    if (!keysRes.error) {
      const map = new Map<string, string>();
      for (const key of (keysRes.data ?? []) as ApiKeyRow[]) {
        map.set(key.id, `${key.name}（${key.key_prefix}）`);
      }
      apiKeysRef.current = map;
      setApiKeys(map);
    }
    if (!hooksRes.error) {
      const map = new Map<string, string>();
      for (const hook of (hooksRes.data ?? []) as WebhookRow[]) {
        map.set(hook.id, hook.name);
      }
      webhooksRef.current = map;
      setWebhooks(map);
    }
  }, []);

  const load = React.useCallback(async () => {
    setLoading(true);
    setError(null);

    const supabase = createClient();
    let query = supabase
      .from("integration_call_logs")
      .select(LOG_LIST_COLUMNS, { count: "exact" });

    if (durationSort !== "none") {
      query = query.order("duration_ms", {
        ascending: durationSort === "asc",
        nullsFirst: false,
      });
    }
    query = query
      .order("created_at", { ascending: false })
      .order("id", { ascending: false });

    if (kindFilter !== ALL) {
      query = query.eq("kind", kindFilter);
    }
    if (statusFilter === "failed") {
      // 失败 = HTTP ≥400 或记有 error（含 webhook 超时/无响应，status_code 为 NULL）
      query = query.or("status_code.gte.400,error.not.is.null");
    } else if (statusFilter === "2xx") {
      query = query.gte("status_code", 200).lte("status_code", 299);
    } else if (statusFilter === "4xx") {
      query = query.gte("status_code", 400).lte("status_code", 499);
    } else if (statusFilter === "5xx") {
      query = query.gte("status_code", 500).lte("status_code", 599);
    }
    if (dateFrom) {
      query = query.gte(
        "created_at",
        new Date(`${dateFrom}T00:00:00`).toISOString(),
      );
    }
    if (dateTo) {
      query = query.lte(
        "created_at",
        new Date(`${dateTo}T23:59:59.999`).toISOString(),
      );
    }

    // 密钥/端点模糊筛选：引用名在客户端映射里匹配出 id 再回传服务端（含方法/事件名）
    const referenceKeyword = referenceFilter.trim().toLowerCase();
    if (referenceKeyword) {
      const matchingKeyIds = Array.from(apiKeysRef.current.entries())
        .filter(([, label]) => label.toLowerCase().includes(referenceKeyword))
        .map(([id]) => id);
      const matchingWebhookIds = Array.from(webhooksRef.current.entries())
        .filter(([, name]) => name.toLowerCase().includes(referenceKeyword))
        .map(([id]) => id);
      // PostgREST or 表达式：值内逗号/括号会破坏语法，先中和；* 为 ilike 通配符
      const pattern = `*${referenceKeyword.replace(/[(),*%\\"]/g, " ").trim()}*`;
      const clauses = [`method_event.ilike.${pattern}`];
      if (matchingKeyIds.length > 0) {
        clauses.push(`key_id.in.(${matchingKeyIds.join(",")})`);
      }
      if (matchingWebhookIds.length > 0) {
        clauses.push(`webhook_id.in.(${matchingWebhookIds.join(",")})`);
      }
      query = query.or(clauses.join(","));
    }

    query = query.range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);

    const { data, error: listError, count } = await query;
    if (listError) {
      setError(listError.message);
      setRows([]);
      setTotal(0);
    } else {
      setRows(data ?? []);
      setTotal(count ?? 0);
    }
    setLoading(false);
  }, [
    kindFilter,
    statusFilter,
    dateFrom,
    dateTo,
    page,
    durationSort,
    referenceFilter,
  ]);

  React.useEffect(() => {
    void loadRefs();
  }, [loadRefs]);

  React.useEffect(() => {
    void load();
  }, [load]);

  React.useEffect(() => {
    setPage(1);
  }, [kindFilter, statusFilter, dateFrom, dateTo, referenceFilter, durationSort]);

  const pageCount = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const currentPage = Math.min(page, pageCount);
  const hasActiveFilters =
    kindFilter !== ALL ||
    statusFilter !== ALL ||
    referenceFilter.trim() !== "" ||
    dateFrom !== "" ||
    dateTo !== "";

  const referenceName = (row: LogListRow) => {
    if (row.kind === "api") {
      if (!row.key_id) {
        return "未关联密钥";
      }
      return apiKeys.get(row.key_id) ?? row.key_id;
    }
    if (!row.webhook_id) {
      return "未关联端点";
    }
    return webhooks.get(row.webhook_id) ?? row.webhook_id;
  };

  const resetFilters = () => {
    setKindFilter(ALL);
    setStatusFilter(ALL);
    setReferenceFilter("");
    setDateFrom("");
    setDateTo("");
  };

  const toggleDurationSort = () => {
    setDurationSort((prev) =>
      prev === "none" ? "desc" : prev === "desc" ? "asc" : "none",
    );
  };

  /** 详情打开：先展示列表字段，再补拉 2KB 级 request/response 摘要 */
  const openDetail = async (row: LogListRow) => {
    setDetail({ ...row, request_excerpt: null, response_excerpt: null });
    const { data, error: detailError } = await createClient()
      .from("integration_call_logs")
      .select("request_excerpt,response_excerpt")
      .eq("id", row.id)
      .eq("created_at", row.created_at)
      .maybeSingle();
    if (detailError || !data) {
      return;
    }
    setDetail((prev) =>
      prev && prev.id === row.id && prev.created_at === row.created_at
        ? { ...prev, ...data }
        : prev,
    );
  };

  const copyText = async (text: string, label: string) => {
    try {
      await navigator.clipboard.writeText(text);
      toast.success(`${label}已复制`);
    } catch {
      toast.error("复制失败，请手动选择并复制");
    }
  };

  const handleExport = async () => {
    setExporting(true);
    const { error: exportError } = await createClient().rpc("request_export", {
      p_source: "integration.logs",
    });
    setExporting(false);

    if (exportError) {
      toast.error(translateIntegrationLogsErrorMessage(exportError.message));
      return;
    }
    toast.success("导出任务已创建，完成后到 /report/exports 下载");
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
            加载失败：{translateIntegrationLogsErrorMessage(error)}
          </p>
          <Button variant="outline" onClick={() => void load()}>
            重试
          </Button>
        </div>
      );
    }
    if (rows.length === 0) {
      return (
        <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
          <ScrollTextIcon className="size-8 opacity-60" />
          {hasActiveFilters ? (
            <>
              <span>未找到匹配的调用记录</span>
              <Button variant="outline" size="sm" onClick={resetFilters}>
                清除筛选
              </Button>
            </>
          ) : (
            <span>暂无调用记录（明细保留 30 天）</span>
          )}
        </div>
      );
    }

    if (isMobile) {
      return (
        <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
          {rows.map((row) => (
            <button
              key={`${row.id}-${row.created_at}`}
              type="button"
              onClick={() => void openDetail(row)}
              className="flex w-full flex-col gap-2 rounded-xl border bg-card p-3 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
            >
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <div className="truncate font-mono text-xs leading-tight text-muted-foreground">
                    {formatDateTime(row.created_at)}
                  </div>
                  <div className="truncate font-medium">
                    {row.method_event}
                  </div>
                </div>
                <div className="flex shrink-0 items-center gap-1.5">
                  <KindBadge kind={row.kind} />
                  <StatusBadge code={row.status_code} />
                </div>
              </div>
              <div className="flex flex-col gap-1.5 text-sm">
                <div className="flex items-center justify-between gap-4">
                  <span className="text-muted-foreground">
                    {row.kind === "api" ? "密钥" : "端点"}
                  </span>
                  <span className="truncate">{referenceName(row)}</span>
                </div>
                <div className="flex items-center justify-between gap-4">
                  <span className="text-muted-foreground">耗时</span>
                  <span>{formatDuration(row.duration_ms)}</span>
                </div>
                {row.error ? (
                  <div className="flex items-start justify-between gap-4">
                    <span className="shrink-0 text-muted-foreground">错误</span>
                    <span className="line-clamp-2 text-right text-xs text-destructive">
                      {row.error}
                    </span>
                  </div>
                ) : null}
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
              <TableHead className="text-center">类型</TableHead>
              <TableHead className="text-center">密钥 / 端点</TableHead>
              <TableHead className="text-center">方法 / 事件</TableHead>
              <TableHead className="text-center">状态码</TableHead>
              <TableHead
                className="text-center"
                aria-sort={
                  durationSort === "asc"
                    ? "ascending"
                    : durationSort === "desc"
                      ? "descending"
                      : "none"
                }
              >
                <button
                  type="button"
                  onClick={toggleDurationSort}
                  className="inline-flex items-center gap-1 rounded-md px-1 py-0.5 transition-colors hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                  aria-label="按耗时排序"
                >
                  耗时
                  {durationSort === "asc" ? (
                    <ArrowUpIcon className="size-3.5" />
                  ) : durationSort === "desc" ? (
                    <ArrowDownIcon className="size-3.5" />
                  ) : (
                    <ArrowUpDownIcon className="size-3.5 opacity-60" />
                  )}
                </button>
              </TableHead>
              <TableHead className="text-center">错误</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row) => (
              <TableRow
                key={`${row.id}-${row.created_at}`}
                className="cursor-pointer"
                tabIndex={0}
                onClick={() => void openDetail(row)}
                onKeyDown={(event) => {
                  if (event.target !== event.currentTarget) {
                    return;
                  }
                  if (event.key === "Enter" || event.key === " ") {
                    event.preventDefault();
                    void openDetail(row);
                  }
                }}
              >
                <TableCell className="text-center text-xs whitespace-nowrap text-muted-foreground">
                  {formatDateTime(row.created_at)}
                </TableCell>
                <TableCell className="text-center">
                  <KindBadge kind={row.kind} />
                </TableCell>
                <TableCell className="max-w-44 truncate text-center">
                  {referenceName(row)}
                </TableCell>
                <TableCell className="text-center font-mono text-xs">
                  {row.method_event}
                </TableCell>
                <TableCell className="text-center">
                  <StatusBadge code={row.status_code} />
                </TableCell>
                <TableCell className="text-center text-xs whitespace-nowrap">
                  {formatDuration(row.duration_ms)}
                </TableCell>
                <TableCell className="max-w-56 text-center text-xs text-muted-foreground">
                  <span className="line-clamp-2">{row.error ?? "—"}</span>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    );
  };

  return (
    <div className="flex flex-col gap-2 p-0 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-wrap items-center gap-2">
            <Select value={kindFilter} onValueChange={setKindFilter}>
              <SelectTrigger
                className="h-11 w-full sm:w-32 lg:h-8"
                aria-label="按类型筛选"
              >
                <SelectValue placeholder="全部类型" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL}>全部类型</SelectItem>
                <SelectItem value="api">API</SelectItem>
                <SelectItem value="webhook">Webhook</SelectItem>
              </SelectContent>
            </Select>
            <Select
              value={statusFilter}
              onValueChange={(value) =>
                setStatusFilter(
                  value as (typeof CALL_STATUS_FILTER_OPTIONS)[number]["value"],
                )
              }
            >
              <SelectTrigger
                className="h-11 w-full sm:w-36 lg:h-8"
                aria-label="按状态码筛选"
              >
                <SelectValue placeholder="全部状态" />
              </SelectTrigger>
              <SelectContent>
                {CALL_STATUS_FILTER_OPTIONS.map((option) => (
                  <SelectItem key={option.value} value={option.value}>
                    {option.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Input
              value={referenceFilter}
              onChange={(event) => setReferenceFilter(event.target.value)}
              placeholder="密钥 / 端点名称"
              className="h-11 w-full text-base sm:w-44 lg:h-8 lg:text-sm"
              aria-label="按密钥或端点名称筛选"
            />
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

            <div className="flex w-full items-center gap-2 sm:ml-auto sm:w-auto">
              <Button
                variant="outline"
                onClick={() => void handleExport()}
                disabled={exporting}
                className="h-11 flex-1 lg:h-8 lg:flex-none"
              >
                {exporting ? (
                  <Loader2Icon
                    className="animate-spin"
                    data-icon="inline-start"
                  />
                ) : (
                  <DownloadIcon data-icon="inline-start" />
                )}
                导出
              </Button>
            </div>
          </div>

          {renderList()}

          {!loading && !error && total > 0 ? (
            <div className="flex items-center justify-between gap-2 text-sm text-muted-foreground">
              <span>
                共 {total} 条 · 第 {currentPage} / {pageCount} 页
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
              {detail
                ? `${CALL_LOG_KIND_LABELS[asCallLogKind(detail.kind)]} · ${detail.method_event}`
                : "调用详情"}
            </SheetTitle>
            <SheetDescription>
              {detail ? `记录 #${detail.id}` : "调用记录详情"}
            </SheetDescription>
          </SheetHeader>
          <div className="flex min-h-0 flex-col gap-4 overflow-y-auto px-4">
            {detail ? (
              <>
                <div className="grid grid-cols-2 gap-3 rounded-lg border p-3">
                  <MetaItem
                    label="时间"
                    value={formatDateTime(detail.created_at)}
                  />
                  <MetaItem
                    label="类型"
                    value={<KindBadge kind={detail.kind} />}
                  />
                  <MetaItem
                    label={detail.kind === "api" ? "密钥" : "端点"}
                    value={referenceName(detail)}
                  />
                  <MetaItem label="方法 / 事件" value={detail.method_event} />
                  <MetaItem
                    label="状态码"
                    value={<StatusBadge code={detail.status_code} />}
                  />
                  <MetaItem
                    label="耗时"
                    value={formatDuration(detail.duration_ms)}
                  />
                </div>

                {detail.error ? (
                  <div className="flex items-start gap-2 rounded-lg border border-destructive/30 bg-destructive/5 p-3 text-sm text-destructive">
                    <AlertTriangleIcon className="mt-0.5 size-4 shrink-0" />
                    <span className="break-all">{detail.error}</span>
                  </div>
                ) : null}

                <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                  <ExcerptPanel
                    title="请求摘要"
                    content={detail.request_excerpt}
                    onCopy={(content) => void copyText(content, "请求摘要")}
                  />
                  <ExcerptPanel
                    title="响应摘要"
                    content={detail.response_excerpt}
                    onCopy={(content) => void copyText(content, "响应摘要")}
                  />
                </div>
              </>
            ) : null}
          </div>
        </SheetContent>
      </Sheet>
    </div>
  );
}
