"use client";

// 数据权限配置（access/010）
//
// 拓扑与规则：
//   - 数据源：角色名录 roles_v + role_data_scopes（范围事实源）；
//   - 行 = 角色，行内 Select 选择四档范围（self/dept/dept_tree/all），
//     保存调 upsert_data_scope RPC；「all」仅 admin 角色可选，其余行禁用并提示；
//   - 角色无 scope 行显示「未配置」：helper 按 fail-closed 返回空集，保存后即时生效；
//   - 预检：选人调 preview_scope（admin 专用），按真实会话语义展示角色/范围/可见统计；
//   - 移动端同构：单列卡片（角色信息 + Select + 保存），预检区同样单列。

import * as React from "react";
import {
  EyeIcon,
  Loader2Icon,
  RefreshCwIcon,
  SaveIcon,
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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
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
import {
  DATA_SCOPE_BADGE_CLASSES,
  DATA_SCOPE_LABELS,
  DATA_SCOPE_OPTIONS,
  FALLBACK_BADGE_CLASS,
  ROLE_KIND_BADGE_CLASSES,
  ROLE_STATUS_BADGE_CLASSES,
  translateDataScopeErrorMessage,
  type DataScope,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type RoleStatus = "active" | "disabled";

type RoleInfo = {
  id: string;
  name: string;
  code: string;
  isBuiltin: boolean;
  status: RoleStatus;
};

type ScopeState = Record<string, DataScope | null>;

type PreviewUser = {
  id: string;
  name: string;
  status: "active" | "inactive";
  department: string | null;
};

type PreviewResult = {
  user_id: string;
  user_name: string | null;
  user_status: "active" | "inactive";
  role_code: string | null;
  role_name: string | null;
  department_id: string | null;
  department_name: string | null;
  scope: DataScope | null;
  user_count: number;
  dept_count: number;
};

const asRoleStatus = (value: string | null): RoleStatus =>
  value === "disabled" ? "disabled" : "active";

const asDataScope = (value: string | null | undefined): DataScope | null => {
  if (
    value === "self" ||
    value === "dept" ||
    value === "dept_tree" ||
    value === "all"
  ) {
    return value;
  }
  return null;
};

const formatDateTime = (value: string | null) =>
  value ? new Date(value).toLocaleString("zh-CN", { hour12: false }) : "—";

const sortRoles = (list: RoleInfo[]) =>
  [...list].sort((a, b) => {
    if (a.isBuiltin !== b.isBuiltin) {
      return a.isBuiltin ? -1 : 1;
    }
    return a.name.localeCompare(b.name, "zh-CN");
  });

export function DataScopesTable() {
  const isMobile = useIsMobile();
  const [roles, setRoles] = React.useState<RoleInfo[]>([]);
  const [scopes, setScopes] = React.useState<ScopeState>({});
  const [savedScopes, setSavedScopes] = React.useState<ScopeState>({});
  const [updatedAt, setUpdatedAt] = React.useState<Record<string, string>>({});
  const [users, setUsers] = React.useState<PreviewUser[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [savingRoleId, setSavingRoleId] = React.useState<string | null>(null);

  const [previewUserId, setPreviewUserId] = React.useState("");
  const [preview, setPreview] = React.useState<PreviewResult | null>(null);
  const [previewLoading, setPreviewLoading] = React.useState(false);
  const [previewError, setPreviewError] = React.useState<string | null>(null);

  const load = React.useCallback(async () => {
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const [roleResult, scopeResult, userResult] = await Promise.all([
      supabase.from("roles_v").select("*"),
      supabase
        .from("role_data_scopes")
        .select("role_id, scope, updated_at"),
      supabase
        .from("profiles")
        .select("id, full_name, email, status, department")
        .order("full_name"),
    ]);

    const loadError =
      roleResult.error ?? scopeResult.error ?? userResult.error;
    if (loadError) {
      setError(loadError.message);
      setRoles([]);
      setScopes({});
      setSavedScopes({});
      setUpdatedAt({});
      setUsers([]);
      setLoading(false);
      return;
    }

    const nextRoles = sortRoles(
      (roleResult.data ?? [])
        .filter((row) => row.id && row.code && row.name)
        .map(
          (row): RoleInfo => ({
            id: row.id ?? "",
            name: row.name ?? "",
            code: row.code ?? "",
            isBuiltin: row.is_builtin ?? false,
            status: asRoleStatus(row.status),
          }),
        ),
    );

    const nextScopes: ScopeState = {};
    const nextUpdatedAt: Record<string, string> = {};
    for (const row of scopeResult.data ?? []) {
      nextScopes[row.role_id] = asDataScope(row.scope);
      if (row.updated_at) {
        nextUpdatedAt[row.role_id] = row.updated_at;
      }
    }

    setRoles(nextRoles);
    setScopes({ ...nextScopes });
    setSavedScopes({ ...nextScopes });
    setUpdatedAt(nextUpdatedAt);
    setUsers(
      (userResult.data ?? []).map(
        (row): PreviewUser => ({
          id: row.id ?? "",
          name: row.full_name ?? row.email?.split("@")[0] ?? row.id ?? "",
          status: row.status === "inactive" ? "inactive" : "active",
          department: row.department,
        }),
      ),
    );
    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const runPreview = React.useCallback(async (userId: string) => {
    if (!userId) {
      setPreview(null);
      setPreviewError(null);
      return;
    }
    setPreviewLoading(true);
    setPreviewError(null);
    const supabase = createClient();
    const { data, error: previewRpcError } = await supabase.rpc(
      "preview_scope",
      { p_user_id: userId },
    );
    setPreviewLoading(false);

    if (previewRpcError) {
      setPreview(null);
      setPreviewError(previewRpcError.message);
      return;
    }
    setPreview(data as unknown as PreviewResult);
  }, []);

  // 预检随选人变化即时刷新
  React.useEffect(() => {
    void runPreview(previewUserId);
  }, [previewUserId, runPreview]);

  const setScope = (roleId: string, value: string) => {
    const scope = asDataScope(value);
    if (!scope) {
      return;
    }
    setScopes((prev) => ({ ...prev, [roleId]: scope }));
  };

  const isDirty = (role: RoleInfo) =>
    scopes[role.id] !== savedScopes[role.id];

  const handleSave = async (role: RoleInfo) => {
    const scope = scopes[role.id];
    if (!scope) {
      toast.error("请先选择数据范围");
      return;
    }

    setSavingRoleId(role.id);
    const supabase = createClient();
    const { data, error: saveError } = await supabase.rpc(
      "upsert_data_scope",
      { p_role_id: role.id, p_scope: scope },
    );
    setSavingRoleId(null);

    if (saveError) {
      toast.error(translateDataScopeErrorMessage(saveError.message));
      // 失败以数据库实际状态为准（可能被并发改过）
      void load();
      return;
    }

    const saved = asDataScope(
      (data as { scope?: string | null } | null)?.scope ?? scope,
    );
    setScopes((prev) => ({ ...prev, [role.id]: saved }));
    setSavedScopes((prev) => ({ ...prev, [role.id]: saved }));
    setUpdatedAt((prev) => ({
      ...prev,
      [role.id]:
        (data as { updated_at?: string | null } | null)?.updated_at ??
        new Date().toISOString(),
    }));
    toast.success(
      `已保存：${role.name} → ${saved ? DATA_SCOPE_LABELS[saved] : "未配置"}`,
    );
    if (previewUserId) {
      void runPreview(previewUserId);
    }
  };

  const renderScopeSelect = (role: RoleInfo, idPrefix: string) => {
    const current = scopes[role.id] ?? null;
    const lockedAdminOption = role.code !== "admin";
    return (
      <Select
        value={current ?? ""}
        onValueChange={(value) => setScope(role.id, value)}
        disabled={savingRoleId !== null}
      >
        <SelectTrigger
          id={`${idPrefix}-${role.id}`}
          className="w-full min-w-40 min-h-11 lg:min-h-8"
          aria-label={`${role.name} 的数据范围`}
        >
          <SelectValue placeholder="未配置（当前不可见任何数据）" />
        </SelectTrigger>
        <SelectContent>
          {DATA_SCOPE_OPTIONS.map((option) => (
            <SelectItem
              key={option.value}
              value={option.value}
              disabled={option.value === "all" && lockedAdminOption}
              title={
                option.value === "all" && lockedAdminOption
                  ? "仅系统管理员角色可配置「全部」"
                  : undefined
              }
            >
              {option.label}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    );
  };

  const renderSaveButton = (role: RoleInfo, className?: string) => (
    <Button
      className={className}
      size={isMobile ? "default" : "sm"}
      variant="outline"
      disabled={!isDirty(role) || savingRoleId !== null}
      onClick={() => void handleSave(role)}
    >
      {savingRoleId === role.id ? (
        <Loader2Icon className="animate-spin" data-icon="inline-start" />
      ) : (
        <SaveIcon data-icon="inline-start" />
      )}
      保存
    </Button>
  );

  const scopeBadge = (scope: DataScope | null) => {
    if (!scope) {
      return (
        <Badge variant="outline" className={FALLBACK_BADGE_CLASS}>
          未配置 · 空集
        </Badge>
      );
    }
    return (
      <Badge variant="outline" className={DATA_SCOPE_BADGE_CLASSES[scope]}>
        {DATA_SCOPE_LABELS[scope]}
      </Badge>
    );
  };

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardHeader>
          <CardTitle>数据权限</CardTitle>
          <CardDescription>
            为每个角色配置可见数据范围：仅本人 / 本部门 / 本部门及以下 /
            全部。「全部」仅系统管理员角色可配置；未配置的角色按空集处理（看不到任何数据）。
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          {loading ? (
            <div className="flex flex-col gap-2">
              {Array.from({ length: 5 }).map((_, index) => (
                <Skeleton key={index} className="h-12 w-full" />
              ))}
            </div>
          ) : error ? (
            <div className="flex flex-col items-center gap-2 py-8 text-sm">
              <p className="text-destructive">
                加载失败：{translateDataScopeErrorMessage(error)}
              </p>
              <Button variant="outline" onClick={() => void load()}>
                重试
              </Button>
            </div>
          ) : roles.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <ShieldCheckIcon className="size-8 opacity-60" />
              <span>暂无角色，请先在「角色管理」创建</span>
            </div>
          ) : isMobile ? (
            <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
              {roles.map((role) => (
                <div
                  key={role.id}
                  className="flex w-full flex-col gap-3 rounded-xl border bg-card p-4 shadow-xs"
                >
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <div className="flex items-center gap-1.5">
                        <span className="truncate font-medium">{role.name}</span>
                        <Badge
                          variant="outline"
                          className={ROLE_KIND_BADGE_CLASSES[
                            role.isBuiltin ? "builtin" : "custom"
                          ]}
                        >
                          {role.isBuiltin ? "内置" : "自定义"}
                        </Badge>
                      </div>
                      <div className="truncate font-mono text-xs text-muted-foreground">
                        {role.code}
                      </div>
                    </div>
                    <Badge
                      variant="outline"
                      className={ROLE_STATUS_BADGE_CLASSES[role.status]}
                    >
                      {role.status === "active" ? "启用" : "停用"}
                    </Badge>
                  </div>
                  <div className="flex flex-col gap-1.5">
                    <span className="text-xs text-muted-foreground">
                      数据范围
                    </span>
                    {renderScopeSelect(role, "scope-mobile")}
                    {role.code !== "admin" ? (
                      <span className="text-[11px] text-muted-foreground">
                        「全部」仅系统管理员角色可配置
                      </span>
                    ) : null}
                  </div>
                  <div className="flex items-center justify-between gap-3">
                    <span className="text-[11px] text-muted-foreground">
                      更新于 {formatDateTime(updatedAt[role.id] ?? null)}
                    </span>
                    {renderSaveButton(role, "h-11")}
                  </div>
                </div>
              ))}
            </div>
          ) : (
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="text-center">角色</TableHead>
                    <TableHead className="text-center">类型</TableHead>
                    <TableHead className="text-center">状态</TableHead>
                    <TableHead className="w-[260px] text-center">
                      数据范围
                    </TableHead>
                    <TableHead className="text-center">最近更新</TableHead>
                    <TableHead className="text-center">操作</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {roles.map((role) => (
                    <TableRow key={role.id}>
                      <TableCell className="text-center">
                        <div className="flex flex-col">
                          <span className="font-medium">{role.name}</span>
                          <span className="font-mono text-xs text-muted-foreground">
                            {role.code}
                          </span>
                        </div>
                      </TableCell>
                      <TableCell className="text-center">
                        <Badge
                          variant="outline"
                          className={ROLE_KIND_BADGE_CLASSES[
                            role.isBuiltin ? "builtin" : "custom"
                          ]}
                        >
                          {role.isBuiltin ? "内置" : "自定义"}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-center">
                        <Badge
                          variant="outline"
                          className={ROLE_STATUS_BADGE_CLASSES[role.status]}
                        >
                          {role.status === "active" ? "启用" : "停用"}
                        </Badge>
                      </TableCell>
                      <TableCell>
                        <div className="flex flex-col items-center gap-1">
                          {renderScopeSelect(role, "scope")}
                          {role.code !== "admin" ? (
                            <span className="text-[11px] text-muted-foreground">
                              「全部」仅系统管理员角色可配置
                            </span>
                          ) : null}
                        </div>
                      </TableCell>
                      <TableCell className="text-center text-xs text-muted-foreground">
                        {formatDateTime(updatedAt[role.id] ?? null)}
                      </TableCell>
                      <TableCell className="text-center">
                        {renderSaveButton(role)}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </CardContent>
      </Card>

      <Card className="rounded-none border-0 md:rounded-xl md:border">
        <CardHeader>
          <CardTitle>以用户视角预检</CardTitle>
          <CardDescription>
            选择用户后按真实会话语义（角色数据范围）计算可见范围统计，用于切换范围前的影响评估。
            账号停用或角色未配置时可见范围为空集。
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
            <Select
              value={previewUserId}
              onValueChange={setPreviewUserId}
              disabled={loading || users.length === 0}
            >
              <SelectTrigger
                className="w-full text-base sm:max-w-sm min-h-11 lg:min-h-8 lg:text-sm"
                aria-label="选择要预检的用户"
              >
                <SelectValue placeholder="选择用户（按姓名排序）" />
              </SelectTrigger>
              <SelectContent>
                {users.map((user) => (
                  <SelectItem key={user.id} value={user.id}>
                    {user.name}
                    {user.department ? `（${user.department}）` : ""}
                    {user.status === "inactive" ? " · 停用" : ""}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Button
              variant="outline"
              size="icon"
              className="h-11 w-11 lg:h-8 lg:w-8"
              disabled={!previewUserId || previewLoading}
              onClick={() => void runPreview(previewUserId)}
              aria-label="重新预检"
            >
              <RefreshCwIcon
                className={previewLoading ? "animate-spin" : undefined}
              />
            </Button>
          </div>

          {previewLoading ? (
            <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
              {Array.from({ length: 4 }).map((_, index) => (
                <Skeleton key={index} className="h-20 w-full" />
              ))}
            </div>
          ) : previewError ? (
            <p className="text-sm text-destructive">
              预检失败：{translateDataScopeErrorMessage(previewError)}
            </p>
          ) : !preview ? (
            <div className="flex flex-col items-center gap-2 py-8 text-sm text-muted-foreground">
              <EyeIcon className="size-8 opacity-60" />
              <span>选择用户后展示其可见范围</span>
            </div>
          ) : (
            <div className="flex flex-col gap-3">
              <div className="flex flex-wrap items-center gap-2">
                <span className="font-medium">
                  {preview.user_name ?? preview.user_id}
                </span>
                <Badge
                  variant="outline"
                  className={
                    preview.user_status === "active"
                      ? ROLE_STATUS_BADGE_CLASSES.active
                      : ROLE_STATUS_BADGE_CLASSES.disabled
                  }
                >
                  {preview.user_status === "active" ? "启用" : "停用"}
                </Badge>
                <span className="text-sm text-muted-foreground">
                  {preview.role_name ?? "未知角色"}
                  {preview.role_code ? ` · ${preview.role_code}` : ""}
                </span>
              </div>
              <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
                <div className="flex flex-col gap-1 rounded-lg border bg-card p-3">
                  <span className="text-xs text-muted-foreground">
                    数据范围
                  </span>
                  {scopeBadge(preview.scope)}
                </div>
                <div className="flex flex-col gap-1 rounded-lg border bg-card p-3">
                  <span className="text-xs text-muted-foreground">
                    所属部门
                  </span>
                  <span className="text-sm">
                    {preview.department_name ?? "未设置"}
                  </span>
                </div>
                <div className="flex flex-col gap-1 rounded-lg border bg-card p-3">
                  <span className="text-xs text-muted-foreground">
                    可见用户数
                  </span>
                  <span className="text-xl font-semibold tabular-nums">
                    {preview.user_count}
                  </span>
                </div>
                <div className="flex flex-col gap-1 rounded-lg border bg-card p-3">
                  <span className="text-xs text-muted-foreground">
                    可见部门数
                  </span>
                  <span className="text-xl font-semibold tabular-nums">
                    {preview.dept_count}
                  </span>
                </div>
              </div>
              {preview.scope === null ? (
                <p className="text-xs text-amber-600 dark:text-amber-400">
                  该账号停用或角色未配置数据范围，按 fail-closed
                  处理为可见空集；停用账号重新启用后按角色配置生效。
                </p>
              ) : null}
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
