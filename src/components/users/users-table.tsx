"use client";

import * as React from "react";
import {
  Loader2Icon,
  SaveIcon,
  SearchIcon,
  UserRoundXIcon,
} from "lucide-react";
import { toast } from "sonner";

import { banUser, unbanUser } from "@/app/(admin)/org/users/actions";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
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
import { Separator } from "@/components/ui/separator";
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

/**
 * IM 账号绑定字段（im/006）：三家多槽位展示，当前启用厂商高亮；
 * 写入走 im_admin_set_userid / im_unbind（admin，写 audit），不直接改表。
 */
const IM_BINDING_FIELDS = [
  { provider: "feishu", key: "feishu_userid", label: "飞书 userid" },
  { provider: "wecom", key: "wecom_userid", label: "企业微信 userid" },
  { provider: "dingtalk", key: "dingtalk_userid", label: "钉钉 userid" },
] as const;

const IM_PROVIDER_LABELS: Record<string, string> = {
  feishu: "飞书",
  wecom: "企业微信",
  dingtalk: "钉钉",
};

type ImBindingProvider = (typeof IM_BINDING_FIELDS)[number]["provider"];
type ImForm = Record<ImBindingProvider, string>;

const EMPTY_IM_FORM: ImForm = { feishu: "", wecom: "", dingtalk: "" };

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
  const [departmentFilter, setDepartmentFilter] = React.useState(ALL);
  const [page, setPage] = React.useState(1);
  const [editing, setEditing] = React.useState<Profile | null>(null);
  const [form, setForm] = React.useState<EditForm>(EMPTY_FORM);
  const [imForm, setImForm] = React.useState<ImForm>(EMPTY_IM_FORM);
  const [imSaving, setImSaving] = React.useState(false);
  const [imClearing, setImClearing] = React.useState<string | null>(null);
  const [enabledProvider, setEnabledProvider] = React.useState<string | null>(
    null,
  );
  const [saving, setSaving] = React.useState(false);
  const [departments, setDepartments] = React.useState<DepartmentOption[]>([]);
  const [positions, setPositions] = React.useState<PositionOption[]>([]);

  const load = React.useCallback(async () => {
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const [profileRes, departmentRes, positionRes, providerRes] =
      await Promise.all([
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
        // 当前启用厂商（im/006）：编辑抽屉据此高亮对应 userid 字段
        supabase.rpc("im_get_enabled_provider"),
      ]);

    if (!providerRes.error) {
      setEnabledProvider(providerRes.data ?? null);
    }

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
      if (departmentFilter !== ALL && row.department_id !== departmentFilter) {
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
  }, [rows, search, roleFilter, statusFilter, departmentFilter]);

  React.useEffect(() => {
    setPage(1);
  }, [search, roleFilter, statusFilter, departmentFilter]);

  const pageCount = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const currentPage = Math.min(page, pageCount);
  const hasActiveFilters =
    search.trim() !== "" ||
    roleFilter !== ALL ||
    statusFilter !== ALL ||
    departmentFilter !== ALL;
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
    setImForm({
      feishu: row.feishu_userid ?? "",
      wecom: row.wecom_userid ?? "",
      dingtalk: row.dingtalk_userid ?? "",
    });
  };

  const closeEdit = () => {
    setEditing(null);
    setForm(EMPTY_FORM);
    setImForm(EMPTY_IM_FORM);
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

  /** 工具栏部门筛选：仅 active 部门，按层级缩进（与编辑下拉口径一致） */
  const departmentFilterOptions = React.useMemo(
    () =>
      departments
        .filter((item) => item.status === "active")
        .map((item) => ({
          id: item.id,
          label: `${"\u3000".repeat(Math.max(0, item.depth - 1))}${item.name}`,
        })),
    [departments],
  );

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

    const statusChanged = form.status !== editing.status;

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

    // Auth 层 ban/unban 先于档案状态：
    // 停用 = banUser → status='inactive'；启用 = unbanUser → status='active'。
    // 前端守卫不可信，action 内会以当前会话二次校验调用者为 admin。
    if (statusChanged) {
      const banResult =
        form.status === "inactive"
          ? await banUser(editing.id)
          : await unbanUser(editing.id);
      if (!banResult.ok) {
        setSaving(false);
        toast.error(banResult.message);
        return;
      }
    }

    // admin_update_profile 负责姓名/部门/岗位/状态（角色已收窄，不再传 p_role）；
    // org/009：部门/岗位走 id 参数（触发器回写部门文本），仅在变更时传参；
    // 批次 3：选中「未指定」时传对应 clear 参数显式清空（触发器 null→null 回写文本）
    const departmentChanged =
      form.departmentId !== (editing.department_id ?? NONE);
    const positionChanged = form.positionId !== (editing.position_id ?? NONE);
    const { error: saveError } = await supabase.rpc("admin_update_profile", {
      p_user_id: editing.id,
      p_full_name: form.full_name.trim() || undefined,
      p_status: form.status,
      ...(departmentChanged
        ? form.departmentId === NONE
          ? { p_clear_department: true }
          : { p_department_id: form.departmentId }
        : {}),
      ...(positionChanged
        ? form.positionId === NONE
          ? { p_clear_position: true }
          : { p_position_id: form.positionId }
        : {}),
    });
    setSaving(false);

    if (saveError) {
      const message = translateUserErrorMessage(saveError.message);
      if (!statusChanged) {
        toast.error(message);
      } else {
        // 档案写入失败 → 回滚 Auth 层 ban/unban，避免“档案状态与登录封禁”不一致
        const rollback =
          form.status === "inactive"
            ? await unbanUser(editing.id)
            : await banUser(editing.id);
        toast.error(
          rollback.ok
            ? `${message}（已恢复该账号原登录状态）`
            : `${message}；登录状态回滚失败，请手动检查该账号`,
        );
      }
      void load();
      return;
    }

    toast.success(
      statusChanged && form.status === "inactive"
        ? "已停用，该账号已无法登录"
        : "已保存",
    );
    closeEdit();
    void load();
  };

  const isSelf = editing?.id === currentUserId;

  // ---------------------------------------------------------------------------
  // IM 账号绑定（im/006）：admin 手工录入 / 清空，走 im_admin_set_userid / im_unbind
  // ---------------------------------------------------------------------------
  const imDirty = React.useMemo(() => {
    if (!editing) {
      return false;
    }
    return IM_BINDING_FIELDS.some(
      (field) =>
        (imForm[field.provider] ?? "").trim() !== (editing[field.key] ?? ""),
    );
  }, [editing, imForm]);

  const handleSaveImBindings = async () => {
    if (!editing) {
      return;
    }
    const changes = IM_BINDING_FIELDS.filter(
      (field) =>
        (imForm[field.provider] ?? "").trim() !== (editing[field.key] ?? ""),
    );
    if (changes.length === 0) {
      toast.info("IM 绑定没有变更");
      return;
    }

    setImSaving(true);
    const supabase = createClient();
    for (const field of changes) {
      const value = (imForm[field.provider] ?? "").trim();
      const { error } =
        value === ""
          ? await supabase.rpc("im_unbind", {
              p_user_id: editing.id,
              p_provider: field.provider,
            })
          : await supabase.rpc("im_admin_set_userid", {
              p_user_id: editing.id,
              p_provider: field.provider,
              p_userid: value,
            });
      if (error) {
        setImSaving(false);
        toast.error(
          `${value === "" ? "清空" : "保存"}「${field.label}」失败：${translateUserErrorMessage(error.message)}`,
        );
        return;
      }
    }
    setImSaving(false);
    toast.success("IM 绑定已保存");
    setEditing((prev) => {
      if (!prev) {
        return prev;
      }
      const next = { ...prev };
      for (const field of changes) {
        next[field.key] = (imForm[field.provider] ?? "").trim() || null;
      }
      return next;
    });
    void load();
  };

  const handleClearImBinding = async (
    field: (typeof IM_BINDING_FIELDS)[number],
  ) => {
    if (!editing) {
      return;
    }
    const confirmed = window.confirm(
      `清空「${field.label}」绑定？该用户将无法用${
        IM_PROVIDER_LABELS[field.provider] ?? field.provider
      }扫码登录。`,
    );
    if (!confirmed) {
      return;
    }

    setImClearing(field.provider);
    const supabase = createClient();
    const { error } = await supabase.rpc("im_unbind", {
      p_user_id: editing.id,
      p_provider: field.provider,
    });
    setImClearing(null);
    if (error) {
      toast.error(
        `清空「${field.label}」失败：${translateUserErrorMessage(error.message)}`,
      );
      return;
    }
    toast.success(`已清空「${field.label}」绑定`);
    setImForm((prev) => ({ ...prev, [field.provider]: "" }));
    setEditing((prev) =>
      prev ? { ...prev, [field.key]: null } : prev,
    );
    void load();
  };

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
                placeholder="搜索姓名 / 邮箱"
                className="h-11 pl-8 text-base lg:h-8 lg:text-sm"
                aria-label="搜索姓名或邮箱"
              />
            </div>
            <Select value={roleFilter} onValueChange={setRoleFilter}>
              <SelectTrigger
                className="w-full sm:w-36 min-h-11 lg:min-h-8"
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
                className="w-full sm:w-32 min-h-11 lg:min-h-8"
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
            <Select value={departmentFilter} onValueChange={setDepartmentFilter}>
              <SelectTrigger
                className="w-full sm:w-40 min-h-11 lg:min-h-8"
                aria-label="按部门筛选"
              >
                <SelectValue placeholder="全部部门" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL}>全部部门</SelectItem>
                {departmentFilterOptions.map((option) => (
                  <SelectItem key={option.id} value={option.id}>
                    {option.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
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
                      setDepartmentFilter(ALL);
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
                  className="flex w-full flex-col gap-2 rounded-xl border bg-card p-3 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                >
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <div className="truncate font-medium">
                        {row.full_name ?? row.email ?? "-"}
                      </div>
                      <div className="truncate text-xs leading-tight text-muted-foreground">
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
                      role="button"
                      tabIndex={0}
                      aria-label={`编辑用户 ${row.full_name ?? row.email ?? "-"}`}
                      onClick={() => openEdit(row)}
                      onKeyDown={(event) => {
                        if (event.key === "Enter" || event.key === " ") {
                          event.preventDefault();
                          openEdit(row);
                        }
                      }}
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
          className="w-full sm:max-w-[480px]"
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
                  <SelectItem value={NONE}>未指定</SelectItem>
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
                  <SelectItem value={NONE}>未指定</SelectItem>
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

            <Separator />

            <div className="flex flex-col gap-3">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <h3 className="text-sm font-medium">IM 账号绑定</h3>
                {enabledProvider ? (
                  <Badge
                    variant="outline"
                    className="border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300"
                  >
                    当前启用：
                    {IM_PROVIDER_LABELS[enabledProvider] ?? enabledProvider}
                  </Badge>
                ) : (
                  <span className="text-xs text-muted-foreground">
                    当前未启用任何厂商
                  </span>
                )}
              </div>
              <p className="text-xs text-muted-foreground">
                录入厂商 userid
                后用户可扫码 / 免登进入系统；切换厂商不清空绑定，高亮为当前启用厂商。
              </p>
              {IM_BINDING_FIELDS.map((field) => {
                const bound = editing?.[field.key] ?? null;
                const active = enabledProvider === field.provider;
                return (
                  <Field
                    key={field.provider}
                    className={
                      active
                        ? "gap-2 rounded-lg border border-primary/40 bg-primary/5 p-3"
                        : "gap-2 rounded-lg border p-3 opacity-70"
                    }
                  >
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <FieldLabel htmlFor={`im-binding-${field.provider}`}>
                        {field.label}
                      </FieldLabel>
                      <div className="flex items-center gap-1.5">
                        {bound ? (
                          <Badge
                            variant="outline"
                            className="border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-900/60 dark:bg-blue-950/60 dark:text-blue-300"
                          >
                            已绑定
                          </Badge>
                        ) : (
                          <span className="text-xs text-muted-foreground">
                            未绑定
                          </span>
                        )}
                        {bound ? (
                          <Button
                            type="button"
                            variant="ghost"
                            size="sm"
                            className="h-11 lg:h-8"
                            disabled={imSaving || imClearing === field.provider}
                            onClick={() => void handleClearImBinding(field)}
                          >
                            {imClearing === field.provider ? (
                              <Loader2Icon
                                className="size-3.5 animate-spin"
                                data-icon="inline-start"
                              />
                            ) : null}
                            清空
                          </Button>
                        ) : null}
                      </div>
                    </div>
                    <Input
                      id={`im-binding-${field.provider}`}
                      value={imForm[field.provider]}
                      placeholder={bound ?? "未绑定"}
                      className="font-mono"
                      onChange={(event) =>
                        setImForm((prev) => ({
                          ...prev,
                          [field.provider]: event.target.value,
                        }))
                      }
                    />
                  </Field>
                );
              })}
              <div className="flex items-center justify-end gap-2">
                <span className="mr-auto text-xs text-muted-foreground">
                  留空后保存 = 清空该厂商绑定；解绑仅管理员可操作。
                </span>
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  className="h-11 lg:h-8"
                  disabled={imSaving || !imDirty}
                  onClick={() => void handleSaveImBindings()}
                >
                  {imSaving ? (
                    <Loader2Icon
                      className="size-3.5 animate-spin"
                      data-icon="inline-start"
                    />
                  ) : (
                    <SaveIcon
                      className="size-3.5"
                      data-icon="inline-start"
                    />
                  )}
                  保存绑定
                </Button>
              </div>
            </div>
          </div>
          <SheetFooter className="flex-row justify-end gap-2">
            <Button
              variant="outline"
              onClick={closeEdit}
              className="h-8"
            >
              取消
            </Button>
            <Button
              onClick={() => void handleSave()}
              disabled={saving}
              className="h-8"
            >
              {saving ? (
                <Loader2Icon
                  className="size-3.5 animate-spin"
                  data-icon="inline-start"
                />
              ) : (
                <SaveIcon className="size-3.5" data-icon="inline-start" />
              )}
              保存
            </Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>
    </div>
  );
}
