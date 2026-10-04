import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { DeliveriesTable } from "@/components/messages/deliveries-table";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "发送记录",
};

export default async function MessageHistoryPage() {
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

  // admin 全量视图；普通用户经 RLS 仅见本人记录（history.md RLS 契约）
  return <DeliveriesTable isAdmin={profile?.role === "admin"} />;
}
