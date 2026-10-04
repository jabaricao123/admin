import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { ForbiddenCard } from "@/components/forbidden-card";
import { UsersTable } from "@/components/users/users-table";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "用户管理",
};

export default async function OrgUsersPage() {
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
        description="仅管理员可访问用户管理。"
      />
    );
  }

  return <UsersTable currentUserId={user.id} />;
}
