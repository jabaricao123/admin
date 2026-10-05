import type { Metadata } from "next";

import { DashboardTodos } from "@/components/dashboard/dashboard-todos";

// @next-codemod-ignore Cache Components：管理端路由均为服务端动态鉴权，允许阻塞式导航。
export const instant = false;

export const metadata: Metadata = {
  title: "我的待办",
};

export default function DashboardTodosPage() {
  return <DashboardTodos />;
}
