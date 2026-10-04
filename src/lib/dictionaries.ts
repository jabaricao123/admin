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
    message === "对象存储配置不存在，请先保存配置" ||
    message === "推送配置不存在，请先保存配置" ||
    message === "短信配置不存在，请先保存配置" ||
    message === "测试手机号不能为空" ||
    message === "测试手机号格式不正确" ||
    message === "短信通道未启用，请先开启通道后再测试" ||
    message === "启用推送渠道前请先填写 Webhook URL" ||
    message === "参数值不能为 NULL" ||
    message === "仅管理员可执行此操作" ||
    /^(参数 key 不能为空|参数分组不能为空|参数说明不能为空|未知参数类型|参数值类型与 |字典标识不能为空|字典用途说明不能为空|字典项 value 不能为空|字典项 label 不能为空|非法字典项状态|字典项不存在|字典 .+ 尚未登记用途说明|未知推送渠道|模板名称不能为空|模板场景不能为空|模板 code 不能为空|非法模板状态|短信模板不存在)/.test(
      message,
    );
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
    /^(数据源|同步任务|目标表|目标字段|字段映射|映射项|样本|profiles|没有可回滚|调度|Webhook|cron|时区|任务未启用|上级部门|负责人邮箱|所属部门|岗位编码|冲突|仅管理员)/.test(
      message,
    );
  return isBusinessRule ? message : translateErrorMessage(message);
}

// ---------------------------------------------------------------------------
// 第三方数据同步（sync）：执行记录 / 冲突裁决 / 调度
// ---------------------------------------------------------------------------

/** 触发方式（sync_runs.trigger_type / sync_schedules.trigger_type） */
export type SyncTriggerType = "manual" | "cron" | "webhook";

export const SYNC_TRIGGER_TYPE_LABELS: Record<SyncTriggerType, string> = {
  manual: "手动",
  cron: "定时",
  webhook: "Webhook",
};

export const SYNC_TRIGGER_TYPE_OPTIONS = (
  ["manual", "cron", "webhook"] as SyncTriggerType[]
).map((value) => ({ value, label: SYNC_TRIGGER_TYPE_LABELS[value] }));

export function asSyncTriggerType(value: string): SyncTriggerType {
  return value === "cron" || value === "webhook" ? value : "manual";
}

/** 执行状态（sync_runs.status） */
export type SyncRunStatus = "running" | "success" | "partial" | "failed";

export const SYNC_RUN_STATUS_LABELS: Record<SyncRunStatus, string> = {
  running: "执行中",
  success: "成功",
  partial: "部分成功",
  failed: "失败",
};

export const SYNC_RUN_STATUS_BADGE_CLASSES: Record<SyncRunStatus, string> = {
  running:
    "border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-900/60 dark:bg-blue-950/60 dark:text-blue-300",
  success:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  partial:
    "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300",
  failed:
    "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300",
};

export function asSyncRunStatus(value: string): SyncRunStatus {
  return value === "success" || value === "partial" || value === "failed"
    ? value
    : "running";
}

/** 冲突裁决状态（sync_conflicts.resolution） */
export type SyncConflictResolution = "pending" | "adopted" | "ignored";

export const SYNC_CONFLICT_RESOLUTION_LABELS: Record<
  SyncConflictResolution,
  string
> = {
  pending: "待处理",
  adopted: "已采纳",
  ignored: "已忽略",
};

export const SYNC_CONFLICT_RESOLUTION_BADGE_CLASSES: Record<
  SyncConflictResolution,
  string
> = {
  pending:
    "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300",
  adopted:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  ignored:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
};

export function asSyncConflictResolution(
  value: string,
): SyncConflictResolution {
  return value === "adopted" || value === "ignored" ? value : "pending";
}

/** 调度状态（sync_schedules.status；disabled_pending_unschedule 为停用待注销瞬态） */
export type SyncScheduleStatus =
  | "active"
  | "disabled"
  | "disabled_pending_unschedule";

export const SYNC_SCHEDULE_STATUS_LABELS: Record<SyncScheduleStatus, string> = {
  active: "启用",
  disabled: "停用",
  disabled_pending_unschedule: "停用（待注销）",
};

export const SYNC_SCHEDULE_STATUS_BADGE_CLASSES: Record<
  SyncScheduleStatus,
  string
