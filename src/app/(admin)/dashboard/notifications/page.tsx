import type { Metadata } from "next";

import { DashboardNotifications } from "@/components/dashboard/dashboard-notifications";

export const metadata: Metadata = {
  title: "我的通知",
};

export default function DashboardNotificationsPage() {
  return <DashboardNotifications />;
}
