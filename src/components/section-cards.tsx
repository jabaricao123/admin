import {
  ShieldCheckIcon,
  UserCheckIcon,
  UsersIcon,
  UserXIcon,
} from "lucide-react";

import { Badge } from "@/components/ui/badge";
import {
  Card,
  CardAction,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";

export type UserStats = {
  total: number;
  active: number;
  inactive: number;
  admins: number;
};

export function SectionCards({ stats }: { stats: UserStats }) {
  const activeRate =
    stats.total > 0 ? Math.round((stats.active / stats.total) * 100) : 0;

  const cards = [
    {
      label: "用户总数",
      value: stats.total,
      icon: UsersIcon,
      badge: null as string | null,
      hint: "含内部与外部角色",
    },
    {
      label: "活跃用户",
      value: stats.active,
      icon: UserCheckIcon,
      badge: `占比 ${activeRate}%`,
      hint: "处于启用状态",
    },
    {
      label: "停用用户",
      value: stats.inactive,
      icon: UserXIcon,
      badge: null,
      hint: "已停用账号",
    },
    {
      label: "管理员",
      value: stats.admins,
      icon: ShieldCheckIcon,
      badge: null,
      hint: "可调整角色与状态",
    },
  ];

  return (
    <div className="grid grid-cols-1 gap-4 px-4 *:data-[slot=card]:bg-gradient-to-t *:data-[slot=card]:from-primary/5 *:data-[slot=card]:to-card *:data-[slot=card]:shadow-xs lg:px-6 @xl/main:grid-cols-2 @5xl/main:grid-cols-4 dark:*:data-[slot=card]:bg-card">
      {cards.map((card) => (
        <Card key={card.label} className="@container/card">
          <CardHeader>
            <CardDescription>{card.label}</CardDescription>
            <CardTitle className="text-2xl font-semibold tabular-nums @[250px]/card:text-3xl">
              {card.value}
            </CardTitle>
            <CardAction>
              {card.badge ? (
                <Badge variant="outline">
                  <card.icon data-icon="inline-start" />
                  {card.badge}
                </Badge>
              ) : null}
            </CardAction>
          </CardHeader>
        </Card>
      ))}
    </div>
  );
}
