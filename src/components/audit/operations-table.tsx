"use client";

// 操作日志页面（audit/004）：工具栏多筛选 + Table + 详情 Sheet（diff 字段级渲染）
// + 对象时间线模式（按 object_type + object_id 查看完整变更史）。
// 数据源：audit_operations_v（security_invoker；底层 RLS 仅 admin 可见）。
// 导出：request_export('audit.operations')（report/007 管道，admin 独占源）。

import * as React from "react";
import {
  DownloadIcon,
  FileClockIcon,
  FileSearchIcon,
  Loader2Icon,
} from "lucide-react";
import { toast } from "sonner";

import { DiffView } from "@/components/audit/diff-view";
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
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { useIsMobile } from "@/hooks/use-mobile";
import type { Database } from "@/lib/database.types";
import {
  auditActionBadgeClass,
  auditActionLabel,
  auditModuleLabel,
  formatDateTime,
  summarizeDiff,
  translateAuditErrorMessage,
} from "@/lib/audit";
import { createClient } from "@/lib/supabase/client";

const ALL = "all";
const SYSTEM = "__system__";
const PAGE_SIZE = 20;
/** 首版内存筛选：取最近 500 条（v2 数据量上来后改服务端筛选 + 分页） */
const FETCH_LIMIT = 500;
const TIMELINE_LIMIT = 200;

type OperationRow =
  Database["public"]["Views"]["audit_operations_v"]["Row"];
type ViewMode = "list" | "timeline";

function ActionBadge({ action }: { action: string | null }) {
  return (
    <Badge
      variant="outline"
      className={auditActionBadgeClass(action ?? "")}
    >
      {auditActionLabel(action)}
    </Badge>
  );
}

