"use client";

import { usePathname } from "next/navigation";

import { ThemeToggle } from "@/components/theme-toggle";
import { Separator } from "@/components/ui/separator";
import { SidebarTrigger } from "@/components/ui/sidebar";

const PAGE_TITLES: Record<string, string> = {
  "/": "工作台",
  "/org/departments": "部门管理",
  "/org/positions": "岗位管理",
  "/access/roles": "角色管理",
  "/access/permissions": "菜单权限",
  "/access/data-scopes": "数据权限",
  "/message/inbox": "站内信",
  "/org/users": "用户管理",
  "/org/chart": "组织架构",
  "/system/services/mail": "邮件服务",
  "/system/services/storage": "对象存储",
  "/approval/todo": "我的待办",
  "/approval/mine": "我发起的",
  "/approval/cc": "抄送我的",
  "/audit/operations": "操作日志",
  "/audit/logins": "登录日志",
  "/sync/sources": "数据源配置",
  "/sync/tasks": "同步任务",
};

export function SiteHeader() {
  const pathname = usePathname();
  const title = PAGE_TITLES[pathname] ?? "企业管理系统";

  return (
    <header className="flex h-(--header-height) shrink-0 items-center gap-2 border-b transition-[width,height] ease-linear group-has-data-[collapsible=icon]/sidebar-wrapper:h-(--header-height)">
      <div className="flex w-full items-center gap-1 px-4 lg:gap-2 lg:px-6">
        <SidebarTrigger className="-ml-1" />
        <Separator
          orientation="vertical"
          className="mx-2 data-[orientation=vertical]:h-4"
        />
        <h1 className="text-base font-medium">{title}</h1>
        <div className="ml-auto flex items-center gap-2">
          <ThemeToggle />
        </div>
      </div>
    </header>
  );
}
