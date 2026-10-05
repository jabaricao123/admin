import {
  ListTodoIcon,
  ShieldXIcon,
  UserCheckIcon,
  UserPlusIcon,
  UsersIcon,
} from "lucide-react";

import { Badge } from "@/components/ui/badge";
import {
  Card,
  CardAction,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";

/**
 * 工作台统计（org_stats RPC 解析结果；兼容 get_dashboard_stats 委托版）。
 * admin 全量计数；非 admin 仅本人待办数，其余卡片占位。
 */
export type DashboardStats =
  | {
      isAdmin: true;
      totalUsers: number;
      newThisWeek: number;
      activeUsers: number;
      pendingTodos: number;
    }
  | { isAdmin: false; pendingTodos: number };

type CardItem = {
  label: string;
  value: number | null;
  icon: typeof UsersIcon;
  placeholder: boolean;
  hint: string;
};

export function SectionCards({ stats }: { stats: DashboardStats }) {
  // 卡片值只取 RPC 返回数字，页面不做二次计算（overview.md 验收）
  const cards: CardItem[] = stats.isAdmin
    ? [
        {
          label: "用户总数",
          value: stats.totalUsers,
          icon: UsersIcon,
          placeholder: false,
          hint: "全系统账号总数",
        },
        {
          label: "本周新增",
          value: stats.newThisWeek,
          icon: UserPlusIcon,
          placeholder: false,
          hint: "本周注册的账号（周一算起）",
        },
        {
          label: "活跃用户",
          value: stats.activeUsers,
          icon: UserCheckIcon,
          placeholder: false,
          hint: "处于启用状态",
        },
        {
          label: "待办数",
          value: stats.pendingTodos,
          icon: ListTodoIcon,
          placeholder: false,
          hint: "待你处理的审批",
        },
      ]
    : [
        {
          label: "用户总数",
          value: null,
          icon: UsersIcon,
          placeholder: true,
          hint: "全局统计仅管理员可见",
        },
        {
          label: "本周新增",
          value: null,
          icon: UserPlusIcon,
          placeholder: true,
          hint: "全局统计仅管理员可见",
        },
        {
          label: "活跃用户",
          value: null,
          icon: UserCheckIcon,
          placeholder: true,
          hint: "全局统计仅管理员可见",
        },
        {
          label: "待办数",
          value: stats.pendingTodos,
          icon: ListTodoIcon,
          placeholder: false,
          hint: "待你处理的审批",
        },
      ];

  return (
    <div className="grid grid-cols-1 gap-2 px-4 *:data-[slot=card]:bg-gradient-to-t *:data-[slot=card]:from-primary/5 *:data-[slot=card]:to-card *:data-[slot=card]:shadow-xs lg:px-6 @xl/main:grid-cols-2 @5xl/main:grid-cols-4 dark:*:data-[slot=card]:bg-card">
      {cards.map((card) => (
        <Card key={card.label} className="@container/card gap-3! py-3!">
          <CardHeader>
            <CardDescription>{card.label}</CardDescription>
            <CardTitle className="text-2xl font-semibold tabular-nums @[250px]/card:text-3xl">
              {card.value ?? "—"}
            </CardTitle>
            {card.placeholder ? (
              <CardAction>
                <Badge variant="outline" className="text-muted-foreground">
                  <ShieldXIcon data-icon="inline-start" />
                  仅管理员
                </Badge>
              </CardAction>
            ) : null}
            <p className="col-span-full text-xs text-muted-foreground">
              {card.hint}
            </p>
          </CardHeader>
        </Card>
      ))}
    </div>
  );
}
