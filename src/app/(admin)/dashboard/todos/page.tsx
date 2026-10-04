import type { Metadata } from "next";

import { DashboardTodos } from "@/components/dashboard/dashboard-todos";

export const metadata: Metadata = {
  title: "我的待办",
};

export default function DashboardTodosPage() {
  return <DashboardTodos />;
}
