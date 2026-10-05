import type { Metadata } from "next";

import { DashboardNotifications } from "@/components/dashboard/dashboard-notifications";

// @next-codemod-ignore Cache Components：管理端路由均为服务端动态鉴权，允许阻塞式导航。
export const instant = false;

export const metadata: Metadata = {
  title: "我的通知",
};

export default function DashboardNotificationsPage() {
  return <DashboardNotifications />;
}
