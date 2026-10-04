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

/** audit 页面 RPC 错误：业务拒绝信息已中文（部分带来源名/表名），原文透传；其余走通用映射 */
export function translateAuditErrorMessage(message: string): string {
  const isBusinessRule =
    /^(仅管理员可导出该来源|导出源已停用|导出源不存在)：/.test(message) ||
    message === "进行中的导出任务已达上限（3），请等待完成后再试" ||
    /^表 .+ 不在数据变更白名单中$/.test(message) ||
    /^表名(不合法|不能为空)/.test(message) ||
    message === "记录标识不能为空";
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
  publish: "发布",
  unpublish: "取消发布",
  register: "登记",
  fail: "失败",
  retry: "重试",
};

export function auditActionLabel(action: string | null | undefined): string {
  if (!action) {
    return "—";
  }
  return AUDIT_ACTION_LABELS[action] ?? action;
}

/** 动作 Badge 配色：危险动作红 / 写操作绿·蓝 / 其余灰（配合 Badge variant="outline"） */
export function auditActionBadgeClass(action: string): string {
  if (
    action === "denied" ||
    action === "delete" ||
    action === "revoke" ||
    action === "fail"
  ) {
    return "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300";
  }
  if (action === "create" || action === "enable" || action === "approve") {
    return "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300";
  }
  if (
    action === "update" ||
    action === "upsert" ||
    action === "assign" ||
    action === "verify" ||
    action === "publish" ||
    action === "unpublish" ||
    action === "register" ||
    action === "retry"
  ) {
    return "border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-900/60 dark:bg-blue-950/60 dark:text-blue-300";
  }
  return "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400";
}

// ---------------------------------------------------------------------------
// 登录日志（audit/005）：结果/警示 Badge 配色 + 失败原因中性色 + UA 摘要
// ---------------------------------------------------------------------------

/** 登录成功 Badge 配色（配合 Badge variant="outline"） */
export const LOGIN_SUCCESS_BADGE_CLASS =
  "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300";

/** 登录失败 Badge 配色（配合 Badge variant="outline"） */
export const LOGIN_FAILURE_BADGE_CLASS =
  "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300";

/** 多 IP 失败警示 Badge 配色（配合 Badge variant="outline"） */
export const LOGIN_MULTI_IP_BADGE_CLASS =
  "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300";

/** 失败原因 Badge 中性配色：与红色「失败」结果 Badge 区分（配合 Badge variant="outline"） */
export const LOGIN_FAIL_REASON_BADGE_CLASS =
  "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400";

/**
 * UA → 「浏览器 · 系统」摘要（自写轻量解析，仅常见组合，未知回退「未知设备」）。
 * 例：Chrome/Linux UA → 「Chrome · Linux」；iPhone Safari → 「Safari · iPhone」。
 * 原始 UA 由调用方放入 title 悬停展示。
 */
export function userAgentSummary(ua: string | null | undefined): string {
  if (!ua) {
    return "—";
  }
  const browser = /Edg[A-Z]?\//.test(ua)
    ? "Edge"
    : /OPR\//.test(ua)
      ? "Opera"
      : /Firefox\/|FxiOS\//.test(ua)
        ? "Firefox"
        : /Chrome\/|CriOS\//.test(ua)
          ? "Chrome"
          : /Safari\//.test(ua)
            ? "Safari"
            : null;
  // 顺序敏感：iPhone/iPad 的 UA 亦含 "like Mac OS X"，Android 亦含 "Linux"
  const os = /iPhone|iPod/.test(ua)
    ? "iPhone"
    : /iPad/.test(ua)
      ? "iPad"
      : /Android/.test(ua)
        ? "Android"
        : /Windows/.test(ua)
          ? "Windows"
          : /Mac OS X|Macintosh/.test(ua)
            ? "macOS"
            : /Linux|X11/.test(ua)
              ? "Linux"
              : null;
  const parts = [browser, os].filter((part): part is string => part !== null);
  return parts.length > 0 ? parts.join(" · ") : "未知设备";
}

