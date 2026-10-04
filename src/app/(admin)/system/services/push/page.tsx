import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { ForbiddenCard } from "@/components/forbidden-card";
import { PushConfigPanel } from "@/components/system/push-config-panel";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "消息推送",
};

export default async function SystemServicesPushPage() {
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
        description="仅管理员可访问消息推送配置。"
      />
    );
  }

  return <PushConfigPanel />;
}
