"use client";

import * as React from "react";
import {
  ChevronRightIcon,
  Loader2Icon,
  NetworkIcon,
  PlusIcon,
  SaveIcon,
  SearchIcon,
} from "lucide-react";
import { cn } from "cn";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Field, FieldDescription, FieldLabel } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetFooter,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { useIsMobile } from "@/hooks/use-mobile";
import type { Database } from "@/lib/database.types";
import {
  DEPARTMENT_STATUS_BADGE_CLASSES,
  DEPARTMENT_STATUS_LABELS,
  translateErrorMessage,
  translateOrgErrorMessage,
  type DepartmentStatus,
  type Profile,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

const ROOT_VALUE = "root";
const NONE_VALUE = "none";
/** 桌面端层级缩进步长（1.5rem），移动端缩放为一半 */
const INDENT_REM = 1.5;
const MOBILE_INDENT_REM = 0.75;

type DepartmentRow = Database["public"]["Views"]["departments_v"]["Row"];
type LeaderOption = Pick<Profile, "id" | "full_name" | "email" | "status">;
type UpsertDepartmentArgs =
  Database["public"]["Functions"]["upsert_department"]["Args"];

type DepartmentNode = {
  id: string;
  name: string;
  parentId: string | null;
  leaderId: string | null;
  sortOrder: number;
  status: DepartmentStatus;
  depth: number;
  path: string;
  children: DepartmentNode[];
};

type DepartmentTreeData = {
  roots: DepartmentNode[];
  map: Map<string, DepartmentNode>;
  /** 深度优先全量节点（含被折叠的），用于搜索与下拉选项 */
  list: DepartmentNode[];
};

type DepartmentForm = {
  /** null = 新建 */
  id: string | null;
  name: string;
  parentId: string;
  leaderId: string;
  sortOrder: string;
};

type SheetState =
  | { mode: "create" }
  | { mode: "edit"; node: DepartmentNode }
  | null;

const EMPTY_FORM: DepartmentForm = {
  id: null,
  name: "",
  parentId: ROOT_VALUE,
  leaderId: NONE_VALUE,
  sortOrder: "0",
};

const asDepartmentStatus = (value: string | null): DepartmentStatus =>
  value === "disabled" ? "disabled" : value === "deleted" ? "deleted" : "active";

const leaderDisplayName = (leader: LeaderOption): string =>
  leader.full_name?.trim() || leader.email?.split("@")[0] || "未命名用户";

const buildTree = (rows: DepartmentRow[]): DepartmentTreeData => {
  const map = new Map<string, DepartmentNode>();
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

  const compare = (a: DepartmentNode, b: DepartmentNode) =>
    a.sortOrder - b.sortOrder || a.name.localeCompare(b.name, "zh-CN");

  const roots: DepartmentNode[] = [];
  for (const node of map.values()) {
    const parent = node.parentId ? map.get(node.parentId) : undefined;
    if (parent) {
      parent.children.push(node);
    } else {
      roots.push(node);
    }
  }

  const sortRecursively = (nodes: DepartmentNode[]) => {
    nodes.sort(compare);
    for (const node of nodes) {
      sortRecursively(node.children);
    }
  };
  sortRecursively(roots);

  const list: DepartmentNode[] = [];
  const visit = (node: DepartmentNode) => {
    list.push(node);
    node.children.forEach(visit);
  };
  roots.forEach(visit);

  return { roots, map, list };
};

export function DepartmentsTree() {
  const isMobile = useIsMobile();
  const [rows, setRows] = React.useState<DepartmentRow[]>([]);
  const [leaders, setLeaders] = React.useState<LeaderOption[]>([]);
  const [leadersError, setLeadersError] = React.useState(false);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [search, setSearch] = React.useState("");
  const [expanded, setExpanded] = React.useState<Set<string>>(new Set());
  const initializedRef = React.useRef(false);
  const [sheet, setSheet] = React.useState<SheetState>(null);
  const [form, setForm] = React.useState<DepartmentForm>(EMPTY_FORM);
  const [saving, setSaving] = React.useState(false);
  const [acting, setActing] = React.useState<
    "disable" | "enable" | "delete" | null
  >(null);

  const load = React.useCallback(async () => {
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const [treeResult, leaderResult] = await Promise.all([
      supabase.rpc("department_tree"),
      supabase
        .from("profiles")
        .select("id, full_name, email, status")
        .order("full_name"),
    ]);

    if (treeResult.error) {
      setError(treeResult.error.message);
      setRows([]);
    } else {
      setRows(treeResult.data ?? []);
    }

    if (leaderResult.error) {
      setLeadersError(true);
      setLeaders([]);
    } else {
      setLeadersError(false);
      setLeaders(leaderResult.data ?? []);
    }
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
      if (node.depth <= 2 && node.children.length > 0) {
        initial.add(node.id);
      }
    }
    setExpanded(initial);
    initializedRef.current = true;
  }, [tree]);

  const leaderNames = React.useMemo(() => {
    const map = new Map<string, string>();
    for (const leader of leaders) {
      map.set(leader.id, leaderDisplayName(leader));
    }
    return map;
  }, [leaders]);

  const leaderLabel = React.useCallback(
    (id: string | null) => (id ? (leaderNames.get(id) ?? "未知用户") : "—"),
    [leaderNames],
  );

  // 搜索：命中节点 + 其祖先链保留，并强制展开祖先链
  const searchResult = React.useMemo(() => {
    const keyword = search.trim().toLowerCase();
    if (!keyword) {
      return null;
    }
    const keep = new Set<string>();
    const expand = new Set<string>();
    for (const node of tree.list) {
      const haystack = `${node.name} ${leaderLabel(node.leaderId)}`.toLowerCase();
      if (!haystack.includes(keyword)) {
        continue;
      }
      keep.add(node.id);
      let current = node.parentId ? tree.map.get(node.parentId) : undefined;
      while (current) {
        keep.add(current.id);
        expand.add(current.id);
        current = current.parentId ? tree.map.get(current.parentId) : undefined;
      }
    }
    return { keep, expand };
  }, [search, tree, leaderLabel]);

  const visibleNodes = React.useMemo(() => {
    const output: DepartmentNode[] = [];
    const visit = (node: DepartmentNode) => {
      if (searchResult && !searchResult.keep.has(node.id)) {
        return;
      }
      output.push(node);
      const isOpen = searchResult
        ? searchResult.expand.has(node.id)
        : expanded.has(node.id);
      if (isOpen) {
        node.children.forEach(visit);
      }
    };
    tree.roots.forEach(visit);
    return output;
  }, [tree, expanded, searchResult]);

  const toggleExpand = (id: string) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(id)) {
        next.delete(id);
      } else {
        next.add(id);
      }
      return next;
    });
  };

  const expandAncestors = (parentId: string | null) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      let current = parentId ? tree.map.get(parentId) : undefined;
      while (current) {
        next.add(current.id);
        current = current.parentId
          ? tree.map.get(current.parentId)
          : undefined;
      }
      return next;
    });
  };

  const openCreate = () => {
    setForm(EMPTY_FORM);
    setSheet({ mode: "create" });
  };

  const openEdit = (node: DepartmentNode) => {
    setForm({
      id: node.id,
      name: node.name,
      parentId: node.parentId ?? ROOT_VALUE,
      leaderId: node.leaderId ?? NONE_VALUE,
      sortOrder: String(node.sortOrder),
    });
    setSheet({ mode: "edit", node });
  };

  const closeSheet = () => {
    setSheet(null);
    setForm(EMPTY_FORM);
    setActing(null);
  };

  const editingNode = sheet?.mode === "edit" ? sheet.node : null;

  /** 候选父部门是否等于当前节点自身或其子孙（前端预警，服务端仍会防环） */
  const isSelfOrDescendant = (candidateId: string): boolean => {
    if (form.id === null) {
      return false;
    }
    if (candidateId === form.id) {
      return true;
    }
    let current = tree.map.get(candidateId);
    while (current?.parentId) {
      if (current.parentId === form.id) {
        return true;
      }
      current = tree.map.get(current.parentId);
    }
    return false;
  };

  const parentOptions = tree.list.map((node) => ({
    id: node.id,
    label: `${"　".repeat(Math.max(0, node.depth - 1))}${node.name}${
      node.status === "disabled" ? "（已停用）" : ""
    }`,
    disabled: isSelfOrDescendant(node.id),
  }));

  const parentTriggerLabel =
    form.parentId === ROOT_VALUE
      ? "无（根部门）"
      : (tree.map.get(form.parentId)?.name ?? "（未知部门）");

  // 负责人候选：在职优先；已停用用户保留展示但不可选
  const leaderOptions = React.useMemo(() => {
    const options = leaders.map((leader) => ({
      id: leader.id,
      label:
        leader.status === "active"
          ? leaderDisplayName(leader)
          : `${leaderDisplayName(leader)}（已停用）`,
      disabled: leader.status !== "active",
    }));
    if (
      form.leaderId !== NONE_VALUE &&
      !options.some((option) => option.id === form.leaderId)
    ) {
      options.unshift({
        id: form.leaderId,
        label: leaderNames.get(form.leaderId) ?? "未知用户",
        disabled: true,
      });
    }
    return options;
  }, [leaders, form.leaderId, leaderNames]);

  const leaderTriggerLabel =
    form.leaderId === NONE_VALUE
      ? "未指定"
      : (leaderNames.get(form.leaderId) ?? "未知用户");

  const handleSave = async () => {
    const name = form.name.trim();
    if (!name) {
      toast.error("请输入部门名称");
      return;
    }
    if (
      form.id !== null &&
      form.parentId !== ROOT_VALUE &&
      isSelfOrDescendant(form.parentId)
    ) {
      toast.error("不能将部门移动到自身或其子孙部门下（会形成循环）");
      return;
    }

    setSaving(true);
    const supabase = createClient();
    const args = {
      p_id: form.id,
      p_name: name,
      p_parent_id: form.parentId === ROOT_VALUE ? null : form.parentId,
      p_leader_id: form.leaderId === NONE_VALUE ? null : form.leaderId,
      p_sort_order: Number.parseInt(form.sortOrder, 10) || 0,
    };
    // 生成物未表达 uuid 参数可为 NULL（p_id 为 null 表示新建），运行时允许传 null
    const { data, error: saveError } = await supabase.rpc(
      "upsert_department",
      args as UpsertDepartmentArgs,
    );
    setSaving(false);

    if (saveError) {
      toast.error(translateOrgErrorMessage(saveError.message));
      return;
    }

    toast.success("已保存");
    expandAncestors(data?.parent_id ?? null);
    closeSheet();
    void load();
  };

  const runStatusAction = async (action: "disable" | "enable" | "delete") => {
    if (sheet?.mode !== "edit") {
      return;
    }
    const node = sheet.node;

    if (action === "delete") {
      const confirmed = window.confirm(
        `确定删除部门「${node.name}」？删除后不可恢复（逻辑删除），仅空部门（无子部门、无岗位、无在职人员）可删除。`,
      );
      if (!confirmed) {
        return;
      }
    }

    setActing(action);
    const supabase = createClient();
    const result =
      action === "disable"
        ? await supabase.rpc("disable_department", { p_id: node.id })
        : action === "enable"
          ? await supabase.rpc("enable_department", { p_id: node.id })
          : await supabase.rpc("delete_department", { p_id: node.id });
    setActing(null);

    if (result.error) {
      toast.error(translateOrgErrorMessage(result.error.message));
      void load();
      return;
    }

    if (action === "delete") {
      toast.success("已删除");
      closeSheet();
    } else {
      toast.success(action === "disable" ? "已停用" : "已启用");
      setSheet({
        mode: "edit",
        node: { ...node, status: action === "disable" ? "disabled" : "active" },
      });
    }
    void load();
  };

  const hasSearch = search.trim() !== "";
  const isEmpty = visibleNodes.length === 0;

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
            <div className="relative flex-1 sm:max-w-xs">
              <SearchIcon className="absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder="搜索部门 / 负责人"
                className="h-11 pl-8 text-base lg:h-8 lg:text-sm"
                aria-label="搜索部门或负责人"
              />
            </div>
            <div className="flex items-center gap-2 sm:ml-auto">
              <Button onClick={openCreate} className="h-11 lg:h-8">
                <PlusIcon data-icon="inline-start" />
                新增部门
              </Button>
            </div>
          </div>

          {loading ? (
            <div className="flex flex-col gap-2">
              {Array.from({ length: 5 }).map((_, index) => (
                <Skeleton key={index} className="h-12 w-full" />
              ))}
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
          ) : isEmpty ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <NetworkIcon className="size-8 opacity-60" />
              {hasSearch ? (
                <>
                  <span>未找到匹配的部门</span>
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => setSearch("")}
                  >
                    清除搜索
                  </Button>
                </>
              ) : (
                <>
                  <span>暂无部门</span>
                  <Button variant="outline" size="sm" onClick={openCreate}>
                    <PlusIcon data-icon="inline-start" />
                    新增部门
                  </Button>
                </>
              )}
            </div>
          ) : isMobile ? (
            <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
              {visibleNodes.map((node) => {
                const isOpen = searchResult
                  ? searchResult.expand.has(node.id)
                  : expanded.has(node.id);
                return (
                  <div
                    key={node.id}
                    className="flex items-start gap-1"
                    style={{
                      paddingLeft: `${(node.depth - 1) * MOBILE_INDENT_REM}rem`,
                    }}
                  >
                    {node.children.length > 0 ? (
                      <button
                        type="button"
                        onClick={() => toggleExpand(node.id)}
                        aria-label={`${isOpen ? "折叠" : "展开"}部门 ${node.name}`}
                        aria-expanded={isOpen}
                        className="mt-3 flex size-11 shrink-0 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-muted focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none lg:size-8"
                      >
                        <ChevronRightIcon
                          className={cn(
                            "size-4 transition-transform",
                            isOpen && "rotate-90",
                          )}
                        />
                      </button>
                    ) : (
                      <span className="mt-3 size-11 shrink-0 lg:size-8" aria-hidden />
                    )}
                    <button
                      type="button"
                      data-slot="department-card"
                      onClick={() => openEdit(node)}
                      className="flex min-w-0 flex-1 flex-col gap-2 rounded-xl border bg-card p-3 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                    >
                      <div className="flex items-start justify-between gap-3">
                        <div className="min-w-0">
                          <div className="truncate font-medium">{node.name}</div>
                          {node.path ? (
                            <div className="truncate text-xs leading-tight text-muted-foreground">
                              {node.path}
                            </div>
                          ) : null}
                        </div>
                        <Badge
                          variant="outline"
                          className={DEPARTMENT_STATUS_BADGE_CLASSES[node.status]}
                        >
                          {DEPARTMENT_STATUS_LABELS[node.status]}
                        </Badge>
                      </div>
                      <div className="flex flex-col gap-1.5 text-sm">
                        <div className="flex items-center justify-between gap-4">
                          <span className="text-muted-foreground">负责人</span>
                          <span className="truncate">
                            {leaderLabel(node.leaderId)}
                          </span>
                        </div>
                        <div className="flex items-center justify-between gap-4">
                          <span className="text-muted-foreground">排序</span>
                          <span className="tabular-nums">{node.sortOrder}</span>
                        </div>
                      </div>
                    </button>
                  </div>
                );
              })}
            </div>
          ) : (
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="text-center">部门名称</TableHead>
                    <TableHead className="text-center">负责人</TableHead>
                    <TableHead className="w-20 text-center">排序</TableHead>
                    <TableHead className="w-24 text-center">状态</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {visibleNodes.map((node) => {
                    const isOpen = searchResult
                      ? searchResult.expand.has(node.id)
                      : expanded.has(node.id);
                    return (
                      <TableRow
                        key={node.id}
                        className="cursor-pointer"
                        role="button"
                        tabIndex={0}
                        aria-label={`编辑部门 ${node.name}`}
                        onClick={() => openEdit(node)}
                        onKeyDown={(event) => {
                          if (event.key === "Enter" || event.key === " ") {
                            event.preventDefault();
                            openEdit(node);
                          }
                        }}
                      >
                        <TableCell>
                          <div
                            className="flex items-center gap-1 text-left"
                            style={{
                              paddingLeft: `${(node.depth - 1) * INDENT_REM}rem`,
                            }}
                          >
                            {node.children.length > 0 ? (
                              <button
                                type="button"
                                onClick={(event) => {
                                  event.stopPropagation();
                                  toggleExpand(node.id);
                                }}
                                aria-label={`${isOpen ? "折叠" : "展开"}部门 ${node.name}`}
                                aria-expanded={isOpen}
                                className="flex size-6 shrink-0 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-muted focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                              >
                                <ChevronRightIcon
                                  className={cn(
                                    "size-4 transition-transform",
                                    isOpen && "rotate-90",
                                  )}
                                />
                              </button>
                            ) : (
                              <span
                                className="size-6 shrink-0"
                                aria-hidden
                              />
                            )}
                            <span className="font-medium">{node.name}</span>
                          </div>
                        </TableCell>
                        <TableCell className="text-center">
                          {leaderLabel(node.leaderId)}
                        </TableCell>
                        <TableCell className="text-center tabular-nums">
                          {node.sortOrder}
                        </TableCell>
                        <TableCell className="text-center">
                          <Badge
                            variant="outline"
                            className={DEPARTMENT_STATUS_BADGE_CLASSES[node.status]}
                          >
                            {DEPARTMENT_STATUS_LABELS[node.status]}
                          </Badge>
                        </TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </div>
          )}

          {!loading && !error && tree.list.length > 0 ? (
            <div className="text-sm text-muted-foreground">
              {hasSearch
                ? `匹配 ${visibleNodes.length} 个（共 ${tree.list.length} 个部门）`
                : `共 ${tree.list.length} 个部门`}
            </div>
          ) : null}
        </CardContent>
      </Card>

      <Sheet
        open={sheet !== null}
        onOpenChange={(open) => {
          if (!open) {
            closeSheet();
          }
        }}
      >
        <SheetContent
          side="right"
          className="w-full sm:max-w-[480px]"
        >
          <SheetHeader>
            <SheetTitle>
              {sheet?.mode === "create" ? "新增部门" : "编辑部门"}
            </SheetTitle>
            <SheetDescription className="flex flex-col gap-1">
              {editingNode ? (
                <>
                  <span className="font-medium text-foreground">
                    {editingNode.name}
                  </span>
                  <span className="truncate font-mono text-xs">
                    {editingNode.path}
                  </span>
                  <span className="flex items-center gap-1.5 text-xs">
                    当前状态：
                    <Badge
                      variant="outline"
                      className={
                        DEPARTMENT_STATUS_BADGE_CLASSES[editingNode.status]
                      }
                    >
                      {DEPARTMENT_STATUS_LABELS[editingNode.status]}
                    </Badge>
                  </span>
                </>
              ) : (
                <span>填写部门信息，保存后立即生效。</span>
              )}
            </SheetDescription>
          </SheetHeader>
          <div className="flex min-h-0 flex-col gap-4 overflow-y-auto px-4">
            <Field>
              <FieldLabel htmlFor="department-name">名称</FieldLabel>
              <Input
                id="department-name"
                value={form.name}
                onChange={(event) =>
                  setForm((prev) => ({ ...prev, name: event.target.value }))
                }
                placeholder="如：研发部"
              />
            </Field>
            <Field>
              <FieldLabel htmlFor="department-parent">父部门</FieldLabel>
              <Select
                value={form.parentId}
                onValueChange={(value) =>
                  setForm((prev) => ({ ...prev, parentId: value }))
                }
              >
                <SelectTrigger id="department-parent" className="w-full">
                  <SelectValue>{parentTriggerLabel}</SelectValue>
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value={ROOT_VALUE}>无（根部门）</SelectItem>
                  {parentOptions.map((option) => (
                    <SelectItem
                      key={option.id}
                      value={option.id}
                      disabled={option.disabled}
                    >
                      {option.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              {editingNode ? (
                <FieldDescription>
                  不能选择自身或其子孙部门（服务端同样会拒绝成环）。
                </FieldDescription>
              ) : null}
            </Field>
            <Field>
              <FieldLabel htmlFor="department-leader">负责人</FieldLabel>
              <Select
                value={form.leaderId}
                onValueChange={(value) =>
                  setForm((prev) => ({ ...prev, leaderId: value }))
                }
              >
                <SelectTrigger id="department-leader" className="w-full">
                  <SelectValue>{leaderTriggerLabel}</SelectValue>
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value={NONE_VALUE}>未指定</SelectItem>
                  {leaderOptions.map((option) => (
                    <SelectItem
                      key={option.id}
                      value={option.id}
                      disabled={option.disabled}
                    >
                      {option.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              {leadersError ? (
                <FieldDescription className="text-destructive">
                  负责人名单加载失败，请刷新页面重试。
                </FieldDescription>
              ) : null}
            </Field>
            <Field>
              <FieldLabel htmlFor="department-sort">排序号</FieldLabel>
              <Input
                id="department-sort"
                type="number"
                inputMode="numeric"
                step={1}
                value={form.sortOrder}
                onChange={(event) =>
                  setForm((prev) => ({ ...prev, sortOrder: event.target.value }))
                }
              />
              <FieldDescription>
                同级部门按排序号升序排列，数字小的在前。
              </FieldDescription>
            </Field>

            {editingNode ? (
              <div className="flex flex-col gap-2 rounded-lg border p-3">
                <div className="text-sm font-medium">状态操作</div>
                <p className="text-xs text-muted-foreground">
                  停用后该部门不再出现在选人下拉；存在在职人员时无法停用；仅空部门可删除。
                </p>
                <div className="flex flex-wrap gap-2">
                  {editingNode.status === "active" ? (
                    <Button
                      variant="outline"
                      size="sm"
                      disabled={acting !== null}
                      onClick={() => void runStatusAction("disable")}
                    >
                      {acting === "disable" ? (
                        <Loader2Icon
                          className="animate-spin"
                          data-icon="inline-start"
                        />
                      ) : null}
                      停用
                    </Button>
                  ) : null}
                  {editingNode.status === "disabled" ? (
                    <Button
                      variant="outline"
                      size="sm"
                      disabled={acting !== null}
                      onClick={() => void runStatusAction("enable")}
                    >
                      {acting === "enable" ? (
                        <Loader2Icon
                          className="animate-spin"
                          data-icon="inline-start"
                        />
                      ) : null}
                      启用
                    </Button>
                  ) : null}
                  <Button
                    variant="destructive"
                    size="sm"
                    disabled={acting !== null}
                    onClick={() => void runStatusAction("delete")}
                  >
                    {acting === "delete" ? (
                      <Loader2Icon
                        className="animate-spin"
                        data-icon="inline-start"
                      />
                    ) : null}
                    删除
                  </Button>
                </div>
              </div>
            ) : null}
          </div>
          <SheetFooter className="flex-row justify-end gap-2">
            <Button
              variant="outline"
              onClick={closeSheet}
              className="h-11 lg:h-8"
            >
              取消
            </Button>
            <Button
              onClick={() => void handleSave()}
              disabled={saving}
              className="h-11 lg:h-8"
            >
              {saving ? (
                <Loader2Icon
                  className="animate-spin"
                  data-icon="inline-start"
                />
              ) : (
                <SaveIcon data-icon="inline-start" />
              )}
              保存
            </Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>
    </div>
  );
}
