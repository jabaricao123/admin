import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { ForbiddenCard } from "@/components/forbidden-card";
import { SmsConfigPanel } from "@/components/system/sms-config-panel";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "短信服务",
};

export default async function SystemServicesSmsPage() {
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
        description="仅管理员可访问短信服务配置。"
      />
    );
  }

  return <SmsConfigPanel />;
}
