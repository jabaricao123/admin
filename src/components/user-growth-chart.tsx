"use client";

import { ShieldXIcon } from "lucide-react";
import { Area, AreaChart, CartesianGrid, XAxis, YAxis } from "recharts";

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
import type { SignupTrendPoint } from "@/lib/trends";

const chartConfig = {
  count: {
    label: "新增用户",
    color: "var(--chart-1)",
  },
} satisfies ChartConfig;

/** UTC 日期（RPC 口径）→ 图表轴标签 M/D */
function formatDayLabel(day: string): string {
  const date = new Date(`${day}T00:00:00Z`);
  if (Number.isNaN(date.getTime())) {
    return day;
  }
  return `${date.getUTCMonth() + 1}/${date.getUTCDate()}`;
}

export function UserGrowthChart({
  data,
  isAdmin,
}: {
  /** signup_trend(p_days=30) 返回的逐日注册数 */
  data: SignupTrendPoint[];
  isAdmin: boolean;
}) {
  if (!isAdmin) {
    return (
      <Card className="@container/card">
        <CardHeader>
          <CardTitle>注册趋势</CardTitle>
          <CardDescription>近 30 天注册用户数</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col items-center gap-3 py-16 text-center">
          <ShieldXIcon className="size-10 text-muted-foreground" />
          <div className="text-lg font-medium">需要管理员权限</div>
          <p className="max-w-md text-sm text-muted-foreground">
            注册趋势来自全量用户档案（signup_trend RPC），仅管理员可读；
            数据层会过滤非管理员的查询结果。
          </p>
        </CardContent>
      </Card>
    );
  }

  const points = data.map((point) => ({
    ...point,
    label: formatDayLabel(point.day),
  }));
  const lowData = data.reduce((sum, point) => sum + point.count, 0) < 10;

  return (
    <Card className="@container/card">
      <CardHeader>
        <CardTitle>注册趋势</CardTitle>
        <CardDescription>
          {lowData ? (
            <span>用户数据还很少，趋势图将在积累更多注册后变得有意义</span>
          ) : (
            <span className="hidden @[540px]/card:block">
              近 30 天按日统计的注册用户数
            </span>
          )}
        </CardDescription>
      </CardHeader>
      <CardContent className="px-2 pt-4 sm:px-6 sm:pt-6">
        <ChartContainer
          config={chartConfig}
          className="aspect-auto h-[250px] w-full"
        >
          <AreaChart data={points}>
            <defs>
              <linearGradient id="fillCount" x1="0" y1="0" x2="0" y2="1">
                <stop
                  offset="5%"
                  stopColor="var(--color-count)"
                  stopOpacity={0.8}
                />
                <stop
                  offset="95%"
                  stopColor="var(--color-count)"
                  stopOpacity={0.1}
                />
              </linearGradient>
            </defs>
            <CartesianGrid vertical={false} />
            <XAxis
              dataKey="label"
              tickLine={false}
              axisLine={false}
              tickMargin={8}
              minTickGap={24}
              tick={{ fill: "var(--muted-foreground)" }}
            />
            <YAxis
              allowDecimals={false}
              tickLine={false}
              axisLine={false}
              tickMargin={4}
              width={28}
              tick={{ fill: "var(--muted-foreground)" }}
            />
            <ChartTooltip
              cursor={false}
              content={<ChartTooltipContent indicator="dot" />}
            />
            <Area
              dataKey="count"
              type="monotone"
              fill="url(#fillCount)"
              stroke="var(--color-count)"
              strokeWidth={2}
              dot={{ r: 3, fill: "var(--color-count)", strokeWidth: 0 }}
              activeDot={{ r: 5 }}
            />
          </AreaChart>
        </ChartContainer>
      </CardContent>
    </Card>
  );
}
