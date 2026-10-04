// 报表中心共享工具（report/004 + report/008）：
// 自定义报表配置的类型/解析/文案，导出任务状态与来源字典，CSV 下载命名等。
// 供 /report/custom 与 /report/exports 页面复用；不依赖 React，可在客户端/服务端组件中使用。

import type { Json } from "@/lib/database.types";
import { formatDateTime, isPlainObject } from "@/lib/audit";
import {
  EXPORT_SOURCE_LABELS,
  EXPORT_STATUS_BADGE_CLASSES,
  EXPORT_STATUS_LABELS,
  REPORT_AGG_LABELS,
  REPORT_CHART_LABELS,
  REPORT_FILTER_OP_LABELS,
  REPORT_VISIBILITY_BADGE_CLASSES,
  REPORT_VISIBILITY_LABELS,
  translateErrorMessage,
  type ExportStatus,
  type ReportAgg,
  type ReportChartType,
  type ReportFilterOp,
  type ReportVisibility,
} from "@/lib/dictionaries";

// 报表枚举的文案与 Badge 配色集中维护在 @/lib/dictionaries（DESIGN §4.6），
// 此处转出便于报表页面单点引入；类型同样转出。
export type {
  ExportStatus,
  ReportAgg,
  ReportChartType,
  ReportFilterOp,
  ReportVisibility,
};
export {
  EXPORT_SOURCE_LABELS,
  EXPORT_STATUS_BADGE_CLASSES,
  EXPORT_STATUS_LABELS,
  REPORT_AGG_LABELS,
  REPORT_CHART_LABELS,
  REPORT_FILTER_OP_LABELS,
  REPORT_VISIBILITY_BADGE_CLASSES,
  REPORT_VISIBILITY_LABELS,
};

/* -------------------------------------------------------------------------- */
/* 1. 自定义报表：配置类型与解析                                              */
/* -------------------------------------------------------------------------- */

export type ReportMetric = { column: string; agg: ReportAgg };
export type ReportFilter = { column: string; op: ReportFilterOp; value: Json };

/** run_report 的 config 契约（docs/modules/report/custom.md） */
export type ReportConfig = {
  dimensions: string[];
  metrics: ReportMetric[];
  filters: ReportFilter[];
  chart: ReportChartType;
};

/** 列表/详情使用的定义（config 已解析为强类型） */
export type ReportDefinition = {
  id: string;
  name: string;
  source_view: string;
  config: ReportConfig;
  visibility: ReportVisibility;
  owner_id: string;
  updated_at: string;
};

/** run_report 返回值：{columns, rows, chart} */
export type ReportRunResult = {
  columns: string[];
  rows: Array<Record<string, Json>>;
  chart: ReportChartType;
};

/** report_allowed_views 单行（allowed_columns = {"列名":"PG 类型"}） */
export type AllowedView = {
  view_name: string;
  allowed_columns: Record<string, string>;
};

export const REPORT_CHART_TYPES: ReportChartType[] = [
  "table",
  "bar",
  "line",
  "pie",
];

export const REPORT_AGG_OPTIONS = (
  Object.keys(REPORT_AGG_LABELS) as ReportAgg[]
).map((value) => ({ value, label: REPORT_AGG_LABELS[value] }));

export const REPORT_FILTER_OP_OPTIONS = (
  Object.keys(REPORT_FILTER_OP_LABELS) as ReportFilterOp[]
).map((value) => ({ value, label: REPORT_FILTER_OP_LABELS[value] }));

const NUMERIC_TYPES = ["integer", "bigint", "numeric", "double precision"];
const TEMPORAL_TYPES = ["date", "timestamptz"];

/** 数值列（sum/avg 仅数值列可用，与 app.validate_report_config 对齐） */
export function isNumericType(type: string | undefined): boolean {
  return type !== undefined && NUMERIC_TYPES.includes(type);
}

/** 时间列（between 用日期/时间选择器） */
export function isTemporalType(type: string | undefined): boolean {
  return type !== undefined && TEMPORAL_TYPES.includes(type);
}

/** 度量别名（与 run_report 的 <agg>_<column> 约定一致） */
export function metricAlias(metric: ReportMetric): string {
  return `${metric.agg}_${metric.column}`;
}

/** 度量展示名：如「求和（depth）」 */
export function metricLabel(metric: ReportMetric): string {
  return `${REPORT_AGG_LABELS[metric.agg]}（${metric.column}）`;
}

/** 宽松解析 config（直接改库/历史数据不炸前端），非法项丢弃 */
export function parseReportConfig(value: Json | null | undefined): ReportConfig {
  const fallback: ReportConfig = {
    dimensions: [],
    metrics: [],
    filters: [],
    chart: "table",
  };
  if (!isPlainObject(value)) {
    return fallback;
  }

  const dimensions = Array.isArray(value.dimensions)
    ? value.dimensions.filter(
        (item): item is string => typeof item === "string" && item.trim() !== "",
      )
    : [];

  const metrics = Array.isArray(value.metrics)
    ? value.metrics.flatMap((item) => {
        if (!isPlainObject(item)) {
          return [];
        }
        const column = typeof item.column === "string" ? item.column : "";
        const agg: ReportAgg =
          item.agg === "sum" || item.agg === "avg" || item.agg === "count"
            ? item.agg
            : "count";
        return column ? [{ column, agg }] : [];
      })
    : [];

  const filters = Array.isArray(value.filters)
    ? value.filters.flatMap((item) => {
        if (!isPlainObject(item)) {
          return [];
        }
        const column = typeof item.column === "string" ? item.column : "";
        const op: ReportFilterOp =
          item.op === "in" || item.op === "between" || item.op === "like"
            ? item.op
            : "=";
        if (!column) {
          return [];
        }
        return [{ column, op, value: (item.value ?? "") as Json }];
      })
    : [];

  const chart: ReportChartType = REPORT_CHART_TYPES.includes(
    value.chart as ReportChartType,
  )
    ? (value.chart as ReportChartType)
    : "table";

  return { dimensions, metrics, filters, chart };
}

