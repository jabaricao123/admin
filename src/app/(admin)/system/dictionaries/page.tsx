import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { DictionariesTable } from "@/components/system/dictionaries-table";
import { ForbiddenCard } from "@/components/forbidden-card";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "字典管理",
};

export default async function SystemDictionariesPage() {
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
        module="system"
        description="仅管理员可访问字典管理。"
      />
    );
  }

  return <DictionariesTable />;
}