> = {
  active:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  disabled:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
  disabled_pending_unschedule:
    "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300",
};

export function asSyncScheduleStatus(value: string): SyncScheduleStatus {
  return value === "disabled" || value === "disabled_pending_unschedule"
    ? value
    : "active";
}

/** cron 预设频率（页面选择器；高级模式直接暴露表达式） */
export type SyncCronPreset = "hourly" | "daily" | "weekly" | "custom";

export const SYNC_CRON_PRESET_LABELS: Record<SyncCronPreset, string> = {
  hourly: "每小时",
  daily: "每天",
  weekly: "每周",
  custom: "自定义（高级）",
};

export const SYNC_CRON_PRESET_OPTIONS = (
  ["hourly", "daily", "weekly", "custom"] as SyncCronPreset[]
).map((value) => ({ value, label: SYNC_CRON_PRESET_LABELS[value] }));

export const SYNC_WEEKDAY_LABELS: { value: string; label: string }[] = [
  { value: "1", label: "周一" },
  { value: "2", label: "周二" },
  { value: "3", label: "周三" },
  { value: "4", label: "周四" },
  { value: "5", label: "周五" },
  { value: "6", label: "周六" },
  { value: "0", label: "周日" },
];

/** cron 摘要（列表展示；无法识别时原样返回） */
export function describeCronExpr(expr: string | null): string {
  if (!expr) {
    return "—";
  }
  const parts = expr.trim().split(/\s+/);
  if (parts.length !== 5) {
    return expr;
  }
  const [minute, hour, day, month, dow] = parts;
  if (minute === "0" && hour === "*" && day === "*" && month === "*" && dow === "*") {
    return "每小时";
  }
  if (/^\d{1,2}$/.test(minute) && /^\d{1,2}$/.test(hour)) {
    const time = `${hour.padStart(2, "0")}:${minute.padStart(2, "0")}`;
    if (day === "*" && month === "*" && dow === "*") {
      return `每天 ${time}`;
    }
    if (day === "*" && month === "*" && /^\d$/.test(dow)) {
      const weekday =
        SYNC_WEEKDAY_LABELS.find((item) => item.value === dow)?.label ?? dow;
      return `每${weekday} ${time}`;
    }
  }
  return expr;
}

// ---------------------------------------------------------------------------
// 接口/集成中心（integration）：API 密钥 / Webhook
// ---------------------------------------------------------------------------

/** API 密钥状态（api_keys.status；吊销即时失效且不可恢复） */
export type ApiKeyStatus = "active" | "revoked";

export const API_KEY_STATUS_LABELS: Record<ApiKeyStatus, string> = {
  active: "生效",
  revoked: "已吊销",
};

export const API_KEY_STATUS_BADGE_CLASSES: Record<ApiKeyStatus, string> = {
  active:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  revoked:
    "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300",
};

export function asApiKeyStatus(value: string): ApiKeyStatus {
  return value === "revoked" ? "revoked" : "active";
}

export const API_KEY_STATUS_OPTIONS = (
  Object.keys(API_KEY_STATUS_LABELS) as ApiKeyStatus[]
).map((value) => ({ value, label: API_KEY_STATUS_LABELS[value] }));

/** API 密钥范围（v1 前端常量：预设只读范围，写入仍由服务端 scopes 白名单把关） */
export const API_KEY_SCOPE_LABELS: Record<string, string> = {
  "org:read": "组织只读",
  "report:read": "报表只读",
  "audit:read": "审计只读",
};

export const API_KEY_SCOPE_OPTIONS = Object.keys(API_KEY_SCOPE_LABELS).map(
  (value) => ({ value, label: API_KEY_SCOPE_LABELS[value] }),
);

/** 密钥有效期预设（签发向导第三步；never = 永不过期） */
export type ApiKeyExpiryPreset = "30" | "90" | "365" | "never";

export const API_KEY_EXPIRY_LABELS: Record<ApiKeyExpiryPreset, string> = {
  "30": "30 天",
  "90": "90 天",
  "365": "365 天",
  never: "永不过期",
};

export const API_KEY_EXPIRY_OPTIONS = (
  Object.keys(API_KEY_EXPIRY_LABELS) as ApiKeyExpiryPreset[]
).map((value) => ({ value, label: API_KEY_EXPIRY_LABELS[value] }));