function ObjectCell({ row }: { row: OperationRow }) {
  return (
    <div className="flex flex-col items-center">
      <span className="text-sm">{row.object_type}</span>
      <span className="max-w-48 truncate font-mono text-xs text-muted-foreground">
        {row.object_id ?? "—"}
      </span>
    </div>
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

export function OperationsTable() {
  const isMobile = useIsMobile();
  const [mode, setMode] = React.useState<ViewMode>("list");

  const [rows, setRows] = React.useState<OperationRow[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);

  const [moduleFilter, setModuleFilter] = React.useState(ALL);
  const [actorFilter, setActorFilter] = React.useState(ALL);
  const [actionFilter, setActionFilter] = React.useState(ALL);
  const [objectTypeFilter, setObjectTypeFilter] = React.useState(ALL);
  const [dateFrom, setDateFrom] = React.useState("");
  const [dateTo, setDateTo] = React.useState("");
  const [page, setPage] = React.useState(1);

  const [detail, setDetail] = React.useState<OperationRow | null>(null);
  const [exporting, setExporting] = React.useState(false);

  const [timelineType, setTimelineType] = React.useState("");
  const [timelineId, setTimelineId] = React.useState("");
  const [timelineRows, setTimelineRows] = React.useState<OperationRow[]>([]);
  const [timelineLoading, setTimelineLoading] = React.useState(false);
  const [timelineError, setTimelineError] = React.useState<string | null>(null);
  const [timelineSearched, setTimelineSearched] = React.useState(false);

  const load = React.useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: listError } = await createClient()
      .from("audit_operations_v")
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
  }, [moduleFilter, actorFilter, actionFilter, objectTypeFilter, dateFrom, dateTo]);

  const moduleOptions = React.useMemo(
    () =>
      Array.from(
        new Set(
          rows
            .map((row) => row.module)
            .filter((module): module is string => typeof module === "string"),
        ),
      ).sort((a, b) => a.localeCompare(b, "zh-CN")),
    [rows],
  );

  const actionOptions = React.useMemo(
    () =>
      Array.from(
        new Set(
          rows
            .map((row) => row.action)
            .filter((action): action is string => typeof action === "string"),
        ),
      ).sort((a, b) => a.localeCompare(b, "zh-CN")),
    [rows],
  );

  const objectTypeOptions = React.useMemo(
    () =>
      Array.from(
        new Set(
          rows
            .map((row) => row.object_type)
            .filter((type): type is string => typeof type === "string"),
        ),
      ).sort((a, b) => a.localeCompare(b, "zh-CN")),
    [rows],
  );

  /** 操作人下拉：actor_id → 姓名；NULL 归入「系统/后台」 */
  const actorOptions = React.useMemo(() => {
    const map = new Map<string, string>();
    for (const row of rows) {
      if (!row.actor_id || map.has(row.actor_id)) {
        continue;
      }
      map.set(
        row.actor_id,
        row.actor_name?.trim() ||
          `${row.actor_id.slice(0, 8)}…`,
      );
    }
    return Array.from(map, ([id, label]) => ({ id, label })).sort((a, b) =>
      a.label.localeCompare(b.label, "zh-CN"),
    );
  }, [rows]);

  const filtered = React.useMemo(() => {
    const fromTime = dateFrom ? new Date(`${dateFrom}T00:00:00`).getTime() : null;
    const toTime = dateTo ? new Date(`${dateTo}T23:59:59.999`).getTime() : null;

    return rows.filter((row) => {
      if (moduleFilter !== ALL && row.module !== moduleFilter) {
        return false;
      }
      if (actorFilter !== ALL) {
        if (actorFilter === SYSTEM) {
          if (row.actor_id !== null) {
            return false;
          }
        } else if (row.actor_id !== actorFilter) {
          return false;
        }
      }
      if (actionFilter !== ALL && row.action !== actionFilter) {
        return false;
      }
      if (objectTypeFilter !== ALL && row.object_type !== objectTypeFilter) {
        return false;
      }
      if (row.created_at === null) {
        return fromTime === null && toTime === null;
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
  }, [
    rows,
    moduleFilter,
    actorFilter,
    actionFilter,
    objectTypeFilter,
    dateFrom,
    dateTo,
  ]);

  const pageCount = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const currentPage = Math.min(page, pageCount);
  const pagedRows = filtered.slice(
    (currentPage - 1) * PAGE_SIZE,
    currentPage * PAGE_SIZE,
  );
  const hasActiveFilters =
    moduleFilter !== ALL ||
    actorFilter !== ALL ||
    actionFilter !== ALL ||
    objectTypeFilter !== ALL ||
    dateFrom !== "" ||
    dateTo !== "";

  const resetFilters = () => {
    setModuleFilter(ALL);
    setActorFilter(ALL);
    setActionFilter(ALL);
    setObjectTypeFilter(ALL);
    setDateFrom("");
    setDateTo("");
  };

  const openDetail = (row: OperationRow) => {
    setDetail(row);
  };

  const handleExport = async () => {
    setExporting(true);
    const { error: exportError } = await createClient().rpc("request_export", {
      p_source: "audit.operations",
    });
    setExporting(false);

    if (exportError) {
      toast.error(translateAuditErrorMessage(exportError.message));
      return;
    }
    // 报表中心导出页（/report/exports）已上线：引导到任务列表下载
    toast.success("导出任务已创建，完成后到 /report/exports 下载");
  };

  const handleTimelineSearch = async (
    event: React.FormEvent<HTMLFormElement>,
  ) => {
    event.preventDefault();
    const objectType = timelineType.trim();
    const objectId = timelineId.trim();
    if (!objectType || !objectId) {
      toast.error("请填写对象类型与对象标识");
      return;
    }

    setTimelineLoading(true);
    setTimelineSearched(true);
    setTimelineError(null);
    const { data, error: timelineQueryError } = await createClient()
      .from("audit_operations_v")
      .select("*")
      .eq("object_type", objectType)
      .eq("object_id", objectId)
      .order("created_at", { ascending: true })
      .limit(TIMELINE_LIMIT);
    setTimelineLoading(false);

    if (timelineQueryError) {
      setTimelineError(timelineQueryError.message);
      setTimelineRows([]);
    } else {
      setTimelineRows(data ?? []);
    }
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
            加载失败：{translateAuditErrorMessage(error)}
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
          <FileClockIcon className="size-8 opacity-60" />
          {hasActiveFilters ? (
            <>
              <span>未找到匹配的操作记录</span>
              <Button variant="outline" size="sm" onClick={resetFilters}>
                清除筛选
              </Button>
            </>
          ) : (
            <span>暂无操作日志</span>
          )}
        </div>
      );
    }

    if (isMobile) {
      return (
        <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
          {pagedRows.map((row) => (
            <button
              key={row.id}
              type="button"
              onClick={() => openDetail(row)}
              className="flex w-full flex-col gap-2 rounded-xl border bg-card p-3 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
            >
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <div className="truncate font-medium">
                    {row.actor_name ?? "系统/后台"}
                  </div>
                  <div className="truncate text-xs leading-tight text-muted-foreground">
                    {formatDateTime(row.created_at)}
                  </div>
                </div>
                <ActionBadge action={row.action} />
              </div>
              <div className="flex flex-col gap-1.5 text-sm">
                <div className="flex items-center justify-between gap-4">
                  <span className="text-muted-foreground">模块</span>
                  <span>{auditModuleLabel(row.module)}</span>
                </div>
                <div className="flex items-center justify-between gap-4">
                  <span className="text-muted-foreground">对象</span>
                  <span className="truncate">
                    {row.object_type}
                    {row.object_id ? ` · ${row.object_id}` : ""}
                  </span>
                </div>
                <div className="flex items-start justify-between gap-4">
                  <span className="shrink-0 text-muted-foreground">差异</span>
                  <span className="text-right text-xs break-all">
                    {summarizeDiff(row.diff)}
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
              <TableHead className="text-center">操作人</TableHead>
              <TableHead className="text-center">模块</TableHead>
              <TableHead className="text-center">动作</TableHead>
              <TableHead className="text-center">对象</TableHead>
              <TableHead className="text-center">差异摘要</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {pagedRows.map((row) => (
              <TableRow
                key={row.id}
                className="cursor-pointer"
                tabIndex={0}
                onClick={() => openDetail(row)}
                onKeyDown={(event) => {
                  if (event.target !== event.currentTarget) {
                    return;
                  }
                  if (event.key === "Enter" || event.key === " ") {
                    event.preventDefault();
                    openDetail(row);
                  }
                }}
              >
                <TableCell className="text-center text-xs whitespace-nowrap text-muted-foreground">
                  {formatDateTime(row.created_at)}
                </TableCell>
                <TableCell className="text-center">
                  {row.actor_name ?? "系统/后台"}
                </TableCell>
                <TableCell className="text-center">
                  <Badge variant="outline" className="text-muted-foreground">
                    {auditModuleLabel(row.module)}
                  </Badge>
                </TableCell>
                <TableCell className="text-center">
                  <ActionBadge action={row.action} />
                </TableCell>
                <TableCell className="text-center">
                  <ObjectCell row={row} />
                </TableCell>
                <TableCell className="max-w-80 text-center text-xs text-muted-foreground">
                  <span className="line-clamp-2">{summarizeDiff(row.diff)}</span>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    );
  };

  const renderTimeline = () => {
    if (!timelineSearched) {
      return (
        <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
          <FileSearchIcon className="size-8 opacity-60" />
          <span>输入对象类型与对象标识，查看该对象的完整变更史</span>
        </div>
      );
    }
    if (timelineLoading) {
      return (
        <div className="flex flex-col gap-2">
          {Array.from({ length: 4 }).map((_, index) => (
            <Skeleton key={index} className="h-16 w-full" />
          ))}
        </div>
      );
    }
    if (timelineError) {
      return (
        <div className="flex flex-col items-center gap-2 py-8 text-sm">
          <p className="text-destructive">
            加载失败：{translateAuditErrorMessage(timelineError)}
          </p>
        </div>
      );
    }
    if (timelineRows.length === 0) {
      return (
        <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
          <FileSearchIcon className="size-8 opacity-60" />
          <span>
            未找到 {timelineType.trim()} · {timelineId.trim()} 的变更记录
          </span>
        </div>
      );
    }

    return (
      <ol className="relative ml-1.5 flex list-none flex-col gap-4 border-l pl-5">
        {timelineRows.map((row) => (
          <li key={row.id} className="relative">
            <span className="absolute top-3 -left-[25px] size-2.5 rounded-full border-2 border-background bg-primary" />
            <button
              type="button"
              onClick={() => openDetail(row)}
              className="flex w-full flex-col gap-2 rounded-xl border bg-card p-3 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
            >
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span className="text-xs text-muted-foreground">
                  {formatDateTime(row.created_at)}
                </span>
                <div className="flex items-center gap-2">
                  <Badge variant="outline" className="text-muted-foreground">
                    {auditModuleLabel(row.module)}
                  </Badge>
                  <ActionBadge action={row.action} />
                </div>
              </div>
              <div className="text-sm">
                <span className="text-muted-foreground">操作人：</span>
                {row.actor_name ?? "系统/后台"}
              </div>
              <div className="text-xs break-all text-muted-foreground">
                {summarizeDiff(row.diff)}
              </div>
            </button>
          </li>
        ))}
      </ol>
    );
  };

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-wrap items-center gap-2">
            <ToggleGroup
              type="single"
              value={mode}
              onValueChange={(value) => {
                if (value === "list" || value === "timeline") {
                  setMode(value);
                }
              }}
              variant="outline"
              className="w-full sm:w-auto"
              aria-label="视图切换"
            >
              <ToggleGroupItem
                value="list"
                className="h-11 flex-1 px-3 lg:h-8 lg:flex-none"
              >
                列表
              </ToggleGroupItem>
              <ToggleGroupItem
                value="timeline"
                className="h-11 flex-1 px-3 lg:h-8 lg:flex-none"
              >
                对象时间线
              </ToggleGroupItem>
            </ToggleGroup>

            {mode === "list" ? (
              <>
                <Select value={moduleFilter} onValueChange={setModuleFilter}>
                  <SelectTrigger
                    className="h-11 w-full sm:w-32 lg:h-8"
                    aria-label="按模块筛选"
                  >
                    <SelectValue placeholder="全部模块" />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value={ALL}>全部模块</SelectItem>
                    {moduleOptions.map((module) => (
                      <SelectItem key={module} value={module}>
                        {auditModuleLabel(module)}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <Select value={actorFilter} onValueChange={setActorFilter}>
                  <SelectTrigger
                    className="h-11 w-full sm:w-32 lg:h-8"
                    aria-label="按操作人筛选"
                  >
                    <SelectValue placeholder="全部操作人" />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value={ALL}>全部操作人</SelectItem>
                    <SelectItem value={SYSTEM}>系统/后台</SelectItem>
                    {actorOptions.map((actor) => (
                      <SelectItem key={actor.id} value={actor.id}>
                        {actor.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <Select value={actionFilter} onValueChange={setActionFilter}>
                  <SelectTrigger
                    className="h-11 w-full sm:w-28 lg:h-8"
                    aria-label="按动作筛选"
                  >
                    <SelectValue placeholder="全部动作" />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value={ALL}>全部动作</SelectItem>
                    {actionOptions.map((action) => (
                      <SelectItem key={action} value={action}>
                        {auditActionLabel(action)}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <Select
                  value={objectTypeFilter}
                  onValueChange={setObjectTypeFilter}
                >
                  <SelectTrigger
                    className="h-11 w-full sm:w-32 lg:h-8"
                    aria-label="按对象类型筛选"
                  >
                    <SelectValue placeholder="全部对象" />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value={ALL}>全部对象</SelectItem>
                    {objectTypeOptions.map((type) => (
                      <SelectItem key={type} value={type}>
                        {type}
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
              </>
            ) : (
              <form
                onSubmit={(event) => void handleTimelineSearch(event)}
                className="flex w-full flex-wrap items-center gap-2 sm:w-auto"
              >
                <Input
                  value={timelineType}
                  onChange={(event) => setTimelineType(event.target.value)}
                  placeholder="对象类型，如 department"
                  className="h-11 w-full text-base sm:w-44 lg:h-8 lg:text-sm"
                  aria-label="对象类型"
                />
                <Input
                  value={timelineId}
                  onChange={(event) => setTimelineId(event.target.value)}
                  placeholder="对象标识，如 42"
                  className="h-11 w-full text-base sm:w-40 lg:h-8 lg:text-sm"
                  aria-label="对象标识"
                />
                <Button type="submit" className="h-11 w-full lg:h-8 sm:w-auto">
                  <FileSearchIcon data-icon="inline-start" />
                  查看时间线
                </Button>
              </form>
            )}

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

          {mode === "list" ? renderList() : renderTimeline()}

          {mode === "list" && !loading && !error && filtered.length > 0 ? (
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
              {detail
                ? `${auditActionLabel(detail.action)} · ${detail.object_type}`
                : "操作详情"}
            </SheetTitle>
            <SheetDescription>
              {detail?.id !== null && detail?.id !== undefined
                ? `记录 #${detail.id}`
                : "操作记录详情"}
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
                    label="操作人"
                    value={detail.actor_name ?? "系统/后台"}
                  />
                  <MetaItem
                    label="模块"
                    value={auditModuleLabel(detail.module)}
                  />
                  <MetaItem
                    label="动作"
                    value={<ActionBadge action={detail.action} />}
                  />
                  <MetaItem label="对象类型" value={detail.object_type} />
                  <MetaItem label="对象标识" value={detail.object_id ?? "—"} />
                </div>
                <section className="flex flex-col gap-2">
                  <h3 className="text-sm font-medium">字段差异</h3>
                  <DiffView diff={detail.diff} />
                </section>
                <section className="flex flex-col gap-2">
                  <h3 className="text-sm font-medium">上下文</h3>
                  <div className="grid grid-cols-1 gap-3 rounded-lg border p-3">
                    <MetaItem
                      label="IP"
                      value={
                        detail.ip === null || detail.ip === undefined
                          ? "—"
                          : String(detail.ip)
                      }
                    />
                    <MetaItem label="UA" value={detail.ua ?? "—"} />
                  </div>
                </section>
              </>
            ) : null}
          </div>
        </SheetContent>
      </Sheet>
    </div>
  );
}
