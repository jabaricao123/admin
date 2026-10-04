"use client";

// 报表中心 · run_report 结果渲染（report/004）
// 输入：解析后的 config + run_report 返回值；输出：图（柱/折线/饼，--chart-N token）/表切换。
// 移动端强制表格（DESIGN §3：移动端图表降级），与预置报表行为一致。

import * as React from "react";
import {
  Bar,
  BarChart,
  CartesianGrid,
  Cell,
  Line,
  LineChart,
  Pie,
  PieChart,
  XAxis,
  YAxis,
} from "recharts";

import {
  ReportEmptyState,
  ViewToggle,
  type ReportViewMode,
} from "@/components/report/report-shared";
import {
  ChartContainer,
  ChartLegend,
  ChartLegendContent,
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
import type { Json } from "@/lib/database.types";
import {
  metricAlias,
  metricLabel,
  type ReportConfig,
  type ReportRunResult,
} from "@/lib/report";

const CHART_COLORS = [
  "var(--chart-1)",
  "var(--chart-2)",
  "var(--chart-3)",
  "var(--chart-4)",
  "var(--chart-5)",
];

/** 单元格展示：null → —，布尔中文化，对象 JSON 化 */
export function formatCell(value: Json | undefined): string {
  if (value === null || value === undefined) {
    return "—";
  }
  if (typeof value === "boolean") {
    return value ? "是" : "否";
  }
  if (typeof value === "object") {
    return JSON.stringify(value);
  }
  return String(value);
}

function toNumber(value: Json | undefined): number {
  if (typeof value === "number") {
    return value;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

export function ReportResultView({
  config,
  result,
  height = 240,
}: {
  config: ReportConfig;
  result: ReportRunResult;
  height?: number;
}) {
  const isMobile = useIsMobile();
  const [view, setView] = React.useState<ReportViewMode>(
    config.chart === "table" ? "table" : "chart",
  );

  // 切换到另一张报表/配置时，回到默认视图
  React.useEffect(() => {
    setView(config.chart === "table" ? "table" : "chart");
  }, [config.chart, result]);

  const metrics = React.useMemo(
    () =>
      config.metrics.map((metric, index) => ({
        alias: metricAlias(metric),
        label: metricLabel(metric),
        color: CHART_COLORS[index % CHART_COLORS.length],
      })),
    [config.metrics],
  );

  const dimensions = config.dimensions;

  const chartRows = React.useMemo(
    () =>
      result.rows.map((row, index) => {
        const label =
          dimensions.length > 0
            ? dimensions.map((dim) => formatCell(row[dim])).join(" / ")
            : `第 ${index + 1} 行`;
        const item: Record<string, string | number> = { __label: label };
        for (const metric of metrics) {
          item[metric.alias] = toNumber(row[metric.alias]);
        }
        return item;
      }),
    [result.rows, dimensions, metrics],
  );

  const effectiveView: ReportViewMode = isMobile ? "table" : view;
  const canChart = metrics.length > 0 && result.rows.length > 0;

  const renderTable = () => (
    <div className="overflow-x-auto">
      <Table>
        <TableHeader>
          <TableRow>
            {result.columns.map((column) => {
              const metric = metrics.find((item) => item.alias === column);
              return (
                <TableHead key={column} className="text-center">
                  {metric ? metric.label : column}
                </TableHead>
              );
            })}
          </TableRow>
        </TableHeader>
        <TableBody>
          {result.rows.map((row, index) => (
            <TableRow key={index}>
              {result.columns.map((column) => (
                <TableCell
                  key={column}
                  className="text-center tabular-nums whitespace-nowrap"
                >
                  {formatCell(row[column])}
                </TableCell>
              ))}
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );

  const renderChart = () => {
    if (!canChart) {
      return (
        <ReportEmptyState
          title="当前配置无可视化序列"
          description={
            metrics.length === 0
              ? "至少添加一个度量后才能出图；可切换表格查看维度明细。"
              : "当前筛选条件下没有数据。"
          }
        />
      );
    }

    const chartConfig: ChartConfig = Object.fromEntries(
      metrics.map((metric) => [
        metric.alias,
        { label: metric.label, color: metric.color },
      ]),
    );

    if (config.chart === "pie") {
      const primary = metrics[0];
      const pieData = chartRows.map((row) => ({
        name: String(row.__label),
        value: Number(row[primary.alias] ?? 0),
      }));
      return (
        <ChartContainer
          config={{ value: { label: primary.label, color: primary.color } }}
          className="aspect-auto h-[280px] w-full"
        >
          <PieChart>
            <ChartTooltip
              cursor={false}
              content={<ChartTooltipContent nameKey="name" />}
            />
            <ChartLegend content={<ChartLegendContent nameKey="name" />} />
            <Pie data={pieData} dataKey="value" nameKey="name" outerRadius={90}>
              {pieData.map((entry, index) => (
                <Cell
                  key={`${entry.name}-${index}`}
                  fill={CHART_COLORS[index % CHART_COLORS.length]}
                />
              ))}
            </Pie>
          </PieChart>
        </ChartContainer>
      );
    }

    if (config.chart === "line") {
      return (
        <ChartContainer
          config={chartConfig}
          className="aspect-auto w-full"
          style={{ height }}
        >
          <LineChart data={chartRows} margin={{ left: 0, right: 12, top: 8 }}>
            <CartesianGrid vertical={false} />
            <XAxis
              dataKey="__label"
              tickLine={false}
              axisLine={false}
              tickMargin={8}
            />
            <YAxis
              allowDecimals={false}
              tickLine={false}
              axisLine={false}
              width={40}
            />
            <ChartTooltip
              cursor={false}
              content={<ChartTooltipContent indicator="line" />}
            />
            {metrics.length > 1 ? (
              <ChartLegend content={<ChartLegendContent />} />
            ) : null}
            {metrics.map((metric) => (
              <Line
                key={metric.alias}
                type="monotone"
                dataKey={metric.alias}
                stroke={`var(--color-${metric.alias})`}
                strokeWidth={2}
                dot={false}
              />
            ))}
          </LineChart>
        </ChartContainer>
      );
    }

    return (
      <ChartContainer
        config={chartConfig}
        className="aspect-auto w-full"
        style={{ height }}
      >
        <BarChart data={chartRows} margin={{ left: 0, right: 12, top: 8 }}>
          <CartesianGrid vertical={false} />
          <XAxis
            dataKey="__label"
            tickLine={false}
            axisLine={false}
            tickMargin={8}
          />
          <YAxis
            allowDecimals={false}
            tickLine={false}
            axisLine={false}
            width={40}
          />
          <ChartTooltip
            cursor={false}
            content={<ChartTooltipContent indicator="dot" />}
          />
          {metrics.length > 1 ? (
            <ChartLegend content={<ChartLegendContent />} />
          ) : null}
          {metrics.map((metric) => (
            <Bar
              key={metric.alias}
              dataKey={metric.alias}
              fill={`var(--color-${metric.alias})`}
              radius={4}
            />
          ))}
        </BarChart>
      </ChartContainer>
    );
  };

  if (result.rows.length === 0) {
    return (
      <ReportEmptyState
        title="暂无数据"
        description="当前账号的数据范围（RLS）内没有匹配记录。"
      />
    );
  }

  return (
    <div className="flex flex-col gap-3">
      <ViewToggle value={effectiveView} onChange={setView} />
      {effectiveView === "chart" ? renderChart() : renderTable()}
    </div>
  );
}
