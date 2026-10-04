import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { DepartmentsTree } from "@/components/departments/departments-tree";
import { ForbiddenCard } from "@/components/forbidden-card";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "部门管理",
};

export default async function OrgDepartmentsPage() {
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
        description="仅管理员可访问部门管理。"
      />
    );
  }

  return <DepartmentsTree />;
}
