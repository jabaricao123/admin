import type { Metadata } from "next";

import { OrgChartView } from "@/components/org-chart/org-chart-view";

// @next-codemod-ignore Cache Components：管理端路由均为服务端动态鉴权，允许阻塞式导航。
export const instant = false;

export const metadata: Metadata = {
  title: "组织架构",
};

export default function OrgChartPage() {
  return <OrgChartView />;
}