export function parseReportDefinition(row: {
  id: string;
  name: string;
  source_view: string;
  config: Json;
  visibility: string;
  owner_id: string;
  updated_at: string;
}): ReportDefinition {
  return {
    id: row.id,
    name: row.name,
    source_view: row.source_view,
    config: parseReportConfig(row.config),
    visibility: row.visibility === "public" ? "public" : "private",
    owner_id: row.owner_id,
    updated_at: row.updated_at,
  };
}

export function parseRunResult(value: Json | null | undefined): ReportRunResult {
  if (!isPlainObject(value)) {
    return { columns: [], rows: [], chart: "table" };
  }
  const columns = Array.isArray(value.columns)
    ? value.columns.filter((item): item is string => typeof item === "string")
    : [];
  const rows = Array.isArray(value.rows)
    ? (value.rows.filter(isPlainObject) as Array<Record<string, Json>>)
    : [];
  const chart: ReportChartType = REPORT_CHART_TYPES.includes(
    value.chart as ReportChartType,
  )
    ? (value.chart as ReportChartType)
    : "table";
  return { columns, rows, chart };
}

export function allowedViewColumns(view: AllowedView): Array<{
  name: string;
  type: string;
}> {
  return Object.entries(view.allowed_columns)
    .map(([name, type]) => ({ name, type: String(type) }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

/** 报表 RPC 错误：业务拒绝信息已中文（部分带参数），原文透传；其余走通用映射 */
export function translateReportErrorMessage(message: string): string {
  // 删除预检（delete_report_definition）的订阅引用拒绝带动态订阅数，显式列入白名单原文透传，
  // 防止后续收窄中文兜底时被二次包裹为「操作失败：…（若持续出现请联系管理员）」
  const isBusinessRule =
    /^该报表仍有 \d+ 条订阅记录（含已删除订阅），无法删除$/.test(message) ||
    /[\u4e00-\u9fa5]/.test(message);
  return isBusinessRule ? message : translateErrorMessage(message);
}

/** 配置摘要（详情/导出任务行使用）：只列结构化要点，避免 JSON 噪音 */
export function reportConfigSummary(config: ReportConfig): string {
  const parts: string[] = [];
  if (config.dimensions.length > 0) {
    parts.push(`维度：${config.dimensions.join("、")}`);
  }
  if (config.metrics.length > 0) {
    parts.push(`度量：${config.metrics.map(metricLabel).join("、")}`);
  }
  if (config.filters.length > 0) {
    parts.push(`筛选：${config.filters.length} 项`);
  }
  parts.push(`图表：${REPORT_CHART_LABELS[config.chart]}`);
  return parts.join("；");
}

/* -------------------------------------------------------------------------- */
/* 2. 数据导出：任务状态 / 来源字典 / CSV 下载                                */
/* -------------------------------------------------------------------------- */

export function exportStatusOf(status: string): ExportStatus {
  return status === "queued" ||
    status === "running" ||
    status === "done" ||
    status === "failed"
    ? status
    : "queued";
}

export function exportSourceLabel(source: string): string {
  return EXPORT_SOURCE_LABELS[source] ?? source;
}

/** 源是否为 admin 独占（config_schema.access=admin，与 request_export 校验一致） */
export function isAdminOnlySource(configSchema: Json): boolean {
  return isPlainObject(configSchema) && configSchema.access === "admin";
}

/** 导出 config 摘要：v1 仅记录条件（audit.operations 支持 start/end 时间段） */
export function exportConfigSummary(config: Json | null | undefined): string {
  if (!isPlainObject(config)) {
    return "—";
  }
  const parts: string[] = [];
  const start = config.start;
  const end = config.end;
  if (typeof start === "string" && start) {
    parts.push(`起 ${formatDateTime(start)}`);
  }
  if (typeof end === "string" && end) {
    parts.push(`止 ${formatDateTime(end)}`);
  }
  return parts.length > 0 ? parts.join(" ～ ") : "无附加条件";
}

/** 文件大小格式化（size_bytes） */
export function formatBytes(size: number | null | undefined): string {
  if (size === null || size === undefined) {
    return "—";
  }
  if (size < 1024) {
    return `${size} B`;
  }
  if (size < 1024 * 1024) {
    return `${(size / 1024).toFixed(1)} KB`;
  }
  return `${(size / 1024 / 1024).toFixed(1)} MB`;
}

/** exports.md 功能需求 3：完成后 7 天内可下载（与 download_export 校验一致） */
export function isExportExpired(createdAt: string): boolean {
  const created = new Date(createdAt).getTime();
  return Number.isNaN(created) || Date.now() - created > 7 * 24 * 60 * 60 * 1000;
}

/** CSV 下载文件名：export-<source>-<YYYY-MM-DD>.csv */
export function exportFileName(source: string, createdAt: string): string {
  const date = new Date(createdAt);
  const stamp = Number.isNaN(date.getTime())
    ? "unknown"
    : `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(
        date.getDate(),
      ).padStart(2, "0")}`;
  return `export-${source}-${stamp}.csv`;
}

/** 单用户进行中任务上限（exports.md：queued + running ≤ 3） */
export const EXPORT_ACTIVE_LIMIT = 3;

// formatDateTime 由 audit 模块提供（全站统一格式）；此处转出便于报表页面单点引入。
export { formatDateTime };