/** Webhook 状态（webhooks.status；停用端点不再收到事件） */
export type WebhookStatus = "active" | "disabled";

export const WEBHOOK_STATUS_LABELS: Record<WebhookStatus, string> = {
  active: "启用",
  disabled: "停用",
};

export const WEBHOOK_STATUS_BADGE_CLASSES: Record<WebhookStatus, string> = {
  active:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  disabled:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
};

export function asWebhookStatus(value: string): WebhookStatus {
  return value === "disabled" ? "disabled" : "active";
}

export const WEBHOOK_STATUS_OPTIONS = (
  Object.keys(WEBHOOK_STATUS_LABELS) as WebhookStatus[]
).map((value) => ({ value, label: WEBHOOK_STATUS_LABELS[value] }));

/**
 * Webhook 订阅事件清单（v1 前端常量，按模块分组）。
 * 与 docs/modules/integration/webhooks.md 首期发射点契约一致：
 * approval 3 个 + org.user_changed + sync.run_finished + webhook.ping。
 */
export type WebhookEventOption = { value: string; label: string };
export type WebhookEventGroup = {
  module: string;
  label: string;
  events: WebhookEventOption[];
};

export const WEBHOOK_EVENT_GROUPS: WebhookEventGroup[] = [
  {
    module: "approval",
    label: "审批",
    events: [
      { value: "approval.submitted", label: "审批提交" },
      { value: "approval.approved", label: "审批通过" },
      { value: "approval.rejected", label: "审批驳回" },
    ],
  },
  {
    module: "org",
    label: "组织",
    events: [{ value: "org.user_changed", label: "用户变更" }],
  },
  {
    module: "sync",
    label: "同步",
    events: [{ value: "sync.run_finished", label: "同步完成" }],
  },
  {
    module: "webhook",
    label: "Webhook",
    events: [{ value: "webhook.ping", label: "测试 ping" }],
  },
];

export const WEBHOOK_EVENT_LABELS: Record<string, string> = Object.fromEntries(
  WEBHOOK_EVENT_GROUPS.flatMap((group) =>
    group.events.map((event) => [event.value, event.label]),
  ),
);

/** Webhook 重试策略（retry_policy jsonb；投递器 005 按 max_attempts/backoff 消费） */
export const WEBHOOK_MAX_ATTEMPTS_OPTIONS = [
  { value: "1", label: "不重试（仅 1 次）" },
  { value: "3", label: "3 次" },
  { value: "5", label: "5 次" },
];

export const WEBHOOK_BACKOFF_LABELS: Record<string, string> = {
  exponential: "指数退避（2^n 分钟）",
  linear: "固定间隔（n 分钟）",
};

export const WEBHOOK_BACKOFF_OPTIONS = Object.keys(WEBHOOK_BACKOFF_LABELS).map(
  (value) => ({ value, label: WEBHOOK_BACKOFF_LABELS[value] }),
);

/** 投递明细状态（webhook_deliveries.status） */
export type DeliveryStatus = "delivering" | "done" | "failed";

export const DELIVERY_STATUS_LABELS: Record<DeliveryStatus, string> = {
  delivering: "投递中",
  done: "成功",
  failed: "失败",
};

export const DELIVERY_STATUS_BADGE_CLASSES: Record<DeliveryStatus, string> = {
  done: "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  delivering:
    "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300",
  failed:
    "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300",
};

export function asDeliveryStatus(value: string): DeliveryStatus {
  return value === "done" || value === "failed" ? value : "delivering";
}

/** 接口集成 RPC 错误：业务拒绝信息已中文（部分带参数），原文透传；其余走通用映射 */
export function translateIntegrationErrorMessage(message: string): string {
  const isBusinessRule =
    /^(密钥|Webhook|事件|至少订阅|有效期|重试策略|自定义 header|scopes)/.test(
      message,
    ) || message === "仅管理员可执行此操作";
  return isBusinessRule ? message : translateErrorMessage(message);
}

// ---------------------------------------------------------------------------
// 消息中心 · 通知文案模板（message_templates）
// ---------------------------------------------------------------------------

/** 模板渠道（message_templates.channel；本期仅建模，投递在 message/009） */
export type TemplateChannel = "inbox" | "email" | "push";

