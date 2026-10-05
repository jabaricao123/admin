"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

import {
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  useSidebar,
} from "@/components/ui/sidebar";

export type NavItem = {
  title: string;
  url: string;
  icon?: React.ReactNode;
};

export type NavGroup = {
  /** 分组唯一键（menu_items 顶级 key），React key 用 */
  key: string;
  /** 分组标题（menu_items 顶级 label） */
  label: string;
  items: NavItem[];
};

export function NavMain({
  groups,
  unreadCount,
}: {
  groups: NavGroup[];
  /** 站内信未读数：与菜单数据无关，仅命中收件箱路由时渲染徽标 */
  unreadCount: number;
}) {
  const pathname = usePathname();
  const { setOpenMobile, isMobile } = useSidebar();

  return (
    <>
      {groups.map((group) => (
        <SidebarGroup key={group.key}>
          <SidebarGroupLabel>{group.label}</SidebarGroupLabel>
          <SidebarGroupContent>
            <SidebarMenu>
              {group.items.map((item) => {
                const isActive =
                  item.url === "/"
                    ? pathname === "/"
                    : pathname === item.url ||
                      pathname.startsWith(`${item.url}/`);
                const showUnreadBadge =
                  item.url === "/message/inbox" && unreadCount > 0;

                return (
                  <SidebarMenuItem key={item.url}>
                    <SidebarMenuButton
                      asChild
                      tooltip={item.title}
                      isActive={isActive}
                    >
                      <Link
                        href={item.url}
                        aria-current={isActive ? "page" : undefined}
                        onClick={
                          isMobile ? () => setOpenMobile(false) : undefined
                        }
                      >
                        {item.icon}
                        <span>{item.title}</span>
                      </Link>
                    </SidebarMenuButton>
                    {showUnreadBadge ? (
                      <span
                        aria-label={`${unreadCount} 条未读`}
                        className="pointer-events-none absolute top-1/2 right-1 z-10 flex h-5 min-w-5 -translate-y-1/2 items-center justify-center rounded-full bg-primary px-1 text-[10px] leading-none font-semibold text-primary-foreground tabular-nums group-data-[collapsible=icon]:top-0.5 group-data-[collapsible=icon]:right-0.5 group-data-[collapsible=icon]:h-2 group-data-[collapsible=icon]:min-w-2 group-data-[collapsible=icon]:translate-y-0 group-data-[collapsible=icon]:p-0 group-data-[collapsible=icon]:text-[0]"
                      >
                        {unreadCount > 99 ? "99+" : unreadCount}
                      </span>
                    ) : null}
                  </SidebarMenuItem>
                );
              })}
            </SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>
      ))}
    </>
  );
}
