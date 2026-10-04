"use client";

import * as React from "react";
import {
  BanIcon,
  CheckCheckIcon,
  CircleAlertIcon,
  ListChecksIcon,
  Loader2Icon,
  RefreshCwIcon,
} from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useIsMobile } from "@/hooks/use-mobile";
import { cn } from "@/lib/utils";
import type { Database, Json } from "@/lib/database.types";
import {
  asSyncConflictResolution,
  asSyncRunStatus,
  asSyncTriggerType,
  SYNC_CONFLICT_RESOLUTION_BADGE_CLASSES,
  SYNC_CONFLICT_RESOLUTION_LABELS,
  SYNC_RUN_STATUS_BADGE_CLASSES,
  SYNC_RUN_STATUS_LABELS,
  SYNC_TARGET_TABLE_LABELS,
  asSyncTargetTable,
  SYNC_TRIGGER_TYPE_LABELS,
  translateSyncErrorMessage,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type RunRow =
  Database["public"]["Functions"]["get_sync_runs"]["Returns"][number];
type ConflictRow =
  Database["public"]["Functions"]["get_sync_run_conflicts"]["Returns"][number];

type RunStats = {
  insert: number;
  update: number;
  conflict: number;
  skip: number;
  failed: number;
};

const EMPTY_STATS: RunStats = {
  insert: 0,
  update: 0,
  conflict: 0,
  skip: 0,
  failed: 0,
};

const parseStats = (stats: Json): RunStats => {
  if (!stats || typeof stats !== "object" || Array.isArray(stats)) {
    return EMPTY_STATS;
  }
  const record = stats as Record<string, unknown>;
  const num = (key: keyof RunStats): number =>
    typeof record[key] === "number" ? (record[key] as number) : 0;
  return {
    insert: num("insert"),
    update: num("update"),
    conflict: num("conflict"),
    skip: num("skip"),
    failed: num("failed"),
  };
};

const formatDateTime = (value: string | null | undefined): string => {
  if (!value) {
    return "—";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }
  return date.toLocaleString("zh-CN", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  });
};

const formatDuration = (
  startedAt: string,
  finishedAt: string | null | undefined,
): string => {
  if (!finishedAt) {
    return "执行中";
  }
  const start = new Date(startedAt).getTime();
  const finish = new Date(finishedAt).getTime();
  if (Number.isNaN(start) || Number.isNaN(finish) || finish < start) {
    return "—";
  }
  const seconds = (finish - start) / 1000;
  if (seconds < 60) {
    return `${seconds.toFixed(seconds < 10 ? 1 : 0)} 秒`;
  }
  return `${Math.floor(seconds / 60)} 分 ${Math.round(seconds % 60)} 秒`;
};

/** 值摘要：对象按键值行展开（最多 6 行），其余 JSON 序列化 */
const summarizeJson = (value: Json | null | undefined): string[] => {
  if (value === null || value === undefined) {
    return ["—"];
  }
  if (typeof value !== "object" || Array.isArray(value)) {
    return [JSON.stringify(value)];
  }
  return Object.entries(value)
    .slice(0, 6)
    .map(([key, item]) => `${key}: ${JSON.stringify(item)}`);
};

const STAT_ITEMS: { key: keyof RunStats; label: string; className: string }[] = [
  { key: "insert", label: "新增", className: "text-emerald-600 dark:text-emerald-400" },
  { key: "update", label: "更新", className: "text-blue-600 dark:text-blue-400" },
  { key: "conflict", label: "冲突", className: "text-amber-600 dark:text-amber-400" },
  { key: "skip", label: "跳过", className: "text-muted-foreground" },
  { key: "failed", label: "失败", className: "text-red-600 dark:text-red-400" },
];

