"use client";

// 登录日志页面（audit/005）：admin 全量视图 / 普通用户「我的登录记录」。
// 数据源：audit_logins（RLS：admin 全量；user_id = auth.uid() 本人自查），
// 前端同一查询按角色自动收敛，无需分页数据源。

import * as React from "react";
import {
  AlertTriangleIcon,
  KeyRoundIcon,
  RefreshCwIcon,
  SearchIcon,
  ShieldAlertIcon,
} from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
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
  formatDateTime,
  loginFailReasonLabel,
  translateAuditErrorMessage,
} from "@/lib/audit";
import { createClient } from "@/lib/supabase/client";

const ALL = "all";
const PAGE_SIZE = 20;
const FETCH_LIMIT = 500;
const SUCCESS_BADGE_CLASS =
  "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300";
const FAILURE_BADGE_CLASS =
  "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300";

type LoginRow = Database["public"]["Tables"]["audit_logins"]["Row"];
type ResultFilter = "all" | "success" | "failure";
type TimeRange = "all" | "7d" | "30d";

const TIME_RANGE_OPTIONS: { value: TimeRange; label: string }[] = [
  { value: "all", label: "全部时间" },
  { value: "7d", label: "近 7 天" },
  { value: "30d", label: "近 30 天" },
];

function withinTimeRange(value: string | null, range: TimeRange): boolean {
  if (!value || range === "all") {
    return true;
  }
  const days = range === "7d" ? 7 : 30;
  return Date.now() - new Date(value).getTime() <= days * 24 * 3_600_000;
}

function ResultBadge({ success }: { success: boolean }) {
  return (
    <Badge
      variant="outline"
      className={success ? SUCCESS_BADGE_CLASS : FAILURE_BADGE_CLASS}
    >
      {success ? "成功" : "失败"}
    </Badge>
  );
}

/** logins.md 功能 4：同账号短窗口多 IP 失败警示 */
function MultiIpWarning() {
  return (
    <Badge
      variant="outline"
      className="border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300"
    >
      <AlertTriangleIcon className="size-3" />
      多 IP 失败
    </Badge>
  );
}

/** 短窗口（±10 分钟）内同邮箱失败尝试来自 ≥2 个不同 IP 的行 id 集合 */
function findMultiIpFailureIds(rows: LoginRow[]): Set<number> {
  const WINDOW_MS = 10 * 60 * 1000;
  const marks = new Set<number>();
  const byEmail = new Map<string, LoginRow[]>();

  for (const row of rows) {
    if (row.success || !row.email || row.ip === null) {
      continue;
    }
    const list = byEmail.get(row.email) ?? [];
    list.push(row);
    byEmail.set(row.email, list);
  }

  for (const list of byEmail.values()) {
    for (const row of list) {
      const time = new Date(row.created_at ?? 0).getTime();
      const ips = new Set<string>();
      for (const other of list) {
        const otherTime = new Date(other.created_at ?? 0).getTime();
        if (Math.abs(otherTime - time) <= WINDOW_MS) {
          ips.add(String(other.ip));
        }
      }
      if (ips.size >= 2) {
        marks.add(row.id);
      }
    }
  }

  return marks;
}

