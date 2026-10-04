import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { ForbiddenCard } from "@/components/forbidden-card";
import { OperationsTable } from "@/components/audit/operations-table";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "操作日志",
};

export default async function AuditOperationsPage() {
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
        description="仅管理员可访问操作日志。"
      />
    );
  }

  return <OperationsTable />;
}