export const TEMPLATE_CHANNEL_LABELS: Record<TemplateChannel, string> = {
  inbox: "站内信",
  email: "邮件",
  push: "推送",
};

export const TEMPLATE_CHANNEL_OPTIONS = (
  Object.keys(TEMPLATE_CHANNEL_LABELS) as TemplateChannel[]
).map((value) => ({ value, label: TEMPLATE_CHANNEL_LABELS[value] }));

export function asTemplateChannel(value: string): TemplateChannel {
  return value === "email" || value === "push" ? value : "inbox";
}

/** 模板状态（draft 可编辑 / published 生效 / disabled 停用） */
export type TemplateStatus = "draft" | "published" | "disabled";

export const TEMPLATE_STATUS_LABELS: Record<TemplateStatus, string> = {
  draft: "草稿",
  published: "已发布",
  disabled: "已停用",
};

export const TEMPLATE_STATUS_BADGE_CLASSES: Record<TemplateStatus, string> = {
  draft:
    "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300",
  published:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  disabled:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
};

export function asTemplateStatus(value: string): TemplateStatus {
  return value === "published" || value === "disabled" ? value : "draft";
}

/** 通知文案模板 RPC 错误：业务拒绝信息已中文（部分带参数），原文透传；其余走通用映射 */
export function translateMessageTemplateErrorMessage(message: string): string {
  const isBusinessRule =
    /^(事件未注册|渠道不合法|该版本非草稿|标题模板不能为空|已停用版本|模板不存在|模板事件与渠道)/.test(
      message,
    ) || message === "仅管理员可执行此操作";
  return isBusinessRule ? message : translateErrorMessage(message);
}

/* -------------------------------------------------------------------------- */
/* 报表中心（report/004 + report/008）                                         */
/* -------------------------------------------------------------------------- */

/** 自定义报表 · 图表类型（config.chart，与 report_definitions check 对齐） */
export type ReportChartType = "table" | "bar" | "line" | "pie";

export const REPORT_CHART_LABELS: Record<ReportChartType, string> = {
  table: "表格",
  bar: "柱状图",
  line: "折线图",
  pie: "饼图",
};

/** 自定义报表 · 可见性（private 仅 owner/admin；public 全员可读） */
export type ReportVisibility = "private" | "public";

export const REPORT_VISIBILITY_LABELS: Record<ReportVisibility, string> = {
  private: "私有",
  public: "公共",
};

export const REPORT_VISIBILITY_BADGE_CLASSES: Record<ReportVisibility, string> = {
  private:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
  public:
    "border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-900/60 dark:bg-blue-950/60 dark:text-blue-300",
};

/** 自定义报表 · 度量聚合（count/sum/avg；sum/avg 仅数值列） */
export type ReportAgg = "count" | "sum" | "avg";

export const REPORT_AGG_LABELS: Record<ReportAgg, string> = {
  count: "计数",
  sum: "求和",
  avg: "平均",
};

/** 自定义报表 · 筛选操作符（编辑器提供 = / in / between / like） */
export type ReportFilterOp = "=" | "in" | "between" | "like";

export const REPORT_FILTER_OP_LABELS: Record<ReportFilterOp, string> = {
  "=": "等于（=）",
  in: "属于（in）",
  between: "区间（between）",
  like: "包含（like）",
};

/* -------------------------------------------------------------------------- */
/* 报表中心 · 报表订阅（report/005 + report/006）                               */
/* -------------------------------------------------------------------------- */

/** 订阅频率预设（页面只给预设，cron 由 upsert_report_subscription 映射落表） */
export type ReportSubscriptionPreset = "hourly" | "daily" | "weekly";

export const REPORT_SUBSCRIPTION_PRESET_LABELS: Record<
  ReportSubscriptionPreset,
  string
> = {
  hourly: "每小时",
  daily: "每天",
  weekly: "每周",
};

export const REPORT_SUBSCRIPTION_PRESET_OPTIONS = (
  ["hourly", "daily", "weekly"] as ReportSubscriptionPreset[]
).map((value) => ({ value, label: REPORT_SUBSCRIPTION_PRESET_LABELS[value] }));

/** 订阅状态（report_subscriptions.status；逻辑删行不出现在列表） */
export type ReportSubscriptionStatus = "active" | "disabled";

