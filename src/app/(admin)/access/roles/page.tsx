import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { ForbiddenCard } from "@/components/forbidden-card";
import { RolesTable } from "@/components/roles/roles-table";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "角色管理",
};

export default async function AccessRolesPage() {
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
        description="仅管理员可访问角色管理。"
      />
    );
  }

  return <RolesTable />;
}
