"use client";

// 预置报表 · 部门分布（report/001）
// 数据源：departments_v（公开视图）+ profiles（在岗口径）+ positions_v（编制口径）。
// 口径：每个部门含子部门聚合（按 path 前缀递归归属）；在岗=在职用户，编制=启用岗位 headcount 之和。
// 校验口径 TODO（org/013）：department_headcount() 公开 RPC 上线后可替换为单源聚合。

import * as React from "react";
import { Bar, BarChart, CartesianGrid, XAxis, YAxis } from "recharts";
import { Building2Icon, DownloadIcon, Loader2Icon } from "lucide-react";
import { toast } from "sonner";

import {
  ReportEmptyState,
  ReportErrorState,
  ReportLoadingSkeleton,
  ViewToggle,
  type ReportViewMode,
} from "@/components/report/report-shared";
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
import { translateErrorMessage, type ProfileStatus } from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type DeptRow = {
  id: string;
  name: string;
  path: string;
  status: string;
  depth: number;
};

type ProfileRow = {
  department_id: string | null;
  department: string | null;
  status: ProfileStatus;
};

type PositionRow = {
  department_id: string | null;
  headcount: number;
  status: string;
};

type DeptStat = DeptRow & { staff: number; headcount: number };

const chartConfig = {
  staff: {
    label: "在岗（含子部门）",
    color: "var(--chart-1)",
  },
  headcount: {
    label: "编制（含子部门）",
    color: "var(--chart-2)",
  },
} satisfies ChartConfig;

/** 图表最多展示的部门数（其余见表格） */
const CHART_LIMIT = 10;

