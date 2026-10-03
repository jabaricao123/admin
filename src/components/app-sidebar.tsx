"use client";

// 侧边栏（access/008）：菜单改为数据驱动。
//
// 数据源：visible_menus RPC（服务端按当前用户角色过滤并组树）——
//   - admin：全量菜单，fallback=false；
//   - 其他角色：role_menu_grants 授权集 + 祖先链，fallback=false；
//   - 零授权兜底：全量菜单 + fallback=true（过渡期），本组件不展示额外 UI（静默）；
//   - 无角色：空集（fail-closed），渲染显式空态文案。
//
// 本组件不再按 profiles.role 硬过滤；交互保持：折叠为图标、当前路由高亮、
// 移动端 Sheet 侧滑（均见 nav-main.tsx）。加载时显示骨架；RPC 失败时静默回退
// 静态最小菜单（工作台 + 站内信）防白屏。

import * as React from "react";
import Link from "next/link";
import { BoxesIcon } from "lucide-react";

import { NavMain, type NavGroup, type NavItem } from "@/components/nav-main";
import { NavUser, type SidebarUser } from "@/components/nav-user";
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from "@/components/ui/sidebar";
import { Skeleton } from "@/components/ui/skeleton";
import type { Database } from "@/lib/database.types";
import { DEFAULT_MENU_ICON, ICON_MAP } from "@/lib/menu-icons";
import { createClient } from "@/lib/supabase/client";

/**
 * visible_menus 单行。生成类型未标注 SQL 的可空列，这里修正
 * （route 与 parent_key 均允许 NULL：按钮级菜单 / 顶级菜单）。
 */
type MenuRow = Omit<
  Database["public"]["Functions"]["visible_menus"]["Returns"][number],
  "parent_key" | "route"
> & {
  parent_key: string | null;
  route: string | null;
};

/** 加载骨架行数 */
const SKELETON_ROWS = 6;

function compareBySortOrder(a: MenuRow, b: MenuRow) {
  if (a.sort_order !== b.sort_order) {
    return a.sort_order - b.sort_order;
  }
  return a.key.localeCompare(b.key);
}

function renderMenuIcon(key: string) {
  const Icon = ICON_MAP[key] ?? DEFAULT_MENU_ICON;
  return <Icon />;
}

function toNavItem(row: MenuRow, route: string): NavItem {
  return {
    title: row.label,
    url: route,
    icon: renderMenuIcon(row.key),
  };
}

/**
 * 按 parent_key 组树：顶级 = 分组标题，子菜单 = 组内项。
 * - 子项 key=路由，仅渲染有 route 的项（按钮级 key 无 route，不进侧栏）；
 * - 顶级自身有子项时仅作分组标题；仅授权顶级（visible_menus 祖先链只回顶层）时，
 *   顶级有 route 则降级为组内单项，无 route 的顶级仅作分组标题（不渲染空组）。
 */
function buildNavGroups(rows: MenuRow[]): NavGroup[] {
  const childrenByParent = new Map<string, MenuRow[]>();
  const topRows: MenuRow[] = [];

  for (const row of rows) {
    if (row.parent_key === null) {
      topRows.push(row);
      continue;
    }
    const children = childrenByParent.get(row.parent_key);
    if (children) {
      children.push(row);
    } else {
      childrenByParent.set(row.parent_key, [row]);
    }
  }

  return topRows
    .sort(compareBySortOrder)
    .map((top) => {
      const children = (childrenByParent.get(top.key) ?? []).sort(
        compareBySortOrder,
      );
      const items = children
        .filter(
          (child): child is MenuRow & { route: string } => child.route !== null,
        )
        .map((child) => toNavItem(child, child.route));

      if (items.length === 0 && top.route !== null) {
        items.push(toNavItem(top, top.route));
      }

      return { key: top.key, label: top.label, items };
    })
    .filter((group) => group.items.length > 0);
}

/** RPC 失败兜底：静态最小菜单，防侧栏白屏 */
const FALLBACK_GROUPS: NavGroup[] = [
  {
    key: "fallback",
    label: "导航",
    items: [
      { title: "工作台", url: "/", icon: renderMenuIcon("/") },
      {
        title: "站内信",
        url: "/message/inbox",
        icon: renderMenuIcon("/message/inbox"),
      },
    ],
  },
];

export function AppSidebar({
  user,
  ...props
}: React.ComponentProps<typeof Sidebar> & { user: SidebarUser }) {
  const [groups, setGroups] = React.useState<NavGroup[] | null>(null);

  React.useEffect(() => {
    let cancelled = false;

    async function loadMenus() {
      const supabase = createClient();
      const { data, error } = await supabase.rpc("visible_menus");
      if (cancelled) {
        return;
      }
      if (error || !data) {
        // 过渡兜底：RPC 失败静默回退静态最小菜单（防白屏），保留 console 便于排查
        console.error("visible_menus 加载失败，已回退静态菜单：", error?.message);
        setGroups(FALLBACK_GROUPS);
        return;
      }
      setGroups(buildNavGroups(data));
    }

    void loadMenus();
    return () => {
      cancelled = true;
    };
  }, []);

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
        {groups === null ? (
          <SidebarGroup>
            <SidebarGroupLabel>导航</SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu>
                {Array.from({ length: SKELETON_ROWS }, (_, index) => (
                  <SidebarMenuItem key={index}>
                    <div className="flex h-8 items-center gap-2 rounded-md px-2">
                      <Skeleton className="size-4 rounded-md" />
                      <Skeleton className="h-4 w-2/3" />
                    </div>
                  </SidebarMenuItem>
                ))}
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        ) : groups.length === 0 ? (
          <SidebarGroup>
            <SidebarGroupContent>
              <p className="px-2 py-1 text-xs text-sidebar-foreground/60">
                暂无可访问菜单，请联系管理员分配权限
              </p>
            </SidebarGroupContent>
          </SidebarGroup>
        ) : (
          <NavMain groups={groups} />
        )}
      </SidebarContent>
      <SidebarFooter>
        <NavUser user={user} />
      </SidebarFooter>
    </Sidebar>
  );
}
