"use client";

// 预置报表 · 操作活跃度（report/001）
// 数据源：audit_operations_v（security_invoker；底层 RLS 仅 admin 可读）。
// 非 admin：显式「需要管理员权限」占位（RLS 兜底，页面不做数据请求）。
// 展示：近 N 天按日操作量折线（图/表切换）+ 活跃用户 Top10 + 导出（request_export('audit.operations')）。

import * as React from "react";
import { CartesianGrid, Line, LineChart, XAxis, YAxis } from "recharts";
import {
  DownloadIcon,
  Loader2Icon,
  ShieldXIcon,
} from "lucide-react";
import { toast } from "sonner";

import {
  ReportEmptyState,
  ReportErrorState,
  ReportLoadingSkeleton,
  ViewToggle,
  type ReportViewMode,
} from "@/components/report/report-shared";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import {
  ChartContainer,
  ChartTooltip,
  ChartTooltipContent,
  type ChartConfig,
} from "@/components/ui/chart";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { useIsMobile } from "@/hooks/use-mobile";
import { translateAuditErrorMessage } from "@/lib/audit";
import { translateErrorMessage } from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type OperationRow = {
  created_at: string | null;
  actor_id: string | null;
  actor_name: string | null;
};

type DayBucket = { key: string; label: string; count: number };

const RANGE_OPTIONS = [
  { value: "7", label: "近 7 天", days: 7 },
  { value: "30", label: "近 30 天", days: 30 },
  { value: "90", label: "近 90 天", days: 90 },
] as const;

/** 每页拉取条数（PostgREST max_rows=1000） */
const FETCH_PAGE = 1000;
/** 最多翻页数：10 页 = 1 万条，超出提示截断 */
const MAX_PAGES = 10;

const chartConfig = {
  count: {
    label: "操作量",
    color: "var(--chart-3)",
  },
} satisfies ChartConfig;

function pad(value: number) {
  return value.toString().padStart(2, "0");
}

