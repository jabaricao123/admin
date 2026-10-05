import { redirect } from "next/navigation";

import { cookies } from "next/headers";

import { AppSidebar } from "@/components/app-sidebar";
import { SiteHeader } from "@/components/site-header";
import { DictionariesLoader } from "@/components/system/dictionaries-loader";
import { SidebarInset, SidebarProvider } from "@/components/ui/sidebar";
import { createClient } from "@/lib/supabase/server";

// @next-codemod-ignore Cache Components：管理端路由均为服务端动态鉴权，允许阻塞式导航。
export const instant = false;

const SIDEBAR_COOKIE_NAME = "sidebar_state";

export default async function AdminLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const cookieStore = await cookies();
  const sidebarOpen = cookieStore.get(SIDEBAR_COOKIE_NAME)?.value !== "false";

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: profile } = await supabase
    .from("profiles")
    .select("full_name, email, role, status")
    .eq("id", user.id)
    .maybeSingle();

  const userInfo = {
    name: profile?.full_name ?? user.email ?? "未命名用户",
    email: profile?.email ?? user.email ?? "",
    role: profile?.role ?? "engineer",
  };

  return (
    <SidebarProvider
      defaultOpen={sidebarOpen}
      style={
        {
          "--sidebar-width": "calc(var(--spacing) * 72)",
          "--header-height": "calc(var(--spacing) * 12)",
        } as React.CSSProperties
      }
    >
      <AppSidebar variant="inset" user={userInfo} />
      <DictionariesLoader />
      <SidebarInset>
        <SiteHeader />
        <div className="flex flex-1 flex-col">
          <div className="@container/main flex flex-1 flex-col gap-2">
            {children}
          </div>
        </div>
      </SidebarInset>
    </SidebarProvider>
  );
}
