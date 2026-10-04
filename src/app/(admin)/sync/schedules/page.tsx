import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { ForbiddenCard } from "@/components/forbidden-card";
import { SyncSchedulesTable } from "@/components/sync/sync-schedules-table";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "调度管理",
};

export default async function SyncSchedulesPage() {
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
        module="sync"
        description="仅管理员可访问同步调度管理。"
      />
    );
  }

  return <SyncSchedulesTable />;
}