export const REPORT_SUBSCRIPTION_STATUS_LABELS: Record<
  ReportSubscriptionStatus,
  string
> = {
  active: "启用",
  disabled: "停用",
};

export const REPORT_SUBSCRIPTION_STATUS_BADGE_CLASSES: Record<
  ReportSubscriptionStatus,
  string
> = {
  active:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  disabled:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
};

export function asReportSubscriptionStatus(
  value: string,
): ReportSubscriptionStatus {
  return value === "disabled" ? "disabled" : "active";
}

/** 订阅执行状态（report_subscription_runs.status） */
export type ReportSubscriptionRunStatus = "running" | "success" | "failed";

export const REPORT_SUBSCRIPTION_RUN_STATUS_LABELS: Record<
  ReportSubscriptionRunStatus,
  string
> = {
  running: "执行中",
  success: "成功",
  failed: "失败",
};

export const REPORT_SUBSCRIPTION_RUN_STATUS_BADGE_CLASSES: Record<
  ReportSubscriptionRunStatus,
  string
> = {
  running:
    "border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-900/60 dark:bg-blue-950/60 dark:text-blue-300",
  success:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  failed:
    "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300",
};

export function asReportSubscriptionRunStatus(
  value: string,
): ReportSubscriptionRunStatus {
  return value === "success" || value === "failed" ? value : "running";
}

/** 投递渠道（channels；email 经 message 渠道分发降级，本工单不直发） */
export type ReportChannel = "inbox" | "email";

export const REPORT_CHANNEL_LABELS: Record<ReportChannel, string> = {
  inbox: "站内信",
  email: "邮件",
};

/** 星期（与 sync 调度共用一套 0=周日 的取值） */
export const REPORT_WEEKDAY_LABELS = SYNC_WEEKDAY_LABELS;

/** 数据导出 · 任务状态（export_jobs.status 状态机） */
export type ExportStatus = "queued" | "running" | "done" | "failed";

export const EXPORT_STATUS_LABELS: Record<ExportStatus, string> = {
  queued: "排队中",
  running: "生成中",
  done: "已完成",
  failed: "失败",
};

/** 导出状态 Badge 配色：排队灰 / 生成蓝 / 完成绿 / 失败红 */
export const EXPORT_STATUS_BADGE_CLASSES: Record<ExportStatus, string> = {
  queued:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
  running:
    "border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-900/60 dark:bg-blue-950/60 dark:text-blue-300",
  done:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  failed:
    "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300",
};

/** 导出源展示名（未登记来源回退原始 source） */
export const EXPORT_SOURCE_LABELS: Record<string, string> = {
  "org.users": "用户名单",
  "audit.operations": "操作日志",
  "integration.logs": "调用日志",
};

/** 系统管理 · 公告状态（system_announcements.status，状态机见 announcements.md） */
export type AnnouncementStatus = "draft" | "published" | "offline" | "archived";

export const ANNOUNCEMENT_STATUS_LABELS: Record<AnnouncementStatus, string> = {
  draft: "草稿",
  published: "已发布",
  offline: "已下线",
  archived: "已归档",
};

/** 公告状态 Badge 配色：草稿黄（待发布）/ 发布绿 / 下线灰 / 归档蓝 */
export const ANNOUNCEMENT_STATUS_BADGE_CLASSES: Record<
  AnnouncementStatus,
  string
> = {
  draft:
    "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300",
  published:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  offline:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
  archived:
    "border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-900/60 dark:bg-blue-950/60 dark:text-blue-300",
};

/** 数据库 status 收敛到已知公告状态；未知值按草稿展示（fail-safe） */
export function asAnnouncementStatus(value: string): AnnouncementStatus {
  return value === "published" || value === "offline" || value === "archived"
    ? value
    : "draft";
}

/** 公告范围展示：all→全员；role:<code>→角色：<中文名> */
export function announcementAudienceLabel(audience: string): string {
  if (audience === "all") {
    return "全员";
  }
  if (audience.startsWith("role:")) {
    const code = audience.slice(5) as UserRole;
    return `角色：${ROLE_LABELS[code] ?? code}`;
  }
  return audience;
}

