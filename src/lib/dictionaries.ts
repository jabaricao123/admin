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

/**
 * 用户管理 RPC 错误：组织/角色业务拒绝信息已中文且部分带参数（如
 * 「部门不存在或已删除：<id>」），原文透传；其余走通用映射。
 */
export function translateUserErrorMessage(message: string): string {
  const isBusinessRule =
    /^(部门不存在或已删除|岗位不存在|用户不存在|角色不存在)：/.test(message) ||
    /^角色(已停用，无法分配|不可分配（兼容期仅支持内置角色）)：/.test(message);
  return isBusinessRule ? message : translateErrorMessage(message);
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

/** 权限管理 · 菜单授权 RPC 错误：业务拒绝信息已中文（部分带参数），原文透传；其余走通用映射 */
export function translatePermissionErrorMessage(message: string): string {
  const isBusinessRule =
    /^(角色不存在|菜单项不存在)：/.test(message) ||
    message === "仅管理员可执行此操作";
  return isBusinessRule ? message : translateErrorMessage(message);
}

/** 权限管理 · 数据范围（role_data_scopes.scope，四档） */
export type DataScope = "self" | "dept" | "dept_tree" | "all";

export const DATA_SCOPE_LABELS: Record<DataScope, string> = {
  self: "仅本人",
  dept: "本部门",
  dept_tree: "本部门及以下",
  all: "全部",
};

export const DATA_SCOPE_DESCRIPTIONS: Record<DataScope, string> = {
  self: "只能看到与本人相关的数据",
  dept: "可以看到本部门成员相关的数据",
  dept_tree: "可以看到本部门及下属部门成员相关的数据",
  all: "可以看到全部数据（仅管理员角色可配置）",
};

export const DATA_SCOPE_OPTIONS = (
  Object.keys(DATA_SCOPE_LABELS) as DataScope[]
).map((value) => ({ value, label: DATA_SCOPE_LABELS[value] }));

/** 权限管理 · 数据范围 RPC 错误：业务拒绝信息已中文（部分带参数），原文透传；其余走通用映射 */
export function translateDataScopeErrorMessage(message: string): string {
  const isBusinessRule =
    /^(角色不存在|非法数据范围)：/.test(message) ||
    [
      "仅管理员可执行此操作",
      "仅系统管理员角色可配置「全部」数据范围",
    ].includes(message);
  return isBusinessRule ? message : translateErrorMessage(message);
}

/** 消息中心 RPC 错误：属主校验等业务拒绝信息已中文，原文透传；其余走通用映射 */
export function translateMessageErrorMessage(message: string): string {
  const isBusinessRule = message === "消息不存在或无权操作";
  return isBusinessRule ? message : translateErrorMessage(message);
}

/** 系统管理 · 服务配置验证状态（system_services.verify_status，草稿可存状态机） */
export type ServiceVerifyStatus = "unverified" | "verified" | "failed";

export const SERVICE_VERIFY_STATUS_LABELS: Record<ServiceVerifyStatus, string> = {
  unverified: "待验证",
  verified: "已验证",
  failed: "验证失败",
};

export const SERVICE_VERIFY_STATUS_BADGE_CLASSES: Record<
  ServiceVerifyStatus,
  string
> = {
  verified:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  unverified:
    "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300",
  failed:
    "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300",
};

/** 数据库 verify_status 收敛到已知状态；未知值按「待验证」展示（fail-safe） */
export function asServiceVerifyStatus(value: string): ServiceVerifyStatus {
  return value === "verified" || value === "failed" ? value : "unverified";
}

/** 系统管理 RPC 错误：业务拒绝信息已中文，原文透传；其余走通用映射 */
export function translateSystemErrorMessage(message: string): string {
  const isBusinessRule =
    message === "测试收件邮箱不能为空" ||
    message === "邮件配置不存在，请先保存配置" ||
    message === "对象存储配置不存在，请先保存配置";
  return isBusinessRule ? message : translateErrorMessage(message);
}

/** 审批中心 · 实例状态（approval_instances.status，状态机见 engine.md） */
export type ApprovalInstanceStatus =
  | "running"
  | "approved"
  | "rejected"
  | "withdrawn";

export const APPROVAL_INSTANCE_STATUS_LABELS: Record<
  ApprovalInstanceStatus,
  string
> = {
  running: "进行中",
  approved: "已通过",
  rejected: "已驳回",
  withdrawn: "已撤回",
};

/** mine.md：进行中蓝 / 通过绿 / 驳回红 / 撤回灰 */
export const APPROVAL_INSTANCE_STATUS_BADGE_CLASSES: Record<
  ApprovalInstanceStatus,
  string
> = {
  running:
    "border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-900/60 dark:bg-blue-950/60 dark:text-blue-300",
  approved:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  rejected:
    "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300",
  withdrawn:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
};

/** 数据库 string 收敛到已知实例状态；未知值按「进行中」展示（fail-safe） */
export function asApprovalInstanceStatus(
  value: string,
): ApprovalInstanceStatus {
  return value === "approved" || value === "rejected" || value === "withdrawn"
    ? value
    : "running";
}

export const APPROVAL_INSTANCE_STATUS_OPTIONS = (
  Object.keys(APPROVAL_INSTANCE_STATUS_LABELS) as ApprovalInstanceStatus[]
).map((value) => ({ value, label: APPROVAL_INSTANCE_STATUS_LABELS[value] }));

/** 审批中心 · 任务状态（approval_tasks.status） */
export type ApprovalTaskStatus = "pending" | "approved" | "rejected" | "skipped";

export const APPROVAL_TASK_STATUS_LABELS: Record<ApprovalTaskStatus, string> = {
  pending: "待处理",
  approved: "已通过",
  rejected: "已驳回",
  skipped: "已跳过",
};

export const APPROVAL_TASK_STATUS_BADGE_CLASSES: Record<
  ApprovalTaskStatus,
  string
> = {
  pending:
    "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300",
  approved:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  rejected:
    "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300",
  skipped:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
};

/** 数据库 string 收敛到已知任务状态；未知值按「待处理」展示（fail-safe） */
export function asApprovalTaskStatus(value: string): ApprovalTaskStatus {
  return value === "approved" ||
    value === "rejected" ||
    value === "skipped"
    ? value
    : "pending";
}

/** 审批中心 RPC 错误：业务拒绝信息已中文（部分带参数），原文透传；其余走通用映射 */
export function translateApprovalErrorMessage(message: string): string {
  const isBusinessRule =
    /^(催办过于频繁|审批实例不存在：|审批实例已结束)/.test(message) ||
    /^(仅发起人可撤回审批|仅发起人可催办)$/.test(message) ||
    /^(当前审批任务已处理|任务已处理|该任务不是当前审批节点)/.test(message) ||
    [
      "驳回必须填写意见",
      "无权处理该审批任务",
      "审批抄送不存在或无权操作",
      "审批实例不存在或无权查看",
    ].includes(message);
  return isBusinessRule ? message : translateErrorMessage(message);
}

// ---------------------------------------------------------------------------
// 第三方数据同步（sync）：数据源 / 任务 / 映射白名单（镜像数据库约束，写入仍由服务端把关）
// ---------------------------------------------------------------------------

/** 数据源类型（sync_sources.type） */
export type SyncSourceType = "api" | "db" | "excel";

export const SYNC_SOURCE_TYPE_LABELS: Record<SyncSourceType, string> = {
  api: "REST API",
  db: "外部数据库",
  excel: "Excel 模板",
};

export const SYNC_SOURCE_TYPE_BADGE_CLASSES: Record<SyncSourceType, string> = {
  api: "border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-900/60 dark:bg-blue-950/60 dark:text-blue-300",
  db: "border-violet-200 bg-violet-50 text-violet-700 dark:border-violet-900/60 dark:bg-violet-950/60 dark:text-violet-300",
  excel:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
};

export function asSyncSourceType(value: string): SyncSourceType {
  return value === "db" || value === "excel" ? value : "api";
}

/** 启停状态（sync_sources.status / sync_tasks.status） */
export type SyncStatus = "active" | "disabled";

export const SYNC_STATUS_LABELS: Record<SyncStatus, string> = {
  active: "启用",
  disabled: "停用",
};

export const SYNC_STATUS_BADGE_CLASSES: Record<SyncStatus, string> = {
  active:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  disabled:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
};

export function asSyncStatus(value: string): SyncStatus {
  return value === "disabled" ? "disabled" : "active";
}

/** 目标表白名单（sync_tasks.target_table，硬编码于 app.validate_sync_mapping） */
export type SyncTargetTable = "departments" | "positions" | "profiles";

export const SYNC_TARGET_TABLE_LABELS: Record<SyncTargetTable, string> = {
  departments: "部门",
  positions: "岗位",
  profiles: "用户档案",
};

export const SYNC_TARGET_TABLE_OPTIONS = (
  ["departments", "positions", "profiles"] as SyncTargetTable[]
).map((value) => ({ value, label: SYNC_TARGET_TABLE_LABELS[value] }));

export function asSyncTargetTable(value: string): SyncTargetTable {
  return value === "positions" || value === "profiles" ? value : "departments";
}

/**
 * 目标字段白名单（页面下拉镜像 app.validate_sync_mapping 的硬编码数组）。
 * profiles 显式不含 role/status（INDEX 规则 7：角色走 access 单通道、启停用走 org RPC）。
 */
export const SYNC_TARGET_FIELD_OPTIONS: Record<
  SyncTargetTable,
  { value: string; label: string }[]
> = {
  departments: [
    { value: "name", label: "名称" },
    { value: "parent_name", label: "上级部门名称" },
    { value: "leader_email", label: "负责人邮箱" },
    { value: "sort_order", label: "排序号" },
  ],
  positions: [
    { value: "name", label: "岗位名称" },
    { value: "code", label: "岗位编码" },
    { value: "department_name", label: "所属部门名称" },
    { value: "headcount", label: "编制数" },
    { value: "description", label: "职责描述" },
  ],
  profiles: [
    { value: "full_name", label: "姓名" },
    { value: "department_name", label: "部门名称" },
    { value: "position_code", label: "岗位编码" },
    { value: "email", label: "邮箱（匹配键）" },
  ],
};

/** 同步方向（sync_tasks.direction） */
export type SyncDirection = "pull" | "push";

export const SYNC_DIRECTION_LABELS: Record<SyncDirection, string> = {
  pull: "拉取（源 → 目标表）",
  push: "推送（目标表 → 外部，只推送）",
};

export const SYNC_DIRECTION_OPTIONS = (
  ["pull", "push"] as SyncDirection[]
).map((value) => ({ value, label: SYNC_DIRECTION_LABELS[value] }));

export function asSyncDirection(value: string): SyncDirection {
  return value === "push" ? "push" : "pull";
}

/** 冲突策略（sync_tasks.conflict_policy） */
export type SyncConflictPolicy = "skip" | "overwrite" | "manual";

export const SYNC_CONFLICT_POLICY_LABELS: Record<SyncConflictPolicy, string> = {
  skip: "跳过",
  overwrite: "覆盖",
  manual: "标记人工处理",
};

export const SYNC_CONFLICT_POLICY_DESCRIPTIONS: Record<
  SyncConflictPolicy,
  string
> = {
  skip: "匹配键已存在时保留目标现状，仅新增未匹配行",
  overwrite: "匹配键已存在时用源数据更新目标行",
  manual: "匹配键已存在时计入冲突，留给人工裁决",
};

export const SYNC_CONFLICT_POLICY_OPTIONS = (
  ["skip", "overwrite", "manual"] as SyncConflictPolicy[]
).map((value) => ({ value, label: SYNC_CONFLICT_POLICY_LABELS[value] }));

export function asSyncConflictPolicy(value: string): SyncConflictPolicy {
  return value === "overwrite" || value === "manual" ? value : "skip";
}

/** 同步 RPC 错误：业务拒绝信息已中文（部分带参数），原文透传；其余走通用映射 */
export function translateSyncErrorMessage(message: string): string {
  const isBusinessRule =
    /^(数据源|同步任务|目标表|目标字段|字段映射|映射项|样本|profiles|没有可回滚)/.test(
      message,
    );
  return isBusinessRule ? message : translateErrorMessage(message);
}
