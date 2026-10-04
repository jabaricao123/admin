import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { ForbiddenCard } from "@/components/forbidden-card";
import { PositionsTable } from "@/components/positions/positions-table";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "岗位管理",
};

export default async function OrgPositionsPage() {
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
        module="org"
        description="仅管理员可访问岗位管理。"
      />
    );
  }

  return <PositionsTable />;
}
