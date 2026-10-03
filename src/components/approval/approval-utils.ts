// 审批中心页面共享工具：时间/时长格式化、来源模块文案、筛选计算。

export const APPROVAL_PAGE_SIZE = 20;

/** todo.md：等待超 48h 行加警示 Badge */
export const OVERDUE_HOURS = 48;

/** 催办节流窗口（mine.md：同单据 2 小时内仅一次） */
export const URGE_THROTTLE_MS = 2 * 60 * 60 * 1000;

/** source_module → 展示名；未知模块回退显示原始标识 */
const SOURCE_MODULE_LABELS: Record<string, string> = {
  dashboard: "工作台",
  org: "组织管理",
  access: "权限管理",
  approval: "审批中心",
  report: "报表中心",
  audit: "审计中心",
  integration: "接口集成",
  sync: "数据同步",
  system: "系统管理",
  message: "消息中心",
  demo: "演示模块",
};

export function sourceModuleLabel(module: string | null): string {
  if (!module) {
    return "—";
  }
  return SOURCE_MODULE_LABELS[module] ?? module;
}

export function formatDateTime(value: string | null | undefined): string {
  if (!value) {
    return "—";
  }
  return new Date(value).toLocaleString("zh-CN", { hour12: false });
}

function hoursSince(value: string): number {
  return (Date.now() - new Date(value).getTime()) / 3_600_000;
}

export function isOverdue48h(from: string): boolean {
  return hoursSince(from) > OVERDUE_HOURS;
}

/** 等待时长：刚刚 / N 分钟 / N 小时 M 分 / N 天 M 小时 */
export function formatWaiting(from: string): string {
  const minutes = Math.floor((Date.now() - new Date(from).getTime()) / 60_000);
  if (!Number.isFinite(minutes) || minutes < 0) {
    return "—";
  }
  if (minutes < 1) {
    return "刚刚";
  }
  if (minutes < 60) {
    return `${minutes} 分钟`;
  }
  const hours = Math.floor(minutes / 60);
  if (hours < 24) {
    const rest = minutes % 60;
    return rest > 0 ? `${hours} 小时 ${rest} 分` : `${hours} 小时`;
  }
  const days = Math.floor(hours / 24);
  const restHours = hours % 24;
  return restHours > 0 ? `${days} 天 ${restHours} 小时` : `${days} 天`;
}

/** 催办节流剩余毫秒；0 表示可催办 */
export function urgeThrottleRemainingMs(lastUrgedAt: string | null): number {
  if (!lastUrgedAt) {
    return 0;
  }
  return Math.max(
    0,
    new Date(lastUrgedAt).getTime() + URGE_THROTTLE_MS - Date.now(),
  );
}

export function formatRemaining(ms: number): string {
  const minutes = Math.ceil(ms / 60_000);
  if (minutes < 60) {
    return `${minutes} 分钟`;
  }
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  return rest > 0 ? `${hours} 小时 ${rest} 分` : `${hours} 小时`;
}

export type TimeRange = "all" | "7d" | "30d";

export const TIME_RANGE_OPTIONS: { value: TimeRange; label: string }[] = [
  { value: "all", label: "全部时间" },
  { value: "7d", label: "近 7 天" },
  { value: "30d", label: "近 30 天" },
];

export function withinTimeRange(value: string, range: TimeRange): boolean {
  if (range === "all") {
    return true;
  }
  const days = range === "7d" ? 7 : 30;
  return Date.now() - new Date(value).getTime() <= days * 24 * 3_600_000;
}