/** 登录失败原因归类（audit/005 写入枚举；im/002 增 IM 未绑定；im/008 增密码登录关闭） → 展示文案 */
export const LOGIN_FAIL_REASON_LABELS: Record<string, string> = {
  invalid_credentials: "邮箱或密码错误",
  user_banned: "账号已禁用",
  im_not_bound: "未绑定 IM 账号",
  password_login_disabled: "密码登录已关闭",
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

// ---------------------------------------------------------------------------
// 数据变更（audit/007）：表名 / 快照字段 / 变更类型 展示配置
// ---------------------------------------------------------------------------

/** audit_row_versions.table_name → 展示名；未知表回退原始表名 */
export const ROW_VERSION_TABLE_LABELS: Record<string, string> = {
  profiles: "用户档案",
  departments: "部门",
  positions: "岗位",
};

export function rowVersionTableLabel(table: string | null | undefined): string {
  if (!table) {
    return "—";
  }
  return ROW_VERSION_TABLE_LABELS[table] ?? table;
}

/** 行快照字段 → 展示名；未知字段回退原始 key */
export const ROW_VERSION_FIELD_LABELS: Record<string, string> = {
  id: "ID",
  full_name: "姓名",
  department: "部门（文本）",
  department_id: "部门 ID",
  position_id: "岗位 ID",
  role: "角色",
  status: "状态",
  created_by: "创建人",
  updated_by: "更新人",
  created_at: "创建时间",
  updated_at: "更新时间",
  name: "名称",
  parent_id: "上级部门 ID",
  leader_id: "负责人 ID",
  sort_order: "排序号",
  code: "编码",
  headcount: "编制数",
  description: "描述",
};

export function rowVersionFieldLabel(key: string): string {
  return ROW_VERSION_FIELD_LABELS[key] ?? key;
}

/** 版本变更类型（RPC 推断：insert/update/delete）→ 展示名 */
export const ROW_VERSION_CHANGE_LABELS: Record<string, string> = {
  insert: "新建",
  update: "修改",
  delete: "删除",
};

export function rowVersionChangeLabel(changeType: string | null | undefined): string {
  if (!changeType) {
    return "—";
  }
  return ROW_VERSION_CHANGE_LABELS[changeType] ?? changeType;
}

/** 版本变更类型 Badge 配色（复用动作配色：insert→create） */
export function rowVersionChangeBadgeClass(changeType: string): string {
  return auditActionBadgeClass(changeType === "insert" ? "create" : changeType);
}

// ---------------------------------------------------------------------------
// 合规报告（audit/008）：周期/范围 展示配置
// ---------------------------------------------------------------------------

export type CompliancePeriod = "week" | "month" | "quarter";

export const COMPLIANCE_PERIOD_LABELS: Record<CompliancePeriod, string> = {
  week: "周报",
  month: "月报",
  quarter: "季度报",
};

export const COMPLIANCE_PERIOD_OPTIONS = (
  Object.keys(COMPLIANCE_PERIOD_LABELS) as CompliancePeriod[]
).map((value) => ({ value, label: COMPLIANCE_PERIOD_LABELS[value] }));

export function compliancePeriodLabel(period: string | null | undefined): string {
  if (!period) {
    return "—";
  }
  return COMPLIANCE_PERIOD_LABELS[period as CompliancePeriod] ?? period;
}

/** 报告范围：all=全系统；其余为模块标识（复用 AUDIT_MODULE_LABELS 展示） */
export function complianceRangeLabel(range: string | null | undefined): string {
  if (!range) {
    return "—";
  }
  if (range === "all") {
    return "全系统";
  }
  return AUDIT_MODULE_LABELS[range] ?? range;
}

/** 范围下拉：全系统 + 已知模块（值=module 标识，与 audit_operations.module 对齐） */
export const COMPLIANCE_RANGE_OPTIONS = [
  { value: "all", label: "全系统" },
  ...Object.entries(AUDIT_MODULE_LABELS).map(([value, label]) => ({
    value,
    label,
  })),
];
