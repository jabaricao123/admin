// 审批中心 · 模板设计器 / 流程配置 共享工具（工单 approval/008+009+010+011 页面配套）
//
// 纯前端工具：schema ↔ 设计器字段、nodes ↔ 节点草稿的互转与本地校验；
// 与 DB 侧 app.validate_template_schema / app.validate_flow_nodes 语义对齐
// （服务端仍是最终把关，本文件只做即时提示与序列化）。

import type { Database, Json } from "@/lib/database.types";

// ---------------------------------------------------------------------------
// 版本状态（draft/published/disabled；published 冻结、disabled 无实例引用才可停用）
// ---------------------------------------------------------------------------
export type ConfigStatus = "draft" | "published" | "disabled";

export const CONFIG_STATUS_LABELS: Record<ConfigStatus, string> = {
  draft: "草稿",
  published: "已发布",
  disabled: "已停用",
};

export const CONFIG_STATUS_BADGE_CLASSES: Record<ConfigStatus, string> = {
  draft:
    "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300",
  published:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  disabled:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
};

export function asConfigStatus(value: string): ConfigStatus {
  return value === "published" || value === "disabled" ? value : "draft";
}

// ---------------------------------------------------------------------------
// 模板字段设计器
// ---------------------------------------------------------------------------
export const FIELD_TYPES = [
  "text",
  "number",
  "date",
  "select",
  "multiselect",
] as const;

export type FieldType = (typeof FIELD_TYPES)[number];

export const FIELD_TYPE_LABELS: Record<FieldType, string> = {
  text: "文本",
  number: "数字",
  date: "日期",
  select: "单选",
  multiselect: "多选",
};

/** 附件类型依赖 system 对象存储（templates.md：P1 前隐藏），本期不下发 */
export const FIELD_TYPE_OPTIONS = FIELD_TYPES.map((value) => ({
  value,
  label: FIELD_TYPE_LABELS[value],
}));

export function asFieldType(value: string): FieldType {
  return (FIELD_TYPES as readonly string[]).includes(value)
    ? (value as FieldType)
    : "text";
}

export type DesignerField = {
  id: string;
  key: string;
  label: string;
  type: FieldType;
  required: boolean;
  /** 原始输入（默认值）：数字按数值、多选按逗号分隔序列化 */
  defaultValue: string;
  /** 原始输入（选项）：逗号分隔，仅单选/多选使用 */
  options: string;
};

let uidCounter = 0;

export function nextUid(prefix: string): string {
  uidCounter += 1;
  return `${prefix}-${uidCounter}`;
}

export function newDesignerField(partial?: Partial<DesignerField>): DesignerField {
  return {
    id: nextUid("field"),
    key: "",
    label: "",
    type: "text",
    required: false,
    defaultValue: "",
    options: "",
    ...partial,
  };
}

export function splitOptions(raw: string): string[] {
  return raw
    .split(/[,，]/)
    .map((item) => item.trim())
    .filter((item) => item.length > 0);
}

/** schema.fields → 设计器字段草稿（兼容附件等未展示类型，回退文本） */
export function fieldsFromSchema(schema: Json): DesignerField[] {
  if (!schema || typeof schema !== "object" || Array.isArray(schema)) {
    return [];
  }
  const rawFields = (schema as { fields?: unknown }).fields;
  if (!Array.isArray(rawFields)) {
    return [];
  }
  return rawFields.flatMap((item) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      return [];
    }
    const record = item as Record<string, unknown>;
    const key = typeof record.key === "string" ? record.key : "";
    const label = typeof record.label === "string" && record.label ? record.label : key;
    const type = typeof record.type === "string" ? asFieldType(record.type) : "text";
    const required = record.required === true;
    const options = Array.isArray(record.options)
      ? record.options.filter((option): option is string => typeof option === "string").join(", ")
      : "";
    let defaultValue = "";
    if (record.default !== undefined && record.default !== null) {
      if (Array.isArray(record.default)) {
        defaultValue = record.default.map((value) => String(value)).join(", ");
      } else if (typeof record.default !== "object") {
        defaultValue = String(record.default);
      }
    }
    return [{ id: nextUid("field"), key, label, type, required, defaultValue, options }];
  });
}

