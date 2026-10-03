"use client";

import Link from "next/link";
import { BoxesIcon, LayoutDashboardIcon, UsersIcon } from "lucide-react";

import { NavMain, type NavItem } from "@/components/nav-main";
import { NavUser, type SidebarUser } from "@/components/nav-user";
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from "@/components/ui/sidebar";

export function AppSidebar({
  user,
  ...props
}: React.ComponentProps<typeof Sidebar> & { user: SidebarUser }) {
  const navItems: NavItem[] = [
    {
      title: "工作台",
      url: "/",
      icon: <LayoutDashboardIcon />,
    },
  ];

  if (user.role === "admin") {
    navItems.push({
      title: "用户管理",
      url: "/settings/users",
      icon: <UsersIcon />,
    });
  }

  return (
    <Sidebar collapsible="icon" {...props}>
      <SidebarHeader>
        <SidebarMenu>
          <SidebarMenuItem>
            <SidebarMenuButton
              asChild
              className="data-[slot=sidebar-menu-button]:p-1.5!"
            >
              <Link href="/">
                <div className="flex size-6 items-center justify-center rounded-md bg-primary text-primary-foreground">
                  <BoxesIcon className="size-4" />
                </div>
                <span className="text-base font-semibold">企业管理系统</span>
              </Link>
            </SidebarMenuButton>
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarHeader>
      <SidebarContent>
        <NavMain label="导航" items={navItems} />
      </SidebarContent>
      <SidebarFooter>
        <NavUser user={user} />
      </SidebarFooter>
    </Sidebar>
  );
}
