"use client";

// 权限审计页面（access/011）：权限域专用审计视图。
// 列表 A「权限变更记录」：audit_operations_v 过滤 module='access'（role/menu_grant/profile_role/
//   role_data_scope 的 create/update/assign/grant/revoke/...），筛选 操作人/对象类型/时间段，
//   列展示差异摘要，详情 Sheet 用 DiffView 渲染字段级前后值。
// 列表 B「越权尝试」：audit_denied_v（user/module/route/reason/time）只读展示；
//   写入由各模块守衞/RLS 捕获后经 audit_log('denied') 完成，当前无写入方时显式空态说明。
// 导出：request_export('audit.operations')（report 统一导出管道），toast 引导 /report/exports。

import * as React from "react";
import { useRouter } from "next/navigation";
import {
  DownloadIcon,
  FileClockIcon,
  Loader2Icon,
  ShieldAlertIcon,
} from "lucide-react";
import { toast } from "sonner";

import { DiffView } from "@/components/audit/diff-view";
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
/** 首版内存筛选：与 audit/004 操作日志一致，取最近 500 条（v2 改服务端筛选） */
const FETCH_LIMIT = 500;
const DENIED_LIMIT = 200;

type OperationRow = Database["public"]["Views"]["audit_operations_v"]["Row"];
type DeniedRow = Database["public"]["Views"]["audit_denied_v"]["Row"];

/** access 模块审计对象类型 → 展示名；未知类型回退原始标识 */
const OBJECT_TYPE_LABELS: Record<string, string> = {
  role: "角色",
  profile_role: "用户角色",
  menu_grant: "菜单授权",
  role_data_scope: "数据范围",
};

function objectTypeLabel(objectType: string | null | undefined): string {
  if (!objectType) {
    return "—";
  }
  return OBJECT_TYPE_LABELS[objectType] ?? objectType;
}

