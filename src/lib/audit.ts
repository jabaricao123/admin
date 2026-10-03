// audit 模块共享工具：模块/动作文案、登录失败原因归类、diff 摘要与值格式化。
// 供操作日志/登录日志页面与登录打点复用；不依赖 React，可在客户端/服务端组件中使用。

import type { Json } from "@/lib/database.types";
import { translateErrorMessage } from "@/lib/dictionaries";

export function formatDateTime(value: string | null | undefined): string {
  if (!value) {
    return "—";
  }
  return new Date(value).toLocaleString("zh-CN", { hour12: false });
}

/** audit 页面 RPC 错误：业务拒绝信息已中文（部分带来源名），原文透传；其余走通用映射 */
export function translateAuditErrorMessage(message: string): string {
  const isBusinessRule =
    /^(仅管理员可导出该来源|导出源已停用|导出源不存在)：/.test(message) ||
    message === "进行中的导出任务已达上限（3），请等待完成后再试";
  return isBusinessRule ? message : translateErrorMessage(message);
}


/** 顶级模块标识 → 展示名；未知模块回退原始标识 */
export const AUDIT_MODULE_LABELS: Record<string, string> = {
  dashboard: "工作台",
  org: "组织管理",
  access: "权限管理",
  approval: "审批中心",
  report: "报表中心",
  audit: "审计中心",
  integration: "接口/集成",
  sync: "数据同步",
  system: "系统管理",
  message: "消息中心",
  demo: "演示模块",
};

export function auditModuleLabel(module: string | null | undefined): string {
  if (!module) {
    return "—";
  }
  return AUDIT_MODULE_LABELS[module] ?? module;
}

/** 动作标识 → 展示名；未知动作回退原始标识 */
export const AUDIT_ACTION_LABELS: Record<string, string> = {
  create: "新建",
  update: "修改",
  delete: "删除",
  assign: "分配",
  denied: "越权拦截",
  upsert: "保存",
  verify: "验证",
  revoke: "吊销",
  request: "发起",
  urge: "催办",
  submit: "提交",
  approve: "通过",
  reject: "驳回",
  withdraw: "撤回",
  enable: "启用",
  disable: "停用",
  cleanup: "清理",
};

export function auditActionLabel(action: string | null | undefined): string {
  if (!action) {
    return "—";
  }
  return AUDIT_ACTION_LABELS[action] ?? action;
}

/** 动作 Badge 配色：危险动作红 / 写操作绿·蓝 / 其余灰（配合 Badge variant="outline"） */
export function auditActionBadgeClass(action: string): string {
  if (action === "denied" || action === "delete" || action === "revoke") {
    return "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300";
  }
  if (action === "create" || action === "enable" || action === "approve") {
    return "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300";
  }
  if (
    action === "update" ||
    action === "upsert" ||
    action === "assign" ||
    action === "verify"
  ) {
    return "border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-900/60 dark:bg-blue-950/60 dark:text-blue-300";
  }
  return "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400";
}

/** 登录失败原因归类（audit/005 写入枚举） → 展示文案 */
export const LOGIN_FAIL_REASON_LABELS: Record<string, string> = {
  invalid_credentials: "邮箱或密码错误",
  user_banned: "账号已禁用",
  other: "其他原因",
};

export function loginFailReasonLabel(
  reason: string | null | undefined,
): string {
  if (!reason) {
    return "—";
  }
  return LOGIN_FAIL_REASON_LABELS[reason] ?? reason;
}

/**
 * 登录失败归类：Supabase Auth 错误文案 → invalid_credentials / user_banned / other。
 * 与 public.record_login_attempt 的归档枚举保持一致。
 */
export function classifyLoginFailure(
  message: string,
): "invalid_credentials" | "user_banned" | "other" {
  if (/invalid login credentials/i.test(message)) {
    return "invalid_credentials";
  }
  if (/banned/i.test(message)) {
    return "user_banned";
  }
  return "other";
}

/** 仅保留纯对象（排除数组/null） */
export function isPlainObject(
  value: unknown,
): value is Record<string, Json | undefined> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** diff 值展示：字符串直出、布尔中文化、对象/数组 JSON 序列化 */
export function formatDiffValue(value: unknown): string {
  if (value === null || value === undefined) {
    return "—";
  }
  if (typeof value === "string") {
    return value === "" ? "（空）" : value;
  }
  if (typeof value === "boolean") {
    return value ? "是" : "否";
  }
  if (typeof value === "number") {
    return String(value);
  }
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

function formatShort(value: unknown, max = 36): string {
  const text = formatDiffValue(value);
  return text.length > max ? `${text.slice(0, max)}…` : text;
}

/**
 * 差异摘要（列表列用）：
 * - before/after 对象：列出变化字段「旧 → 新」（最多 3 项）；
 * - before/after 标量：直接「旧 → 新」；
 * - 其余平铺字段：key=value（最多 3 项）；denied 等含 reason 时优先展示原因。
 */
export function summarizeDiff(diff: Json | null | undefined): string {
  if (!isPlainObject(diff)) {
    return "—";
  }

  const hasBeforeAfter = "before" in diff || "after" in diff;
  if (hasBeforeAfter) {
    const { before, after } = diff;
    if (isPlainObject(before) || isPlainObject(after)) {
      const beforeObj = isPlainObject(before) ? before : {};
      const afterObj = isPlainObject(after) ? after : {};
      const keys = Array.from(
        new Set([...Object.keys(beforeObj), ...Object.keys(afterObj)]),
      );
      const changed = keys.filter(
        (key) =>
          JSON.stringify(beforeObj[key] ?? null) !==
          JSON.stringify(afterObj[key] ?? null),
      );
      if (changed.length === 0) {
        return "无字段变化";
      }
      const parts = changed
        .slice(0, 3)
        .map(
          (key) =>
            `${key}：${formatShort(beforeObj[key])} → ${formatShort(afterObj[key])}`,
        );
      return (
        parts.join("；") +
        (changed.length > 3 ? ` 等 ${changed.length} 项` : "")
      );
    }
    return `${formatShort(before)} → ${formatShort(after)}`;
  }

  if (diff.reason !== undefined) {
    return `原因：${formatShort(diff.reason)}`;
  }

  const keys = Object.keys(diff);
  if (keys.length === 0) {
    return "—";
  }
  const parts = keys.slice(0, 3).map((key) => `${key}=${formatShort(diff[key])}`);
  return parts.join("、") + (keys.length > 3 ? ` 等 ${keys.length} 项` : "");
}
