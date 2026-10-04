"use client";

// 预置报表 · 人员统计（report/001）
// 数据源：profiles（RLS：内部员工可读全部，外部账号仅本人 → 数字随数据范围收窄）。
// 展示：总数 / 在职 / 停用 + 按角色分布柱图（图/表切换）+ 导出（request_export('org.users')）。

import * as React from "react";
import { Bar, BarChart, CartesianGrid, XAxis, YAxis } from "recharts";
import { DownloadIcon, Loader2Icon, UsersIcon } from "lucide-react";
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
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { useIsMobile } from "@/hooks/use-mobile";
import { translateAuditErrorMessage } from "@/lib/audit";
import {
  ROLE_OPTIONS,
  translateErrorMessage,
  type ProfileStatus,
  type UserRole,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type ProfileStatRow = { role: UserRole; status: ProfileStatus };

const chartConfig = {
  count: {
    label: "人数",
    color: "var(--chart-1)",
  },
} satisfies ChartConfig;

function StatBox({ label, value }: { label: string; value: number }) {
  return (
    <div className="rounded-lg border p-3 text-center">
      <div className="text-2xl font-semibold tabular-nums">{value}</div>
      <div className="text-xs text-muted-foreground">{label}</div>
    </div>
  );
}

export function UserStatsReport() {
  const isMobile = useIsMobile();
  const [view, setView] = React.useState<ReportViewMode>("chart");
  const [rows, setRows] = React.useState<ProfileStatRow[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [exporting, setExporting] = React.useState(false);

  const load = React.useCallback(async () => {
    setLoading(true);
    setError(null);

    const { data, error: queryError } = await createClient()
      .from("profiles")
      .select("role,status");

    if (queryError) {
      setError(translateErrorMessage(queryError.message));
      setRows([]);
    } else {
      setRows((data ?? []) as ProfileStatRow[]);
    }
    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const total = rows.length;
  const active = rows.filter((row) => row.status === "active").length;
  const inactive = total - active;

  const roleStats = React.useMemo(
    () =>
      ROLE_OPTIONS.map(({ value, label }) => ({
        role: value,
        label,
        count: rows.filter((row) => row.role === value).length,
      })).sort((a, b) => b.count - a.count || a.label.localeCompare(b.label, "zh-CN")),
    [rows],
  );

  const chartRows = React.useMemo(
    () =>
      roleStats
        .filter((item) => item.count > 0)
        .map((item) => ({ role: item.label, count: item.count })),
    [roleStats],
  );

  const handleExport = async () => {
    setExporting(true);
    const { error: exportError } = await createClient().rpc("request_export", {
      p_source: "org.users",
    });
    setExporting(false);

    if (exportError) {
      toast.error(translateAuditErrorMessage(exportError.message));
      return;
    }
    // 报表中心导出页（/report/exports）已上线：引导到任务列表下载
    toast.success("导出任务已创建，完成后到 /report/exports 下载");
  };

  const effectiveView = isMobile ? "table" : view;

  const renderContent = () => {
    if (loading) {
      return <ReportLoadingSkeleton />;
    }
    if (error) {
      return <ReportErrorState message={error} onRetry={() => void load()} />;
    }
    if (total === 0) {
      return (
        <ReportEmptyState
          icon={UsersIcon}
          title="暂无用户数据"
          description="当前账号数据范围内没有可见的用户档案。"
        />
      );
    }

    if (effectiveView === "table") {
      return (
        <div className="overflow-x-auto">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>角色</TableHead>
                <TableHead className="text-right">人数</TableHead>
                <TableHead className="text-right">占比</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {roleStats.map((item) => (
                <TableRow key={item.role}>
                  <TableCell>{item.label}</TableCell>
                  <TableCell className="text-right tabular-nums">
                    {item.count}
                  </TableCell>
                  <TableCell className="text-right tabular-nums text-muted-foreground">
                    {total > 0 ? `${Math.round((item.count / total) * 100)}%` : "—"}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      );
    }

    if (chartRows.length === 0) {
      return <ReportEmptyState title="暂无角色分布数据" />;
    }

    return (
      <ChartContainer
        config={chartConfig}
        className="aspect-auto h-[280px] w-full"
      >
        <BarChart data={chartRows} layout="vertical" margin={{ left: 8, right: 16 }}>
          <CartesianGrid horizontal={false} />
          <XAxis type="number" allowDecimals={false} tickLine={false} axisLine={false} />
          <YAxis
            type="category"
            dataKey="role"
            width={64}
            tickLine={false}
            axisLine={false}
            tick={{ fill: "var(--muted-foreground)" }}
          />
          <ChartTooltip
            cursor={false}
            content={<ChartTooltipContent indicator="dot" />}
          />
          <Bar dataKey="count" fill="var(--color-count)" radius={4} />
        </BarChart>
      </ChartContainer>
    );
  };

  return (
    <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
      <CardHeader>
        <CardTitle>人员统计</CardTitle>
        <CardDescription>
          用户总数、在职 / 停用与角色分布（数据源 profiles，按当前账号数据范围过滤）
        </CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-4 p-4 md:p-6">
        <div className="flex flex-wrap items-center gap-2">
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
              导出用户名单
            </Button>
          </div>
        </div>

        {loading ? (
          <div className="grid grid-cols-3 gap-3">
            {Array.from({ length: 3 }).map((_, index) => (
              <div key={index} className="h-20 animate-pulse rounded-lg border" />
            ))}
          </div>
        ) : (
          <div className="grid grid-cols-3 gap-3">
            <StatBox label="总人数" value={total} />
            <StatBox label="在职" value={active} />
            <StatBox label="停用" value={inactive} />
          </div>
        )}

        {renderContent()}
      </CardContent>
    </Card>
  );
}
