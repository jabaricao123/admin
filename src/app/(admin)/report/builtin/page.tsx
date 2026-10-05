import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { BuiltinReports } from "@/components/report/builtin-reports";
import { createClient } from "@/lib/supabase/server";

// @next-codemod-ignore Cache Components：管理端路由均为服务端动态鉴权，允许阻塞式导航。
export const instant = false;

export const metadata: Metadata = {
  title: "预置报表",
};

export default async function ReportBuiltinPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  // 活跃度报表的 admin 占位判定；数据层仍由 audit_operations_v 的 RLS 兜底
  const { data: profile } = await supabase
    .from("profiles")
    .select("role")
    .eq("id", user.id)
    .maybeSingle();

  return <BuiltinReports isAdmin={profile?.role === "admin"} />;
}
