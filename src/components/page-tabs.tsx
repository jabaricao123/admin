"use client";

// 多标签页（shell）：页头「已打开页面」标签栏。
//
// 保活（cacheComponents + React Activity）：客户端导航时页面不再卸载，仅隐藏——
// 表单、滚动、筛选等 React/DOM 状态切回时保留（见 next.config.mjs 的 cacheComponents）。
// 限制：Next.js 只保活最近 3 个路由，更早的标签切回时重新渲染（框架启发式）；
// 刷新/重开浏览器只从 sessionStorage 恢复标签列表，不恢复页面内状态。
//
// 固定标签：工作台（/ 重定向目标 /dashboard）不可关闭，保证标签永不为空；
// 其余标签支持单个关闭（X / 鼠标中键）；尾随菜单提供刷新当前页（保活下数据不自动重取）
// 与「关闭其他 / 关闭全部」。

import * as React from "react";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { ChevronDownIcon, RefreshCwIcon, XIcon } from "lucide-react";
import { cn } from "cn";

import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { PAGE_TITLES } from "@/lib/page-titles";

/** 固定标签：工作台（/dashboard，根路径重定向目标） */
const HOME_HREF = "/dashboard";
/** sessionStorage 键：只存可关闭标签的 href（标题实时取自 PAGE_TITLES，改名不残留旧文案） */
const STORAGE_KEY = "admin.page-tabs";

type Tab = {
  href: string;
  title: string;
  /** 固定标签不可关闭（工作台） */
  pinned?: boolean;
};

const HOME_TAB: Tab = {
  href: HOME_HREF,
  title: PAGE_TITLES[HOME_HREF],
  pinned: true,
};

function createTab(href: string): Tab {
  return { href, title: PAGE_TITLES[href] };
}

/**
 * 首屏标签：工作台 + 当前页。只依赖 pathname（SSR 与 hydration 一致），
 * sessionStorage 的恢复在挂载后的 effect 里做，避免 hydration mismatch。
 */
function initialTabs(activeHref: string): Tab[] {
  const tabs = [HOME_TAB];
  if (activeHref !== HOME_HREF && isTabRoute(activeHref)) {
    tabs.push(createTab(activeHref));
  }
  return tabs;
}

/** 是否登记为标签：排除根路径（重定向别名）与未登记路由 */
function isTabRoute(href: string): boolean {
  return href !== "/" && Boolean(PAGE_TITLES[href]);
}

