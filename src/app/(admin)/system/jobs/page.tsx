import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { CronJobsMonitor } from "@/components/system/cron-jobs-monitor";
import { ForbiddenCard } from "@/components/forbidden-card";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "定时任务",
};

export default async function SystemJobsPage() {
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
        description="仅管理员可访问定时任务监控。"
      />
    );
  }

  return <CronJobsMonitor />;
}
