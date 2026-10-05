import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { ExportsList } from "@/components/report/exports-list";
import { createClient } from "@/lib/supabase/server";

// @next-codemod-ignore Cache Components：管理端路由均为服务端动态鉴权，允许阻塞式导航。
export const instant = false;

export const metadata: Metadata = {
  title: "数据导出",
};

export default async function ReportExportsPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  // admin 可见全量任务与停用源；普通用户仅自己的任务（RLS 兜底）
  const { data: profile } = await supabase
    .from("profiles")
    .select("role")
    .eq("id", user.id)
    .maybeSingle();

  return (
    <ExportsList
      currentUserId={user.id}
      isAdmin={profile?.role === "admin"}
    />
  );
}