/** 设计器字段草稿 → schema（服务端结构：{fields:[{key,label,type,required,options,default}]}） */
export function fieldsToSchema(fields: DesignerField[]): Json {
  const payload = fields.map((field) => {
    const key = field.key.trim();
    const record: Record<string, Json> = {
      key,
      label: field.label.trim() || key,
      type: field.type,
      required: field.required,
    };
    if (field.type === "select" || field.type === "multiselect") {
      record.options = splitOptions(field.options);
    }
    const rawDefault = field.defaultValue.trim();
    if (rawDefault) {
      if (field.type === "number") {
        record.default = Number(rawDefault);
      } else if (field.type === "multiselect") {
        record.default = splitOptions(rawDefault);
      } else {
        record.default = rawDefault;
      }
    }
    return record;
  });
  return { fields: payload } as Json;
}

const FIELD_KEY_RE = /^[a-zA-Z_][a-zA-Z0-9_]*$/;

/** 本地校验（与 DB 校验语义一致）；返回首个错误信息，null 表示通过 */
export function validateDesignerFields(fields: DesignerField[]): string | null {
  if (fields.length === 0) {
    return "至少需要一个字段";
  }
  const seen = new Set<string>();
  for (let index = 0; index < fields.length; index += 1) {
    const field = fields[index];
    const label = field.label.trim();
    const key = field.key.trim();
    if (!label) {
      return `第 ${index + 1} 个字段缺少标签`;
    }
    if (!key || !FIELD_KEY_RE.test(key)) {
      return `字段「${label}」的字段名不是合法标识符（字母/下划线开头）`;
    }
    if (seen.has(key)) {
      return `字段名重复：${key}`;
    }
    seen.add(key);
    if (
      (field.type === "select" || field.type === "multiselect") &&
      splitOptions(field.options).length === 0
    ) {
      return `字段「${label}」至少需要一个选项`;
    }
    if (
      field.type === "number" &&
      field.defaultValue.trim() &&
      Number.isNaN(Number(field.defaultValue.trim()))
    ) {
      return `字段「${label}」的默认值应为数字`;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// 流程节点设计器
// ---------------------------------------------------------------------------
export const APPROVER_RULE_TYPES = ["role", "dept_leader", "user"] as const;

export type ApproverRuleType = (typeof APPROVER_RULE_TYPES)[number];

export const APPROVER_RULE_LABELS: Record<ApproverRuleType, string> = {
  role: "按角色",
  dept_leader: "部门负责人",
  user: "指定人",
};

export const APPROVER_RULE_OPTIONS = APPROVER_RULE_TYPES.map((value) => ({
  value,
  label: APPROVER_RULE_LABELS[value],
}));

export function asApproverRuleType(value: string): ApproverRuleType {
  return value === "dept_leader" || value === "user" ? value : "role";
}

export type FlowNodeDraft = {
  id: string;
  ruleType: ApproverRuleType;
  /** 角色规则取值：roles.id（新存储）；读取存量节点时由 resolveRoleId 归一化 code → id */
  roleId: string;
  userId: string;
  /** 原始输入：空串=未设置（可选超时） */
  timeoutHours: string;
};

export function newFlowNode(partial?: Partial<FlowNodeDraft>): FlowNodeDraft {
  return {
    id: nextUid("node"),
    ruleType: "role",
    roleId: "",
    userId: "",
    timeoutHours: "",
    ...partial,
  };
}

/**
 * 归一化角色规则取值：新存储为 roles.id；存量节点为 roles.code，按 code 反查为 id。
 * 两者都不匹配时原样返回（交由校验层提示重选，不静默丢弃）。
 */
export function resolveRoleId(
  value: string,
  roles: { id: string; code: string }[],
): string {
  if (!value) {
    return "";
  }
  if (roles.some((role) => role.id === value)) {
    return value;
  }
  return roles.find((role) => role.code === value)?.id ?? value;
}

export function nodesFromJson(nodes: Json): FlowNodeDraft[] {
  if (!Array.isArray(nodes)) {
    return [];
  }
  return nodes.flatMap((item) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      return [];
    }
    const record = item as Record<string, unknown>;
    const rule =
      record.approver_rule &&
      typeof record.approver_rule === "object" &&
      !Array.isArray(record.approver_rule)
        ? (record.approver_rule as Record<string, unknown>)
        : {};
    const ruleType =
      typeof rule.type === "string" ? asApproverRuleType(rule.type) : "role";
    const value = typeof rule.value === "string" ? rule.value : "";
    const timeout = record.timeout_hours;
    return [
      {
        id: nextUid("node"),
        ruleType,
        roleId: ruleType === "role" ? value : "",
        userId: ruleType === "user" ? value : "",
        timeoutHours: typeof timeout === "number" ? String(timeout) : "",
      },
    ];
  });
}

export function nodesToJson(nodes: FlowNodeDraft[]): Json {
  const payload = nodes.map((node, index) => {
    const rule: Record<string, Json> = { type: node.ruleType };
    if (node.ruleType === "role") {
      rule.value = node.roleId;
    } else if (node.ruleType === "user") {
      rule.value = node.userId;
    }
    const record: Record<string, Json> = {
      seq: index + 1,
      approver_rule: rule,
    };
    if (node.timeoutHours.trim()) {
      record.timeout_hours = Number(node.timeoutHours);
    }
    return record;
  });
  return payload as Json;
}

/** 本地校验；返回首个错误信息，null 表示通过 */
export function validateFlowNodes(
  nodes: FlowNodeDraft[],
  roleIds: string[],
  userIds: string[],
): string | null {
  if (nodes.length === 0) {
    return "至少需要一个节点";
  }
  for (let index = 0; index < nodes.length; index += 1) {
    const node = nodes[index];
    if (node.ruleType === "role" && !roleIds.includes(node.roleId)) {
      return `节点 ${index + 1}：请选择审批角色`;
    }
    if (node.ruleType === "user" && !userIds.includes(node.userId)) {
      return `节点 ${index + 1}：请选择指定审批人`;
    }
    if (node.timeoutHours.trim()) {
      const hours = Number(node.timeoutHours);
      if (!Number.isFinite(hours) || hours < 0) {
        return `节点 ${index + 1}：超时时长应为非负数字`;
      }
    }
  }
  return null;
}

export function ruleSummary(
  node: FlowNodeDraft,
  roles: { id: string; code: string; name: string }[],
  profiles: { id: string; full_name: string | null }[],
): string {
  if (node.ruleType === "dept_leader") {
    return "发起人部门负责人";
  }
  if (node.ruleType === "user") {
    const profile = profiles.find((item) => item.id === node.userId);
    return profile
      ? `指定：${profile.full_name ?? profile.id.slice(0, 8)}`
      : "指定：未选择";
  }
  const role =
    roles.find((item) => item.id === node.roleId) ??
    roles.find((item) => item.code === node.roleId);
  return role ? `角色：${role.name}` : "角色：未选择";
}

// ---------------------------------------------------------------------------
// 模拟运行样例数据（按模板 schema 生成，可编辑后提交 simulate_flow）
// ---------------------------------------------------------------------------
export function sampleFormData(schema: Json): Record<string, Json> {
  const result: Record<string, Json> = {};
  const today = new Date().toISOString().slice(0, 10);
  for (const field of fieldsFromSchema(schema)) {
    const key = field.key.trim();
    if (!key) {
      continue;
    }
    if (field.defaultValue.trim()) {
      if (field.type === "number") {
        result[key] = Number(field.defaultValue);
      } else if (field.type === "multiselect") {
        result[key] = splitOptions(field.defaultValue);
      } else {
        result[key] = field.defaultValue.trim();
      }
      continue;
    }
    if (field.type === "number") {
      result[key] = 1;
    } else if (field.type === "date") {
      result[key] = today;
    } else if (field.type === "select") {
      result[key] = splitOptions(field.options)[0] ?? "选项一";
    } else if (field.type === "multiselect") {
      result[key] = splitOptions(field.options).slice(0, 1);
    } else {
      result[key] = "示例文本";
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// 实例引用数（approval_usage_counts 按 template_version_id / flow_version_id 分组）
// ---------------------------------------------------------------------------
export type UsageCounts = { total: number; running: number };

type UsageRow =
  Database["public"]["Functions"]["approval_usage_counts"]["Returns"][number];

export function buildUsageMaps(rows: UsageRow[]): {
  templates: Map<string, UsageCounts>;
  flows: Map<string, UsageCounts>;
} {
  const templates = new Map<string, UsageCounts>();
  const flows = new Map<string, UsageCounts>();
  for (const row of rows) {
    const counts = {
      total: Number(row.total_count),
      running: Number(row.running_count),
    };
    templates.set(row.template_version_id, counts);
    flows.set(row.flow_version_id, counts);
  }
  return { templates, flows };
}