export function SyncRunsTable() {
  const isMobile = useIsMobile();
  const [runs, setRuns] = React.useState<RunRow[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [detailOpen, setDetailOpen] = React.useState(false);
  const [selected, setSelected] = React.useState<RunRow | null>(null);
  const [conflicts, setConflicts] = React.useState<ConflictRow[]>([]);
  const [conflictsLoading, setConflictsLoading] = React.useState(false);
  const [resolvingId, setResolvingId] = React.useState<string | null>(null);

  const load = React.useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const supabase = createClient();
      const { data, error: loadError } = await supabase.rpc("get_sync_runs", {
        p_task_id: undefined,
        p_limit: 100,
        p_offset: 0,
      });
      if (loadError) {
        setError(loadError.message);
        setRuns([]);
      } else {
        setRuns(data ?? []);
      }
    } catch (loadError) {
      setError(
        loadError instanceof Error ? loadError.message : String(loadError),
      );
      setRuns([]);
    }
    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const loadConflicts = React.useCallback(async (runId: string) => {
    setConflictsLoading(true);
    const supabase = createClient();
    const { data, error: loadError } = await supabase.rpc(
      "get_sync_run_conflicts",
      { p_run_id: runId },
    );
    setConflictsLoading(false);
    if (loadError) {
      toast.error(translateSyncErrorMessage(loadError.message));
      setConflicts([]);
      return;
    }
    setConflicts(data ?? []);
  }, []);

  const openDetail = (run: RunRow) => {
    setSelected(run);
    setConflicts([]);
    setDetailOpen(true);
    void loadConflicts(run.id);
  };

  const handleResolve = async (
    conflict: ConflictRow,
    resolution: "adopted" | "ignored",
  ) => {
    setResolvingId(conflict.id);
    const supabase = createClient();
    const { error: resolveError } = await supabase.rpc(
      "resolve_sync_conflict",
      { p_conflict_id: conflict.id, p_resolution: resolution },
    );
    setResolvingId(null);

    if (resolveError) {
      toast.error(translateSyncErrorMessage(resolveError.message));
      return;
    }

    toast.success(resolution === "adopted" ? "已采纳源值" : "已忽略（保留目标值）");

    // 本地同步详情：pending 减一；无失败且无剩余 pending 时 partial→success（与后端一致）
    setSelected((prev) => {
      if (!prev || prev.id !== conflict.run_id) {
        return prev;
      }
      const pending = Math.max(0, prev.pending_conflicts - 1);
      const stats = parseStats(prev.stats);
      const nextStatus =
        pending === 0 &&
        stats.failed === 0 &&
        !prev.error &&
        prev.status === "partial"
          ? "success"
          : prev.status;
      return { ...prev, pending_conflicts: pending, status: nextStatus };
    });

    if (selected) {
      void loadConflicts(selected.id);
    }
    void load();
  };

  const renderRunStatus = (status: string) => {
    const normalized = asSyncRunStatus(status);
    return (
      <Badge
        variant="outline"
        className={SYNC_RUN_STATUS_BADGE_CLASSES[normalized]}
      >
        {SYNC_RUN_STATUS_LABELS[normalized]}
      </Badge>
    );
  };

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardHeader>
          <CardTitle>执行记录</CardTitle>
          <CardDescription>
            每次同步执行的技术明细：触发方式、计数、耗时与错误；冲突策略为「人工处理」的行在此裁决
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex items-center justify-end gap-2">
            <Button
              variant="outline"
              size="icon"
              onClick={() => void load()}
              disabled={loading}
              aria-label="刷新执行记录"
              className="h-11 w-11 lg:h-8 lg:w-8"
            >
              <RefreshCwIcon className={loading ? "animate-spin" : undefined} />
            </Button>
          </div>

          {loading ? (
            <div className="flex flex-col gap-2">
              {Array.from({ length: 4 }).map((_, index) => (
                <Skeleton key={index} className="h-12 w-full" />
              ))}
            </div>
          ) : error ? (
            <div className="flex flex-col items-center gap-2 py-8 text-sm">
              <p className="text-destructive">
                加载失败：{translateSyncErrorMessage(error)}
              </p>
              <Button variant="outline" onClick={() => void load()}>
                重试
              </Button>
            </div>
          ) : runs.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <ListChecksIcon className="size-8 opacity-60" />
              <span>暂无执行记录，触发一次同步任务后在此查看</span>
            </div>
          ) : isMobile ? (
            <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
              {runs.map((run) => {
                const stats = parseStats(run.stats);
                return (
                  <button
                    key={run.id}
                    type="button"
                    data-slot="sync-run-card"
                    onClick={() => openDetail(run)}
                    className="flex w-full flex-col gap-2.5 rounded-xl border bg-card p-4 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                  >
                    <div className="flex items-start justify-between gap-3">
                      <div className="min-w-0">
                        <div className="truncate font-medium">
                          {run.task_name}
                        </div>
                        <div className="truncate text-xs text-muted-foreground">
                          {formatDateTime(run.started_at)} ·{" "}
                          {formatDuration(run.started_at, run.finished_at)}
                        </div>
                      </div>
                      {renderRunStatus(run.status)}
                    </div>
                    <div className="flex flex-wrap items-center gap-1.5">
                      <Badge variant="outline">
                        {SYNC_TRIGGER_TYPE_LABELS[asSyncTriggerType(run.trigger_type)]}
                      </Badge>
                      <Badge variant="outline">
                        {SYNC_TARGET_TABLE_LABELS[asSyncTargetTable(run.target_table)]}
                      </Badge>
                      {run.pending_conflicts > 0 ? (
                        <Badge
                          variant="outline"
                          className={
                            SYNC_CONFLICT_RESOLUTION_BADGE_CLASSES.pending
                          }
                        >
                          待裁决 {run.pending_conflicts}
                        </Badge>
                      ) : null}
                    </div>
                    <div className="flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted-foreground">
                      <span>新增 {stats.insert}</span>
                      <span>更新 {stats.update}</span>
                      <span>冲突 {stats.conflict}</span>
                      <span>跳过 {stats.skip}</span>
                      <span>失败 {stats.failed}</span>
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
                    <TableHead className="text-center">任务</TableHead>
                    <TableHead className="text-center">触发</TableHead>
                    <TableHead className="text-center">开始时间</TableHead>
                    <TableHead className="text-center">耗时</TableHead>
                    <TableHead className="text-center">结果</TableHead>
                    <TableHead className="text-center">新增</TableHead>
                    <TableHead className="text-center">更新</TableHead>
                    <TableHead className="text-center">冲突</TableHead>
                    <TableHead className="text-center">跳过</TableHead>
                    <TableHead className="text-center">失败</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {runs.map((run) => {
                    const stats = parseStats(run.stats);
                    return (
                      <TableRow
                        key={run.id}
                        className="cursor-pointer"
                        onClick={() => openDetail(run)}
                      >
                        <TableCell className="text-center font-medium">
                          {run.task_name}
                        </TableCell>
                        <TableCell className="text-center">
                          <Badge variant="outline">
                            {
                              SYNC_TRIGGER_TYPE_LABELS[
                                asSyncTriggerType(run.trigger_type)
                              ]
                            }
                          </Badge>
                        </TableCell>
                        <TableCell className="text-center text-xs text-muted-foreground">
                          {formatDateTime(run.started_at)}
                        </TableCell>
                        <TableCell className="text-center text-xs text-muted-foreground">
                          {formatDuration(run.started_at, run.finished_at)}
                        </TableCell>
                        <TableCell className="text-center">
                          <div className="flex items-center justify-center gap-1">
                            {renderRunStatus(run.status)}
                            {run.pending_conflicts > 0 ? (
                              <Badge
                                variant="outline"
                                className={
                                  SYNC_CONFLICT_RESOLUTION_BADGE_CLASSES.pending
                                }
                              >
                                {run.pending_conflicts}
                              </Badge>
                            ) : null}
                          </div>
                        </TableCell>
                        <TableCell className="text-center tabular-nums">
                          {stats.insert}
                        </TableCell>
                        <TableCell className="text-center tabular-nums">
                          {stats.update}
                        </TableCell>
                        <TableCell className="text-center tabular-nums">
                          {stats.conflict}
                        </TableCell>
                        <TableCell className="text-center tabular-nums">
                          {stats.skip}
                        </TableCell>
                        <TableCell
                          className={cn(
                            "text-center tabular-nums",
                            stats.failed > 0 && "font-medium text-red-600 dark:text-red-400",
                          )}
                        >
                          {stats.failed}
                        </TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </div>
          )}
        </CardContent>
      </Card>

      <Sheet open={detailOpen} onOpenChange={setDetailOpen}>
        <SheetContent
          side="right"
          className="w-full overflow-hidden sm:max-w-3xl"
        >
          <SheetHeader>
            <SheetTitle>执行详情</SheetTitle>
            <SheetDescription className="flex flex-wrap items-center gap-2">
              {selected ? (
                <>
                  <span className="font-medium text-foreground">
                    {selected.task_name}
                  </span>
                  <Badge variant="outline">
                    {
                      SYNC_TRIGGER_TYPE_LABELS[
                        asSyncTriggerType(selected.trigger_type)
                      ]
                    }
                  </Badge>
                  {renderRunStatus(selected.status)}
                  <span className="text-xs">
                    {formatDateTime(selected.started_at)}
                  </span>
                </>
              ) : null}
            </SheetDescription>
          </SheetHeader>

          {selected ? (
            <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-4">
              <div className="grid grid-cols-5 gap-2">
                {STAT_ITEMS.map((item) => (
                  <div
                    key={item.key}
                    className="rounded-xl border p-3 text-center"
                  >
                    <div
                      className={cn(
                        "text-xl font-semibold tabular-nums",
                        item.className,
                      )}
                    >
                      {parseStats(selected.stats)[item.key]}
                    </div>
                    <div className="text-xs text-muted-foreground">
                      {item.label}
                    </div>
                  </div>
                ))}
              </div>

              <div className="grid grid-cols-2 gap-2 text-xs text-muted-foreground">
                <div>开始：{formatDateTime(selected.started_at)}</div>
                <div>结束：{formatDateTime(selected.finished_at)}</div>
                <div>
                  耗时：{formatDuration(selected.started_at, selected.finished_at)}
                </div>
                <div>执行人：{selected.executed_by_name ?? "—"}</div>
              </div>

              <Tabs defaultValue="conflicts" className="min-h-0">
                <TabsList>
                  <TabsTrigger value="conflicts">
                    冲突队列
                    {selected.pending_conflicts > 0
                      ? `（${selected.pending_conflicts}）`
                      : ""}
                  </TabsTrigger>
                  <TabsTrigger value="errors">错误明细</TabsTrigger>
                </TabsList>

                <TabsContent value="conflicts" className="flex flex-col gap-2">
                  {conflictsLoading ? (
                    <div className="flex flex-col gap-2">
                      {Array.from({ length: 3 }).map((_, index) => (
                        <Skeleton key={index} className="h-20 w-full" />
                      ))}
                    </div>
                  ) : conflicts.length === 0 ? (
                    <div className="flex flex-col items-center gap-2 py-10 text-sm text-muted-foreground">
                      <CheckCheckIcon className="size-8 opacity-60" />
                      <span>本次执行无冲突记录</span>
                    </div>
                  ) : (
                    conflicts.map((conflict) => {
                      const resolution = asSyncConflictResolution(
                        conflict.resolution,
                      );
                      return (
                        <div
                          key={conflict.id}
                          className="flex flex-col gap-2 rounded-xl border p-3"
                        >
                          <div className="flex flex-wrap items-center justify-between gap-2">
                            <div className="font-medium">
                              {conflict.row_key}
                            </div>
                            <Badge
                              variant="outline"
                              className={
                                SYNC_CONFLICT_RESOLUTION_BADGE_CLASSES[resolution]
                              }
                            >
                              {SYNC_CONFLICT_RESOLUTION_LABELS[resolution]}
                            </Badge>
                          </div>
                          <div className="grid gap-2 text-xs sm:grid-cols-2">
                            <div className="rounded-lg bg-muted/50 p-2">
                              <div className="mb-1 font-medium">源值</div>
                              {summarizeJson(conflict.source_data).map((line) => (
                                <div key={line} className="truncate">
                                  {line}
                                </div>
                              ))}
                            </div>
                            <div className="rounded-lg bg-muted/50 p-2">
                              <div className="mb-1 font-medium">目标值</div>
                              {summarizeJson(conflict.target_data).map((line) => (
                                <div key={line} className="truncate">
                                  {line}
                                </div>
                              ))}
                            </div>
                          </div>
                          {resolution === "pending" ? (
                            <div className="flex items-center justify-end gap-2">
                              <Button
                                size="sm"
                                variant="outline"
                                disabled={resolvingId === conflict.id}
                                onClick={() =>
                                  void handleResolve(conflict, "ignored")
                                }
                              >
                                <BanIcon data-icon="inline-start" />
                                忽略（保留目标值）
                              </Button>
                              <Button
                                size="sm"
                                disabled={resolvingId === conflict.id}
                                onClick={() =>
                                  void handleResolve(conflict, "adopted")
                                }
                              >
                                {resolvingId === conflict.id ? (
                                  <Loader2Icon
                                    className="animate-spin"
                                    data-icon="inline-start"
                                  />
                                ) : (
                                  <CheckCheckIcon data-icon="inline-start" />
                                )}
                                采纳源值
                              </Button>
                            </div>
                          ) : (
                            <div className="text-right text-xs text-muted-foreground">
                              {conflict.resolved_by_name
                                ? `${conflict.resolved_by_name} · `
                                : ""}
                              {formatDateTime(conflict.resolved_at)}
                            </div>
                          )}
                        </div>
                      );
                    })
                  )}
                </TabsContent>

                <TabsContent value="errors">
                  {selected.error ? (
                    <div className="flex items-start gap-2 rounded-xl border border-red-200 bg-red-50 p-3 text-xs text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300">
                      <CircleAlertIcon className="mt-0.5 size-4 shrink-0" />
                      <pre className="whitespace-pre-wrap font-mono">
                        {selected.error}
                      </pre>
                    </div>
                  ) : (
                    <div className="flex flex-col items-center gap-2 py-10 text-sm text-muted-foreground">
                      <CheckCheckIcon className="size-8 opacity-60" />
                      <span>本次执行无错误</span>
                    </div>
                  )}
                </TabsContent>
              </Tabs>
            </div>
          ) : null}
        </SheetContent>
      </Sheet>
    </div>
  );
}