/** 公告范围选项：全员 + 7 个 user_role 枚举角色 */
export const ANNOUNCEMENT_AUDIENCE_OPTIONS = [
  { value: "all", label: "全员" },
  ...ROLE_OPTIONS.map((role) => ({
    value: `role:${role.value}`,
    label: `角色：${role.label}`,
  })),
];

/** 系统管理 · 公告 RPC 错误：业务拒绝信息已中文（部分带状态参数），原文透传；其余走通用映射 */
export function translateAnnouncementErrorMessage(message: string): string {
  const isBusinessRule =
    /^(公告|生效时段)/.test(message) ||
    /^(仅草稿|仅已发布|发布前请)/.test(message);
  return isBusinessRule ? message : translateErrorMessage(message);
}

// ---------------------------------------------------------------------------
// 接口/集成 · 调用日志（integration/007-008）
// ---------------------------------------------------------------------------

/** 调用类型（integration_call_logs.kind） */
export type CallLogKind = "api" | "webhook";

export const CALL_LOG_KIND_LABELS: Record<CallLogKind, string> = {
  api: "API",
  webhook: "Webhook",
};

export const CALL_LOG_KIND_BADGE_CLASSES: Record<CallLogKind, string> = {
  api: "border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-900/60 dark:bg-blue-950/60 dark:text-blue-300",
  webhook:
    "border-violet-200 bg-violet-50 text-violet-700 dark:border-violet-900/60 dark:bg-violet-950/60 dark:text-violet-300",
};

export function asCallLogKind(value: string): CallLogKind {
  return value === "webhook" ? "webhook" : "api";
}

/** 状态码 Badge 配色：2xx 绿 / 4xx 黄 / 5xx 红 / 其他（含无响应）灰 */
export function callStatusCodeBadgeClass(code: number | null): string {
  if (code === null) {
    return "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400";
  }
  if (code >= 500) {
    return "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300";
  }
  if (code >= 400) {
    return "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300";
  }
  if (code >= 200 && code < 300) {
    return "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300";
  }
  return "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400";
}

export function callStatusLabel(code: number | null): string {
  return code === null ? "无响应" : String(code);
}

/** 调用日志筛选：状态码档位（一键 ≥400 为 failed） */
export type CallStatusFilter = "all" | "failed" | "2xx" | "4xx" | "5xx";

export const CALL_STATUS_FILTER_OPTIONS = [
  { value: "all", label: "全部状态" },
  { value: "failed", label: "失败（≥400）" },
  { value: "2xx", label: "2xx 成功" },
  { value: "4xx", label: "4xx 客户端错误" },
  { value: "5xx", label: "5xx 服务端错误" },
] as const;

/** 导出源 integration.logs 的错误透传（业务提示已是中文） */
export function translateIntegrationLogsErrorMessage(message: string): string {
  return translateIntegrationErrorMessage(message);
}

/* -------------------------------------------------------------------------- */
/* 系统管理 · 消息推送 / 短信服务（system/004 + system/005）                     */
/* -------------------------------------------------------------------------- */

/** 推送渠道（system_services service='push' config 子键；双卡片） */
export type PushChannel = "wecom" | "dingtalk";

export const PUSH_CHANNEL_LABELS: Record<PushChannel, string> = {
  wecom: "企业微信",
  dingtalk: "钉钉",
};

export const PUSH_CHANNEL_DESCRIPTIONS: Record<PushChannel, string> = {
  wecom: "企业微信群机器人 Webhook（群设置 → 群机器人 → 添加机器人）",
  dingtalk: "钉钉群机器人 Webhook（群设置 → 智能群助手 → 添加机器人）",
};

export const PUSH_CHANNEL_OPTIONS = (
  Object.keys(PUSH_CHANNEL_LABELS) as PushChannel[]
).map((value) => ({ value, label: PUSH_CHANNEL_LABELS[value] }));

export function asPushChannel(value: string): PushChannel {
  return value === "dingtalk" ? "dingtalk" : "wecom";
}

/** 短信服务商（services-sms.md：阿里云/腾讯云预设） */
export type SmsProvider = "aliyun" | "tencent";

export const SMS_PROVIDER_LABELS: Record<SmsProvider, string> = {
  aliyun: "阿里云",
  tencent: "腾讯云",
};

export const SMS_PROVIDER_OPTIONS = (
  Object.keys(SMS_PROVIDER_LABELS) as SmsProvider[]
).map((value) => ({ value, label: SMS_PROVIDER_LABELS[value] }));

