import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { AuthInfoPanel } from "@/components/system/auth-info-panel";
import { ForbiddenCard } from "@/components/forbidden-card";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "身份认证",
};

export default async function SystemServicesAuthPage() {
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
        module="system"
        description="仅管理员可访问身份认证配置。"
      />
    );
  }

  return <AuthInfoPanel />;
}
