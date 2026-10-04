"use client";

import * as React from "react";
import {
  ChevronRightIcon,
  NetworkIcon,
  RefreshCwIcon,
  UserRoundIcon,
  UsersIcon,
} from "lucide-react";
import { cn } from "cn";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardAction,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { useIsMobile } from "@/hooks/use-mobile";
import type { Database } from "@/lib/database.types";
import {
  DEPARTMENT_STATUS_BADGE_CLASSES,
  DEPARTMENT_STATUS_LABELS,
  PROFILE_STATUS_BADGE_CLASSES,
  PROFILE_STATUS_LABELS,
  ROLE_BADGE_CLASSES,
  ROLE_LABELS,
  translateErrorMessage,
  type DepartmentStatus,
  type Profile,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

/** 默认展开到第 3 级：depth <= 2 的节点展开，depth >= 3 的折叠 */
const DEFAULT_VISIBLE_DEPTH = 3;
/** 移动端每级缩进步长（与部门管理页一致） */
const MOBILE_INDENT_REM = 0.75;

type DepartmentRow = Database["public"]["Views"]["departments_v"]["Row"];

type DirectoryMember = Pick<
  Profile,
  "id" | "full_name" | "email" | "role" | "status" | "department_id"
>;

/** department_headcount()：deptId → 在岗人数（含子部门聚合） */
type HeadcountMap = Map<string, number>;

type ChartNode = {
  id: string;
  name: string;
  parentId: string | null;
  leaderId: string | null;
  sortOrder: number;
  status: DepartmentStatus;
  depth: number;
  path: string;
  children: ChartNode[];
};

type ChartTree = {
  roots: ChartNode[];
  list: ChartNode[];
  map: Map<string, ChartNode>;
};

const asDepartmentStatus = (value: string | null): DepartmentStatus =>
  value === "disabled" ? "disabled" : value === "deleted" ? "deleted" : "active";

const displayName = (
  member: Pick<DirectoryMember, "full_name" | "email">,
): string =>
  member.full_name?.trim() || member.email?.split("@")[0] || "未命名用户";

/** departments_v 扁平行 → 树（按 sort_order、名称排序，与部门管理页口径一致） */
const buildTree = (rows: DepartmentRow[]): ChartTree => {
  const map = new Map<string, ChartNode>();
  for (const row of rows) {
    if (!row.id) {
      continue;
    }
    map.set(row.id, {
      id: row.id,
      name: row.name ?? "",
      parentId: row.parent_id,
      leaderId: row.leader_id,
      sortOrder: row.sort_order ?? 0,
      status: asDepartmentStatus(row.status),
      depth: row.depth ?? 1,
      path: row.path ?? "",
      children: [],
    });
  }

  const compare = (a: ChartNode, b: ChartNode) =>
    a.sortOrder - b.sortOrder || a.name.localeCompare(b.name, "zh-CN");

  const roots: ChartNode[] = [];
  for (const node of map.values()) {
    const parent = node.parentId ? map.get(node.parentId) : undefined;
    if (parent) {
      parent.children.push(node);
    } else {
      roots.push(node);
    }
  }

  const sortRecursively = (nodes: ChartNode[]) => {
    nodes.sort(compare);
    for (const node of nodes) {
      sortRecursively(node.children);
    }
  };
  sortRecursively(roots);

  const list: ChartNode[] = [];
  const visit = (node: ChartNode) => {
    list.push(node);
    node.children.forEach(visit);
  };
  roots.forEach(visit);

  return { roots, list, map };
};

type DesktopTreeSharedProps = {
  expanded: Set<string>;
  leaderLabel: (id: string | null) => string;
  countOf: (id: string) => number;
  onToggle: (id: string) => void;
  onOpenMembers: (id: string) => void;
};

/**
 * 桌面自绘树的一层：层级容器用 ::before 画父节点到横线的竖线，
 * 节点 li 用 ::before/::after 画半段横线与到卡片的竖线（纯 CSS，无图形库）。
 */
function DesktopLevel({
  nodes,
  level,
  ...shared
}: DesktopTreeSharedProps & { nodes: ChartNode[]; level: number }) {
  return (
    <ul
      className={cn(
        "flex items-start justify-center",
        level === 1
          ? "gap-10"
          : "relative pt-6 before:absolute before:top-0 before:left-1/2 before:h-6 before:border-l before:border-border",
      )}
    >
      {nodes.map((node) => (
        <DesktopNode key={node.id} node={node} level={level} {...shared} />
      ))}
    </ul>
  );
}

function DesktopNode({
  node,
  level,
  expanded,
  leaderLabel,
  countOf,
  onToggle,
  onOpenMembers,
}: DesktopTreeSharedProps & { node: ChartNode; level: number }) {
  const hasChildren = node.children.length > 0;
  const isOpen = hasChildren && expanded.has(node.id);
  const count = countOf(node.id);

  const cardBody = (
    <>
      <div className="flex w-full items-center gap-2">
        <span className="truncate font-medium">{node.name}</span>
        {node.status === "disabled" ? (
          <Badge
            variant="outline"
            className={cn(
              "shrink-0",
              DEPARTMENT_STATUS_BADGE_CLASSES.disabled,
            )}
          >
            {DEPARTMENT_STATUS_LABELS.disabled}
          </Badge>
        ) : null}
        {hasChildren ? (
          <ChevronRightIcon
            aria-hidden
            className={cn(
              "ml-auto size-4 shrink-0 text-muted-foreground transition-transform",
              isOpen && "rotate-90 text-primary",
            )}
          />
        ) : null}
      </div>
      <div className="flex w-full items-center gap-1.5 text-xs text-muted-foreground">
        <UserRoundIcon aria-hidden className="size-3.5 shrink-0" />
        <span className="truncate">{leaderLabel(node.leaderId)}</span>
      </div>
      <div className="flex w-full items-center gap-1.5 text-xs text-muted-foreground">
        <UsersIcon aria-hidden className="size-3.5 shrink-0" />
        <span className="tabular-nums">{count} 人</span>
        {hasChildren && !isOpen ? (
          <span className="ml-auto shrink-0">下级 {node.children.length}</span>
        ) : null}
      </div>
    </>
  );

  return (
    <li
      className={cn(
        "relative flex shrink-0 flex-col items-center px-2",
        level > 1 &&
          cn(
            "pt-6",
            "before:absolute before:top-0 before:right-1/2 before:h-6 before:w-1/2 before:border-t before:border-border",
            "after:absolute after:top-0 after:left-1/2 after:h-6 after:w-1/2 after:border-t after:border-l after:border-border",
            "first:before:border-t-0",
            "last:after:border-t-0 last:after:border-l-0 last:before:border-r",
            "only:pt-0 only:before:hidden only:after:hidden",
          ),
      )}
    >
      <div
        data-slot="org-chart-node"
        className={cn(
          "w-60 overflow-hidden rounded-xl border bg-card shadow-xs transition-colors",
          isOpen ? "border-primary/60" : "hover:border-primary/40",
        )}
      >
        {hasChildren ? (
          <button
            type="button"
            onClick={() => onToggle(node.id)}
            aria-expanded={isOpen}
            aria-label={`${isOpen ? "折叠" : "展开"}部门「${node.name}」的下级`}
            className="flex w-full flex-col gap-2 p-3 text-left transition-colors hover:bg-accent/60 focus-visible:bg-accent/60 focus-visible:outline-none"
          >
            {cardBody}
          </button>
        ) : (
          <div className="flex w-full flex-col gap-2 p-3 text-left">
            {cardBody}
          </div>
        )}
        <div className="border-t">
          <button
            type="button"
            onClick={() => onOpenMembers(node.id)}
            className="flex w-full items-center justify-center gap-1.5 px-3 py-1.5 text-xs font-medium text-primary transition-colors hover:bg-accent hover:text-accent-foreground focus-visible:bg-accent focus-visible:outline-none"
          >
            <UsersIcon aria-hidden className="size-3.5" />
            查看人员
          </button>
        </div>
      </div>
      {isOpen ? (
        <DesktopLevel
          nodes={node.children}
          level={level + 1}
          expanded={expanded}
          leaderLabel={leaderLabel}
          countOf={countOf}
          onToggle={onToggle}
          onOpenMembers={onOpenMembers}
        />
      ) : null}
    </li>
  );
}

export function OrgChartView() {
  const isMobile = useIsMobile();
  const [rows, setRows] = React.useState<DepartmentRow[]>([]);
  const [members, setMembers] = React.useState<DirectoryMember[]>([]);
  /** department_headcount() 结果：deptId → 在岗人数（含子部门）；null = RPC 失败，走前端兜底 */
  const [headcounts, setHeadcounts] = React.useState<HeadcountMap | null>(null);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [expanded, setExpanded] = React.useState<Set<string>>(new Set());
  const [summaryId, setSummaryId] = React.useState<string | null>(null);
  const [memberDeptId, setMemberDeptId] = React.useState<string | null>(null);
  const initializedRef = React.useRef(false);

  const load = React.useCallback(async () => {
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const [treeResult, directoryResult, headcountResult] = await Promise.all([
      supabase.rpc("department_tree"),
      supabase
        .from("profiles")
        .select("id, full_name, email, role, status, department_id"),
      supabase.rpc("department_headcount"),
    ]);

    const loadError = treeResult.error ?? directoryResult.error;
    if (loadError) {
      setError(loadError.message);
      setRows([]);
      setMembers([]);
    } else {
      setRows(treeResult.data ?? []);
      setMembers((directoryResult.data ?? []) as DirectoryMember[]);
    }

    // 人数口径（org/013）：优先 department_headcount()（active + 含子部门聚合）；
    // RPC 失败时置 null，由上方的 profiles 聚合兜底
    setHeadcounts(
      headcountResult.error
        ? null
        : new Map(
            (headcountResult.data ?? []).map((row) => [
              row.department_id,
              Number(row.headcount),
            ]),
          ),
    );
    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const tree = React.useMemo(() => buildTree(rows), [rows]);

  // 默认展开前两级（根节点 depth=1），即默认展示至第 3 级
  React.useEffect(() => {
    if (initializedRef.current || tree.list.length === 0) {
      return;
    }
    const initial = new Set<string>();
    for (const node of tree.list) {
      if (
        node.depth <= DEFAULT_VISIBLE_DEPTH - 1 &&
        node.children.length > 0
      ) {
        initial.add(node.id);
      }
    }
    setExpanded(initial);
    initializedRef.current = true;
  }, [tree]);

  /** profiles 按 department_id 聚合：成员抽屉数据源 + RPC 失败时的人数兜底 */
  const membersByDept = React.useMemo(() => {
    const map = new Map<string, DirectoryMember[]>();
    for (const member of members) {
      if (!member.department_id) {
        continue;
      }
      const list = map.get(member.department_id);
      if (list) {
        list.push(member);
      } else {
        map.set(member.department_id, [member]);
      }
    }
    return map;
  }, [members]);

  const leaderNames = React.useMemo(() => {
    const map = new Map<string, string>();
    for (const member of members) {
      map.set(member.id, displayName(member));
    }
    return map;
  }, [members]);

  const leaderLabel = React.useCallback(
    (id: string | null) =>
      id ? (leaderNames.get(id) ?? "未知用户") : "—",
    [leaderNames],
  );

  /** 人数：优先 department_headcount()（在岗、含子部门），RPC 失败/缺行时回退前端聚合 */
  const countOf = React.useCallback(
    (id: string) => {
      const fromRpc = headcounts?.get(id);
      if (fromRpc !== undefined) {
        return fromRpc;
      }
      return membersByDept.get(id)?.length ?? 0;
    },
    [headcounts, membersByDept],
  );

  const toggleExpand = React.useCallback((id: string) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(id)) {
        next.delete(id);
      } else {
        next.add(id);
      }
      return next;
    });
  }, []);

  // 移动端：扁平可见节点序列（accordion 按 expanded 逐级展开）
  const visibleNodes = React.useMemo(() => {
    const output: ChartNode[] = [];
    const visit = (node: ChartNode) => {
      output.push(node);
      if (expanded.has(node.id)) {
        node.children.forEach(visit);
      }
    };
    tree.roots.forEach(visit);
    return output;
  }, [tree, expanded]);

  const memberDept = memberDeptId ? (tree.map.get(memberDeptId) ?? null) : null;

  const memberList = React.useMemo(() => {
    if (!memberDeptId) {
      return [];
    }
    const list = [...(membersByDept.get(memberDeptId) ?? [])];
    return list.sort((a, b) => {
      if (a.status !== b.status) {
        return a.status === "active" ? -1 : 1;
      }
      return displayName(a).localeCompare(displayName(b), "zh-CN");
    });
  }, [memberDeptId, membersByDept]);

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardHeader>
          <CardTitle>组织架构</CardTitle>
          <CardDescription>
            只读树形组织图：部门层级、负责人与人数；默认展示前 3 级，点击节点展开下级
          </CardDescription>
          <CardAction>
            <Button
              variant="outline"
              size="sm"
              onClick={() => void load()}
              disabled={loading}
              className="h-11 lg:h-7"
            >
              <RefreshCwIcon
                data-icon="inline-start"
                className={cn(loading && "animate-spin")}
              />
              刷新
            </Button>
          </CardAction>
        </CardHeader>
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          {loading ? (
            <div className="flex flex-col gap-3">
              <Skeleton className="h-40 w-full rounded-xl" />
              <Skeleton className="h-40 w-full rounded-xl" />
            </div>
          ) : error ? (
            <div className="flex flex-col items-center gap-2 py-8 text-sm">
              <p className="text-destructive">
                加载失败：{translateErrorMessage(error)}
              </p>
              <Button variant="outline" onClick={() => void load()}>
                重试
              </Button>
            </div>
          ) : tree.roots.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <NetworkIcon className="size-8 opacity-60" />
              <span>暂无部门，请先维护部门</span>
            </div>
          ) : (
            <>
              <div className="text-sm text-muted-foreground">
                共 {tree.list.length} 个部门
              </div>
              {isMobile ? (
                <div className="flex flex-col">
                  {visibleNodes.map((node) => {
                    const hasChildren = node.children.length > 0;
                    const isOpen = expanded.has(node.id);
                    const summaryOpen = summaryId === node.id;
                    const count = countOf(node.id);
                    return (
                      <div
                        key={node.id}
                        data-slot="org-chart-mobile-row"
                        className="flex flex-col"
                        style={{
                          paddingLeft: `${(node.depth - 1) * MOBILE_INDENT_REM}rem`,
                        }}
                      >
                        <div className="flex items-center gap-0.5 border-b">
                          {hasChildren ? (
                            <button
                              type="button"
                              onClick={() => toggleExpand(node.id)}
                              aria-expanded={isOpen}
                              aria-label={`${isOpen ? "折叠" : "展开"}部门「${node.name}」的下级`}
                              className="flex size-11 shrink-0 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-muted focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                            >
                              <ChevronRightIcon
                                className={cn(
                                  "size-4 transition-transform",
                                  isOpen && "rotate-90",
                                )}
                              />
                            </button>
                          ) : (
                            <span className="size-11 shrink-0" aria-hidden />
                          )}
                          <button
                            type="button"
                            onClick={() =>
                              setSummaryId(summaryOpen ? null : node.id)
                            }
                            aria-expanded={summaryOpen}
                            className="flex min-h-11 min-w-0 flex-1 items-center gap-2 py-2 text-left focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                          >
                            <span className="truncate font-medium">
                              {node.name}
                            </span>
                            {node.status === "disabled" ? (
                              <Badge
                                variant="outline"
                                className={cn(
                                  "shrink-0",
                                  DEPARTMENT_STATUS_BADGE_CLASSES.disabled,
                                )}
                              >
                                {DEPARTMENT_STATUS_LABELS.disabled}
                              </Badge>
                            ) : null}
                            <span className="ml-auto shrink-0 text-xs text-muted-foreground tabular-nums">
                              {count} 人
                            </span>
                          </button>
                          <button
                            type="button"
                            onClick={() => setMemberDeptId(node.id)}
                            aria-label={`查看部门「${node.name}」人员`}
                            className="flex size-11 shrink-0 items-center justify-center rounded-md text-primary transition-colors hover:bg-accent focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                          >
                            <UsersIcon className="size-4" />
                          </button>
                        </div>
                        {summaryOpen ? (
                          <div className="my-2 ml-1 flex flex-col gap-1.5 rounded-lg border bg-card p-3 text-sm shadow-xs">
                            <div className="flex items-center justify-between gap-4">
                              <span className="text-muted-foreground">
                                负责人
                              </span>
                              <span className="truncate">
                                {leaderLabel(node.leaderId)}
                              </span>
                            </div>
                            <div className="flex items-center justify-between gap-4">
                              <span className="text-muted-foreground">层级</span>
                              <span className="truncate">{node.path}</span>
                            </div>
                            <div className="flex items-center justify-between gap-4">
                              <span className="text-muted-foreground">人数</span>
                              <span className="tabular-nums">{count} 人</span>
                            </div>
                            <Button
                              variant="outline"
                              size="sm"
                              className="mt-1 h-11 w-full"
                              onClick={() => setMemberDeptId(node.id)}
                            >
                              <UsersIcon data-icon="inline-start" />
                              查看人员
                            </Button>
                          </div>
                        ) : null}
                      </div>
                    );
                  })}
                </div>
              ) : (
                <div className="overflow-x-auto rounded-xl border bg-muted/30 p-4 md:p-6">
                  <div className="flex w-max min-w-full justify-center">
                    <DesktopLevel
                      nodes={tree.roots}
                      level={1}
                      expanded={expanded}
                      leaderLabel={leaderLabel}
                      countOf={countOf}
                      onToggle={toggleExpand}
                      onOpenMembers={setMemberDeptId}
                    />
                  </div>
                </div>
              )}
            </>
          )}
        </CardContent>
      </Card>

      <Sheet
        open={memberDeptId !== null}
        onOpenChange={(open) => {
          if (!open) {
            setMemberDeptId(null);
          }
        }}
      >
        <SheetContent
          side="right"
          className="w-[35vw] min-w-[320px] max-w-[480px]"
        >
          <SheetHeader>
            <SheetTitle>
              {memberDept ? `${memberDept.name} · 成员` : "部门成员"}
            </SheetTitle>
            <SheetDescription className="flex flex-col gap-1">
              {memberDept?.path ? (
                <span className="truncate font-mono text-xs">
                  {memberDept.path}
                </span>
              ) : null}
              <span>共 {memberList.length} 人 · 只读</span>
            </SheetDescription>
          </SheetHeader>
          <div className="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto px-4 pb-4">
            {memberList.length === 0 ? (
              <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
                <UsersIcon className="size-8 opacity-60" />
                <span>该部门暂无成员</span>
              </div>
            ) : (
              <ul className="flex flex-col gap-2">
                {memberList.map((member) => (
                  <li
                    key={member.id}
                    className="flex items-center justify-between gap-3 rounded-lg border p-3"
                  >
                    <div className="min-w-0">
                      <div className="truncate font-medium">
                        {displayName(member)}
                      </div>
                      {member.email ? (
                        <div className="truncate text-xs text-muted-foreground">
                          {member.email}
                        </div>
                      ) : null}
                    </div>
                    <div className="flex shrink-0 items-center gap-1.5">
                      <Badge
                        variant="outline"
                        className={ROLE_BADGE_CLASSES[member.role]}
                      >
                        {ROLE_LABELS[member.role]}
                      </Badge>
                      <Badge
                        variant="outline"
                        className={PROFILE_STATUS_BADGE_CLASSES[member.status]}
                      >
                        {PROFILE_STATUS_LABELS[member.status]}
                      </Badge>
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </div>
        </SheetContent>
      </Sheet>
    </div>
  );
}