function ActionBadge({ action }: { action: string | null }) {
  return (
    <Badge variant="outline" className={auditActionBadgeClass(action ?? "")}>
      {auditActionLabel(action)}
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

export function AccessAuditView() {
  const isMobile = useIsMobile();
  const router = useRouter();

  const [ops, setOps] = React.useState<OperationRow[]>([]);
  const [opsLoading, setOpsLoading] = React.useState(true);
  const [opsError, setOpsError] = React.useState<string | null>(null);

  const [denied, setDenied] = React.useState<DeniedRow[]>([]);
  const [deniedLoading, setDeniedLoading] = React.useState(true);
  const [deniedError, setDeniedError] = React.useState<string | null>(null);

  const [actorFilter, setActorFilter] = React.useState(ALL);
  const [objectTypeFilter, setObjectTypeFilter] = React.useState(ALL);
  const [dateFrom, setDateFrom] = React.useState("");
  const [dateTo, setDateTo] = React.useState("");
  const [page, setPage] = React.useState(1);

  const [deniedModuleFilter, setDeniedModuleFilter] = React.useState(ALL);

  const [detail, setDetail] = React.useState<OperationRow | null>(null);
  const [exporting, setExporting] = React.useState(false);

  const load = React.useCallback(async () => {
    const supabase = createClient();

    setOpsLoading(true);
    setOpsError(null);
    setDeniedLoading(true);
    setDeniedError(null);

    const [opsResult, deniedResult] = await Promise.all([
      supabase
        .from("audit_operations_v")
        .select("*")
        .eq("module", "access")
        .neq("action", "denied")
        .order("created_at", { ascending: false })
        .limit(FETCH_LIMIT),
      supabase
        .from("audit_denied_v")
        .select("*")
        .order("time", { ascending: false })
        .limit(DENIED_LIMIT),
    ]);

    if (opsResult.error) {
      setOpsError(opsResult.error.message);
      setOps([]);
    } else {
      setOps(opsResult.data ?? []);
    }
    setOpsLoading(false);

    if (deniedResult.error) {
      setDeniedError(deniedResult.error.message);
      setDenied([]);
    } else {
      setDenied(deniedResult.data ?? []);
    }
    setDeniedLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  React.useEffect(() => {
    setPage(1);
  }, [actorFilter, objectTypeFilter, dateFrom, dateTo]);

  const objectTypeOptions = React.useMemo(
    () =>
      Array.from(
        new Set(
          ops
            .map((row) => row.object_type)
            .filter((type): type is string => typeof type === "string"),
        ),
      ).sort((a, b) => a.localeCompare(b, "zh-CN")),
    [ops],
  );

  /** 操作人下拉：actor_id → 姓名；NULL 归入「系统/后台」 */
  const actorOptions = React.useMemo(() => {
    const map = new Map<string, string>();
    for (const row of ops) {
      if (!row.actor_id || map.has(row.actor_id)) {
        continue;
      }
      map.set(row.actor_id, row.actor_name?.trim() || `${row.actor_id.slice(0, 8)}…`);
    }
    return Array.from(map, ([id, label]) => ({ id, label })).sort((a, b) =>
      a.label.localeCompare(b.label, "zh-CN"),
    );
  }, [ops]);

  const filteredOps = React.useMemo(() => {
    const fromTime = dateFrom ? new Date(`${dateFrom}T00:00:00`).getTime() : null;
    const toTime = dateTo ? new Date(`${dateTo}T23:59:59.999`).getTime() : null;

    return ops.filter((row) => {
      if (actorFilter !== ALL) {
        if (actorFilter === SYSTEM) {
          if (row.actor_id !== null) {
            return false;
          }
        } else if (row.actor_id !== actorFilter) {
          return false;
        }
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
  }, [ops, actorFilter, objectTypeFilter, dateFrom, dateTo]);

  const pageCount = Math.max(1, Math.ceil(filteredOps.length / PAGE_SIZE));
  const currentPage = Math.min(page, pageCount);
  const pagedOps = filteredOps.slice(
    (currentPage - 1) * PAGE_SIZE,
    currentPage * PAGE_SIZE,
  );
  const hasActiveFilters =
    actorFilter !== ALL ||
    objectTypeFilter !== ALL ||
    dateFrom !== "" ||
    dateTo !== "";

  const resetFilters = () => {
    setActorFilter(ALL);
    setObjectTypeFilter(ALL);
    setDateFrom("");
    setDateTo("");
  };

  const deniedModuleOptions = React.useMemo(
    () =>
      Array.from(
        new Set(
          denied
            .map((row) => row.module)
            .filter((module): module is string => typeof module === "string"),
        ),
      ).sort((a, b) => a.localeCompare(b, "zh-CN")),
    [denied],
  );

  const filteredDenied = React.useMemo(
    () =>
      denied.filter(
        (row) =>
          deniedModuleFilter === ALL || row.module === deniedModuleFilter,
      ),
    [denied, deniedModuleFilter],
  );

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
    toast.success("导出任务已创建", {
      action: {
        label: "前往下载",
        onClick: () => router.push("/report/exports"),
      },
    });
  };

  const renderOpsList = () => {
    if (opsLoading) {
      return (
        <div className="flex flex-col gap-2">
          {Array.from({ length: 4 }).map((_, index) => (
            <Skeleton key={index} className="h-12 w-full" />
          ))}
        </div>
      );
    }
    if (opsError) {
      return (
        <div className="flex flex-col items-center gap-2 py-8 text-sm">
          <p className="text-destructive">
            加载失败：{translateAuditErrorMessage(opsError)}
          </p>
          <Button variant="outline" onClick={() => void load()}>
            重试
          </Button>
        </div>
      );
    }
    if (pagedOps.length === 0) {
      return (
        <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
          <FileClockIcon className="size-8 opacity-60" />
          {hasActiveFilters ? (
            <>
              <span>未找到匹配的权限变更记录</span>
              <Button variant="outline" size="sm" onClick={resetFilters}>
                清除筛选
              </Button>
            </>
          ) : (
            <span>暂无权限变更记录</span>
          )}
        </div>
      );
    }

    if (isMobile) {
      return (
        <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
          {pagedOps.map((row) => (
            <button
              key={row.id}
              type="button"
              onClick={() => setDetail(row)}
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
                  <span className="text-muted-foreground">对象</span>
                  <span className="truncate">
                    {objectTypeLabel(row.object_type)}
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
              <TableHead className="text-center">对象类型</TableHead>
              <TableHead className="text-center">动作</TableHead>
              <TableHead className="text-center">差异摘要</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {pagedOps.map((row) => (
              <TableRow
                key={row.id}
                className="cursor-pointer"
                role="button"
                tabIndex={0}
                aria-label={`查看权限变更详情：${row.actor_name ?? "系统/后台"} · ${formatDateTime(row.created_at)}`}
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
                  {row.actor_name ?? "系统/后台"}
                </TableCell>
                <TableCell className="text-center">
                  {objectTypeLabel(row.object_type)}
                </TableCell>
                <TableCell className="text-center">
                  <ActionBadge action={row.action} />
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

  const renderDeniedList = () => {
    if (deniedLoading) {
      return (
        <div className="flex flex-col gap-2">
          {Array.from({ length: 3 }).map((_, index) => (
            <Skeleton key={index} className="h-12 w-full" />
          ))}
        </div>
      );
    }
    if (deniedError) {
      return (
        <div className="flex flex-col items-center gap-2 py-8 text-sm">
          <p className="text-destructive">
            加载失败：{translateAuditErrorMessage(deniedError)}
          </p>
          <Button variant="outline" onClick={() => void load()}>
            重试
          </Button>
        </div>
      );
    }
    if (filteredDenied.length === 0) {
      return (
        <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
          <ShieldAlertIcon className="size-8 opacity-60" />
          <span>暂无越权记录</span>
          <p className="max-w-md text-center text-xs">
            越权记录依赖应用层捕获：各模块守卫 / RLS 拒绝后调用
            audit_log 写入 denied 事件后在此展示。
          </p>
        </div>
      );
    }

    if (isMobile) {
      return (
        <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
          {filteredDenied.map((row, index) => (
            <div
              key={`${row.user_id ?? "anon"}-${row.time ?? ""}-${index}`}
              className="flex w-full flex-col gap-2 rounded-xl border bg-card p-3 shadow-xs"
            >
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <div className="truncate font-medium">
                    {row.user_name ?? row.user_id ?? "匿名/后台"}
                  </div>
                  <div className="truncate text-xs leading-tight text-muted-foreground">
                    {formatDateTime(row.time)}
                  </div>
                </div>
                <Badge variant="outline" className="text-muted-foreground">
                  {auditModuleLabel(row.module)}
                </Badge>
              </div>
              <div className="flex flex-col gap-1.5 text-sm">
                <div className="flex items-start justify-between gap-4">
                  <span className="shrink-0 text-muted-foreground">路由</span>
                  <span className="font-mono text-right text-xs break-all">
                    {row.route ?? "—"}
                  </span>
                </div>
                <div className="flex items-start justify-between gap-4">
                  <span className="shrink-0 text-muted-foreground">原因</span>
                  <span className="text-right text-xs break-all">
                    {row.reason ?? "—"}
                  </span>
                </div>
              </div>
            </div>
          ))}
        </div>
      );
    }

    return (
      <div className="overflow-x-auto">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="text-center">用户</TableHead>
              <TableHead className="text-center">模块</TableHead>
              <TableHead className="text-center">路由</TableHead>
              <TableHead className="text-center">原因</TableHead>
              <TableHead className="text-center">时间</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {filteredDenied.map((row, index) => (
              <TableRow key={`${row.user_id ?? "anon"}-${row.time ?? ""}-${index}`}>
                <TableCell className="text-center">
                  {row.user_name ?? row.user_id ?? "匿名/后台"}
                </TableCell>
                <TableCell className="text-center">
                  <Badge variant="outline" className="text-muted-foreground">
                    {auditModuleLabel(row.module)}
                  </Badge>
                </TableCell>
                <TableCell className="max-w-64 text-center font-mono text-xs break-all">
                  {row.route ?? "—"}
                </TableCell>
                <TableCell className="max-w-72 text-center text-xs text-muted-foreground">
                  {row.reason ?? "—"}
                </TableCell>
                <TableCell className="text-center text-xs whitespace-nowrap text-muted-foreground">
                  {formatDateTime(row.time)}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    );
  };

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card gap-3! py-3!">
        <CardHeader>
          <CardTitle>权限变更记录</CardTitle>
          <CardDescription>
            角色、菜单授权、数据范围的角色级变更（audit module=access）
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-wrap items-center gap-2">
            <Select value={actorFilter} onValueChange={setActorFilter}>
              <SelectTrigger
                className="w-full sm:w-36 min-h-11 lg:min-h-8"
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
            <Select
              value={objectTypeFilter}
              onValueChange={setObjectTypeFilter}
            >
              <SelectTrigger
                className="w-full sm:w-36 min-h-11 lg:min-h-8"
                aria-label="按对象类型筛选"
              >
                <SelectValue placeholder="全部对象" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL}>全部对象</SelectItem>
                {objectTypeOptions.map((type) => (
                  <SelectItem key={type} value={type}>
                    {objectTypeLabel(type)}
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

          {renderOpsList()}

          {!opsLoading && !opsError && filteredOps.length > 0 ? (
            <div className="flex items-center justify-between gap-2 text-sm text-muted-foreground">
              <span>
                {hasActiveFilters
                  ? `匹配 ${filteredOps.length} 条（共 ${ops.length} 条）· 第 ${currentPage} / ${pageCount} 页`
                  : `共 ${filteredOps.length} 条 · 第 ${currentPage} / ${pageCount} 页`}
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

      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card gap-3! py-3!">
        <CardHeader>
          <CardTitle>越权尝试</CardTitle>
          <CardDescription>
            被 RLS / 页面守卫拒绝的访问尝试（audit_denied_v）
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          {deniedModuleOptions.length > 0 ? (
            <div className="flex flex-wrap items-center gap-2">
              <Select
                value={deniedModuleFilter}
                onValueChange={setDeniedModuleFilter}
              >
                <SelectTrigger
                  className="w-full sm:w-36 min-h-11 lg:min-h-8"
                  aria-label="按模块筛选越权记录"
                >
                  <SelectValue placeholder="全部模块" />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value={ALL}>全部模块</SelectItem>
                  {deniedModuleOptions.map((module) => (
                    <SelectItem key={module} value={module}>
                      {auditModuleLabel(module)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          ) : null}

          {renderDeniedList()}

          {!deniedLoading && !deniedError && filteredDenied.length > 0 ? (
            <div className="text-sm text-muted-foreground">
              {deniedModuleFilter === ALL
                ? `共 ${filteredDenied.length} 条越权记录`
                : `匹配 ${filteredDenied.length} 条（共 ${denied.length} 条）`}
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
                ? `${auditActionLabel(detail.action)} · ${objectTypeLabel(detail.object_type)}`
                : "权限变更详情"}
            </SheetTitle>
            <SheetDescription>
              {detail?.id !== null && detail?.id !== undefined
                ? `记录 #${detail.id}`
                : "权限变更记录详情"}
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
                    label="对象类型"
                    value={objectTypeLabel(detail.object_type)}
                  />
                  <MetaItem
                    label="动作"
                    value={<ActionBadge action={detail.action} />}
                  />
                  <MetaItem label="对象标识" value={detail.object_id ?? "—"} />
                  <MetaItem
                    label="IP"
                    value={
                      detail.ip === null || detail.ip === undefined
                        ? "—"
                        : String(detail.ip)
                    }
                  />
                </div>
                <section className="flex flex-col gap-2">
                  <h3 className="text-sm font-medium">字段差异</h3>
                  <DiffView diff={detail.diff} />
                </section>
              </>
            ) : null}
          </div>
        </SheetContent>
      </Sheet>
    </div>
  );
}