export function asSmsProvider(value: string): SmsProvider {
  return value === "tencent" ? "tencent" : "aliyun";
}

/** 短信模板登记状态（system_sms_templates.status；服务商后台模板状态另行维护） */
export type SmsTemplateStatus = "active" | "disabled";

export const SMS_TEMPLATE_STATUS_LABELS: Record<SmsTemplateStatus, string> = {
  active: "启用",
  disabled: "停用",
};

export const SMS_TEMPLATE_STATUS_BADGE_CLASSES: Record<
  SmsTemplateStatus,
  string
> = {
  active:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  disabled:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
};

export const SMS_TEMPLATE_STATUS_OPTIONS = (
  Object.keys(SMS_TEMPLATE_STATUS_LABELS) as SmsTemplateStatus[]
).map((value) => ({ value, label: SMS_TEMPLATE_STATUS_LABELS[value] }));

export function asSmsTemplateStatus(value: string): SmsTemplateStatus {
  return value === "disabled" ? "disabled" : "active";
}

/* -------------------------------------------------------------------------- */
/* 字典读取层（system/010）：get_dict 优先、编译期常量兜底                        */
/* -------------------------------------------------------------------------- */

/** common.status 编译期兜底：与 system/009 seed（system_dictionaries）逐字一致 */
export const COMMON_STATUS_LABELS: Record<string, string> = {
  active: "启用",
  disabled: "停用",
  deleted: "已删除",
};

export const COMMON_STATUS_BADGE_CLASSES: Record<string, string> = {
  active:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  disabled:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
  deleted:
    "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300",
};

/** common.yesno 编译期兜底：与 system/009 seed 逐字一致 */
export const COMMON_YESNO_LABELS: Record<string, string> = {
  yes: "是",
  no: "否",
};

export const COMMON_YESNO_BADGE_CLASSES: Record<string, string> = {
  yes: "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  no: "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
};

/** 已登记的共享字典 key（dictionaries.md：前端引用 dict_key，运行时取数） */
export const DICTIONARY_KEYS = {
  commonStatus: "common.status",
  commonYesno: "common.yesno",
} as const;

export type DictionaryKey =
  (typeof DICTIONARY_KEYS)[keyof typeof DICTIONARY_KEYS];

/** get_dict 单项（仅消费 label / color_class；结构对齐 RPC 返回） */
export type DictionaryItem = {
  value: string;
  label: string;
  sort_order: number;
  color_class: string | null;
  status: string;
};

type DictionarySnapshot = Record<DictionaryKey, DictionaryItem[]>;

const DICTIONARY_TTL_MS = 60_000;

function toFallbackItems(
  labels: Record<string, string>,
  badgeClasses: Record<string, string>,
): DictionaryItem[] {
  return Object.entries(labels).map(([value, label], index) => ({
    value,
    label,
    sort_order: (index + 1) * 10,
    color_class: badgeClasses[value] ?? null,
    status: "active",
  }));
}

/** 编译期默认快照（加载前/失败时渲染，不阻塞首屏） */
export const DEFAULT_DICTIONARIES: DictionarySnapshot = {
  "common.status": toFallbackItems(
    COMMON_STATUS_LABELS,
    COMMON_STATUS_BADGE_CLASSES,
  ),
  "common.yesno": toFallbackItems(COMMON_YESNO_LABELS, COMMON_YESNO_BADGE_CLASSES),
};

let dictionarySnapshot: DictionarySnapshot | null = null;
let dictionaryLoadedAt = 0;
let dictionaryInflight: Promise<DictionarySnapshot> | null = null;

function parseDictionaryRows(data: unknown): DictionaryItem[] {
  if (!Array.isArray(data)) {
    return [];
  }
  const items: DictionaryItem[] = [];
  for (const raw of data) {
    if (raw === null || typeof raw !== "object") {
      continue;
    }
    const row = raw as Record<string, unknown>;
    if (typeof row.value !== "string" || typeof row.label !== "string") {
      continue;
    }
    items.push({
      value: row.value,
      label: row.label,
      sort_order: typeof row.sort_order === "number" ? row.sort_order : 0,
      color_class: typeof row.color_class === "string" ? row.color_class : null,
      status: typeof row.status === "string" ? row.status : "active",
    });
  }
  return items;
}