export function LoginsTable({ isAdmin }: { isAdmin: boolean }) {
  const isMobile = useIsMobile();
  const [rows, setRows] = React.useState<LoginRow[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [resultFilter, setResultFilter] = React.useState<ResultFilter>("all");
  const [emailSearch, setEmailSearch] = React.useState("");
  const [timeRange, setTimeRange] = React.useState<TimeRange>("all");
  const [page, setPage] = React.useState(1);

  const load = React.useCallback(async () => {
    setLoading(true);
    setError(null);
    // RLS 自动收敛：admin 全量、其他角色仅本人 user_id 行
    const { data, error: listError } = await createClient()
      .from("audit_logins")
      .select("*")
      .order("created_at", { ascending: false })
      .limit(FETCH_LIMIT);

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
  }, [resultFilter, emailSearch, timeRange]);

  const filtered = React.useMemo(() => {
    const keyword = emailSearch.trim().toLowerCase();
    return rows.filter((row) => {
      if (resultFilter === "success" && !row.success) {
        return false;
      }
      if (resultFilter === "failure" && row.success) {
        return false;
      }
      if (!withinTimeRange(row.created_at, timeRange)) {
        return false;
      }
      if (keyword && !(row.email ?? "").toLowerCase().includes(keyword)) {
        return false;
      }
      return true;
    });
  }, [rows, resultFilter, emailSearch, timeRange]);

  // 异常警示基于全量行计算（避免筛选后丢失同簇上下文）
  const multiIpFailureIds = React.useMemo(
    () => findMultiIpFailureIds(rows),
    [rows],
  );

  const pageCount = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const currentPage = Math.min(page, pageCount);
  const pagedRows = filtered.slice(
    (currentPage - 1) * PAGE_SIZE,
    currentPage * PAGE_SIZE,
  );
  const hasActiveFilters =
    resultFilter !== ALL || emailSearch.trim() !== "" || timeRange !== "all";

  const resetFilters = () => {
    setResultFilter(ALL);
    setEmailSearch("");
    setTimeRange("all");
  };

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardHeader>
          <CardTitle>{isAdmin ? "登录日志" : "我的登录记录"}</CardTitle>
          <CardDescription>
            {isAdmin
              ? "全站登录成功/失败留痕；普通用户仅能看到自己的记录；同账号短窗口多 IP 失败标注警示"
              : "查看本人账号的登录成功与失败记录；同账号短窗口多 IP 失败标注警示"}
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
            <div className="relative flex-1 sm:max-w-xs">
              <SearchIcon className="absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                value={emailSearch}
                onChange={(event) => setEmailSearch(event.target.value)}
                placeholder="搜索邮箱"
                className="h-11 pl-8 text-base lg:h-8 lg:text-sm"
                aria-label="按邮箱搜索"
              />
            </div>
            <Select
              value={resultFilter}
              onValueChange={(value) =>
                setResultFilter(value as ResultFilter)
              }
            >
              <SelectTrigger
                className="h-11 w-full sm:w-32 lg:h-8"
                aria-label="按结果筛选"
              >
                <SelectValue placeholder="全部结果" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL}>全部结果</SelectItem>
                <SelectItem value="success">成功</SelectItem>
                <SelectItem value="failure">失败</SelectItem>
              </SelectContent>
            </Select>
            <Select
              value={timeRange}
              onValueChange={(value) => setTimeRange(value as TimeRange)}
            >
              <SelectTrigger
                className="h-11 w-full sm:w-32 lg:h-8"
                aria-label="按时间筛选"
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
            {hasActiveFilters ? (
              <Button
                variant="ghost"
                onClick={resetFilters}
                className="h-11 lg:h-8"
              >
                清除筛选
              </Button>
            ) : null}
            <Button
              variant="outline"
              size="icon"
              onClick={() => void load()}
              disabled={loading}
              aria-label="刷新登录日志"
              className="h-11 w-11 lg:ml-auto lg:h-8 lg:w-8"
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
                加载失败：{translateAuditErrorMessage(error)}
              </p>
              <Button variant="outline" onClick={() => void load()}>
                重试
              </Button>
            </div>
          ) : pagedRows.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <KeyRoundIcon className="size-8 opacity-60" />
              {hasActiveFilters ? (
                <>
                  <span>未找到匹配的登录记录</span>
                  <Button variant="outline" size="sm" onClick={resetFilters}>
                    清除筛选
                  </Button>
                </>
              ) : (
                <span>暂无登录记录</span>
              )}
            </div>
          ) : isMobile ? (
            <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
              {pagedRows.map((row) => (
                <div
                  key={row.id}
                  className="flex w-full flex-col gap-2.5 rounded-xl border bg-card p-4 shadow-xs"
                >
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <div className="truncate font-medium">
                        {row.email ?? "未知邮箱"}
                      </div>
                      <div className="truncate text-xs text-muted-foreground">
                        {formatDateTime(row.created_at)}
                      </div>
                    </div>
                    <div className="flex shrink-0 flex-col items-end gap-1">
                      <ResultBadge success={row.success} />
                      {multiIpFailureIds.has(row.id) ? <MultiIpWarning /> : null}
                    </div>
                  </div>
                  <div className="flex flex-col gap-1.5 text-sm">
                    {!row.success ? (
                      <div className="flex items-center justify-between gap-4">
                        <span className="text-muted-foreground">失败原因</span>
                        <span>{loginFailReasonLabel(row.fail_reason)}</span>
                      </div>
                    ) : null}
                    <div className="flex items-center justify-between gap-4">
                      <span className="text-muted-foreground">IP</span>
                      <span className="font-mono text-xs">
                        {row.ip === null ? "—" : String(row.ip)}
                      </span>
                    </div>
                    <div className="flex items-start justify-between gap-4">
                      <span className="shrink-0 text-muted-foreground">
                        设备
                      </span>
                      <span
                        className="truncate text-right text-xs"
                        title={row.ua ?? undefined}
                      >
                        {row.ua ?? "—"}
                      </span>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          ) : (
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="text-center">时间</TableHead>
                    <TableHead className="text-center">结果</TableHead>
                    <TableHead className="text-center">用户邮箱</TableHead>
                    <TableHead className="text-center">失败原因</TableHead>
                    <TableHead className="text-center">IP</TableHead>
                    <TableHead className="text-center">设备（UA）</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {pagedRows.map((row) => (
                    <TableRow key={row.id}>
                      <TableCell className="text-center text-xs whitespace-nowrap text-muted-foreground">
                        {formatDateTime(row.created_at)}
                      </TableCell>
                      <TableCell className="text-center">
                        <div className="flex flex-col items-center gap-1">
                          <ResultBadge success={row.success} />
                          {multiIpFailureIds.has(row.id) ? (
                            <MultiIpWarning />
                          ) : null}
                        </div>
                      </TableCell>
                      <TableCell className="text-center">
                        {row.email ?? "—"}
                      </TableCell>
                      <TableCell className="text-center">
                        {row.success ? (
                          <span className="text-muted-foreground">—</span>
                        ) : (
                          <Badge
                            variant="outline"
                            className={FAILURE_BADGE_CLASS}
                          >
                            <ShieldAlertIcon className="size-3" />
                            {loginFailReasonLabel(row.fail_reason)}
                          </Badge>
                        )}
                      </TableCell>
                      <TableCell className="text-center font-mono text-xs">
                        {row.ip === null ? "—" : String(row.ip)}
                      </TableCell>
                      <TableCell className="max-w-64 text-center text-xs text-muted-foreground">
                        <span
                          className="line-clamp-2"
                          title={row.ua ?? undefined}
                        >
                          {row.ua ?? "—"}
                        </span>
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
    </div>
  );
}
