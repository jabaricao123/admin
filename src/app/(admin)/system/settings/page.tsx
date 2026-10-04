import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { ForbiddenCard } from "@/components/forbidden-card";
import { SettingsTable } from "@/components/system/settings-table";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "参数配置",
};

export default async function SystemSettingsPage() {
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
        description="仅管理员可访问参数配置。"
      />
    );
  }

  return <SettingsTable />;
}
