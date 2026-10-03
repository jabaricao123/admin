"use client";

import * as React from "react";
import {
  Loader2Icon,
  PlusIcon,
  RefreshCwIcon,
  SearchIcon,
  ShieldCheckIcon,
} from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
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
import { Textarea } from "@/components/ui/textarea";
import { useIsMobile } from "@/hooks/use-mobile";
import type { Database } from "@/lib/database.types";
import {
  ROLE_KIND_BADGE_CLASSES,
  ROLE_KIND_LABELS,
  ROLE_STATUS_BADGE_CLASSES,
  ROLE_STATUS_LABELS,
  ROLE_STATUS_OPTIONS,
  translateRoleErrorMessage,
  type RoleKind,
  type RoleStatus,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

const PAGE_SIZE = 20;
const ALL = "all";

type UpsertRoleArgs = Database["public"]["Functions"]["upsert_role"]["Args"];

type Role = {
  id: string;
  name: string;
  code: string;
  isBuiltin: boolean;
  description: string;
  status: RoleStatus;
  userCount: number;
};

type RoleForm = {
  name: string;
  code: string;
  description: string;
  status: RoleStatus;
};

const EMPTY_FORM: RoleForm = {
  name: "",
  code: "",
  description: "",
  status: "active",
};

const KIND_OPTIONS: { value: RoleKind; label: string }[] = [
  { value: "builtin", label: "内置" },
  { value: "custom", label: "自定义" },
];

const asRoleStatus = (value: string | null): RoleStatus =>
  value === "disabled" ? "disabled" : "active";

const kindOf = (role: Role): RoleKind => (role.isBuiltin ? "builtin" : "custom");

export function RolesTable() {
  const isMobile = useIsMobile();
  const [rows, setRows] = React.useState<Role[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [search, setSearch] = React.useState("");
  const [kindFilter, setKindFilter] = React.useState(ALL);
  const [statusFilter, setStatusFilter] = React.useState(ALL);
  const [page, setPage] = React.useState(1);
  const [sheetOpen, setSheetOpen] = React.useState(false);
  const [editing, setEditing] = React.useState<Role | null>(null);
  const [form, setForm] = React.useState<RoleForm>(EMPTY_FORM);
  const [saving, setSaving] = React.useState(false);
  const [acting, setActing] = React.useState<
    "disable" | "enable" | "delete" | null
  >(null);

  const load = React.useCallback(async () => {
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const [roleResult, countResult] = await Promise.all([
      supabase.from("roles_v").select("*"),
      supabase.rpc("get_role_user_counts"),
    ]);

    const loadError = roleResult.error ?? countResult.error;
    if (loadError) {
      setError(loadError.message);
      setRows([]);
      setLoading(false);
      return;
    }

    const counts = new Map<string, number>();
    for (const item of countResult.data ?? []) {
      counts.set(item.role_code, item.user_count);
    }

    const next = (roleResult.data ?? []).map((row): Role => {
      const code = row.code ?? "";
      return {
        id: row.id ?? "",
        name: row.name ?? "",
        code,
        isBuiltin: row.is_builtin ?? false,
        description: row.description ?? "",
        status: asRoleStatus(row.status),
        userCount: counts.get(code) ?? 0,
      };
    });
    // 内置角色在前，其余按名称中文排序
    next.sort((a, b) => {
      if (a.isBuiltin !== b.isBuiltin) {
        return a.isBuiltin ? -1 : 1;
      }
      return a.name.localeCompare(b.name, "zh-CN");
    });
    setRows(next);
    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const filtered = React.useMemo(() => {
    const keyword = search.trim().toLowerCase();
    return rows.filter((row) => {
      if (kindFilter !== ALL && kindOf(row) !== kindFilter) {
        return false;
      }
      if (statusFilter !== ALL && row.status !== statusFilter) {
        return false;
      }
      if (keyword) {
        const haystack =
          `${row.name} ${row.code} ${row.description}`.toLowerCase();
        if (!haystack.includes(keyword)) {
          return false;
        }
      }
      return true;
    });
  }, [rows, search, kindFilter, statusFilter]);

  React.useEffect(() => {
    setPage(1);
  }, [search, kindFilter, statusFilter]);

  const pageCount = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const currentPage = Math.min(page, pageCount);
  const hasActiveFilters =
    search.trim() !== "" || kindFilter !== ALL || statusFilter !== ALL;
  const pagedRows = filtered.slice(
    (currentPage - 1) * PAGE_SIZE,
    currentPage * PAGE_SIZE,
  );

  const openCreate = () => {
    setEditing(null);
    setForm(EMPTY_FORM);
    setSheetOpen(true);
  };

  const openEdit = (row: Role) => {
    setEditing(row);
    setForm({
      name: row.name,
      code: row.code,
      description: row.description,
      status: row.status,
    });
    setSheetOpen(true);
  };

  const closeSheet = () => {
    setSheetOpen(false);
    setEditing(null);
    setForm(EMPTY_FORM);
    setActing(null);
  };

  const handleSave = async () => {
    const name = form.name.trim();
    const code = form.code.trim();

    if (!name) {
      toast.error("角色名称不能为空");
      return;
    }
    if (!code) {
      toast.error("角色标识不能为空");
      return;
    }

    setSaving(true);
    const supabase = createClient();
    const args = {
      p_id: editing?.id ?? null,
      p_name: name,
      p_code: code,
      p_description: form.description.trim() || undefined,
      p_status: form.status,
    };
    // 生成物未表达 uuid 参数可为 NULL（p_id 为 null 表示新建），运行时允许传 null
    const { error: saveError } = await supabase.rpc(
      "upsert_role",
      args as UpsertRoleArgs,
    );
    setSaving(false);

    if (saveError) {
      toast.error(translateRoleErrorMessage(saveError.message));
      return;
    }

    toast.success(editing ? "已保存" : "已新增");
    closeSheet();
    void load();
  };

  const runStatusAction = async (action: "disable" | "enable" | "delete") => {
    if (!editing) {
      return;
    }
    const role = editing;

    if (action === "delete") {
      const confirmed = window.confirm(
        `确定删除角色「${role.name}」？删除后不可恢复；有用户引用的角色会被拒绝。`,
      );
      if (!confirmed) {
        return;
      }
    }

    setActing(action);
    const supabase = createClient();
    const result =
      action === "disable"
        ? await supabase.rpc("disable_role", { p_id: role.id })
        : action === "enable"
          ? await supabase.rpc("enable_role", { p_id: role.id })
          : await supabase.rpc("delete_role", { p_id: role.id });
    setActing(null);

    if (result.error) {
      toast.error(translateRoleErrorMessage(result.error.message));
      void load();
      return;
    }

    if (action === "delete") {
      toast.success("已删除");
      closeSheet();
      void load();
      return;
    }

    const nextStatus: RoleStatus = action === "disable" ? "disabled" : "active";
    toast.success(action === "disable" ? "已停用" : "已启用");
    setEditing({ ...role, status: nextStatus });
    setForm((prev) => ({ ...prev, status: nextStatus }));
    void load();
  };

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardHeader>
          <CardTitle>角色管理</CardTitle>
          <CardDescription>
            维护角色定义：内置角色受保护，自定义角色可编辑与启停用
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
            <div className="relative flex-1 sm:max-w-xs">
              <SearchIcon className="absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder="搜索名称 / 标识 / 说明"
                className="h-11 pl-8 text-base lg:h-8 lg:text-sm"
                aria-label="搜索角色名称、标识或说明"
              />
            </div>
            <Select value={kindFilter} onValueChange={setKindFilter}>
              <SelectTrigger
                className="h-11 w-full sm:w-32 lg:h-8"
                aria-label="按类型筛选"
              >
                <SelectValue placeholder="全部类型" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL}>全部类型</SelectItem>
                {KIND_OPTIONS.map((option) => (
                  <SelectItem key={option.value} value={option.value}>
                    {option.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Select value={statusFilter} onValueChange={setStatusFilter}>
              <SelectTrigger
                className="h-11 w-full sm:w-32 lg:h-8"
                aria-label="按状态筛选"
              >
                <SelectValue placeholder="全部状态" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL}>全部状态</SelectItem>
                {ROLE_STATUS_OPTIONS.map((option) => (
                  <SelectItem key={option.value} value={option.value}>
                    {option.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <div className="flex items-center gap-2 sm:ml-auto">
              <Button
                variant="outline"
                size="icon"
                onClick={() => void load()}
                disabled={loading}
                aria-label="刷新角色列表"
                className="h-11 w-11 lg:h-8 lg:w-8"
              >
                <RefreshCwIcon className={loading ? "animate-spin" : undefined} />
              </Button>
              <Button
                onClick={openCreate}
                className="h-11 flex-1 lg:h-8 lg:flex-none"
              >
                <PlusIcon data-icon="inline-start" />
                新增角色
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
                加载失败：{translateRoleErrorMessage(error)}
              </p>
              <Button variant="outline" onClick={() => void load()}>
                重试
              </Button>
            </div>
          ) : pagedRows.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <ShieldCheckIcon className="size-8 opacity-60" />
              {hasActiveFilters ? (
                <>
                  <span>未找到匹配的角色</span>
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => {
                      setSearch("");
                      setKindFilter(ALL);
                      setStatusFilter(ALL);
                    }}
                  >
                    清除筛选
                  </Button>
                </>
              ) : (
                <span>暂无角色，点击「新增角色」创建</span>
              )}
            </div>
          ) : isMobile ? (
            <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
              {pagedRows.map((row) => (
                <button
                  key={row.id}
                  type="button"
                  data-slot="role-card"
                  onClick={() => openEdit(row)}
                  className="flex w-full flex-col gap-2.5 rounded-xl border bg-card p-4 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                >
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <div className="truncate font-medium">{row.name}</div>
                      <div className="truncate font-mono text-xs text-muted-foreground">
                        {row.code}
                      </div>
                    </div>
                    <Badge
                      variant="outline"
                      className={ROLE_STATUS_BADGE_CLASSES[row.status]}
                    >
                      {ROLE_STATUS_LABELS[row.status]}
                    </Badge>
                  </div>
                  <div className="flex flex-col gap-1.5 text-sm">
                    <div className="flex items-center justify-between gap-4">
                      <span className="text-muted-foreground">类型</span>
                      <Badge
                        variant="outline"
                        className={ROLE_KIND_BADGE_CLASSES[kindOf(row)]}
                      >
                        {ROLE_KIND_LABELS[kindOf(row)]}
                      </Badge>
                    </div>
                    <div className="flex items-center justify-between gap-4">
                      <span className="text-muted-foreground">用户数</span>
                      <span className="tabular-nums">{row.userCount}</span>
                    </div>
                    {row.description ? (
                      <div className="flex items-center justify-between gap-4">
                        <span className="shrink-0 text-muted-foreground">
                          说明
                        </span>
                        <span className="truncate">{row.description}</span>
                      </div>
                    ) : null}
                  </div>
                </button>
              ))}
            </div>
          ) : (
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="text-center">名称</TableHead>
                    <TableHead className="text-center">标识</TableHead>
                    <TableHead className="text-center">类型</TableHead>
                    <TableHead className="text-center">用户数</TableHead>
                    <TableHead className="text-center">状态</TableHead>
                    <TableHead className="text-center">说明</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {pagedRows.map((row) => (
                    <TableRow
                      key={row.id}
                      className="cursor-pointer"
                      role="button"
                      tabIndex={0}
                      aria-label={`编辑角色 ${row.name}`}
                      onClick={() => openEdit(row)}
                      onKeyDown={(event) => {
                        if (event.key === "Enter" || event.key === " ") {
                          event.preventDefault();
                          openEdit(row);
                        }
                      }}
                    >
                      <TableCell className="text-center font-medium">
                        {row.name}
                      </TableCell>
                      <TableCell className="text-center font-mono text-xs text-muted-foreground">
                        {row.code}
                      </TableCell>
                      <TableCell className="text-center">
                        <Badge
                          variant="outline"
                          className={ROLE_KIND_BADGE_CLASSES[kindOf(row)]}
                        >
                          {ROLE_KIND_LABELS[kindOf(row)]}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-center tabular-nums">
                        {row.userCount}
                      </TableCell>
                      <TableCell className="text-center">
                        <Badge
                          variant="outline"
                          className={ROLE_STATUS_BADGE_CLASSES[row.status]}
                        >
                          {ROLE_STATUS_LABELS[row.status]}
                        </Badge>
                      </TableCell>
                      <TableCell className="max-w-64 truncate text-center text-muted-foreground">
                        {row.description || "—"}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}

          {!loading && !error && filtered.length > 0 ? (
            <div className="flex items-center justify-between gap-2 text-sm text-muted-foreground">
              <span>
                {hasActiveFilters
                  ? `匹配 ${filtered.length} 条（共 ${rows.length} 条）· 第 ${currentPage} / ${pageCount} 页`
                  : `共 ${filtered.length} 条 · 第 ${currentPage} / ${pageCount} 页`}
              </span>
              <div className="flex items-center gap-2">
                <Button
                  variant="outline"
                  disabled={currentPage <= 1}
                  onClick={() => setPage(currentPage - 1)}
                  className="h-11 px-4 lg:h-8 lg:px-3"
                >
                  上一页
                </Button>
                <Button
                  variant="outline"
                  disabled={currentPage >= pageCount}
                  onClick={() => setPage(currentPage + 1)}
                  className="h-11 px-4 lg:h-8 lg:px-3"
                >
                  下一页
                </Button>
              </div>
            </div>
          ) : null}
        </CardContent>
      </Card>

      <Sheet
        open={sheetOpen}
        onOpenChange={(open) => {
          if (!open) {
            closeSheet();
          }
        }}
      >
        <SheetContent
          side="right"
          className="w-[35vw] min-w-[320px] max-w-[480px]"
        >
          <SheetHeader>
            <SheetTitle>{editing ? "编辑角色" : "新增角色"}</SheetTitle>
            <SheetDescription className="flex flex-col gap-1">
              {editing ? (
                <>
                  <span className="flex items-center gap-2 font-medium text-foreground">
                    {editing.name}
                    <Badge
                      variant="outline"
                      className={ROLE_KIND_BADGE_CLASSES[kindOf(editing)]}
                    >
                      {ROLE_KIND_LABELS[kindOf(editing)]}
                    </Badge>
                  </span>
                  <span className="font-mono text-xs">{editing.code}</span>
                  <span className="text-xs">
                    当前 {editing.userCount} 名用户
                  </span>
                </>
              ) : (
                <span>录入角色名称、唯一标识与说明</span>
              )}
            </SheetDescription>
          </SheetHeader>
          <div className="flex min-h-0 flex-col gap-4 overflow-y-auto px-4">
            <Field>
              <FieldLabel htmlFor="role-name">名称</FieldLabel>
              <Input
                id="role-name"
                value={form.name}
                disabled={editing?.isBuiltin ?? false}
                onChange={(event) =>
                  setForm((prev) => ({ ...prev, name: event.target.value }))
                }
                placeholder="如：生产主管"
              />
              {editing?.isBuiltin ? (
                <FieldDescription>内置角色名称不可修改</FieldDescription>
              ) : null}
            </Field>
            <Field>
              <FieldLabel htmlFor="role-code">标识</FieldLabel>
              <Input
                id="role-code"
                value={form.code}
                disabled={editing?.isBuiltin ?? false}
                onChange={(event) =>
                  setForm((prev) => ({ ...prev, code: event.target.value }))
                }
                placeholder="如：prod_manager"
                className="font-mono"
              />
              <FieldDescription>
                {editing?.isBuiltin
                  ? "内置角色标识不可修改"
                  : "全系统唯一，冲突时保存会被拒绝"}
              </FieldDescription>
            </Field>
            <Field>
              <FieldLabel htmlFor="role-description">说明</FieldLabel>
              <Textarea
                id="role-description"
                rows={3}
                value={form.description}
                onChange={(event) =>
                  setForm((prev) => ({
                    ...prev,
                    description: event.target.value,
                  }))
                }
                placeholder="角色职责 / 适用范围简述（可选）"
              />
              {editing?.isBuiltin ? (
                <FieldDescription>
                  内置角色仅说明可编辑
                </FieldDescription>
              ) : null}
            </Field>
            <Field>
              <FieldLabel htmlFor="role-status">状态</FieldLabel>
              <Select
                value={form.status}
                onValueChange={(value) =>
                  setForm((prev) => ({
                    ...prev,
                    status: value as RoleStatus,
                  }))
                }
                disabled={editing?.isBuiltin ?? false}
              >
                <SelectTrigger id="role-status" className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {ROLE_STATUS_OPTIONS.map((option) => (
                    <SelectItem key={option.value} value={option.value}>
                      {option.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <FieldDescription>
                {editing?.isBuiltin
                  ? "内置角色状态不可修改，请用下方状态操作"
                  : "停用后不再出现在新用户的角色分配下拉中"}
              </FieldDescription>
            </Field>

            {editing ? (
              <div className="flex flex-col gap-2 rounded-lg border p-3">
                <div className="text-sm font-medium">状态操作</div>
                <p className="text-xs text-muted-foreground">
                  有用户引用的角色不能停用或删除；内置角色不可删除；删除后不可恢复。
                </p>
                <div className="flex flex-wrap gap-2">
                  {editing.status === "active" ? (
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
                  {editing.status === "disabled" ? (
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
                  {!editing.isBuiltin ? (
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
                  ) : null}
                </div>
              </div>
            ) : null}
          </div>
          <SheetFooter className="flex-row justify-end gap-2">
            <Button variant="outline" onClick={closeSheet}>
              取消
            </Button>
            <Button onClick={() => void handleSave()} disabled={saving}>
              {saving ? (
                <Loader2Icon
                  className="animate-spin"
                  data-icon="inline-start"
                />
              ) : null}
              保存
            </Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>
    </div>
  );
}
