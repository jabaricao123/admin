"use client";

import * as React from "react";
import {
  Loader2Icon,
  RefreshCwIcon,
  SearchIcon,
  UserRoundXIcon,
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
import {
  Field,
  FieldDescription,
  FieldLabel,
} from "@/components/ui/field";
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
import { createClient } from "@/lib/supabase/client";
import {
  PROFILE_STATUS_BADGE_CLASSES,
  PROFILE_STATUS_LABELS,
  PROFILE_STATUS_OPTIONS,
  ROLE_BADGE_CLASSES,
  ROLE_LABELS,
  ROLE_OPTIONS,
  translateErrorMessage,
  translateUserErrorMessage,
  type Profile,
  type ProfileStatus,
  type PositionStatus,
  type UserRole,
} from "@/lib/dictionaries";

const PAGE_SIZE = 20;
const ALL = "all";
const NONE = "__none__";

const formatDateTime = (value: string) =>
  new Date(value).toLocaleString("zh-CN", { hour12: false });

type DepartmentRow = Pick<
  Database["public"]["Views"]["departments_v"]["Row"],
  "id" | "name" | "depth" | "status"
>;
type PositionRow = Pick<
  Database["public"]["Views"]["positions_v"]["Row"],
  "id" | "name" | "department_id" | "status"
>;

type DepartmentOption = {
  id: string;
  name: string;
  depth: number;
  status: "active" | "disabled";
};

type PositionOption = {
  id: string;
  name: string;
  departmentId: string | null;
  status: PositionStatus;
};

type EditForm = {
  full_name: string;
  departmentId: string;
  positionId: string;
  role: UserRole;
  status: ProfileStatus;
};

const EMPTY_FORM: EditForm = {
  full_name: "",
  departmentId: NONE,
  positionId: NONE,
  role: "engineer",
  status: "active",
};

export function UsersTable({ currentUserId }: { currentUserId: string }) {
  const isMobile = useIsMobile();
  const [rows, setRows] = React.useState<Profile[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [search, setSearch] = React.useState("");
  const [roleFilter, setRoleFilter] = React.useState(ALL);
  const [statusFilter, setStatusFilter] = React.useState(ALL);
  const [page, setPage] = React.useState(1);
  const [editing, setEditing] = React.useState<Profile | null>(null);
  const [form, setForm] = React.useState<EditForm>(EMPTY_FORM);
  const [saving, setSaving] = React.useState(false);
  const [departments, setDepartments] = React.useState<DepartmentOption[]>([]);
  const [positions, setPositions] = React.useState<PositionOption[]>([]);

  const load = React.useCallback(async () => {
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const [profileRes, departmentRes, positionRes] = await Promise.all([
      supabase
        .from("profiles")
        .select("*")
        .order("created_at", { ascending: false }),
      supabase
        .from("departments_v")
        .select("id, name, depth, status")
        .order("path"),
      supabase
        .from("positions_v")
        .select("id, name, department_id, status")
        .order("created_at", { ascending: false }),
    ]);

    if (profileRes.error) {
      setError(profileRes.error.message);
      setRows([]);
    } else {
      setRows((profileRes.data ?? []) as Profile[]);
    }

    if (!departmentRes.error) {
      setDepartments(
        (departmentRes.data ?? []).map((row: DepartmentRow) => ({
          id: row.id ?? "",
          name: row.name ?? "",
          depth: row.depth ?? 1,
          status: row.status === "disabled" ? "disabled" : "active",
        })),
      );
    }

    if (!positionRes.error) {
      setPositions(
        (positionRes.data ?? []).map((row: PositionRow) => ({
          id: row.id ?? "",
          name: row.name ?? "",
          departmentId: row.department_id,
          status: row.status === "disabled" ? "disabled" : "active",
        })),
      );
    }

    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  /** updated_by UUID → 展示名（优先姓名，回退邮箱前缀） */
  const editorNames = React.useMemo(() => {
    const map = new Map<string, string>();
    for (const row of rows) {
      if (row.updated_by) {
        map.set(
          row.updated_by,
          row.full_name ?? row.email?.split("@")[0] ?? "未知用户",
        );
      }
    }
    // 当前登录者也可能出现在 updated_by 里但不在列表中（如被过滤）
    map.set(currentUserId, map.get(currentUserId) ?? "我");
    return map;
  }, [rows, currentUserId]);

  const filtered = React.useMemo(() => {
    const keyword = search.trim().toLowerCase();
    return rows.filter((row) => {
      if (roleFilter !== ALL && row.role !== roleFilter) {
        return false;
      }
      if (statusFilter !== ALL && row.status !== statusFilter) {
        return false;
      }
      if (keyword) {
        const haystack = `${row.full_name ?? ""} ${
          row.email ?? ""
        }`.toLowerCase();
        if (!haystack.includes(keyword)) {
          return false;
        }
      }
      return true;
    });
  }, [rows, search, roleFilter, statusFilter]);

  React.useEffect(() => {
    setPage(1);
  }, [search, roleFilter, statusFilter]);

  const pageCount = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const currentPage = Math.min(page, pageCount);
  const hasActiveFilters =
    search.trim() !== "" || roleFilter !== ALL || statusFilter !== ALL;
  const pagedRows = filtered.slice(
    (currentPage - 1) * PAGE_SIZE,
    currentPage * PAGE_SIZE,
  );

  const openEdit = (row: Profile) => {
    setEditing(row);
    setForm({
      full_name: row.full_name ?? "",
      departmentId: row.department_id ?? NONE,
      positionId: row.position_id ?? NONE,
      role: row.role,
      status: row.status,
    });
  };

  const closeEdit = () => {
    setEditing(null);
    setForm(EMPTY_FORM);
  };

  /**
   * 部门下拉（org/009）：仅 active 部门可按层级缩进选择；
   * 编辑中的存量归属若为停用/已删除部门，补临时选项避免回显空白。
   */
  const departmentOptions = React.useMemo(() => {
    const active = departments
      .filter((item) => item.status === "active")
      .map((item) => ({
        id: item.id,
        label: `${"\u3000".repeat(Math.max(0, item.depth - 1))}${item.name}`,
      }));

    const currentId = editing?.department_id;
    if (currentId && !active.some((item) => item.id === currentId)) {
      const known = departments.find((item) => item.id === currentId);
      const label = known
        ? `${known.name}（已停用）`
        : `${editing?.department?.trim() || "原部门"}（已删除）`;
      return [{ id: currentId, label }, ...active];
    }

    return active;
  }, [departments, editing]);

  /**
   * 岗位下拉（org/009）：active 岗位按所选部门过滤；
   * 未指定部门的通用岗位始终可选；编辑中的存量岗位不在过滤集内时补临时选项。
   */
  const positionOptions = React.useMemo(() => {
    const selected = form.departmentId;
    const filtered = positions
      .filter(
        (item) =>
          item.status === "active" &&
          (selected === NONE ||
            item.departmentId === null ||
            item.departmentId === selected),
      )
      .map((item) => ({ id: item.id, label: item.name }));

    if (
      form.positionId !== NONE &&
      !filtered.some((item) => item.id === form.positionId)
    ) {
      const current = positions.find((item) => item.id === form.positionId);
      if (current) {
        const suffix =
          current.status === "disabled" ? "（已停用）" : "（其他部门）";
        return [
          { id: current.id, label: `${current.name}${suffix}` },
          ...filtered,
        ];
      }
    }

    return filtered;
  }, [positions, form.departmentId, form.positionId]);

  /** 部门切换时，所选岗位不属于新部门（且非通用岗位）则清空岗位选择 */
  const handleDepartmentChange = (value: string) => {
    setForm((prev) => {
      const current = positions.find((item) => item.id === prev.positionId);
      const keepPosition =
        prev.positionId === NONE ||
        value === NONE ||
        current === undefined ||
        current.departmentId === null ||
        current.departmentId === value;
      return {
        ...prev,
        departmentId: value,
        positionId: keepPosition ? prev.positionId : NONE,
      };
    });
  };

  const handleSave = async () => {
    if (!editing) {
      return;
    }

    // 停用确认：状态从启用改为停用时先确认
    if (editing.status === "active" && form.status === "inactive") {
      const confirmed = window.confirm(
        `确定停用「${editing.full_name ?? editing.email ?? ""}」？停用后该账号将无法登录系统。`,
      );
      if (!confirmed) {
        return;
      }
    }

    setSaving(true);
    const supabase = createClient();

    // 角色写入单通道（INDEX 规则 7）：角色变更调 access 的 assign_role
    if (form.role !== editing.role) {
      const { error: roleError } = await supabase.rpc("assign_role", {
        p_target_user: editing.id,
        p_new_role: form.role,
      });
      if (roleError) {
        setSaving(false);
        toast.error(translateUserErrorMessage(roleError.message));
        return;
      }
    }

    // admin_update_profile 负责姓名/部门/岗位/状态（角色已收窄，不再传 p_role）；
    // org/009：部门/岗位走 id 参数（触发器回写部门文本），仅在变更时传参
    const departmentChanged =
      form.departmentId !== (editing.department_id ?? NONE);
    const positionChanged = form.positionId !== (editing.position_id ?? NONE);
    const { error: saveError } = await supabase.rpc("admin_update_profile", {
      p_user_id: editing.id,
      p_full_name: form.full_name.trim() || undefined,
      p_status: form.status,
      ...(departmentChanged && form.departmentId !== NONE
        ? { p_department_id: form.departmentId }
        : {}),
      ...(positionChanged && form.positionId !== NONE
        ? { p_position_id: form.positionId }
        : {}),
    });
    setSaving(false);

    if (saveError) {
      toast.error(translateUserErrorMessage(saveError.message));
      void load();
      return;
    }

    toast.success("已保存");
    closeEdit();
    void load();
  };

  const isSelf = editing?.id === currentUserId;

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardHeader>
          <CardTitle>用户管理</CardTitle>
          <CardDescription>维护账号的角色与启停用状态</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
            <div className="relative flex-1 sm:max-w-xs">
              <SearchIcon className="absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder="搜索姓名 / 邮箱"
                className="h-11 pl-8 text-base lg:h-8 lg:text-sm"
                aria-label="搜索姓名或邮箱"
              />
            </div>
            <Select value={roleFilter} onValueChange={setRoleFilter}>
              <SelectTrigger
                className="w-full sm:w-36 h-11 lg:h-8"
                aria-label="按角色筛选"
              >
                <SelectValue placeholder="全部角色" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL}>全部角色</SelectItem>
                {ROLE_OPTIONS.map((option) => (
                  <SelectItem key={option.value} value={option.value}>
                    {option.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Select value={statusFilter} onValueChange={setStatusFilter}>
              <SelectTrigger
                className="w-full sm:w-32 h-11 lg:h-8"
                aria-label="按状态筛选"
              >
                <SelectValue placeholder="全部状态" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL}>全部状态</SelectItem>
                {PROFILE_STATUS_OPTIONS.map((option) => (
                  <SelectItem key={option.value} value={option.value}>
                    {option.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Button
              variant="outline"
              size="icon"
              onClick={() => void load()}
              disabled={loading}
              aria-label="刷新用户列表"
              className="h-9 w-9 lg:h-8 lg:w-8"
            >
              <RefreshCwIcon className={loading ? "animate-spin" : undefined} />
            </Button>
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
          ) : pagedRows.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <UserRoundXIcon className="size-8 opacity-60" />
              {hasActiveFilters ? (
                <>
                  <span>未找到匹配的用户</span>
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => {
                      setSearch("");
                      setRoleFilter(ALL);
                      setStatusFilter(ALL);
                    }}
                  >
                    清除筛选
                  </Button>
                </>
              ) : (
                <span>暂无用户</span>
              )}
            </div>
          ) : isMobile ? (
            <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
              {pagedRows.map((row) => (
                <button
                  key={row.id}
                  type="button"
                  data-slot="user-card"
                  onClick={() => openEdit(row)}
                  className="flex w-full flex-col gap-2.5 rounded-xl border bg-card p-4 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                >
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <div className="truncate font-medium">
                        {row.full_name ?? row.email ?? "-"}
                      </div>
                      <div className="truncate text-xs text-muted-foreground">
                        {row.email}
                      </div>
                    </div>
                    <Badge
                      variant="outline"
                      className={ROLE_BADGE_CLASSES[row.role]}
                    >
                      {ROLE_LABELS[row.role]}
                    </Badge>
                  </div>
                  <div className="flex flex-col gap-1.5 text-sm">
                    <div className="flex items-center justify-between gap-4">
                      <span className="text-muted-foreground">部门</span>
                      <span>{row.department ?? "-"}</span>
                    </div>
                    <div className="flex items-center justify-between gap-4">
                      <span className="text-muted-foreground">状态</span>
                      <Badge
                        variant="outline"
                        className={PROFILE_STATUS_BADGE_CLASSES[row.status]}
                      >
                        {PROFILE_STATUS_LABELS[row.status]}
                      </Badge>
                    </div>
                    <div className="flex items-center justify-between gap-4">
                      <span className="text-muted-foreground">更新时间</span>
                      <span className="tabular-nums">
                        {formatDateTime(row.updated_at)}
                      </span>
                    </div>
                    <div className="flex items-center justify-between gap-4">
                      <span className="text-muted-foreground">最近修改人</span>
                      <span>
                        {row.updated_by
                          ? (editorNames.get(row.updated_by) ?? "已离职用户")
                          : "—"}
                      </span>
                    </div>
                  </div>
                </button>
              ))}
            </div>
          ) : (
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="text-center">姓名</TableHead>
                    <TableHead className="text-center">部门</TableHead>
                    <TableHead className="text-center">角色</TableHead>
                    <TableHead className="text-center">状态</TableHead>
                    <TableHead className="text-center">更新时间</TableHead>
                    <TableHead className="text-center">最近修改人</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {pagedRows.map((row) => (
                    <TableRow
                      key={row.id}
                      className="cursor-pointer"
                      onClick={() => openEdit(row)}
                    >
                      <TableCell className="text-center">
                        <div className="font-medium">
                          {row.full_name ?? row.email ?? "-"}
                        </div>
                        <div className="text-xs text-muted-foreground">
                          {row.email}
                        </div>
                      </TableCell>
                      <TableCell className="text-center">
                        {row.department ?? "-"}
                      </TableCell>
                      <TableCell className="text-center">
                        <Badge
                          variant="outline"
                          className={ROLE_BADGE_CLASSES[row.role]}
                        >
                          {ROLE_LABELS[row.role]}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-center">
                        <Badge
                          variant="outline"
                          className={PROFILE_STATUS_BADGE_CLASSES[row.status]}
                        >
                          {PROFILE_STATUS_LABELS[row.status]}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-center text-muted-foreground">
                        {formatDateTime(row.updated_at)}
                      </TableCell>
                      <TableCell className="text-center text-muted-foreground">
                        {row.updated_by
                          ? (editorNames.get(row.updated_by) ?? "已离职用户")
                          : "—"}
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
        open={editing !== null}
        onOpenChange={(open) => {
          if (!open) {
            closeEdit();
          }
        }}
      >
        <SheetContent
          side="right"
          className="w-[35vw] min-w-[320px] max-w-[480px]"
        >
          <SheetHeader>
            <SheetTitle>编辑用户</SheetTitle>
            <SheetDescription className="flex flex-col gap-1">
              <span className="font-medium text-foreground">
                {editing?.full_name ?? "未命名用户"}
              </span>
              {editing?.email ? (
                <span className="font-mono text-xs">{editing.email}</span>
              ) : null}
              {editing ? (
                <span className="flex items-center gap-1.5 text-xs">
                  当前：
                  <Badge
                    variant="outline"
                    className={ROLE_BADGE_CLASSES[editing.role]}
                  >
                    {ROLE_LABELS[editing.role]}
                  </Badge>
                  <Badge
                    variant="outline"
                    className={PROFILE_STATUS_BADGE_CLASSES[editing.status]}
                  >
                    {PROFILE_STATUS_LABELS[editing.status]}
                  </Badge>
                </span>
              ) : null}
            </SheetDescription>
          </SheetHeader>
          <div className="flex min-h-0 flex-col gap-4 overflow-y-auto px-4">
            <Field>
              <FieldLabel htmlFor="user-full-name">姓名</FieldLabel>
              <Input
                id="user-full-name"
                value={form.full_name}
                onChange={(event) =>
                  setForm((prev) => ({
                    ...prev,
                    full_name: event.target.value,
                  }))
                }
                placeholder="姓名"
              />
            </Field>
            <Field>
              <FieldLabel htmlFor="user-department">部门</FieldLabel>
              <Select
                value={form.departmentId}
                onValueChange={handleDepartmentChange}
              >
                <SelectTrigger id="user-department" className="w-full">
                  <SelectValue placeholder="未指定" />
                </SelectTrigger>
                <SelectContent>
                  {departmentOptions.map((option) => (
                    <SelectItem key={option.id} value={option.id}>
                      {option.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
            <Field>
              <FieldLabel htmlFor="user-position">岗位</FieldLabel>
              <Select
                value={form.positionId}
                onValueChange={(value) =>
                  setForm((prev) => ({ ...prev, positionId: value }))
                }
              >
                <SelectTrigger id="user-position" className="w-full">
                  <SelectValue placeholder="未指定" />
                </SelectTrigger>
                <SelectContent>
                  {positionOptions.map((option) => (
                    <SelectItem key={option.id} value={option.id}>
                      {option.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <FieldDescription>
                按所选部门过滤；未指定部门的通用岗位始终可选
              </FieldDescription>
            </Field>
            <Field>
              <FieldLabel htmlFor="user-role">角色</FieldLabel>
              <Select
                value={form.role}
                onValueChange={(value) =>
                  setForm((prev) => ({ ...prev, role: value as UserRole }))
                }
                disabled={isSelf}
              >
                <SelectTrigger id="user-role" className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {ROLE_OPTIONS.map((option) => (
                    <SelectItem key={option.value} value={option.value}>
                      {option.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              {isSelf ? (
                <FieldDescription>不能修改自己的角色</FieldDescription>
              ) : null}
            </Field>
            <Field>
              <FieldLabel htmlFor="user-status">状态</FieldLabel>
              <Select
                value={form.status}
                onValueChange={(value) =>
                  setForm((prev) => ({
                    ...prev,
                    status: value as ProfileStatus,
                  }))
                }
                disabled={isSelf}
              >
                <SelectTrigger id="user-status" className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {PROFILE_STATUS_OPTIONS.map((option) => (
                    <SelectItem key={option.value} value={option.value}>
                      {option.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              {isSelf ? (
                <FieldDescription>不能停用自己的账号</FieldDescription>
              ) : null}
            </Field>
          </div>
          <SheetFooter className="flex-row justify-end gap-2">
            <Button variant="outline" onClick={closeEdit}>
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
