import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { CustomReports } from "@/components/report/custom-reports";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "自定义报表",
};

// 分享链接：/report/custom?id=<def_id> —— 详情数据由 run_report 按访问者 RLS 过滤，
// 页面本身不加额外过滤（private 仅 owner/admin 可见）。
export default async function ReportCustomPage({
  searchParams,
}: {
  searchParams: Promise<{ [key: string]: string | string[] | undefined }>;
}) {
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

  const params = await searchParams;
  const rawId = params.id;
  const initialId =
    typeof rawId === "string" && rawId.trim() !== "" ? rawId.trim() : null;

  return (
    <CustomReports
      currentUserId={user.id}
      isAdmin={profile?.role === "admin"}
      initialId={initialId}
    />
  );
}
