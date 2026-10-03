"use client";

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
import type { WeeklySignupPoint } from "@/lib/trends";

const chartConfig = {
  count: {
    label: "新增用户",
    color: "var(--chart-1)",
  },
} satisfies ChartConfig;

export function UserGrowthChart({
  data,
  lowData,
}: {
  data: WeeklySignupPoint[];
  /** 数据不足（总量过低）时降级为提示 */
  lowData?: boolean;
}) {
  return (
    <Card className="@container/card">
      <CardHeader>
        <CardTitle>新增用户</CardTitle>
        <CardDescription>
          {lowData ? (
            <span>用户数据还很少，趋势图将在积累更多注册后变得有意义</span>
          ) : (
            <span className="hidden @[540px]/card:block">
              按周统计的注册用户数
            </span>
          )}
        </CardDescription>
      </CardHeader>
      <CardContent className="px-2 pt-4 sm:px-6 sm:pt-6">
        <ChartContainer
          config={chartConfig}
          className="aspect-auto h-[250px] w-full"
        >
          <AreaChart data={data}>
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
              dataKey="week"
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
