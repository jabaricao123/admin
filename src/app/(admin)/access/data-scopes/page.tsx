import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { DataScopesTable } from "@/components/access/data-scopes-table";
import { ForbiddenCard } from "@/components/forbidden-card";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "数据权限",
};

export default async function AccessDataScopesPage() {
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
        module="access"
        description="仅管理员可访问数据权限配置。"
      />
    );
  }

  return <DataScopesTable />;
}
