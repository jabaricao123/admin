import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { ForbiddenCard } from "@/components/forbidden-card";
import { StorageConfigForm } from "@/components/system/storage-config-form";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "对象存储",
};

export default async function SystemServicesStoragePage() {
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
        description="仅管理员可访问对象存储配置。"
      />
    );
  }

  return <StorageConfigForm />;
}