export function PageTabs() {
  const pathname = usePathname();
  const router = useRouter();
  // 根路径（/）是工作台的重定向别名，统一按工作台处理
  const activeHref = pathname === "/" ? HOME_HREF : pathname;
  const [tabs, setTabs] = React.useState<Tab[]>(() => initialTabs(activeHref));
  const activeRef = React.useRef<HTMLAnchorElement | null>(null);

  // 会话内恢复：合并已存标签与当前状态，过滤未登记路由并去重
  React.useEffect(() => {
    let stored: unknown = null;
    try {
      stored = JSON.parse(sessionStorage.getItem(STORAGE_KEY) ?? "[]");
    } catch {
      stored = null;
    }
    if (!Array.isArray(stored)) {
      return;
    }
    setTabs((prev) => {
      const seen = new Set<string>([HOME_HREF]);
      const next: Tab[] = [HOME_TAB];
      for (const href of [...stored, ...prev.map((tab) => tab.href)]) {
        if (
          typeof href !== "string" ||
          seen.has(href) ||
          !PAGE_TITLES[href]
        ) {
          continue;
        }
        seen.add(href);
        next.push(createTab(href));
      }
      return next;
    });
  }, []);

  // 当前路由登记为标签（回退/前进/侧栏进入均覆盖）
  React.useEffect(() => {
    if (!isTabRoute(activeHref)) {
      return;
    }
    setTabs((prev) =>
      prev.some((tab) => tab.href === activeHref)
        ? prev
        : [...prev, createTab(activeHref)],
    );
  }, [activeHref]);

  // 写回会话存储（仅可关闭标签；隐私模式等写失败不阻塞使用）
  React.useEffect(() => {
    try {
      sessionStorage.setItem(
        STORAGE_KEY,
        JSON.stringify(tabs.filter((tab) => !tab.pinned).map((tab) => tab.href)),
      );
    } catch {
      // 忽略
    }
  }, [tabs]);

  // 活动标签滚动入视野（标签多时横向溢出）
  React.useEffect(() => {
    activeRef.current?.scrollIntoView({ block: "nearest", inline: "nearest" });
  }, [activeHref, tabs]);

  function closeTab(href: string) {
    const index = tabs.findIndex((tab) => tab.href === href);
    if (index === -1) {
      return;
    }
    const next = tabs.filter((tab) => tab.href !== href);
    setTabs(next);
    if (href === activeHref) {
      // 优先激活右侧邻居，其次左侧，最后回工作台
      const fallback = next[index] ?? next[index - 1] ?? HOME_TAB;
      router.push(fallback.href);
    }
  }

  function closeOthers() {
    const keepActive = isTabRoute(activeHref) && activeHref !== HOME_HREF;
    setTabs(keepActive ? [HOME_TAB, createTab(activeHref)] : [HOME_TAB]);
    if (!keepActive && activeHref !== HOME_HREF) {
      router.push(HOME_HREF);
    }
  }

  function closeAll() {
    setTabs([HOME_TAB]);
    if (activeHref !== HOME_HREF) {
      router.push(HOME_HREF);
    }
  }

  const closable = tabs.filter((tab) => !tab.pinned);
  const closableOthers = closable.filter((tab) => tab.href !== activeHref);
  const activeTitle = PAGE_TITLES[activeHref];

  // 未登记路由：暂无标签语义，回退为系统名标题
  if (!activeTitle) {
    return (
      <div className="flex min-w-0 flex-1 items-center">
        <h1 className="truncate text-base font-medium">企业管理系统</h1>
      </div>
    );
  }

  return (
    <>
      <h1 className="sr-only">{activeTitle}</h1>
      <nav
        aria-label="已打开的页面"
        className="no-scrollbar flex min-w-0 flex-1 items-center gap-1 overflow-x-auto"
      >
        {tabs.map((tab) => {
          const isActive = tab.href === activeHref;
          return (
            <div
              key={tab.href}
              data-active={isActive ? "true" : undefined}
              className="group/tab relative flex h-8 shrink-0 items-center"
              onAuxClick={(event) => {
                if (event.button === 1 && !tab.pinned) {
                  event.preventDefault();
                  closeTab(tab.href);
                }
              }}
            >
              <Link
                ref={isActive ? activeRef : undefined}
                href={tab.href}
                title={tab.title}
                aria-current={isActive ? "page" : undefined}
                className={cn(
                  "flex h-8 max-w-44 items-center rounded-md text-sm transition-colors",
                  "focus-visible:ring-ring focus-visible:ring-2 focus-visible:outline-hidden",
                  tab.pinned ? "px-2.5" : "pr-7 pl-2.5",
                  isActive
                    ? "bg-accent font-medium text-accent-foreground"
                    : "text-muted-foreground hover:bg-muted hover:text-foreground",
                )}
              >
                <span className="truncate">{tab.title}</span>
              </Link>
              {tab.pinned ? null : (
                <button
                  type="button"
                  aria-label={`关闭 ${tab.title}`}
                  onClick={() => closeTab(tab.href)}
                  className={cn(
                    "absolute right-1 flex size-5 items-center justify-center rounded-sm transition-[opacity,background-color,color]",
                    "hover:bg-foreground/10 hover:text-foreground focus-visible:ring-ring focus-visible:ring-2 focus-visible:outline-hidden",
                    isActive
                      ? "text-accent-foreground opacity-100"
                      : "text-muted-foreground opacity-0 group-hover/tab:opacity-100 group-focus-within/tab:opacity-100",
                  )}
                >
                  <XIcon className="size-3.5" />
                </button>
              )}
            </div>
          );
        })}
      </nav>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <button
            type="button"
            aria-label="标签页操作"
            className="flex size-8 shrink-0 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-accent hover:text-accent-foreground focus-visible:ring-ring focus-visible:ring-2 focus-visible:outline-hidden"
          >
            <ChevronDownIcon className="size-4" />
          </button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="w-36">
          <DropdownMenuItem onSelect={() => router.refresh()}>
            <RefreshCwIcon />
            刷新当前页
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem
            disabled={closableOthers.length === 0}
            onSelect={closeOthers}
          >
            关闭其他
          </DropdownMenuItem>
          <DropdownMenuItem disabled={closable.length === 0} onSelect={closeAll}>
            关闭全部
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </>
  );
}
