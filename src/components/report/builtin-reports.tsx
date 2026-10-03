"use client";

// 报表中心 · 预置报表页面（report/001）
// 卡片入口 → 报表详情（图 / 表切换；移动端图表降级为表格）。
// 三张报表：人员统计 / 部门分布 / 操作活跃度（后者仅 admin，RLS 兜底）。

import * as React from "react";
import type { LucideIcon } from "lucide-react";
import {
  ActivityIcon,
  ArrowLeftIcon,
  Building2Icon,
  UsersIcon,
} from "lucide-react";

import { ActivityReport } from "@/components/report/activity-report";
import { DepartmentStatsReport } from "@/components/report/department-stats-report";
import { UserStatsReport } from "@/components/report/user-stats-report";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";

type ReportKey = "users" | "departments" | "activity";

type ReportEntry = {
  key: ReportKey;
  title: string;
  description: string;
  hint: string;
  icon: LucideIcon;
};

const REPORTS: ReportEntry[] = [
  {
    key: "users",
    title: "人员统计",
    description: "总数、在职 / 停用、按角色分布",
    hint: "数据源：profiles（按当前账号数据范围过滤）",
    icon: UsersIcon,
  },
  {
    key: "departments",
    title: "部门分布",
    description: "各部门人数（含子部门）、编制 vs 在岗",
    hint: "数据源：departments_v / positions_v",
    icon: Building2Icon,
  },
  {
    key: "activity",
    title: "操作活跃度",
    description: "近 30 天按日操作量、活跃用户 Top10",
    hint: "数据源：audit_operations_v（仅管理员可读）",
    icon: ActivityIcon,
  },
];

export function BuiltinReports({ isAdmin }: { isAdmin: boolean }) {
  const [selected, setSelected] = React.useState<ReportKey | null>(null);
  const current = REPORTS.find((report) => report.key === selected) ?? null;

  if (current) {
    return (
      <div className="flex flex-col gap-4 p-4 md:gap-6 md:p-6">
        <div className="flex items-center gap-3">
          <Button
            variant="outline"
            size="icon"
            onClick={() => setSelected(null)}
            aria-label="返回报表列表"
            className="h-11 w-11 shrink-0 lg:h-8 lg:w-8"
          >
            <ArrowLeftIcon />
          </Button>
          <div className="min-w-0">
            <h2 className="text-lg font-medium">{current.title}</h2>
            <p className="truncate text-sm text-muted-foreground">
              {current.description}
            </p>
          </div>
        </div>

        {current.key === "users" ? <UserStatsReport /> : null}
        {current.key === "departments" ? <DepartmentStatsReport /> : null}
        {current.key === "activity" ? <ActivityReport isAdmin={isAdmin} /> : null}
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-4 p-4 md:gap-6 md:p-6">
      <div>
        <h2 className="text-lg font-medium">预置报表</h2>
        <p className="text-sm text-muted-foreground">
          开箱即用的统计报表，只读消费各模块公开视图；数字随当前账号的数据范围过滤。
        </p>
      </div>

      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
        {REPORTS.map((report) => (
          <button
            key={report.key}
            type="button"
            onClick={() => setSelected(report.key)}
            className="group text-left focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none rounded-xl"
          >
            <Card className="h-full transition-colors group-hover:border-primary/50">
              <CardHeader>
                <div className="flex items-center gap-3">
                  <div className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-muted">
                    <report.icon className="size-4" />
                  </div>
                  <CardTitle className="text-base">{report.title}</CardTitle>
                  {report.key === "activity" && !isAdmin ? (
                    <Badge variant="outline" className="ml-auto text-muted-foreground">
                      需要管理员权限
                    </Badge>
                  ) : null}
                </div>
                <CardDescription>{report.description}</CardDescription>
              </CardHeader>
              <CardContent className="text-xs text-muted-foreground">
                {report.hint}
              </CardContent>
            </Card>
          </button>
        ))}
      </div>
    </div>
  );
}
