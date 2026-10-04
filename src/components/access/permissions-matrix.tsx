"use client";

// 菜单权限矩阵（access/007）
//
// 拓扑与规则：
//   - 数据源：menu_items 注册表（顶级 = 分组列头，子菜单 = 缩进列）+ role_menu_grants
//     （勾选事实源）；admin 行固定全权锁定（数据层 visible_menus 对 admin 不读授权表）；
//   - 桌面：宽矩阵，行头 sticky left 冻结；组级「全选/清空」按列作用于全部可编辑角色；
//   - 移动：按角色逐个配置（角色 Select → 菜单树 checkbox → 保存）；
//   - 保存：对比初始态计算 diff，逐条调 grant_menu/revoke_menu（限流并发），
//     全部成功 toast.success；部分失败列出失败项，并把失败项保留为未保存变更以便重试；
//   - 预览：本页不调用 visible_menus —— 该 RPC 无参数、只反映「当前登录用户」的可见菜单，
//     无法预览任意角色；改为前端用 role_menu_grants 复刻其规则：admin 全量；零授权
//     fail-open 全量（并标注）；其余按授权 + 祖先链补全。

import * as React from "react";
import {
  EyeIcon,
  KeyRoundIcon,
  Loader2Icon,
  RotateCcwIcon,
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
import { Checkbox } from "@/components/ui/checkbox";
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
import type { Database } from "@/lib/database.types";
import {
  FALLBACK_BADGE_CLASS,
  PENDING_BADGE_CLASS,
  ROLE_BADGE_CLASSES,
  ROLE_KIND_BADGE_CLASSES,
  ROLE_STATUS_BADGE_CLASSES,
  translatePermissionErrorMessage,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type MenuItem = Database["public"]["Tables"]["menu_items"]["Row"];

type RoleInfo = {
  id: string;
  name: string;
  code: string;
  isBuiltin: boolean;
  status: "active" | "disabled";
};

type MenuGroup = {
  parent: MenuItem;
  children: MenuItem[];
};

/** 角色 id → 已勾选菜单 key 集 */
type GrantState = Record<string, Set<string>>;

type SaveOp = {
  kind: "grant" | "revoke";
  roleId: string;
  roleName: string;
  menuKey: string;
  menuLabel: string;
};

type SaveFailure = SaveOp & { message: string };

const EMPTY_KEYS: ReadonlySet<string> = new Set();

function compareBySortOrder(a: MenuItem, b: MenuItem) {
  if (a.sort_order !== b.sort_order) {
    return a.sort_order - b.sort_order;
  }
  return a.key.localeCompare(b.key);
}

function buildIndex(items: MenuItem[]) {
  const menuByKey = new Map<string, MenuItem>();
  const childrenMap = new Map<string, MenuItem[]>();

  for (const item of items) {
    menuByKey.set(item.key, item);
    if (item.parent_key === null) {
      continue;
    }
    const list = childrenMap.get(item.parent_key);
    if (list) {
      list.push(item);
    } else {
      childrenMap.set(item.parent_key, [item]);
    }
  }

  const parents = items
    .filter((item) => item.parent_key === null)
    .sort(compareBySortOrder);

  const groups: MenuGroup[] = [];
  for (const parent of parents) {
    const children = (childrenMap.get(parent.key) ?? []).sort(
      compareBySortOrder,
    );
    // 无子菜单的顶级项没有可配置列，不渲染（当前 seed 的 10 个顶级均有子项）
    if (children.length > 0) {
      groups.push({ parent, children });
    }
  }

  return { groups, menuByKey };
}

function setsEqual(a: ReadonlySet<string>, b: ReadonlySet<string>) {
  if (a.size !== b.size) {
    return false;
  }
  for (const key of a) {
    if (!b.has(key)) {
      return false;
    }
  }
  return true;
}

function cloneGrantState(state: GrantState): GrantState {
  const next: GrantState = {};
  for (const [roleId, keys] of Object.entries(state)) {
    next[roleId] = new Set(keys);
  }
  return next;
}

/** 把保存失败的操作重新叠加到草稿上，保留用户未落库的勾选，便于重试 */
function reapplyOps(state: GrantState, ops: SaveOp[]): GrantState {
  const next = cloneGrantState(state);
  for (const op of ops) {
    const set = next[op.roleId] ?? new Set<string>();
    if (op.kind === "grant") {
      set.add(op.menuKey);
    } else {
      set.delete(op.menuKey);
    }
    next[op.roleId] = set;
  }
  return next;
}

function roleStatusOf(value: string | null): "active" | "disabled" {
  return value === "disabled" ? "disabled" : "active";
}

/**
 * 复刻 visible_menus 的可见性计算（见 supabase/migrations/20261004110000_access_visible_menus.sql）：
 *   - admin：全量，fallback = false；
 *   - 零授权：fail-open 全量，fallback = true（过渡期语义）；
 *   - 其余：授权集 + 祖先链补全（保证父级目录带出，且不连带未授权兄弟）。
 * 说明：本页不调用 visible_menus，因为该 RPC 无参数、固定返回当前登录用户的菜单，
 * 无法用于「按角色预览」；这里以 role_menu_grants 为准在前端计算。
 */
function computePreviewKeys(
  role: RoleInfo,
  granted: ReadonlySet<string>,
  allKeys: Set<string>,
  menuByKey: Map<string, MenuItem>,
): { keys: Set<string>; fallback: boolean; full: boolean } {
  if (role.code === "admin") {
    return { keys: allKeys, fallback: false, full: true };
  }
  if (granted.size === 0) {
    return { keys: allKeys, fallback: true, full: false };
  }
  const keys = new Set<string>();
  const stack = [...granted];
  while (stack.length > 0) {
    const current = stack.pop();
    if (current === undefined || keys.has(current)) {
      continue;
    }
    keys.add(current);
    const parentKey = menuByKey.get(current)?.parent_key;
    if (parentKey) {
      stack.push(parentKey);
    }
  }
  return { keys, fallback: false, full: false };
}

export function PermissionsMatrix() {
  const isMobile = useIsMobile();
  const [menuItems, setMenuItems] = React.useState<MenuItem[]>([]);
  const [roles, setRoles] = React.useState<RoleInfo[]>([]);
  const [grants, setGrants] = React.useState<GrantState>({});
  const [savedGrants, setSavedGrants] = React.useState<GrantState>({});
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [saving, setSaving] = React.useState(false);
  const [mobileRoleId, setMobileRoleId] = React.useState("");
  const [previewRoleId, setPreviewRoleId] = React.useState("");

  /** 拉取原始数据；失败返回 null 并写入 error */
  const fetchData = React.useCallback(async () => {
    const supabase = createClient();
    const [menuResult, roleResult, grantResult] = await Promise.all([
      supabase.from("menu_items").select("*").order("sort_order").order("key"),
      supabase.from("roles_v").select("*"),
      supabase.from("role_menu_grants").select("role_id, menu_key"),
    ]);

    const loadError =
      menuResult.error ?? roleResult.error ?? grantResult.error;
    if (loadError) {
      setError(loadError.message);
      return null;
    }

    const nextRoles = (roleResult.data ?? [])
      .filter((row) => row.id && row.code && row.name)
      .map(
        (row): RoleInfo => ({
          id: row.id ?? "",
          name: row.name ?? "",
          code: row.code ?? "",
          isBuiltin: row.is_builtin ?? false,
          status: roleStatusOf(row.status),
        }),
      );
    // 内置角色置顶（admin 在内置中仍按名称序），自定义角色随后按中文名排序
    nextRoles.sort((a, b) => {
      if (a.isBuiltin !== b.isBuiltin) {
        return a.isBuiltin ? -1 : 1;
      }
      return a.name.localeCompare(b.name, "zh-CN");
    });

    const nextGrants: GrantState = {};
    for (const row of grantResult.data ?? []) {
      const set = nextGrants[row.role_id];
      if (set) {
        set.add(row.menu_key);
      } else {
        nextGrants[row.role_id] = new Set([row.menu_key]);
      }
    }

    setError(null);
    return {
      menuItems: menuResult.data ?? [],
      roles: nextRoles,
      grants: nextGrants,
    };
  }, []);

  const load = React.useCallback(async () => {
    setLoading(true);
    const data = await fetchData();
    if (data) {
      setMenuItems(data.menuItems);
      setRoles(data.roles);
      setGrants(cloneGrantState(data.grants));
      setSavedGrants(cloneGrantState(data.grants));
    }
    setLoading(false);
  }, [fetchData]);

  React.useEffect(() => {
    void load();
  }, [load]);

  const { groups, menuByKey } = React.useMemo(
    () => buildIndex(menuItems),
    [menuItems],
  );

  /** 注册表全量 key（含顶级目录），用于预览的可见数量分母与 fail-open 全集 */
  const allKeys = React.useMemo(
    () => new Set(menuItems.map((item) => item.key)),
    [menuItems],
  );

  const editableRoles = React.useMemo(
    () => roles.filter((role) => role.code !== "admin"),
    [roles],
  );

  const pendingOps = React.useMemo(() => {
    const ops: SaveOp[] = [];
    for (const role of editableRoles) {
      const initial = savedGrants[role.id] ?? EMPTY_KEYS;
      const draft = grants[role.id] ?? EMPTY_KEYS;
      for (const menuKey of draft) {
        if (!initial.has(menuKey)) {
          ops.push({
            kind: "grant",
            roleId: role.id,
            roleName: role.name,
            menuKey,
            menuLabel: menuByKey.get(menuKey)?.label ?? menuKey,
          });
        }
      }
      for (const menuKey of initial) {
        if (!draft.has(menuKey)) {
          ops.push({
            kind: "revoke",
            roleId: role.id,
            roleName: role.name,
            menuKey,
            menuLabel: menuByKey.get(menuKey)?.label ?? menuKey,
          });
        }
      }
    }
    return ops;
  }, [editableRoles, savedGrants, grants, menuByKey]);

  // 移动端/预览的默认选中角色：优先第一个可编辑角色，避免默认落在锁定的 admin 行
  const activeMobileRole =
    roles.find((role) => role.id === mobileRoleId) ??
    editableRoles[0] ??
    roles[0] ??
    null;
  const activePreviewRole =
    roles.find((role) => role.id === previewRoleId) ??
    editableRoles[0] ??
    roles[0] ??
    null;

  const setItem = React.useCallback(
    (roleId: string, menuKey: string, checked: boolean) => {
      setGrants((prev) => {
        const set = new Set(prev[roleId] ?? []);
        if (checked) {
          set.add(menuKey);
        } else {
          set.delete(menuKey);
        }
        return { ...prev, [roleId]: set };
      });
    },
    [],
  );

  const setKeysForRole = React.useCallback(
    (roleId: string, keys: string[], checked: boolean) => {
      setGrants((prev) => {
        const set = new Set(prev[roleId] ?? []);
        for (const key of keys) {
          if (checked) {
            set.add(key);
          } else {
            set.delete(key);
          }
        }
        return { ...prev, [roleId]: set };
      });
    },
    [],
  );

  /** 桌面组级批量：某一列组对全部可编辑角色 全选/清空 */
  const setGroupForAllRoles = React.useCallback(
    (group: MenuGroup, checked: boolean) => {
      const keys = group.children.map((child) => child.key);
      setGrants((prev) => {
        const next = { ...prev };
        for (const role of editableRoles) {
          const set = new Set(prev[role.id] ?? []);
          for (const key of keys) {
            if (checked) {
              set.add(key);
            } else {
              set.delete(key);
            }
          }
          next[role.id] = set;
        }
        return next;
      });
    },
    [editableRoles],
  );

  const resetDraft = () => {
    setGrants(cloneGrantState(savedGrants));
  };

  const handleSave = async () => {
    if (pendingOps.length === 0 || saving) {
      return;
    }
    setSaving(true);

    const supabase = createClient();
    const ops = pendingOps;
    const failures: SaveFailure[] = [];
    let cursor = 0;
    // 简单并发池：窗口 6，避免一次保存打出数百个请求
    const workerCount = Math.min(6, ops.length);
    await Promise.all(
      Array.from({ length: workerCount }, async () => {
        while (cursor < ops.length) {
          const op = ops[cursor];
          cursor += 1;
          if (!op) {
            break;
          }
          const result =
            op.kind === "grant"
              ? await supabase.rpc("grant_menu", {
                  p_role_id: op.roleId,
                  p_menu_key: op.menuKey,
                })
              : await supabase.rpc("revoke_menu", {
                  p_role_id: op.roleId,
                  p_menu_key: op.menuKey,
                });
          if (result.error) {
            failures.push({ ...op, message: result.error.message });
          }
        }
      }),
    );

    setSaving(false);

    // 无论成败都以数据库实际状态为准刷新；失败项重新叠加为未保存草稿
    const data = await fetchData();
    if (data) {
      setMenuItems(data.menuItems);
      setRoles(data.roles);
      setSavedGrants(cloneGrantState(data.grants));
      setGrants(
        failures.length > 0
          ? reapplyOps(data.grants, failures)
          : cloneGrantState(data.grants),
      );
    }

    if (failures.length === 0) {
      toast.success("授权已保存");
      return;
    }

    const shown = failures
      .slice(0, 8)
      .map(
        (failure) =>
          `${failure.roleName} · ${failure.menuLabel}（${failure.kind === "grant" ? "授权" : "撤权"}）`,
      );
    const more =
      failures.length > shown.length ? `\n…等共 ${failures.length} 项` : "";
    toast.error(`保存未全部成功：${failures.length}/${ops.length} 项失败`, {
      description: (
        <span className="block whitespace-pre-line">
          {`${shown.join("\n")}${more}\n失败项已保留为未保存变更，可重试。\n原因：${translatePermissionErrorMessage(
            failures[0].message,
          )}`}
        </span>
      ),
      duration: 12000,
    });
  };

  const clearAllForRole = React.useCallback(
    (roleId: string) => {
      setGrants((prev) => ({ ...prev, [roleId]: new Set<string>() }));
    },
    [],
  );

  const roleDirty = React.useCallback(
    (roleId: string) =>
      !setsEqual(
        grants[roleId] ?? EMPTY_KEYS,
        savedGrants[roleId] ?? EMPTY_KEYS,
      ),
    [grants, savedGrants],
  );

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          {loading ? (
            <div className="flex flex-col gap-2">
              {Array.from({ length: 7 }).map((_, index) => (
                <Skeleton key={index} className="h-12 w-full" />
              ))}
            </div>
          ) : error ? (
            <div className="flex flex-col items-center gap-2 py-8 text-sm">
              <p className="text-destructive">
                加载失败：{translatePermissionErrorMessage(error)}
              </p>
              <Button variant="outline" onClick={() => void load()}>
                重试
              </Button>
            </div>
          ) : groups.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <KeyRoundIcon className="size-8 opacity-60" />
              <span>菜单注册表为空，暂无可配置的菜单项</span>
            </div>
          ) : isMobile ? (
            <MobileConfig
              roles={roles}
              groups={groups}
              grants={grants}
              saving={saving}
              activeRole={activeMobileRole}
              roleDirty={roleDirty}
              pendingCount={pendingOps.length}
              onRoleChange={setMobileRoleId}
              onToggleItem={setItem}
              onToggleGroup={setKeysForRole}
              onClearRole={clearAllForRole}
              onReset={resetDraft}
              onSave={() => void handleSave()}
            />
          ) : (
            <DesktopMatrix
              roles={roles}
              groups={groups}
              grants={grants}
              saving={saving}
              pendingCount={pendingOps.length}
              roleDirty={roleDirty}
              onToggleItem={setItem}
              onToggleGroupForAllRoles={setGroupForAllRoles}
              onToggleRow={setKeysForRole}
              onReset={resetDraft}
              onSave={() => void handleSave()}
            />
          )}
        </CardContent>
      </Card>

      {!loading && !error && groups.length > 0 ? (
        <PreviewCard
          roles={roles}
          groups={groups}
          grants={grants}
          savedGrants={savedGrants}
          menuByKey={menuByKey}
          allKeys={allKeys}
          activeRole={activePreviewRole}
          onRoleChange={setPreviewRoleId}
        />
      ) : null}
    </div>
  );
}