export function DepartmentStatsReport() {
  const isMobile = useIsMobile();
  const [view, setView] = React.useState<ReportViewMode>("chart");
  const [depts, setDepts] = React.useState<DeptRow[]>([]);
  const [profiles, setProfiles] = React.useState<ProfileRow[]>([]);
  const [positions, setPositions] = React.useState<PositionRow[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [exporting, setExporting] = React.useState(false);

  const load = React.useCallback(async () => {
    setLoading(true);
    setError(null);

    const supabase = createClient();
    const [deptRes, profileRes, positionRes] = await Promise.all([
      supabase
        .from("departments_v")
        .select("id,name,path,status,depth")
        .order("path", { ascending: true }),
      supabase.from("profiles").select("department_id,department,status"),
      supabase.from("positions_v").select("department_id,headcount,status"),
    ]);

    const queryError =
      deptRes.error ?? profileRes.error ?? positionRes.error;
    if (queryError) {
      setError(translateErrorMessage(queryError.message));
      setDepts([]);
      setProfiles([]);
      setPositions([]);
    } else {
      setDepts((deptRes.data ?? []) as DeptRow[]);
      setProfiles((profileRes.data ?? []) as ProfileRow[]);
      setPositions((positionRes.data ?? []) as PositionRow[]);
    }
    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  /** 导出部门分布数据：走 report 统一导出管道（CSV） */
  const handleExport = async () => {
    setExporting(true);
    const { error: exportError } = await createClient().rpc("request_export", {
      p_source: "org.departments",
    });
    setExporting(false);

    if (exportError) {
      // TODO(report/008 + org/013)：export_sources 尚未注册 org.departments，
      // request_export 会报「导出源不存在」；后端登记该源后删掉本兜底分支。
      if (exportError.message.includes("导出源不存在")) {
        toast.error("该报表导出暂未开通");
        return;
      }
      toast.error(translateErrorMessage(exportError.message));
      return;
    }
    toast.success("导出任务已创建，完成后到 /report/exports 下载");
  };

  const stats = React.useMemo<DeptStat[]>(() => {
    return depts.map((dept) => {
      // 含子部门：path 前缀归属（path 已由 departments_v 递归生成）
      const descendants = depts.filter(
        (item) =>
          item.path === dept.path || item.path.startsWith(`${dept.path}/`),
      );
      const descendantIds = new Set(descendants.map((item) => item.id));
      const descendantNames = new Set(descendants.map((item) => item.name));

      const staff = profiles.filter(
        (profile) =>
          profile.status === "active" &&
          ((profile.department_id !== null &&
            descendantIds.has(profile.department_id)) ||
            (profile.department_id === null &&
              profile.department !== null &&
              descendantNames.has(profile.department))),
      ).length;

      const headcount = positions
        .filter(
          (position) =>
            position.status === "active" &&
            position.department_id !== null &&
            descendantIds.has(position.department_id),
        )
        .reduce((sum, position) => sum + position.headcount, 0);

      return { ...dept, staff, headcount };
    });
  }, [depts, profiles, positions]);

  const totalStaff = stats.reduce((sum, item) => sum + item.staff, 0);
  const totalHeadcount = stats.reduce((sum, item) => sum + item.headcount, 0);
  const hasData = totalStaff > 0 || totalHeadcount > 0;

  const chartRows = React.useMemo(
    () =>
      stats
        .filter((item) => item.status === "active")
        .sort(
          (a, b) =>
            b.staff - a.staff || b.headcount - a.headcount ||
            a.path.localeCompare(b.path, "zh-CN"),
        )
        .slice(0, CHART_LIMIT)
        .map((item) => ({
          name: item.path,
          staff: item.staff,
          headcount: item.headcount,
        })),
    [stats],
  );

  const effectiveView = isMobile ? "table" : view;

  const renderContent = () => {
    if (loading) {
      return <ReportLoadingSkeleton />;
    }
    if (error) {
      return <ReportErrorState message={error} onRetry={() => void load()} />;
    }
    if (!hasData) {
      return (
        <ReportEmptyState
          icon={Building2Icon}
          title="暂无在岗 / 编制数据"
          description="可先在「用户管理」为成员分配部门，或在「岗位管理」为岗位设置编制。"
        />
      );
    }

    if (effectiveView === "table") {
      return (
        <div className="overflow-x-auto">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>部门</TableHead>
                <TableHead className="text-right">在岗（含子部门）</TableHead>
                <TableHead className="text-right">编制（含子部门）</TableHead>
                <TableHead className="text-right">差额</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {stats.map((item) => {
                const diff = item.headcount - item.staff;
                return (
                  <TableRow key={item.id}>
                    <TableCell>
                      <div className="flex items-center gap-2">
                        <span>{item.path}</span>
                        {item.status !== "active" ? (
                          <Badge variant="outline" className="text-muted-foreground">
                            已停用
                          </Badge>
                        ) : null}
                      </div>
                    </TableCell>
                    <TableCell className="text-right tabular-nums">
                      {item.staff}
                    </TableCell>
                    <TableCell className="text-right tabular-nums">
                      {item.headcount}
                    </TableCell>
                    <TableCell
                      className={`text-right tabular-nums ${
                        diff < 0 ? "text-destructive" : "text-muted-foreground"
                      }`}
                    >
                      {diff > 0 ? `+${diff}` : diff}
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </div>
      );
    }

    if (chartRows.length === 0) {
      return <ReportEmptyState title="暂无启用部门的分布数据" />;
    }

    return (
      <div className="flex flex-col gap-2">
        <ChartContainer
          config={chartConfig}
          className="aspect-auto h-[320px] w-full"
        >
          <BarChart
            data={chartRows}
            layout="vertical"
            margin={{ left: 8, right: 16 }}
          >
            <CartesianGrid horizontal={false} />
            <XAxis
              type="number"
              allowDecimals={false}
              tickLine={false}
              axisLine={false}
            />
            <YAxis
              type="category"
              dataKey="name"
              width={128}
              tickLine={false}
              axisLine={false}
              tick={{ fill: "var(--muted-foreground)" }}
            />
            <ChartTooltip
              cursor={false}
              content={<ChartTooltipContent indicator="dot" />}
            />
            <Bar dataKey="staff" fill="var(--color-staff)" radius={4} />
            <Bar dataKey="headcount" fill="var(--color-headcount)" radius={4} />
          </BarChart>
        </ChartContainer>
        <p className="text-xs text-muted-foreground">
          按在岗人数取前 {CHART_LIMIT} 个部门（含子部门聚合）；完整清单见表格视图。
        </p>
      </div>
    );
  };

  return (
    <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card gap-3! py-3!">
      <CardHeader>
        <CardTitle>部门分布</CardTitle>
        <CardDescription>
          各部门在岗与编制对比（含子部门聚合；数据源 departments_v / profiles / positions_v）
        </CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-4 p-4 md:p-6">
        <div className="flex flex-wrap items-center gap-2">
          <ViewToggle value={view} onChange={setView} />
          <Button
            variant="outline"
            onClick={() => void handleExport()}
            disabled={exporting}
            className="ml-auto h-11 lg:h-8"
          >
            {exporting ? (
              <Loader2Icon
                className="animate-spin"
                data-icon="inline-start"
              />
            ) : (
              <DownloadIcon data-icon="inline-start" />
            )}
            导出部门数据
          </Button>
        </div>

        {renderContent()}
      </CardContent>
    </Card>
  );
}