function dateKey(date: Date) {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

export function ActivityReport({ isAdmin }: { isAdmin: boolean }) {
  const isMobile = useIsMobile();
  const [view, setView] = React.useState<ReportViewMode>("chart");
  const [rangeValue, setRangeValue] = React.useState<string>("30");
  const [rows, setRows] = React.useState<OperationRow[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [exporting, setExporting] = React.useState(false);
  const [truncated, setTruncated] = React.useState(false);

  const range =
    RANGE_OPTIONS.find((option) => option.value === rangeValue) ??
    RANGE_OPTIONS[1];

  const load = React.useCallback(async () => {
    if (!isAdmin) {
      setLoading(false);
      return;
    }

    setLoading(true);
    setError(null);
    setTruncated(false);

    // 近 N 天：从 N-1 天前的本地 0 点起（含今天）
    const start = new Date();
    start.setHours(0, 0, 0, 0);
    start.setDate(start.getDate() - (range.days - 1));
    const cutoffIso = start.toISOString();

    const supabase = createClient();
    const collected: OperationRow[] = [];
    let from = 0;
    let capped = false;

    try {
      for (let page = 0; page < MAX_PAGES; page += 1) {
        const { data, error: queryError } = await supabase
          .from("audit_operations_v")
          .select("created_at,actor_id,actor_name")
          .gte("created_at", cutoffIso)
          .order("created_at", { ascending: true })
          .range(from, from + FETCH_PAGE - 1);

        if (queryError) {
          throw queryError;
        }

        const batch = (data ?? []) as OperationRow[];
        collected.push(...batch);
        if (batch.length < FETCH_PAGE) {
          break;
        }
        from += FETCH_PAGE;
        if (page === MAX_PAGES - 1) {
          capped = true;
        }
      }
      setRows(collected);
      setTruncated(capped);
    } catch (queryError) {
      setError(
        translateErrorMessage(
          queryError instanceof Error ? queryError.message : String(queryError),
        ),
      );
      setRows([]);
    }
    setLoading(false);
  }, [isAdmin, range.days]);

  React.useEffect(() => {
    void load();
  }, [load]);

  const dayBuckets = React.useMemo<DayBucket[]>(() => {
    const buckets: DayBucket[] = [];
    const today = new Date();
    today.setHours(0, 0, 0, 0);

    for (let index = range.days - 1; index >= 0; index -= 1) {
      const date = new Date(today.getTime() - index * 24 * 60 * 60 * 1000);
      buckets.push({
        key: dateKey(date),
        label: `${date.getMonth() + 1}/${date.getDate()}`,
        count: 0,
      });
    }

    const byKey = new Map(buckets.map((bucket) => [bucket.key, bucket]));
    for (const row of rows) {
      if (!row.created_at) {
        continue;
      }
      const bucket = byKey.get(dateKey(new Date(row.created_at)));
      if (bucket) {
        bucket.count += 1;
      }
    }

    return buckets;
  }, [rows, range.days]);

  const topUsers = React.useMemo(() => {
    const map = new Map<string, { name: string; count: number }>();
    for (const row of rows) {
      const key = row.actor_id ?? "__system__";
      const name = row.actor_id
        ? row.actor_name?.trim() || `用户 ${row.actor_id.slice(0, 8)}…`
        : "系统/后台";
      const item = map.get(key) ?? { name, count: 0 };
      item.count += 1;
      item.name = name;
      map.set(key, item);
    }
    return Array.from(map.values())
      .sort((a, b) => b.count - a.count || a.name.localeCompare(b.name, "zh-CN"))
      .slice(0, 10);
  }, [rows]);

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

  if (!isAdmin) {
    return (
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card gap-3! py-3!">
        <CardHeader>
          <CardTitle>操作活跃度</CardTitle>
          <CardDescription>按日操作量、活跃用户 Top10</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col items-center gap-3 py-16 text-center">
          <ShieldXIcon className="size-10 text-muted-foreground" />
          <div className="text-lg font-medium">需要管理员权限</div>
          <p className="max-w-md text-sm text-muted-foreground">
            操作活跃度来自审计操作日志（audit_operations_v），仅管理员可读；
            数据层 RLS 会过滤非管理员的查询结果。
          </p>
        </CardContent>
      </Card>
    );
  }

  const effectiveView = isMobile ? "table" : view;
  const hasData = rows.length > 0;

  const renderSeries = () => {
    if (loading) {
      return <ReportLoadingSkeleton />;
    }
    if (error) {
      return <ReportErrorState message={error} onRetry={() => void load()} />;
    }
    if (!hasData) {
      return (
        <ReportEmptyState
          title={`近 ${range.days} 天暂无操作记录`}
          description="调整时间范围或产生新的操作后再查看。"
        />
      );
    }

    if (effectiveView === "table") {
      return (
        <div className="max-h-[320px] overflow-auto">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>日期</TableHead>
                <TableHead className="text-right">操作量</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {dayBuckets.map((bucket) => (
                <TableRow key={bucket.key}>
                  <TableCell className="text-muted-foreground">
                    {bucket.key}
                  </TableCell>
                  <TableCell className="text-right tabular-nums">
                    {bucket.count}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      );
    }

    return (
      <ChartContainer
        config={chartConfig}
        className="aspect-auto h-[280px] w-full"
      >
        <LineChart data={dayBuckets} margin={{ left: 0, right: 12, top: 8 }}>
          <CartesianGrid vertical={false} />
          <XAxis
            dataKey="label"
            tickLine={false}
            axisLine={false}
            tickMargin={8}
            minTickGap={16}
            tick={{ fill: "var(--muted-foreground)" }}
          />
          <YAxis
            allowDecimals={false}
            tickLine={false}
            axisLine={false}
            width={28}
            tick={{ fill: "var(--muted-foreground)" }}
          />
          <ChartTooltip
            cursor={false}
            content={<ChartTooltipContent indicator="line" />}
          />
          <Line
            type="monotone"
            dataKey="count"
            stroke="var(--color-count)"
            strokeWidth={2}
            dot={range.days <= 7 ? { r: 3, fill: "var(--color-count)" } : false}
            activeDot={{ r: 5 }}
          />
        </LineChart>
      </ChartContainer>
    );
  };

  return (
    <div className="flex flex-col gap-4 md:gap-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card gap-3! py-3!">
        <CardHeader>
          <CardTitle>操作活跃度</CardTitle>
          <CardDescription>
            近 {range.days} 天按日操作量与活跃用户 Top10（数据源 audit_operations_v，仅管理员）
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-wrap items-center gap-2">
            <Select value={rangeValue} onValueChange={setRangeValue}>
              <SelectTrigger
                className="w-full sm:w-36 min-h-11 lg:min-h-8"
                aria-label="时间范围"
              >
                <SelectValue placeholder="时间范围" />
              </SelectTrigger>
              <SelectContent>
                {RANGE_OPTIONS.map((option) => (
                  <SelectItem key={option.value} value={option.value}>
                    {option.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <ViewToggle value={view} onChange={setView} />
            <div className="flex w-full items-center gap-2 sm:ml-auto sm:w-auto">
              <Button
                variant="outline"
                onClick={() => void handleExport()}
                disabled={exporting}
                className="h-11 flex-1 lg:h-8 lg:flex-none"
              >
                {exporting ? (
                  <Loader2Icon className="animate-spin" data-icon="inline-start" />
                ) : (
                  <DownloadIcon data-icon="inline-start" />
                )}
                导出操作日志
              </Button>
            </div>
          </div>

          {truncated && !loading && !error ? (
            <p className="text-xs text-muted-foreground">
              数据量较大，仅统计最近 {MAX_PAGES * FETCH_PAGE} 条记录；请缩小时间范围查看精确结果。
            </p>
          ) : null}

          {renderSeries()}
        </CardContent>
      </Card>

      {hasData && !loading && !error ? (
        <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card gap-3! py-3!">
          <CardHeader>
            <CardTitle className="text-base">活跃用户 Top 10</CardTitle>
            <CardDescription>
              近 {range.days} 天操作量排名（系统/后台调用归入「系统/后台」）
            </CardDescription>
          </CardHeader>
          <CardContent className="p-4 md:p-6">
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="w-16 text-center">排名</TableHead>
                    <TableHead>用户</TableHead>
                    <TableHead className="text-right">操作量</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {topUsers.map((user, index) => (
                    <TableRow key={`${user.name}-${index}`}>
                      <TableCell className="text-center tabular-nums text-muted-foreground">
                        {index + 1}
                      </TableCell>
                      <TableCell>{user.name}</TableCell>
                      <TableCell className="text-right tabular-nums">
                        {user.count}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          </CardContent>
        </Card>
      ) : null}
    </div>
  );
}
