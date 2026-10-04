"use client";

// 报表中心 · 数据导出任务页（report/008）
// 列表：来源 / 条件摘要 / 状态 Badge（排队灰·生成蓝·完成绿·失败红；进行中带 spinner）/ 大小 / 时间。
// 详情 Sheet 集成行级动作：下载（download_export → Blob CSV；过期/未完成禁用）、重试（failed → queued）。
// 发起导出 Sheet：enabled 源 Select + 简单 config（audit.operations 时间段；org.users 无 config）+ 限额提示。
// 自动刷新：存在 queued/running 时每 5s 静默轮询列表。

import * as React from "react";
import {
  DownloadIcon,
  FileSpreadsheetIcon,
  Loader2Icon,
  PlusIcon,
  RotateCwIcon,
} from "lucide-react";
import { toast } from "sonner";

import {
  ReportEmptyState,
  ReportErrorState,
  ReportLoadingSkeleton,
} from "@/components/report/report-shared";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import {
  Field,
  FieldDescription,
  FieldLabel,
} from "@/components/ui/field";
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
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { useIsMobile } from "@/hooks/use-mobile";
import type { Json } from "@/lib/database.types";
import {
  EXPORT_ACTIVE_LIMIT,
  EXPORT_STATUS_BADGE_CLASSES,
  EXPORT_STATUS_LABELS,
  exportConfigSummary,
  exportFileName,
  exportSourceLabel,
  exportStatusOf,
  formatBytes,
  formatDateTime,
  isAdminOnlySource,
  isExportExpired,
  translateReportErrorMessage,
} from "@/lib/report";
import { createClient } from "@/lib/supabase/client";

const PAGE_SIZE = 20;
const POLL_INTERVAL_MS = 5000;

type ExportJob = {
  id: string;
  source: string;
  config: Json;
  status: string;
  size_bytes: number | null;
  error: string | null;
  requested_by: string;
  created_at: string;
  started_at: string | null;
  finished_at: string | null;
};

type ExportSource = {
  source: string;
  config_schema: Json;
  owner_module: string;
  enabled: boolean;
};

function StatusBadge({ status }: { status: string }) {
  const parsed = exportStatusOf(status);
  const active = parsed === "queued" || parsed === "running";
  return (
    <Badge variant="outline" className={EXPORT_STATUS_BADGE_CLASSES[parsed]}>
      {active ? <Loader2Icon className="animate-spin" /> : null}
      {EXPORT_STATUS_LABELS[parsed]}
    </Badge>
  );
}

