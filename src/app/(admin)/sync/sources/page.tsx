import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { ShieldXIcon } from "lucide-react";

import { SyncSourcesTable } from "@/components/sync/sync-sources-table";
import { Card, CardContent } from "@/components/ui/card";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "数据源配置",
};

export default async function SyncSourcesPage() {
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
      <div className="flex flex-1 items-center justify-center p-6">
        <Card className="max-w-md">
          <CardContent className="flex flex-col items-center gap-3 py-10 text-center">
            <ShieldXIcon className="size-10 text-muted-foreground" />
            <div className="text-lg font-medium">403 · 无访问权限</div>
            <p className="text-sm text-muted-foreground">
              仅管理员可访问数据源配置。
            </p>
          </CardContent>
        </Card>
      </div>
    );
  }

  return <SyncSourcesTable />;
}
