import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { ComplianceTable } from "@/components/audit/compliance-table";
import { ForbiddenCard } from "@/components/forbidden-card";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "合规报告",
};

export default async function AuditCompliancePage() {
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
        module="audit"
        description="仅管理员可访问合规报告。"
      />
    );
  }

  return <ComplianceTable />;
}
