import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { ApprovalFlowsTable } from "@/components/approval/approval-flows-table";
import { ForbiddenCard } from "@/components/forbidden-card";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "审批流程",
};

export default async function ApprovalFlowsPage() {
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
        module="approval"
        description="仅管理员可访问审批流程。"
      />
    );
  }

  return <ApprovalFlowsTable />;
}