export function ExportsList({ currentUserId, isAdmin }: { currentUserId: string; isAdmin: boolean }) {
  const isMobile = useIsMobile();
  const [jobs, setJobs] = React.useState<ExportJob[]>([]);
  const [sources, setSources] = React.useState<ExportSource[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [page, setPage] = React.useState(1);
  const [detailId, setDetailId] = React.useState<string | null>(null);
  const [downloadingId, setDownloadingId] = React.useState<string | null>(null);
  const [retryingId, setRetryingId] = React.useState<string | null>(null);
  const [requestOpen, setRequestOpen] = React.useState(false);
  const [requestSource, setRequestSource] = React.useState("");
  const [requestStart, setRequestStart] = React.useState("");
  const [requestEnd, setRequestEnd] = React.useState("");
  const [requesting, setRequesting] = React.useState(false);

  const load = React.useCallback(async (options?: { silent?: boolean }) => {
    if (!options?.silent) {
      setLoading(true);
      setError(null);
    }
    const supabase = createClient();
    const [jobRes, sourceRes] = await Promise.all([
      supabase
        .from("export_jobs")
        .select(
          "id, source, config, status, size_bytes, error, requested_by, created_at, started_at, finished_at",
        )
        .order("created_at", { ascending: false }),
      supabase
        .from("export_sources")
        .select("source, config_schema, owner_module, enabled")
        .order("source"),
    ]);

    if (jobRes.error) {
      if (!options?.silent) {
        setError(jobRes.error.message);
        setJobs([]);
      }
    } else {
      setJobs((jobRes.data ?? []) as ExportJob[]);
    }

    if (!sourceRes.error) {
      setSources((sourceRes.data ?? []) as ExportSource[]);
    }

    if (!options?.silent) {
      setLoading(false);
    }
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const hasActive = jobs.some(
    (job) => job.status === "queued" || job.status === "running",
  );

  // 自动刷新：queued/running 存在时每 5s 静默轮询
  React.useEffect(() => {
    if (!hasActive) {
      return;
    }
    const timer = window.setInterval(() => {
      void load({ silent: true });
    }, POLL_INTERVAL_MS);
    return () => window.clearInterval(timer);
  }, [hasActive, load]);

  const availableSources = React.useMemo(
    () =>
      sources.filter(
        (source) =>
          source.enabled &&
          (isAdmin || !isAdminOnlySource(source.config_schema)),
      ),
    [sources, isAdmin],
  );

  const myActiveCount = jobs.filter(
    (job) =>
      job.requested_by === currentUserId &&
      (job.status === "queued" || job.status === "running"),
  ).length;
  const limitReached = myActiveCount >= EXPORT_ACTIVE_LIMIT;

  const openRequest = () => {
    setRequestSource(availableSources[0]?.source ?? "");
    setRequestStart("");
    setRequestEnd("");
    setRequestOpen(true);
  };

  const pageCount = Math.max(1, Math.ceil(jobs.length / PAGE_SIZE));
  const currentPage = Math.min(page, pageCount);
  const pagedRows = jobs.slice(
    (currentPage - 1) * PAGE_SIZE,
    currentPage * PAGE_SIZE,
  );

  const activeJob = jobs.find((job) => job.id === detailId) ?? null;

  const handleDownload = async (job: ExportJob) => {
    setDownloadingId(job.id);
    const { data, error: downloadError } = await createClient().rpc(
      "download_export",
      { p_job_id: job.id },
    );
    setDownloadingId(null);

    if (downloadError) {
      toast.error(translateReportErrorMessage(downloadError.message));
      return;
    }
    if (typeof data !== "string") {
      toast.error("下载失败：文件内容为空");
      return;
    }

    // UTF-8 BOM 提升 Excel 打开中文 CSV 的兼容性
    const blob = new Blob([`\uFEFF${data}`], {
      type: "text/csv;charset=utf-8",
    });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = exportFileName(job.source, job.created_at);
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
    toast.success("已开始下载");
  };

  const handleRetry = async (job: ExportJob) => {
    setRetryingId(job.id);
    const { error: retryError } = await createClient().rpc("retry_export", {
      p_job_id: job.id,
    });
    setRetryingId(null);
    if (retryError) {
      toast.error(translateReportErrorMessage(retryError.message));
      return;
    }
    toast.success("已重新排队，稍后刷新");
    void load();
  };

  const handleRequest = async () => {
    if (!requestSource) {
      toast.error("请选择导出源");
      return;
    }
    if (requestStart && requestEnd && requestStart > requestEnd) {
      toast.error("起始时间不能晚于结束时间");
      return;
    }

    const config: Json = {};
    if (requestSource === "audit.operations") {
      if (requestStart) {
        config.start = new Date(requestStart).toISOString();
      }
      if (requestEnd) {
        config.end = new Date(requestEnd).toISOString();
      }
    }

    setRequesting(true);
    const { error: requestError } = await createClient().rpc("request_export", {
      p_source: requestSource,
      p_config: config,
    });
    setRequesting(false);

    if (requestError) {
      toast.error(translateReportErrorMessage(requestError.message));
      return;
    }
    toast.success("已排队，稍后刷新（worker 每分钟处理）");
    setRequestOpen(false);
    void load();
  };

  const renderList = () => {
    if (loading) {
      return <ReportLoadingSkeleton />;
    }
    if (error) {
      return (
        <ReportErrorState
          message={translateReportErrorMessage(error)}
          onRetry={() => void load()}
        />
      );
    }
    if (pagedRows.length === 0) {
      return (
        <ReportEmptyState
          icon={FileSpreadsheetIcon}
          title="暂无导出任务"
          description="点击右上角「发起导出」，选择来源后排队；完成后可在此下载 CSV。"
        />
      );
    }

    if (isMobile) {
      return (
        <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
          {pagedRows.map((job) => (
            <button
              key={job.id}
              type="button"
              onClick={() => setDetailId(job.id)}
              className="flex w-full flex-col gap-2.5 rounded-xl border bg-card p-4 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
            >
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <div className="truncate font-medium">
                    {exportSourceLabel(job.source)}
                  </div>
                  <div className="truncate font-mono text-xs text-muted-foreground">
                    {job.source}
                  </div>
                </div>
                <StatusBadge status={job.status} />
              </div>
              <div className="flex flex-col gap-1.5 text-sm">
                <div className="flex items-center justify-between gap-4">
                  <span className="text-muted-foreground">条件摘要</span>
                  <span className="truncate">{exportConfigSummary(job.config)}</span>
                </div>
                <div className="flex items-center justify-between gap-4">
                  <span className="text-muted-foreground">大小</span>
                  <span className="tabular-nums">
                    {formatBytes(job.size_bytes)}
                  </span>
                </div>
                <div className="flex items-center justify-between gap-4">
                  <span className="text-muted-foreground">发起时间</span>
                  <span className="tabular-nums">
                    {formatDateTime(job.created_at)}
                  </span>
                </div>
                <div className="flex items-center justify-between gap-4">
                  <span className="text-muted-foreground">完成时间</span>
                  <span className="tabular-nums">
                    {job.finished_at ? formatDateTime(job.finished_at) : "—"}
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
              <TableHead className="text-center">来源</TableHead>
              <TableHead className="text-center">条件摘要</TableHead>
              <TableHead className="text-center">状态</TableHead>
              <TableHead className="text-center">大小</TableHead>
              <TableHead className="text-center">发起时间</TableHead>
              <TableHead className="text-center">完成时间</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {pagedRows.map((job) => (
              <TableRow
                key={job.id}
                className="cursor-pointer"
                onClick={() => setDetailId(job.id)}
              >
                <TableCell className="text-center">
                  <div className="font-medium">{exportSourceLabel(job.source)}</div>
                  <div className="font-mono text-xs text-muted-foreground">
                    {job.source}
                  </div>
                </TableCell>
                <TableCell className="text-center text-muted-foreground">
                  {exportConfigSummary(job.config)}
                </TableCell>
                <TableCell className="text-center">
                  <StatusBadge status={job.status} />
                </TableCell>
                <TableCell className="text-center tabular-nums">
                  {formatBytes(job.size_bytes)}
                </TableCell>
                <TableCell className="text-center text-muted-foreground">
                  {formatDateTime(job.created_at)}
                </TableCell>
                <TableCell className="text-center text-muted-foreground">
                  {job.finished_at ? formatDateTime(job.finished_at) : "—"}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    );
  };

  const parsedStatus = activeJob ? exportStatusOf(activeJob.status) : null;
  const expired =
    activeJob !== null && isExportExpired(activeJob.created_at);
  const downloadable =
    activeJob !== null && parsedStatus === "done" && !expired;

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
            <p className="text-xs text-muted-foreground sm:flex-1">
              进行中任务 {myActiveCount} / {EXPORT_ACTIVE_LIMIT}
              {hasActive ? " · 存在进行中任务，列表每 5 秒自动刷新" : ""}
            </p>
            <div className="flex items-center gap-2">
              <Button
                onClick={openRequest}
                disabled={limitReached || availableSources.length === 0}
                className="h-11 flex-1 lg:h-8 lg:flex-none"
              >
                <PlusIcon data-icon="inline-start" />
                发起导出
              </Button>
            </div>
          </div>

          {limitReached ? (
            <p className="text-xs text-amber-600 dark:text-amber-400">
              进行中的导出任务已达上限（{EXPORT_ACTIVE_LIMIT}），
              请等待完成或重试失败任务后再发起。
            </p>
          ) : null}

          {renderList()}

          {!loading && !error && jobs.length > 0 ? (
            <div className="flex items-center justify-between gap-2 text-sm text-muted-foreground">
              <span>
                共 {jobs.length} 条 · 第 {currentPage} / {pageCount} 页
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
        open={activeJob !== null}
        onOpenChange={(open) => {
          if (!open) {
            setDetailId(null);
          }
        }}
      >
        <SheetContent
          side="right"
          className="w-full sm:max-w-[480px]"
        >
          <SheetHeader>
            <SheetTitle>
              {activeJob ? exportSourceLabel(activeJob.source) : "导出任务"}
            </SheetTitle>
            <SheetDescription className="flex flex-col gap-1.5">
              <span className="font-mono text-xs">{activeJob?.source}</span>
              {activeJob ? (
                <span className="flex flex-wrap items-center gap-2">
                  <StatusBadge status={activeJob.status} />
                  <span>大小：{formatBytes(activeJob.size_bytes)}</span>
                </span>
              ) : null}
            </SheetDescription>
          </SheetHeader>

          {activeJob ? (
            <>
              <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-4">
                <div className="rounded-lg border p-3 text-xs text-muted-foreground">
                  条件摘要：{exportConfigSummary(activeJob.config)}
                </div>
                <dl className="flex flex-col gap-2 text-sm">
                  <div className="flex items-center justify-between gap-4">
                    <dt className="text-muted-foreground">发起时间</dt>
                    <dd className="tabular-nums">
                      {formatDateTime(activeJob.created_at)}
                    </dd>
                  </div>
                  <div className="flex items-center justify-between gap-4">
                    <dt className="text-muted-foreground">开始生成</dt>
                    <dd className="tabular-nums">
                      {activeJob.started_at
                        ? formatDateTime(activeJob.started_at)
                        : "—"}
                    </dd>
                  </div>
                  <div className="flex items-center justify-between gap-4">
                    <dt className="text-muted-foreground">完成时间</dt>
                    <dd className="tabular-nums">
                      {activeJob.finished_at
                        ? formatDateTime(activeJob.finished_at)
                        : "—"}
                    </dd>
                  </div>
                  <div className="flex items-center justify-between gap-4">
                    <dt className="text-muted-foreground">任务 ID</dt>
                    <dd className="truncate font-mono text-xs">
                      {activeJob.id}
                    </dd>
                  </div>
                </dl>

                {parsedStatus === "failed" && activeJob.error ? (
                  <div className="rounded-lg border border-red-200 bg-red-50 p-3 text-xs text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300">
                    失败原因：{activeJob.error}
                  </div>
                ) : null}

                {expired && parsedStatus === "done" ? (
                  <p className="text-xs text-amber-600 dark:text-amber-400">
                    该文件已超过 7 天有效期，不可下载（清理后仅保留记录）。
                  </p>
                ) : null}

                {parsedStatus === "queued" || parsedStatus === "running" ? (
                  <p className="text-xs text-muted-foreground">
                    worker 每分钟轮询队列；生成完成后可下载，页面会自动刷新。
                  </p>
                ) : null}
              </div>

              <SheetFooter className="flex-row justify-end gap-2">
                {parsedStatus === "failed" ? (
                  <Button
                    variant="outline"
                    onClick={() => void handleRetry(activeJob)}
                    disabled={retryingId === activeJob.id || limitReached}
                  >
                    {retryingId === activeJob.id ? (
                      <Loader2Icon
                        className="animate-spin"
                        data-icon="inline-start"
                      />
                    ) : (
                      <RotateCwIcon data-icon="inline-start" />
                    )}
                    重试
                  </Button>
                ) : null}
                <Button
                  onClick={() => void handleDownload(activeJob)}
                  disabled={!downloadable || downloadingId === activeJob.id}
                >
                  {downloadingId === activeJob.id ? (
                    <Loader2Icon
                      className="animate-spin"
                      data-icon="inline-start"
                    />
                  ) : (
                    <DownloadIcon data-icon="inline-start" />
                  )}
                  {expired && parsedStatus === "done" ? "已过期" : "下载 CSV"}
                </Button>
              </SheetFooter>
            </>
          ) : null}
        </SheetContent>
      </Sheet>

      <Sheet open={requestOpen} onOpenChange={setRequestOpen}>
        <SheetContent
          side="right"
          className="w-full sm:max-w-[480px]"
        >
          <SheetHeader>
            <SheetTitle>发起导出</SheetTitle>
            <SheetDescription>
              选择导出源；排队后由 worker 异步生成 CSV，可在任务详情下载。
            </SheetDescription>
          </SheetHeader>

          <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-4">
            <Field>
              <FieldLabel htmlFor="export-source">导出源</FieldLabel>
              <Select value={requestSource} onValueChange={setRequestSource}>
                <SelectTrigger id="export-source" className="w-full">
                  <SelectValue placeholder="请选择导出源" />
                </SelectTrigger>
                <SelectContent>
                  {availableSources.map((source) => (
                    <SelectItem key={source.source} value={source.source}>
                      {exportSourceLabel(source.source)}（{source.source}）
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <FieldDescription>
                {requestSource === "audit.operations"
                  ? "管理员独占源：可附加时间段筛选（worker 按属主权限导出）。"
                  : requestSource === "org.users"
                    ? "无附加条件：按你的数据权限导出可见用户名单。"
                    : "该来源暂无附加条件配置。"}
              </FieldDescription>
            </Field>

            {requestSource === "audit.operations" ? (
              <div className="flex flex-col gap-3 rounded-lg border p-3">
                <div className="text-xs font-medium text-muted-foreground">
                  时间段（可选）
                </div>
                <Field>
                  <FieldLabel htmlFor="export-start">起始时间</FieldLabel>
                  <Input
                    id="export-start"
                    type="datetime-local"
                    value={requestStart}
                    onChange={(event) => setRequestStart(event.target.value)}
                  />
                </Field>
                <Field>
                  <FieldLabel htmlFor="export-end">结束时间</FieldLabel>
                  <Input
                    id="export-end"
                    type="datetime-local"
                    value={requestEnd}
                    onChange={(event) => setRequestEnd(event.target.value)}
                  />
                </Field>
                <FieldDescription>
                  v1 记录到任务条件摘要；不填则导出全部可见记录。
                </FieldDescription>
              </div>
            ) : null}

            <p className="text-xs text-muted-foreground">
              限额：单用户同时进行中的任务 ≤ {EXPORT_ACTIVE_LIMIT}（当前
              {myActiveCount}）。
            </p>
          </div>

          <SheetFooter className="flex-row justify-end gap-2">
            <Button variant="outline" onClick={() => setRequestOpen(false)}>
              取消
            </Button>
            <Button
              onClick={() => void handleRequest()}
              disabled={requesting || !requestSource || limitReached}
            >
              {requesting ? (
                <Loader2Icon className="animate-spin" data-icon="inline-start" />
              ) : null}
              排队导出
            </Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>
    </div>
  );
}
