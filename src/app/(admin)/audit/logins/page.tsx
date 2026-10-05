import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { LoginsTable } from "@/components/audit/logins-table";
import { createClient } from "@/lib/supabase/server";

// @next-codemod-ignore Cache Components：管理端路由均为服务端动态鉴权，允许阻塞式导航。
export const instant = false;

export const metadata: Metadata = {
  title: "登录日志",
};

export default async function AuditLoginsPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: profile } = await supabase
    .from("profiles")
    .select("role")
    .eq("id", user.id)
    .maybeSingle();

  // 普通用户进入「我的登录记录」视图；数据范围由 audit_logins RLS 保证
  return <LoginsTable isAdmin={profile?.role === "admin"} />;
}
