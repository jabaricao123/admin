import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { ApiKeysTable } from "@/components/integration/api-keys-table";
import { ForbiddenCard } from "@/components/forbidden-card";
import { createClient } from "@/lib/supabase/server";

// @next-codemod-ignore Cache Components：管理端路由均为服务端动态鉴权，允许阻塞式导航。
export const instant = false;

export const metadata: Metadata = {
  title: "API 密钥",
};

export default async function IntegrationApiKeysPage() {
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

  if (profile?.role !== "admin") {
    return (
      <ForbiddenCard
        module="integration"
        description="仅管理员可访问 API 密钥管理。"
      />
    );
  }

  return <ApiKeysTable />;
}
