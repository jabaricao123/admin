"use client";

// 系统管理 · 定时任务监控（工单 system/012 页面，消费 system/011 的视图与历史 RPC）
//
// 数据：system_cron_jobs_v（登记 ⨝ pg_cron 聚合，admin 门禁）+ get_cron_run_history（admin）。
// 交互：两 tab（任务登记 / 执行历史）；本页只读监控——零启停按钮，启停回各模块调度页。
// 健康阈值（可验收）：overdue（超 2 个预期周期）黄 Badge；24h 失败率 >50% 红 Badge；
// 孤儿 job（在 cron.job、未登记）红 Badge。
// 移动端（<1024px）：表格渲染卡片（整卡可点直接跳 owner_route）。

import * as React from "react";
import Link from "next/link";
import {
  ClockIcon,
  ExternalLinkIcon,
  InfoIcon,
  RefreshCwIcon,
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
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import type { Database } from "@/lib/database.types";
import { translateSystemErrorMessage } from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type JobRow = Database["public"]["Views"]["system_cron_jobs_v"]["Row"];
type RunRow =
  Database["public"]["Functions"]["get_cron_run_history"]["Returns"][number];
type RunHistoryArgs =
  Database["public"]["Functions"]["get_cron_run_history"]["Args"];

const ALL_JOBS = "__all__";
const RUN_LIMIT = 50;

/** 登记/调度状态文案（视图 status：active/paused/disabled/unscheduled/orphan） */
const JOB_STATUS_LABELS: Record<string, string> = {
  active: "启用",
  paused: "已暂停",
  disabled: "已注销",
  unscheduled: "未调度",
  orphan: "未登记",
};

const JOB_STATUS_BADGE_CLASSES: Record<string, string> = {
  active:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  paused:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
  disabled:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
  unscheduled:
    "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300",
  orphan:
    "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300",
};

/** 执行结果（cron.job_run_details.status）Badge */
const RUN_RESULT_LABELS: Record<string, string> = {
  succeeded: "成功",
  failed: "失败",
  running: "运行中",
};

const RUN_RESULT_BADGE_CLASSES: Record<string, string> = {
  succeeded:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  failed:
    "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300",
  running:
    "border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-900/60 dark:bg-blue-950/60 dark:text-blue-300",
};

const AMBER_BADGE =
  "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300";
const RED_BADGE =
  "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300";

function formatDateTime(value: string | null | undefined): string {
  if (!value) {
    return "—";
  }
  return new Date(value).toLocaleString("zh-CN", { hour12: false });
}

function formatDuration(ms: number | null | undefined): string {
  if (ms === null || ms === undefined) {
    return "—";
  }
  if (ms < 1000) {
    return `${ms} ms`;
  }
  return `${(ms / 1000).toFixed(1)} s`;
}

function jobStatusLabel(status: string | null): string {
  return status ? (JOB_STATUS_LABELS[status] ?? status) : "—";
}

function runResultBadge(result: string | null) {
  if (!result) {
    return <span className="text-muted-foreground">—</span>;
  }
  return (
    <Badge
      variant="outline"
      className={RUN_RESULT_BADGE_CLASSES[result] ?? undefined}
    >
      {RUN_RESULT_LABELS[result] ?? result}
    </Badge>
  );
}

/** 健康告警：孤儿红 / 未调度黄 / 超期黄 / 24h 失败率 >50% 红 */
function healthAlerts(row: JobRow): { label: string; className: string }[] {
  const alerts: { label: string; className: string }[] = [];
  if (row.is_orphan) {
    alerts.push({ label: "未登记（孤儿 job）", className: RED_BADGE });
  } else if (!row.is_scheduled) {
    alerts.push({ label: "未调度", className: AMBER_BADGE });
  }
  if (row.overdue) {
    alerts.push({ label: "超期（>2 周期）", className: AMBER_BADGE });
  }
  const rate = row.failure_rate_24h ?? 0;
  if (rate > 0.5) {
    alerts.push({
      label: `失败率 ${Math.round(rate * 100)}%`,
      className: RED_BADGE,
    });
  }
  return alerts;
}

function HealthBadges({ row }: { row: JobRow }) {
  const alerts = healthAlerts(row);
  if (alerts.length === 0) {
    return <span className="text-muted-foreground">正常</span>;
  }
  return (
    <span className="flex flex-wrap items-center justify-center gap-1">
      {alerts.map((alert) => (
        <Badge key={alert.label} variant="outline" className={alert.className}>
          {alert.label}
        </Badge>
      ))}
    </span>
  );
}

export function CronJobsMonitor() {
  const [jobs, setJobs] = React.useState<JobRow[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);

  const [runs, setRuns] = React.useState<RunRow[]>([]);
  const [runsLoading, setRunsLoading] = React.useState(true);
  const [runsError, setRunsError] = React.useState<string | null>(null);
  const [jobFilter, setJobFilter] = React.useState<string>(ALL_JOBS);
  const [activeTab, setActiveTab] = React.useState("registry");

  const loadRuns = React.useCallback(
    async (jobName: string, options?: { silent?: boolean }) => {
      if (!options?.silent) {
        setRunsLoading(true);
      }
      setRunsError(null);

      const supabase = createClient();
      const { data, error: loadError } = await supabase.rpc(
        "get_cron_run_history",
        {
          p_job_name: jobName === ALL_JOBS ? null : jobName,
          p_limit: RUN_LIMIT,
        } as RunHistoryArgs,
      );

      if (loadError) {
        setRunsError(loadError.message);
        setRuns([]);
        setRunsLoading(false);
        return;
      }

      setRuns(data ?? []);
      setRunsLoading(false);
    },
    [],
  );

  const loadJobs = React.useCallback(
    async (options?: { silent?: boolean }) => {
      if (!options?.silent) {
        setLoading(true);
      }
      setError(null);

      const supabase = createClient();
      const { data, error: loadError } = await supabase
        .from("system_cron_jobs_v")
        .select("*")
        .order("module", { nullsFirst: false })
        .order("job_name");

      if (loadError) {
        setError(loadError.message);
        setLoading(false);
        return;
      }

      setJobs(data ?? []);
      setLoading(false);
    },
    [],
  );

  React.useEffect(() => {
    void loadJobs();
    void loadRuns(ALL_JOBS);
  }, [loadJobs, loadRuns]);

  const jobNames = React.useMemo(() => {
    const names = new Set<string>();
    for (const job of jobs) {
      if (job.job_name) {
        names.add(job.job_name);
      }
    }
    return [...names];
  }, [jobs]);

  const refreshAll = () => {
    void loadJobs({ silent: true });
    void loadRuns(jobFilter, { silent: true });
  };

  const changeJobFilter = (value: string) => {
    setJobFilter(value);
    void loadRuns(value);
  };

  if (loading) {
    return (
      <div className="flex flex-col gap-4 p-4 lg:gap-6 lg:p-6">
        <Skeleton className="h-20 w-full" />
        <Skeleton className="h-96 w-full" />
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex flex-col p-4 lg:p-6">
        <Card>
          <CardContent className="flex flex-col items-center gap-2 py-16 text-sm">
            <p className="text-destructive">
              加载失败：{translateSystemErrorMessage(error)}
            </p>
            <Button variant="outline" onClick={() => void loadJobs()}>
              重试
            </Button>
          </CardContent>
        </Card>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-4 p-4 lg:gap-6 lg:p-6">
      {/* 只读边界说明（INDEX 规则 5：启停回各模块调度页） */}
      <div className="flex items-start gap-2 rounded-xl border bg-muted/40 p-3 text-sm">
        <InfoIcon className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
        <p>
          本页只读监控，启停请前往各模块调度页。健康口径：执行时间超过 2 个预期周期为
          <span className="font-medium"> 超期警示</span>；24h 失败率大于 50% 标红；
          在 pg_cron 运行但未登记的孤儿 job 标红。
        </p>
      </div>

      <Tabs value={activeTab} onValueChange={setActiveTab}>
        <div className="flex flex-wrap items-center justify-between gap-3">
          <TabsList>
            <TabsTrigger value="registry">任务登记</TabsTrigger>
            <TabsTrigger value="history">执行历史</TabsTrigger>
          </TabsList>
          <Button
            variant="outline"
            size="sm"
            onClick={refreshAll}
            disabled={loading || runsLoading}
          >
            <RefreshCwIcon
              className={runsLoading ? "animate-spin" : undefined}
              data-icon="inline-start"
            />
            刷新
          </Button>
        </div>

        {/* 任务登记：registry ⨝ cron.job 聚合（全站 job 只读总览） */}
        <TabsContent value="registry" className="mt-4">
          <Card>
            <CardHeader>
              <CardTitle className="flex items-center gap-2">
                <ClockIcon className="size-4 text-muted-foreground" />
                任务登记（{jobs.length}）
              </CardTitle>
              <CardDescription>
                job 名 / 来源模块 / cron 表达式 / 管理入口 / 上次运行与健康状态
              </CardDescription>
            </CardHeader>
            <CardContent>
              {jobs.length === 0 ? (
                <p className="py-10 text-center text-sm text-muted-foreground">
                  暂无登记任务
                </p>
              ) : (
                <>
                  <div className="hidden overflow-x-auto lg:block">
                    <Table>
                      <TableHeader>
                        <TableRow>
                          <TableHead className="text-center">job 名</TableHead>
                          <TableHead className="text-center">来源模块</TableHead>
                          <TableHead className="text-center">cron 表达式</TableHead>
                          <TableHead className="text-center">管理入口</TableHead>
                          <TableHead className="text-center">状态</TableHead>
                          <TableHead className="text-center">上次运行</TableHead>
                          <TableHead className="text-center">上次结果</TableHead>
                          <TableHead className="text-center">健康</TableHead>
                        </TableRow>
                      </TableHeader>
                      <TableBody>
                        {jobs.map((row) => (
                          <TableRow key={row.job_name ?? "orphan"}>
                            <TableCell className="text-left font-mono text-xs">
                              {row.job_name ?? "（匿名 job）"}
                            </TableCell>
                            <TableCell className="text-center text-xs">
                              {row.module ?? "—"}
                            </TableCell>
                            <TableCell className="text-center font-mono text-xs">
                              {row.cron_expr ?? "—"}
                              <div className="text-[10px] text-muted-foreground">
                                {row.timezone ?? "Asia/Shanghai"}
                              </div>
                            </TableCell>
                            <TableCell className="text-center">
                              {row.owner_route ? (
                                <Link
                                  href={row.owner_route}
                                  className="inline-flex items-center gap-1 text-primary hover:underline"
                                >
                                  去管理
                                  <ExternalLinkIcon className="size-3" />
                                </Link>
                              ) : (
                                <span className="text-muted-foreground">—</span>
                              )}
                            </TableCell>
                            <TableCell className="text-center">
                              <Badge
                                variant="outline"
                                className={
                                  JOB_STATUS_BADGE_CLASSES[row.status ?? ""] ??
                                  undefined
                                }
                              >
                                {jobStatusLabel(row.status)}
                              </Badge>
                            </TableCell>
                            <TableCell className="text-center text-xs text-muted-foreground">
                              {formatDateTime(row.last_run_at)}
                            </TableCell>
                            <TableCell className="text-center">
                              {runResultBadge(row.last_result)}
                            </TableCell>
                            <TableCell className="text-center">
                              <HealthBadges row={row} />
                            </TableCell>
                          </TableRow>
                        ))}
                      </TableBody>
                    </Table>
                  </div>

                  {/* 移动端：卡片（整卡可点跳 owner_route） */}
                  <div className="flex flex-col gap-2 lg:hidden">
                    {jobs.map((row) =>
                      row.owner_route ? (
                        <Link
                          key={row.job_name ?? "orphan"}
                          href={row.owner_route}
                          className="flex flex-col gap-2 rounded-xl border p-4 text-left transition-colors hover:border-primary focus-visible:border-primary focus-visible:outline-none"
                        >
                          <JobCardBody row={row} />
                        </Link>
                      ) : (
                        <div
                          key={row.job_name ?? "orphan"}
                          className="flex flex-col gap-2 rounded-xl border p-4"
                        >
                          <JobCardBody row={row} />
                        </div>
                      ),
                    )}
                  </div>
                </>
              )}
            </CardContent>
          </Card>
        </TabsContent>

        {/* 执行历史：cron.job_run_details 经 admin RPC（可按 job 过滤） */}
        <TabsContent value="history" className="mt-4">
          <Card>
            <CardHeader>
              <CardTitle>执行历史（最近 {RUN_LIMIT} 条）</CardTitle>
              <CardDescription>
                数据来自 pg_cron 运行明细；可按 job 名筛选
              </CardDescription>
            </CardHeader>
            <CardContent className="flex flex-col gap-4">
              <div className="flex items-center gap-2">
                <Select value={jobFilter} onValueChange={changeJobFilter}>
                  <SelectTrigger
                    className="h-11 w-full sm:w-72 lg:h-8"
                    aria-label="按 job 名筛选执行历史"
                  >
                    <SelectValue placeholder="全部 job" />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value={ALL_JOBS}>全部 job</SelectItem>
                    {jobNames.map((name) => (
                      <SelectItem key={name} value={name}>
                        {name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              {runsLoading ? (
                <div className="flex flex-col gap-3">
                  {Array.from({ length: 5 }).map((_, index) => (
                    <Skeleton key={index} className="h-9 w-full" />
                  ))}
                </div>
              ) : runsError ? (
                <div className="flex flex-col items-center gap-2 py-10 text-sm">
                  <p className="text-destructive">
                    加载失败：{translateSystemErrorMessage(runsError)}
                  </p>
                  <Button
                    variant="outline"
                    onClick={() => void loadRuns(jobFilter)}
                  >
                    重试
                  </Button>
                </div>
              ) : runs.length === 0 ? (
                <p className="py-10 text-center text-sm text-muted-foreground">
                  暂无执行记录
                </p>
              ) : (
                <>
                  <div className="hidden overflow-x-auto lg:block">
                    <Table>
                      <TableHeader>
                        <TableRow>
                          <TableHead className="text-center">job 名</TableHead>
                          <TableHead className="text-center">开始时间</TableHead>
                          <TableHead className="text-center">耗时</TableHead>
                          <TableHead className="text-center">结果</TableHead>
                          <TableHead className="text-center">结果信息</TableHead>
                        </TableRow>
                      </TableHeader>
                      <TableBody>
                        {runs.map((run) => (
                          <TableRow key={`${run.runid}`}>
                            <TableCell className="text-left font-mono text-xs">
                              {run.job_name}
                            </TableCell>
                            <TableCell className="text-center text-xs text-muted-foreground">
                              {formatDateTime(run.start_time)}
                            </TableCell>
                            <TableCell className="text-center text-xs">
                              {formatDuration(run.duration_ms)}
                            </TableCell>
                            <TableCell className="text-center">
                              {runResultBadge(run.status)}
                            </TableCell>
                            <TableCell className="max-w-80 truncate text-left text-xs text-muted-foreground">
                              {run.return_message ?? "—"}
                            </TableCell>
                          </TableRow>
                        ))}
                      </TableBody>
                    </Table>
                  </div>

                  <div className="flex flex-col gap-2 lg:hidden">
                    {runs.map((run) => (
                      <div
                        key={`${run.runid}`}
                        className="flex flex-col gap-2 rounded-xl border p-4"
                      >
                        <div className="flex items-center justify-between gap-2">
                          <span className="font-mono text-xs">
                            {run.job_name}
                          </span>
                          {runResultBadge(run.status)}
                        </div>
                        <div className="flex items-center justify-between text-xs text-muted-foreground">
                          <span>{formatDateTime(run.start_time)}</span>
                          <span>{formatDuration(run.duration_ms)}</span>
                        </div>
                        {run.return_message ? (
                          <p className="line-clamp-2 text-xs text-muted-foreground">
                            {run.return_message}
                          </p>
                        ) : null}
                      </div>
                    ))}
                  </div>
                </>
              )}
            </CardContent>
          </Card>
        </TabsContent>
      </Tabs>
    </div>
  );
}

function JobCardBody({ row }: { row: JobRow }) {
  return (
    <>
      <div className="flex items-start justify-between gap-2">
        <span className="font-mono text-xs">{row.job_name ?? "（匿名 job）"}</span>
        <Badge
          variant="outline"
          className={JOB_STATUS_BADGE_CLASSES[row.status ?? ""] ?? undefined}
        >
          {jobStatusLabel(row.status)}
        </Badge>
      </div>
      <div className="flex items-center justify-between text-xs text-muted-foreground">
        <span>{row.module ?? "—"}</span>
        <span className="font-mono">{row.cron_expr ?? "—"}</span>
      </div>
      <div className="flex items-center justify-between text-xs">
        <span className="text-muted-foreground">
          上次：{formatDateTime(row.last_run_at)}
        </span>
        {runResultBadge(row.last_result)}
      </div>
      <div className="flex items-center justify-between gap-2">
        <HealthBadges row={row} />
        {row.owner_route ? (
          <span className="inline-flex shrink-0 items-center gap-1 text-xs text-primary">
            去管理
            <ExternalLinkIcon className="size-3" />
          </span>
        ) : null}
      </div>
    </>
  );
}
