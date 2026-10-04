import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { ForbiddenCard } from "@/components/forbidden-card";
import { SyncRunsTable } from "@/components/sync/sync-runs-table";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "执行记录",
};

export default async function SyncRunsPage() {
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
        description="仅管理员可访问同步执行记录。"
      />
    );
  }

  return <SyncRunsTable />;
}