type DesktopMatrixProps = {
  roles: RoleInfo[];
  groups: MenuGroup[];
  grants: GrantState;
  saving: boolean;
  pendingCount: number;
  roleDirty: (roleId: string) => boolean;
  onToggleItem: (roleId: string, menuKey: string, checked: boolean) => void;
  onToggleGroupForAllRoles: (group: MenuGroup, checked: boolean) => void;
  onToggleRow: (roleId: string, keys: string[], checked: boolean) => void;
  onReset: () => void;
  onSave: () => void;
};

function DesktopMatrix({
  roles,
  groups,
  grants,
  saving,
  pendingCount,
  roleDirty,
  onToggleItem,
  onToggleGroupForAllRoles,
  onToggleRow,
  onReset,
  onSave,
}: DesktopMatrixProps) {
  const columnKeys = React.useMemo(
    () => groups.flatMap((group) => group.children.map((child) => child.key)),
    [groups],
  );
  const hasChanges = pendingCount > 0;

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-col gap-2 xl:flex-row xl:items-center">
        <p className="text-xs text-muted-foreground">
          勾选即授权；父级目录由 visible_menus 的祖先链自动带出。admin
          行固定全权，不可编辑。
        </p>
        <div className="flex flex-wrap items-center gap-2 xl:ml-auto">
          {hasChanges ? (
            <Badge variant="outline" className={PENDING_BADGE_CLASS}>
              {pendingCount} 项未保存
            </Badge>
          ) : null}
          <Button
            variant="outline"
            className="h-8"
            disabled={saving || !hasChanges}
            onClick={onReset}
          >
            <RotateCcwIcon data-icon="inline-start" />
            重置
          </Button>
          <Button
            className="h-8 min-w-28"
            disabled={saving || !hasChanges}
            onClick={onSave}
          >
            {saving ? (
              <Loader2Icon className="size-3.5 animate-spin" data-icon="inline-start" />
            ) : (
              <SaveIcon className="size-3.5" data-icon="inline-start" />
            )}
            保存
          </Button>
        </div>
      </div>

      <div className="overflow-hidden rounded-lg border">
        <Table>
          <TableHeader>
            <TableRow className="hover:bg-transparent">
              <TableHead
                rowSpan={2}
                className="sticky left-0 z-20 h-auto w-[180px] min-w-[180px] border-r bg-card align-bottom"
              >
                <div className="flex flex-col gap-0.5 py-1">
                  <span>角色</span>
                  <span className="text-[11px] font-normal text-muted-foreground">
                    共 {roles.length} 个 · admin 锁定
                  </span>
                </div>
              </TableHead>
              {groups.map((group) => (
                <TableHead
                  key={group.parent.key}
                  colSpan={group.children.length}
                  className="border-l bg-muted/40 px-2 text-center"
                >
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-xs font-semibold">
                      {group.parent.label}
                    </span>
                    <span className="flex items-center gap-0.5">
                      <Button
                        type="button"
                        variant="ghost"
                        size="xs"
                        className="text-[11px] text-muted-foreground"
                        disabled={saving}
                        onClick={() => onToggleGroupForAllRoles(group, true)}
                        aria-label={`${group.parent.label}：全部角色全选`}
                      >
                        全选
                      </Button>
                      <Button
                        type="button"
                        variant="ghost"
                        size="xs"
                        className="text-[11px] text-muted-foreground"
                        disabled={saving}
                        onClick={() => onToggleGroupForAllRoles(group, false)}
                        aria-label={`${group.parent.label}：全部角色清空`}
                      >
                        清空
                      </Button>
                    </span>
                  </div>
                </TableHead>
              ))}
            </TableRow>
            <TableRow className="hover:bg-transparent">
              {groups.map((group) => (
                <React.Fragment key={group.parent.key}>
                  {group.children.map((child) => (
                    <TableHead
                      key={child.key}
                      title={`${child.label}（${child.route ?? "按钮级"}）`}
                      className="w-[84px] min-w-[84px] bg-card px-1 text-center"
                    >
                      <span className="block truncate text-[11px] font-normal text-muted-foreground">
                        {child.label}
                      </span>
                    </TableHead>
                  ))}
                </React.Fragment>
              ))}
            </TableRow>
          </TableHeader>
          <TableBody>
            {roles.map((role) => {
              const locked = role.code === "admin";
              const draft = grants[role.id] ?? EMPTY_KEYS;
              // fallback 判定基于全部已勾选 key（含父级）：零授权 = visible_menus
              // 走 fail-open 全量兜底，矩阵给出行级提示
              const zeroGrants = !locked && draft.size === 0;
              const dirty = !locked && roleDirty(role.id);
              return (
                <TableRow
                  key={role.id}
                  className={
                    locked ? "bg-muted/40 hover:bg-muted/40" : undefined
                  }
                >
                  <TableHead
                    scope="row"
                    className="sticky left-0 z-10 h-auto border-r bg-card px-2 py-2 align-middle"
                  >
                    <div className="flex w-[164px] flex-col gap-1">
                      <div className="flex items-center gap-1.5">
                        <span className="truncate text-sm font-medium">
                          {role.name}
                        </span>
                        {role.isBuiltin ? (
                          <Badge
                            variant="outline"
                            className={ROLE_KIND_BADGE_CLASSES.builtin}
                          >
                            内置
                          </Badge>
                        ) : null}
                      </div>
                      <div className="flex items-center gap-1.5">
                        <span className="font-mono text-[11px] text-muted-foreground">
                          {role.code}
                        </span>
                        {role.status === "disabled" ? (
                          <Badge
                            variant="outline"
                            className={ROLE_STATUS_BADGE_CLASSES.disabled}
                          >
                            停用
                          </Badge>
                        ) : null}
                      </div>
                      {locked ? (
                        <Badge
                          variant="outline"
                          className={ROLE_BADGE_CLASSES.admin}
                        >
                          全权
                        </Badge>
                      ) : zeroGrants ? (
                        <Badge
                          variant="outline"
                          className={FALLBACK_BADGE_CLASS}
                          title="该角色零授权：visible_menus 按 fail-open 兜底，当前默认可见全部菜单"
                        >
                          fallback 默认可见
                        </Badge>
                      ) : null}
                      {dirty ? (
                        <span className="text-[11px] font-medium text-sky-600 dark:text-sky-400">
                          有未保存变更
                        </span>
                      ) : null}
                      {!locked ? (
                        <span className="flex items-center gap-2 text-[11px]">
                          <button
                            type="button"
                            className="text-muted-foreground underline-offset-2 hover:text-foreground hover:underline disabled:opacity-50"
                            disabled={saving}
                            onClick={() => onToggleRow(role.id, columnKeys, true)}
                          >
                            全选本行
                          </button>
                          <button
                            type="button"
                            className="text-muted-foreground underline-offset-2 hover:text-foreground hover:underline disabled:opacity-50"
                            disabled={saving}
                            onClick={() =>
                              onToggleRow(role.id, columnKeys, false)
                            }
                          >
                            清空本行
                          </button>
                        </span>
                      ) : null}
                    </div>
                  </TableHead>
                  {groups.map((group) => (
                    <React.Fragment key={group.parent.key}>
                      {group.children.map((child) => (
                        <TableCell
                          key={child.key}
                          className="border-l px-1 text-center"
                        >
                          <Checkbox
                            checked={locked || draft.has(child.key)}
                            disabled={locked || saving}
                            onCheckedChange={(value) =>
                              onToggleItem(role.id, child.key, value === true)
                            }
                            aria-label={`${role.name} · ${child.label}${
                              locked ? "（admin 全权锁定）" : ""
                            }`}
                          />
                        </TableCell>
                      ))}
                    </React.Fragment>
                  ))}
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      </div>
    </div>
  );
}

type MobileConfigProps = {
  roles: RoleInfo[];
  groups: MenuGroup[];
  grants: GrantState;
  saving: boolean;
  activeRole: RoleInfo | null;
  roleDirty: (roleId: string) => boolean;
  pendingCount: number;
  onRoleChange: (roleId: string) => void;
  onToggleItem: (roleId: string, menuKey: string, checked: boolean) => void;
  onToggleGroup: (roleId: string, keys: string[], checked: boolean) => void;
  onClearRole: (roleId: string) => void;
  onReset: () => void;
  onSave: () => void;
};

function MobileConfig({
  roles,
  groups,
  grants,
  saving,
  activeRole,
  roleDirty,
  pendingCount,
  onRoleChange,
  onToggleItem,
  onToggleGroup,
  onClearRole,
  onReset,
  onSave,
}: MobileConfigProps) {
  const locked = activeRole?.code === "admin";
  const draft = activeRole ? (grants[activeRole.id] ?? EMPTY_KEYS) : EMPTY_KEYS;
  const zeroGrants = !!activeRole && !locked && draft.size === 0;
  const dirty = !!activeRole && !locked && roleDirty(activeRole.id);
  const hasChanges = pendingCount > 0;

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-col gap-2">
        <Select
          value={activeRole?.id ?? ""}
          onValueChange={onRoleChange}
          disabled={roles.length === 0}
        >
          <SelectTrigger
            className="min-h-11 w-full text-base lg:min-h-8"
            aria-label="选择要配置的角色"
          >
            <SelectValue placeholder="选择角色" />
          </SelectTrigger>
          <SelectContent>
            {roles.map((role) => (
              <SelectItem key={role.id} value={role.id}>
                {role.name}
                {role.code === "admin"
                  ? "（全权）"
                  : role.isBuiltin
                    ? "（内置）"
                    : ""}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>

        {activeRole ? (
          <div className="flex flex-wrap items-center gap-2 rounded-lg border bg-muted/30 px-3 py-2 text-xs text-muted-foreground">
            <span className="font-medium text-foreground">
              {activeRole.name}
            </span>
            <span className="font-mono">{activeRole.code}</span>
            {locked ? (
              <Badge variant="outline" className={ROLE_BADGE_CLASSES.admin}>
                全权
              </Badge>
            ) : zeroGrants ? (
              <Badge variant="outline" className={FALLBACK_BADGE_CLASS}>
                fallback 默认可见
              </Badge>
            ) : null}
            {dirty ? (
              <Badge variant="outline" className={PENDING_BADGE_CLASS}>
                有未保存变更
              </Badge>
            ) : null}
            {!locked ? (
              <button
                type="button"
                className="ml-auto text-primary underline-offset-2 hover:underline disabled:opacity-50"
                disabled={saving || draft.size === 0}
                onClick={() => onClearRole(activeRole.id)}
              >
                清空全部菜单
              </button>
            ) : null}
          </div>
        ) : null}

        {locked ? (
          <p className="text-xs text-muted-foreground">
            系统管理员固定拥有全部菜单权限，此角色不可编辑。
          </p>
        ) : (
          <p className="text-xs text-muted-foreground">
            勾选即授权保存；父级目录由 visible_menus 的祖先链自动带出。
          </p>
        )}
      </div>

      {activeRole ? (
        <div className="flex flex-col gap-3">
          {groups.map((group) => {
            const keys = group.children.map((child) => child.key);
            return (
              <div
                key={group.parent.key}
                className="overflow-hidden rounded-xl border"
              >
                <div className="flex min-h-11 items-center justify-between gap-2 border-b bg-muted/40 px-3 py-1.5">
                  <span className="text-sm font-medium">
                    {group.parent.label}
                  </span>
                  <span className="flex items-center gap-1">
                    <Button
                      type="button"
                      variant="ghost"
                      size="xs"
                      disabled={saving || locked}
                      onClick={() => onToggleGroup(activeRole.id, keys, true)}
                      aria-label={`${group.parent.label}：全选`}
                    >
                      全选
                    </Button>
                    <Button
                      type="button"
                      variant="ghost"
                      size="xs"
                      disabled={saving || locked}
                      onClick={() => onToggleGroup(activeRole.id, keys, false)}
                      aria-label={`${group.parent.label}：清空`}
                    >
                      清空
                    </Button>
                  </span>
                </div>
                <div className="flex flex-col divide-y">
                  {group.children.map((child) => {
                    const checked = locked || draft.has(child.key);
                    return (
                      <div
                        key={child.key}
                        className="flex min-h-11 cursor-pointer items-center gap-3 px-3 py-2 transition-colors hover:bg-muted/50"
                        onClick={() => {
                          if (!locked && !saving) {
                            onToggleItem(activeRole.id, child.key, !checked);
                          }
                        }}
                      >
                        <Checkbox
                          checked={checked}
                          disabled={locked || saving}
                          onClick={(event) => event.stopPropagation()}
                          onCheckedChange={(value) =>
                            onToggleItem(
                              activeRole.id,
                              child.key,
                              value === true,
                            )
                          }
                          aria-label={`${activeRole.name} · ${child.label}`}
                        />
                        <span className="text-sm">{child.label}</span>
                        {child.route ? (
                          <span className="ml-auto truncate font-mono text-[11px] text-muted-foreground">
                            {child.route}
                          </span>
                        ) : null}
                      </div>
                    );
                  })}
                </div>
              </div>
            );
          })}
        </div>
      ) : null}

      <div className="sticky bottom-0 z-10 -mx-4 flex items-center gap-2 border-t bg-background/95 px-4 py-3 backdrop-blur md:-mx-6 md:px-6">
        <span className="flex-1 text-xs text-muted-foreground">
          {hasChanges ? `${pendingCount} 项未保存` : "无未保存变更"}
        </span>
        <Button
          variant="outline"
          className="h-8"
          disabled={saving || !hasChanges}
          onClick={onReset}
        >
          重置
        </Button>
        <Button
          className="h-8 flex-1"
          disabled={saving || !hasChanges}
          onClick={onSave}
        >
          {saving ? (
            <Loader2Icon className="size-3.5 animate-spin" data-icon="inline-start" />
          ) : (
            <SaveIcon className="size-3.5" data-icon="inline-start" />
          )}
          保存
        </Button>
      </div>
    </div>
  );
}

type PreviewCardProps = {
  roles: RoleInfo[];
  groups: MenuGroup[];
  grants: GrantState;
  savedGrants: GrantState;
  menuByKey: Map<string, MenuItem>;
  allKeys: Set<string>;
  activeRole: RoleInfo | null;
  onRoleChange: (roleId: string) => void;
};

function PreviewCard({
  roles,
  groups,
  grants,
  savedGrants,
  menuByKey,
  allKeys,
  activeRole,
  onRoleChange,
}: PreviewCardProps) {
  const view = React.useMemo(() => {
    if (!activeRole) {
      return { keys: new Set<string>(), fallback: false, full: false };
    }
    return computePreviewKeys(
      activeRole,
      grants[activeRole.id] ?? EMPTY_KEYS,
      allKeys,
      menuByKey,
    );
  }, [activeRole, grants, allKeys, menuByKey]);

  const dirty =
    !!activeRole &&
    activeRole.code !== "admin" &&
    !setsEqual(
      grants[activeRole.id] ?? EMPTY_KEYS,
      savedGrants[activeRole.id] ?? EMPTY_KEYS,
    );

  const visibleGroups = groups
    .map((group) => ({
      group,
      parentVisible: view.keys.has(group.parent.key),
      children: group.children.filter((child) => view.keys.has(child.key)),
    }))
    .filter((entry) => entry.parentVisible || entry.children.length > 0);

  return (
    <Card className="rounded-none border-0 md:rounded-xl md:border gap-3! py-3!">
      <CardHeader>
        <CardTitle>按角色预览菜单</CardTitle>
        <CardDescription>
          基于当前勾选计算（含未保存变更）。本页不调用 visible_menus——该
          RPC 无参数、只反映当前登录用户，这里在前端按 role_menu_grants
          复刻其规则。
        </CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-4 p-4 md:p-6">
        <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
          <Select
            value={activeRole?.id ?? ""}
            onValueChange={onRoleChange}
            disabled={roles.length === 0}
          >
            <SelectTrigger
              className="w-full sm:w-56 min-h-11 lg:min-h-8"
              aria-label="选择要预览的角色"
            >
              <SelectValue placeholder="选择角色" />
            </SelectTrigger>
            <SelectContent>
              {roles.map((role) => (
                <SelectItem key={role.id} value={role.id}>
                  {role.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          <div className="flex flex-wrap items-center gap-2">
            {view.full ? (
              <Badge variant="outline" className={ROLE_BADGE_CLASSES.admin}>
                全权 · 全部菜单可见
              </Badge>
            ) : view.fallback ? (
              <Badge
                variant="outline"
                className={FALLBACK_BADGE_CLASS}
                title="该角色零授权：visible_menus 按 fail-open 兜底返回全量菜单（过渡期语义）"
              >
                fail-open · 默认可见全部菜单
              </Badge>
            ) : null}
            {dirty ? (
              <Badge variant="outline" className={PENDING_BADGE_CLASS}>
                含未保存变更
              </Badge>
            ) : null}
            <span className="text-xs text-muted-foreground">
              可见 {view.keys.size} / {allKeys.size} 个菜单点
            </span>
          </div>
        </div>

        {visibleGroups.length === 0 ? (
          <div className="flex flex-col items-center gap-2 py-10 text-sm text-muted-foreground">
            <EyeIcon className="size-8 opacity-60" />
            <span>该角色当前没有任何可见菜单</span>
          </div>
        ) : (
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            {visibleGroups.map(({ group, parentVisible, children }) => (
              <div
                key={group.parent.key}
                className="rounded-lg border bg-card p-3"
              >
                <div className="flex items-center justify-between gap-2">
                  <span className="flex items-center gap-2 text-sm font-medium">
                    {group.parent.label}
                    {parentVisible ? null : (
                      <span className="text-[11px] font-normal text-muted-foreground">
                        仅子菜单可见
                      </span>
                    )}
                  </span>
                  <ShieldCheckIcon className="size-4 text-muted-foreground" />
                </div>
                <ul className="mt-2 flex flex-col gap-1">
                  {children.map((child) => (
                    <li
                      key={child.key}
                      className="truncate pl-3 text-sm text-muted-foreground"
                      title={child.route ?? child.key}
                    >
                      {child.label}
                    </li>
                  ))}
                  {children.length === 0 ? (
                    <li className="pl-3 text-xs text-muted-foreground">
                      无可见子菜单
                    </li>
                  ) : null}
                </ul>
              </div>
            ))}
          </div>
        )}
      </CardContent>
    </Card>
  );
}
