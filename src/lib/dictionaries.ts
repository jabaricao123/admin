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
