import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { ReportSubscriptions } from "@/components/report/report-subscriptions";
import { createClient } from "@/lib/supabase/server";

// @next-codemod-ignore Cache Components：管理端路由均为服务端动态鉴权，允许阻塞式导航。
export const instant = false;

export const metadata: Metadata = {
  title: "报表订阅",
};

export default async function ReportSubscriptionsPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  // admin 可见全量订阅；普通用户仅自己的订阅（RLS 兜底）
  return <ReportSubscriptions currentUserId={user.id} />;
}
