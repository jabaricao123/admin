// 全局字典：角色 / 状态等枚举的中文文案与展示配置
// 仅依赖数据库类型，供 UI 组件（Badge、Select 等）复用。

import type { Database } from "@/lib/database.types";

export type UserRole = Database["public"]["Enums"]["user_role"];
export type ProfileStatus = Database["public"]["Enums"]["profile_status"];
export type Profile = Database["public"]["Tables"]["profiles"]["Row"];

/** Supabase / PostgREST 常见错误的中文映射；未命中时返回带原文的兜底文案 */
const ERROR_MESSAGES: Record<string, string> = {
  "Invalid login credentials": "邮箱或密码错误",
  "Email not confirmed": "邮箱尚未确认，请联系管理员",
  "Too many requests": "尝试次数过多，请稍后再试",
  "missing email or phone": "请输入邮箱和密码",
  "仅管理员可执行此操作": "仅管理员可执行此操作",
  "不能修改自己的管理员角色": "不能修改自己的管理员角色",
  "不能停用自己的账号": "不能停用自己的账号",
};

export function translateErrorMessage(message: string): string {
  return (
    ERROR_MESSAGES[message] ??
    `操作失败：${message}（若持续出现请联系管理员）`
  );
}

export const ROLE_LABELS: Record<UserRole, string> = {
  admin: "管理员",
  engineer: "工程师",
  planner: "计划员",
  buyer: "采购员",
  quality: "质量",
  supplier: "供应商",
  customer: "客户",
};

/** 角色 Badge 配色（Tailwind 类名，配合 Badge variant="outline"） */
export const ROLE_BADGE_CLASSES: Record<UserRole, string> = {
  admin:
    "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300",
  engineer:
    "border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-900/60 dark:bg-blue-950/60 dark:text-blue-300",
  planner:
    "border-violet-200 bg-violet-50 text-violet-700 dark:border-violet-900/60 dark:bg-violet-950/60 dark:text-violet-300",
  buyer:
    "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300",
  quality:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  supplier:
    "border-cyan-200 bg-cyan-50 text-cyan-700 dark:border-cyan-900/60 dark:bg-cyan-950/60 dark:text-cyan-300",
  customer:
    "border-indigo-200 bg-indigo-50 text-indigo-700 dark:border-indigo-900/60 dark:bg-indigo-950/60 dark:text-indigo-300",
};

export const ROLE_OPTIONS = (
  Object.keys(ROLE_LABELS) as UserRole[]
).map((value) => ({ value, label: ROLE_LABELS[value] }));

export const PROFILE_STATUS_LABELS: Record<ProfileStatus, string> = {
  active: "启用",
  inactive: "停用",
};

export const PROFILE_STATUS_BADGE_CLASSES: Record<ProfileStatus, string> = {
  active:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  inactive:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
};

export const PROFILE_STATUS_OPTIONS = (
  Object.keys(PROFILE_STATUS_LABELS) as ProfileStatus[]
).map((value) => ({ value, label: PROFILE_STATUS_LABELS[value] }));

/** 组织管理 · 部门状态（departments.status，deleted 为逻辑删除终态） */
export type DepartmentStatus = "active" | "disabled" | "deleted";

export const DEPARTMENT_STATUS_LABELS: Record<DepartmentStatus, string> = {
  active: "启用",
  disabled: "停用",
  deleted: "已删除",
};

export const DEPARTMENT_STATUS_BADGE_CLASSES: Record<DepartmentStatus, string> = {
  active:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  disabled:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
  deleted:
    "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300",
};

/**
 * org 模块 RPC 的业务拒绝信息本身是中文且带动态数量（如「该部门下仍有 3 名在职人员，无法停用」），
 * 原文透传；其余错误走通用映射。
 */
export function translateOrgErrorMessage(message: string): string {
  const isBusinessRule =
    /^该部门下仍有 \d+ (名在职人员|个子部门)，无法(停用|删除)$/.test(message) ||
    /^不能将部门移动到/.test(message);
  return isBusinessRule ? message : translateErrorMessage(message);
}

/** 组织管理 · 岗位状态（positions.status） */
export type PositionStatus = "active" | "disabled";

export const POSITION_STATUS_LABELS: Record<PositionStatus, string> = {
  active: "启用",
  disabled: "停用",
};

export const POSITION_STATUS_BADGE_CLASSES: Record<PositionStatus, string> = {
  active:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  disabled:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
};

export const POSITION_STATUS_OPTIONS = (
  Object.keys(POSITION_STATUS_LABELS) as PositionStatus[]
).map((value) => ({ value, label: POSITION_STATUS_LABELS[value] }));

/** 组织管理 · 岗位 RPC 错误：业务拒绝信息已中文（部分带参数），原文透传；其余走通用映射 */
export function translatePositionErrorMessage(message: string): string {
  const isBusinessRule =
    [
      "岗位名称不能为空",
      "岗位编码不能为空",
      "编制数不能为负数",
    ].includes(message) ||
    /^(岗位编码已存在|岗位状态不合法|所属部门不存在或已删除|岗位不存在)：/.test(
      message,
    ) ||
    /^该岗位仍有 \d+ 名在职人员（按所属部门统计），无法删除$/.test(message);
  return isBusinessRule ? message : translateErrorMessage(message);
}

/** 权限管理 · 角色状态（roles.status，写经 disable_role/enable_role） */
export type RoleStatus = "active" | "disabled";

export const ROLE_STATUS_LABELS: Record<RoleStatus, string> = {
  active: "启用",
  disabled: "停用",
};

export const ROLE_STATUS_BADGE_CLASSES: Record<RoleStatus, string> = {
  active:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  disabled:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
};

export const ROLE_STATUS_OPTIONS = (
  Object.keys(ROLE_STATUS_LABELS) as RoleStatus[]
).map((value) => ({ value, label: ROLE_STATUS_LABELS[value] }));

/** 权限管理 · 角色类型（内置角色受 DB 兜底保护，自定义角色可编辑/删除） */
export type RoleKind = "builtin" | "custom";

export const ROLE_KIND_LABELS: Record<RoleKind, string> = {
  builtin: "内置",
  custom: "自定义",
};

export const ROLE_KIND_BADGE_CLASSES: Record<RoleKind, string> = {
  builtin:
    "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300",
  custom:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
};

/** 权限管理 · 角色 RPC 错误：业务拒绝信息已中文（部分带动态人数），原文透传；其余走通用映射 */
export function translateRoleErrorMessage(message: string): string {
  const isBusinessRule =
    /^该角色下仍有 \d+ 名用户，无法(停用|删除)$/.test(message) ||
    [
      "角色名称不能为空",
      "角色标识不能为空",
      "内置角色仅可修改说明",
      "系统管理员角色不可停用",
    ].includes(message) ||
    /^(角色标识已存在|内置角色不可删除|内置角色不可修改标识|非法状态|角色不存在)：/.test(
      message,
    );
  return isBusinessRule ? message : translateErrorMessage(message);
}

/** 消息中心 RPC 错误：属主校验等业务拒绝信息已中文，原文透传；其余走通用映射 */
export function translateMessageErrorMessage(message: string): string {
  const isBusinessRule = message === "消息不存在或无权操作";
  return isBusinessRule ? message : translateErrorMessage(message);
}