/** DB 行合并覆盖编译期默认：同 value 覆盖 label/排序/配色，DB 独有项追加 */
function mergeDictionaryItems(
  key: DictionaryKey,
  rows: DictionaryItem[],
): DictionaryItem[] {
  if (rows.length === 0) {
    return DEFAULT_DICTIONARIES[key];
  }
  const byValue = new Map<string, DictionaryItem>();
  for (const item of DEFAULT_DICTIONARIES[key]) {
    byValue.set(item.value, item);
  }
  for (const item of rows) {
    byValue.set(item.value, item);
  }
  return Array.from(byValue.values()).sort((a, b) => {
    if (a.sort_order !== b.sort_order) {
      return a.sort_order - b.sort_order;
    }
    return a.value.localeCompare(b.value);
  });
}

/**
 * 加载共享字典（受 TTL 60s 缓存与并发去重约束）。
 * 首选 get_dict RPC（仅 active 项）；失败或缺失的 key 回退编译期默认值，不抛出。
 * 客户端调用（(admin)/layout 挂载的 DictionariesLoader）；首屏先用默认值渲染。
 */
export async function loadDictionaries(options?: {
  force?: boolean;
}): Promise<DictionarySnapshot> {
  const ttl = options?.force ? 0 : DICTIONARY_TTL_MS;
  if (dictionarySnapshot && Date.now() - dictionaryLoadedAt < ttl) {
    return dictionarySnapshot;
  }
  if (dictionaryInflight) {
    return dictionaryInflight;
  }

  dictionaryInflight = (async () => {
    try {
      const { createClient } = await import("@/lib/supabase/client");
      const supabase = createClient();
      const keys = Object.values(DICTIONARY_KEYS) as DictionaryKey[];
      const results = await Promise.all(
        keys.map(async (key) => {
          const { data, error } = await supabase.rpc("get_dict", {
            p_dict_key: key,
          });
          return [key, error ? [] : parseDictionaryRows(data)] as const;
        }),
      );

      const next: DictionarySnapshot = { ...DEFAULT_DICTIONARIES };
      for (const [key, rows] of results) {
        next[key] = mergeDictionaryItems(key, rows);
      }
      dictionarySnapshot = next;
      dictionaryLoadedAt = Date.now();
      return next;
    } catch (error) {
      console.warn("共享字典加载失败，已回退编译期默认值：", error);
      return dictionarySnapshot ?? DEFAULT_DICTIONARIES;
    } finally {
      dictionaryInflight = null;
    }
  })();

  return dictionaryInflight;
}

/** 读取某字典全部项（未加载时返回默认值） */
export function getDictionaryItems(key: DictionaryKey): DictionaryItem[] {
  return (dictionarySnapshot ?? DEFAULT_DICTIONARIES)[key];
}

function findDictionaryItem(
  key: DictionaryKey,
  value: string,
): DictionaryItem | undefined {
  return getDictionaryItems(key).find((item) => item.value === value);
}

/** common.status 文案（未加载/未命中回退编译期常量） */
export function getCommonStatusLabel(value: string): string {
  return (
    findDictionaryItem(DICTIONARY_KEYS.commonStatus, value)?.label ??
    COMMON_STATUS_LABELS[value] ??
    value
  );
}

/** common.status Badge 配色（未加载/未命中回退编译期常量） */
export function getCommonStatusBadgeClass(value: string): string {
  return (
    findDictionaryItem(DICTIONARY_KEYS.commonStatus, value)?.color_class ??
    COMMON_STATUS_BADGE_CLASSES[value] ??
    ""
  );
}

/** common.yesno 文案（未加载/未命中回退编译期常量） */
export function getCommonYesnoLabel(value: string): string {
  return (
    findDictionaryItem(DICTIONARY_KEYS.commonYesno, value)?.label ??
    COMMON_YESNO_LABELS[value] ??
    value
  );
}

/** common.yesno Badge 配色（未加载/未命中回退编译期常量） */
export function getCommonYesnoBadgeClass(value: string): string {
  return (
    findDictionaryItem(DICTIONARY_KEYS.commonYesno, value)?.color_class ??
    COMMON_YESNO_BADGE_CLASSES[value] ??
    ""
  );
}
