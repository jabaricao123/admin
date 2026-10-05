import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { DocsView } from "@/components/integration/docs-view";
import { createClient } from "@/lib/supabase/server";

// @next-codemod-ignore Cache Components：管理端路由均为服务端动态鉴权，允许阻塞式导航。
export const instant = false;

export const metadata: Metadata = {
  title: "接口文档",
};

export default async function IntegrationDocsPage() {
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

  // 登录可见（非 admin 可看）；发布入口仅 admin 展示
  return <DocsView isAdmin={profile?.role === "admin"} />;
}
