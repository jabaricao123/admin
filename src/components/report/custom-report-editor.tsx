"use client";

// 报表中心 · 自定义报表三步编辑器（report/004）
// ① 数据源（report_allowed_views 白名单 Select + 可用列清单）→
// ② 字段（维度多选 / 度量 列+聚合 / 筛选 列+操作符+值）→
// ③ 图表类型（table/bar/line/pie）+ 配置摘要与保存。
// 保存走 save_report_definition（服务端白名单二次校验，前端校验只为体验）。

import * as React from "react";
import {
  BarChart3Icon,
  LineChartIcon,
  Loader2Icon,
  PieChartIcon,
  PlusIcon,
  SaveIcon,
  TableIcon,
  Trash2Icon,
} from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Field,
  FieldDescription,
  FieldLabel,
} from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetFooter,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import type { Database } from "@/lib/database.types";
import {
  allowedViewColumns,
  isNumericType,
  isTemporalType,
  parseReportDefinition,
  REPORT_AGG_OPTIONS,
  REPORT_CHART_LABELS,
  REPORT_FILTER_OP_OPTIONS,
  reportConfigSummary,
  translateReportErrorMessage,
  type AllowedView,
  type ReportAgg,
  type ReportChartType,
  type ReportConfig,
  type ReportDefinition,
  type ReportFilterOp,
} from "@/lib/report";
import { createClient } from "@/lib/supabase/client";

type SaveReportArgs =
  Database["public"]["Functions"]["save_report_definition"]["Args"];

type DraftMetric = { column: string; agg: ReportAgg };

type DraftFilter = {
  column: string;
  op: ReportFilterOp;
  value: string;
  value2: string;
};

const STEPS = [
  { value: 1, label: "数据源" },
  { value: 2, label: "字段" },
  { value: 3, label: "图表" },
] as const;

const CHART_ICONS: Record<ReportChartType, typeof TableIcon> = {
  table: TableIcon,
  bar: BarChart3Icon,
  line: LineChartIcon,
  pie: PieChartIcon,
};

function filterToDraft(filter: ReportConfig["filters"][number]): DraftFilter {
  if (filter.op === "between" && Array.isArray(filter.value)) {
    return {
      column: filter.column,
      op: filter.op,
      value: String(filter.value[0] ?? ""),
      value2: String(filter.value[1] ?? ""),
    };
  }
  if (filter.op === "in" && Array.isArray(filter.value)) {
    return {
      column: filter.column,
      op: filter.op,
      value: filter.value.map((item) => String(item)).join(", "),
      value2: "",
    };
  }
  return {
    column: filter.column,
    op: filter.op,
    value: filter.value === null || filter.value === undefined ? "" : String(filter.value),
    value2: "",
  };
}

export function CustomReportEditor({
  open,
  onOpenChange,
  definition,
  allowedViews,
  onSaved,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** null = 新建 */
  definition: ReportDefinition | null;
  allowedViews: AllowedView[];
  onSaved: () => void;
}) {
  const [step, setStep] = React.useState<1 | 2 | 3>(1);
  const [name, setName] = React.useState("");
  const [sourceView, setSourceView] = React.useState("");
  const [dimensions, setDimensions] = React.useState<string[]>([]);
  const [metrics, setMetrics] = React.useState<DraftMetric[]>([]);
  const [filters, setFilters] = React.useState<DraftFilter[]>([]);
  const [chart, setChart] = React.useState<ReportChartType>("table");
  const [saving, setSaving] = React.useState(false);

  // 打开/切换编辑对象时重置表单
  React.useEffect(() => {
    if (!open) {
      return;
    }
    const config = definition?.config;
    setName(definition?.name ?? "");
    setSourceView(definition?.source_view ?? "");
    setDimensions(config?.dimensions ?? []);
    setMetrics(
      config?.metrics.map((metric) => ({
        column: metric.column,
        agg: metric.agg,
      })) ?? [],
    );
    setFilters(config?.filters.map(filterToDraft) ?? []);
    setChart(config?.chart ?? "table");
    setStep(1);
    setSaving(false);
  }, [open, definition]);

  const currentView = allowedViews.find(
    (view) => view.view_name === sourceView,
  );
  const columns = currentView ? allowedViewColumns(currentView) : [];
  const numericColumns = columns.filter((column) => isNumericType(column.type));
  const sourceOptions = React.useMemo(() => {
    if (sourceView && !allowedViews.some((v) => v.view_name === sourceView)) {
      return [
        ...allowedViews,
        { view_name: sourceView, allowed_columns: {} as Record<string, string> },
      ];
    }
    return allowedViews;
  }, [allowedViews, sourceView]);

  const columnType = (columnName: string) =>
    columns.find((column) => column.name === columnName)?.type;

  const handleSourceChange = (value: string) => {
    setSourceView(value);
    setDimensions([]);
    setMetrics([]);
    setFilters([]);
  };

  const toggleDimension = (columnName: string, checked: boolean) => {
    setDimensions((prev) =>
      checked
        ? [...prev, columnName]
        : prev.filter((item) => item !== columnName),
    );
  };

  const metricColumnOptions = (agg: ReportAgg) =>
    agg === "count" ? columns : numericColumns;

  const updateMetric = (index: number, patch: Partial<DraftMetric>) => {
    setMetrics((prev) =>
      prev.map((metric, i) => (i === index ? { ...metric, ...patch } : metric)),
    );
  };

  const handleMetricAggChange = (index: number, agg: ReportAgg) => {
    setMetrics((prev) =>
      prev.map((metric, i) => {
        if (i !== index) {
          return metric;
        }
        const options = metricColumnOptions(agg);
        const keep = options.some((option) => option.name === metric.column);
        return {
          agg,
          column: keep ? metric.column : (options[0]?.name ?? ""),
        };
      }),
    );
  };

  const updateFilter = (index: number, patch: Partial<DraftFilter>) => {
    setFilters((prev) =>
      prev.map((filter, i) => (i === index ? { ...filter, ...patch } : filter)),
    );
  };

  const handleFilterColumnChange = (index: number, column: string) => {
    setFilters((prev) =>
      prev.map((filter, i) =>
        i === index ? { ...filter, column, value: "", value2: "" } : filter,
      ),
    );
  };

  const handleFilterOpChange = (index: number, op: ReportFilterOp) => {
    setFilters((prev) =>
      prev.map((filter, i) =>
        i === index ? { ...filter, op, value: "", value2: "" } : filter,
      ),
    );
  };

  /** 组装并校验 config；非法时定位到对应步骤并返回 null */
  const buildConfig = (): ReportConfig | null => {
    const fail = (message: string, target: 1 | 2 | 3) => {
      setStep(target);
      toast.error(message);
      return null;
    };

    if (!name.trim()) {
      return fail("请填写报表名称", 1);
    }
    if (!sourceView) {
      return fail("请选择数据源", 1);
    }
    if (dimensions.length === 0 && metrics.length === 0) {
      return fail("至少需要一个维度或度量", 2);
    }
    if (metrics.some((metric) => !metric.column)) {
      return fail("请为每个度量选择列", 2);
    }
    const aliases = metrics.map(
      (metric) => `${metric.agg}_${metric.column}`,
    );
    if (new Set(aliases).size !== aliases.length) {
      return fail("存在重复度量（聚合方式与列相同）", 2);
    }

    const built: ReportConfig = {
      dimensions,
      metrics: metrics.map((metric) => ({ ...metric })),
      filters: [],
      chart,
    };

    for (const filter of filters) {
      if (!filter.column) {
        return fail("请为筛选条件选择列", 2);
      }
      if (filter.op === "between") {
        if (!filter.value.trim() || !filter.value2.trim()) {
          return fail("between 筛选需要同时填写起始与结束值", 2);
        }
        built.filters.push({
          column: filter.column,
          op: "between",
          value: [filter.value.trim(), filter.value2.trim()],
        });
      } else if (filter.op === "in") {
        const values = filter.value
          .split(/[,，]/)
          .map((item) => item.trim())
          .filter(Boolean);
        if (values.length === 0) {
          return fail("in 筛选至少填写一个值（逗号分隔）", 2);
        }
        built.filters.push({ column: filter.column, op: "in", value: values });
      } else {
        if (!filter.value.trim()) {
          return fail("筛选值不能为空", 2);
        }
        built.filters.push({
          column: filter.column,
          op: filter.op,
          value: filter.value.trim(),
        });
      }
    }

    return built;
  };

  const handleSave = async () => {
    const config = buildConfig();
    if (!config) {
      return;
    }

    setSaving(true);
    const { data, error } = await createClient().rpc("save_report_definition", {
      p_id: definition?.id ?? null,
      p_name: name.trim(),
      p_source_view: sourceView,
      p_config: config,
    } as unknown as SaveReportArgs);
    setSaving(false);

    if (error) {
      toast.error(translateReportErrorMessage(error.message));
      return;
    }

    toast.success(definition ? "报表已保存" : "报表已创建");
    if (data) {
      // 触发一次解析校验（结构异常时 parseReportDefinition 会降级而非抛错）
      parseReportDefinition(data);
    }
    onSaved();
  };

  const canJump = (target: 1 | 2 | 3) =>
    target === 1 || (target >= 2 && sourceView !== "");

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent
        side="right"
        className="w-full sm:max-w-[480px]"
      >
        <SheetHeader>
          <SheetTitle>{definition ? "编辑报表" : "新建报表"}</SheetTitle>
          <SheetDescription>
            三步配置：选数据源 → 配字段 → 选图表；标识符仅限白名单列，筛选值参数化执行。
          </SheetDescription>
        </SheetHeader>

        <div className="flex items-center gap-1 px-4">
          {STEPS.map((item, index) => (
            <React.Fragment key={item.value}>
              {index > 0 ? <div className="h-px flex-1 bg-border" /> : null}
              <button
                type="button"
                onClick={() => canJump(item.value) && setStep(item.value)}
                disabled={!canJump(item.value)}
                className={
                  "flex items-center gap-1.5 rounded-md px-2 py-1 text-xs transition-colors " +
                  (step === item.value
                    ? "bg-accent text-accent-foreground"
                    : canJump(item.value)
                      ? "text-muted-foreground hover:text-foreground"
                      : "text-muted-foreground/50")
                }
              >
                <span
                  className={
                    "flex size-4.5 items-center justify-center rounded-full border text-[10px] " +
                    (step === item.value
                      ? "border-primary bg-primary text-primary-foreground"
                      : "border-input")
                  }
                >
                  {item.value}
                </span>
                {item.label}
              </button>
            </React.Fragment>
          ))}
        </div>

        <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-4">
          {step === 1 ? (
            <>
              <Field>
                <FieldLabel htmlFor="report-name">报表名称</FieldLabel>
                <Input
                  id="report-name"
                  value={name}
                  onChange={(event) => setName(event.target.value)}
                  placeholder="如：各部门人数"
                  maxLength={80}
                />
              </Field>
              <Field>
                <FieldLabel htmlFor="report-source">数据源</FieldLabel>
                <Select value={sourceView} onValueChange={handleSourceChange}>
                  <SelectTrigger id="report-source" className="w-full">
                    <SelectValue placeholder="请选择白名单视图" />
                  </SelectTrigger>
                  <SelectContent>
                    {sourceOptions.map((view) => (
                      <SelectItem
                        key={view.view_name}
                        value={view.view_name}
                        disabled={
                          !allowedViews.some(
                            (item) => item.view_name === view.view_name,
                          )
                        }
                      >
                        {view.view_name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <FieldDescription>
                  数据源来自 report_allowed_views 白名单；选后展示可用列。
                </FieldDescription>
              </Field>

              {currentView ? (
                <div className="flex flex-col gap-2">
                  <div className="text-xs font-medium text-muted-foreground">
                    可用列（{columns.length}）
                  </div>
                  <div className="flex max-h-56 flex-wrap gap-1.5 overflow-y-auto rounded-lg border p-3">
                    {columns.map((column) => (
                      <Badge key={column.name} variant="outline" className="font-normal">
                        {column.name}
                        <span className="text-muted-foreground">
                          {column.type}
                        </span>
                      </Badge>
                    ))}
                  </div>
                </div>
              ) : null}
            </>
          ) : null}

          {step === 2 ? (
            <>
              <div className="flex flex-col gap-2">
                <div className="text-sm font-medium">维度（多选）</div>
                {columns.length === 0 ? (
                  <p className="text-xs text-muted-foreground">该数据源没有可用列</p>
                ) : (
                  <div className="flex max-h-44 flex-col gap-1.5 overflow-y-auto rounded-lg border p-2">
                    {columns.map((column) => (
                      <label
                        key={column.name}
                        className="flex cursor-pointer items-center gap-2 rounded-md px-2 py-1.5 text-sm hover:bg-muted/60"
                      >
                        <Checkbox
                          checked={dimensions.includes(column.name)}
                          onCheckedChange={(checked) =>
                            toggleDimension(column.name, checked === true)
                          }
                          aria-label={`维度 ${column.name}`}
                        />
                        <span>{column.name}</span>
                        <span className="ml-auto text-xs text-muted-foreground">
                          {column.type}
                        </span>
                      </label>
                    ))}
                  </div>
                )}
              </div>

              <div className="flex flex-col gap-2">
                <div className="flex items-center justify-between">
                  <div className="text-sm font-medium">度量</div>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    onClick={() =>
                      setMetrics((prev) => [
                        ...prev,
                        {
                          column: columns[0]?.name ?? "",
                          agg: "count",
                        },
                      ])
                    }
                    disabled={columns.length === 0}
                  >
                    <PlusIcon data-icon="inline-start" />
                    添加度量
                  </Button>
                </div>
                {metrics.length === 0 ? (
                  <p className="text-xs text-muted-foreground">
                    未添加度量：仅按维度列出行；图表需至少一个度量。
                  </p>
                ) : (
                  <div className="flex flex-col gap-2">
                    {metrics.map((metric, index) => (
                      <div
                        key={index}
                        className="grid grid-cols-[1fr_1fr_auto] items-center gap-2"
                      >
                        <Select
                          value={metric.column}
                          onValueChange={(value) =>
                            updateMetric(index, { column: value })
                          }
                        >
                          <SelectTrigger
                            className="w-full"
                            aria-label="度量列"
                          >
                            <SelectValue placeholder="列" />
                          </SelectTrigger>
                          <SelectContent>
                            {metricColumnOptions(metric.agg).map((column) => (
                              <SelectItem key={column.name} value={column.name}>
                                {column.name}
                              </SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                        <Select
                          value={metric.agg}
                          onValueChange={(value) =>
                            handleMetricAggChange(index, value as ReportAgg)
                          }
                        >
                          <SelectTrigger className="w-full" aria-label="聚合方式">
                            <SelectValue />
                          </SelectTrigger>
                          <SelectContent>
                            {REPORT_AGG_OPTIONS.map((option) => (
                              <SelectItem key={option.value} value={option.value}>
                                {option.label}
                              </SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon-sm"
                          aria-label="删除度量"
                          onClick={() =>
                            setMetrics((prev) =>
                              prev.filter((_, i) => i !== index),
                            )
                          }
                        >
                          <Trash2Icon />
                        </Button>
                      </div>
                    ))}
                    <FieldDescription>
                      sum / avg 仅数值列可选，由服务端白名单校验兜底。
                    </FieldDescription>
                  </div>
                )}
              </div>

              <div className="flex flex-col gap-2">
                <div className="flex items-center justify-between">
                  <div className="text-sm font-medium">筛选条件</div>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    onClick={() =>
                      setFilters((prev) => [
                        ...prev,
                        {
                          column: columns[0]?.name ?? "",
                          op: "=",
                          value: "",
                          value2: "",
                        },
                      ])
                    }
                    disabled={columns.length === 0}
                  >
                    <PlusIcon data-icon="inline-start" />
                    添加筛选
                  </Button>
                </div>
                {filters.length === 0 ? (
                  <p className="text-xs text-muted-foreground">
                    无筛选条件：查询该数据源当前账号可见的全部记录。
                  </p>
                ) : (
                  <div className="flex flex-col gap-2">
                    {filters.map((filter, index) => {
                      const type = columnType(filter.column);
                      const temporal = isTemporalType(type);
                      return (
                        <div
                          key={index}
                          className="flex flex-col gap-2 rounded-lg border p-3"
                        >
                          <div className="flex items-center gap-2">
                            <Select
                              value={filter.column}
                              onValueChange={(value) =>
                                handleFilterColumnChange(index, value)
                              }
                            >
                              <SelectTrigger
                                className="flex-1"
                                aria-label="筛选列"
                              >
                                <SelectValue placeholder="列" />
                              </SelectTrigger>
                              <SelectContent>
                                {columns.map((column) => (
                                  <SelectItem
                                    key={column.name}
                                    value={column.name}
                                  >
                                    {column.name}
                                  </SelectItem>
                                ))}
                              </SelectContent>
                            </Select>
                            <Select
                              value={filter.op}
                              onValueChange={(value) =>
                                handleFilterOpChange(
                                  index,
                                  value as ReportFilterOp,
                                )
                              }
                            >
                              <SelectTrigger
                                className="w-32"
                                aria-label="筛选操作符"
                              >
                                <SelectValue />
                              </SelectTrigger>
                              <SelectContent>
                                {REPORT_FILTER_OP_OPTIONS.map((option) => (
                                  <SelectItem
                                    key={option.value}
                                    value={option.value}
                                  >
                                    {option.label}
                                  </SelectItem>
                                ))}
                              </SelectContent>
                            </Select>
                            <Button
                              type="button"
                              variant="ghost"
                              size="icon-sm"
                              aria-label="删除筛选条件"
                              onClick={() =>
                                setFilters((prev) =>
                                  prev.filter((_, i) => i !== index),
                                )
                              }
                            >
                              <Trash2Icon />
                            </Button>
                          </div>

                          {filter.op === "between" ? (
                            <div className="flex items-center gap-2">
                              <Input
                                type={
                                  type === "date"
                                    ? "date"
                                    : temporal
                                      ? "datetime-local"
                                      : "text"
                                }
                                value={filter.value}
                                onChange={(event) =>
                                  updateFilter(index, {
                                    value: event.target.value,
                                  })
                                }
                                aria-label="区间起始值"
                                placeholder="起始值"
                              />
                              <span className="text-muted-foreground">～</span>
                              <Input
                                type={
                                  type === "date"
                                    ? "date"
                                    : temporal
                                      ? "datetime-local"
                                      : "text"
                                }
                                value={filter.value2}
                                onChange={(event) =>
                                  updateFilter(index, {
                                    value2: event.target.value,
                                  })
                                }
                                aria-label="区间结束值"
                                placeholder="结束值"
                              />
                            </div>
                          ) : (
                            <Input
                              value={filter.value}
                              onChange={(event) =>
                                updateFilter(index, { value: event.target.value })
                              }
                              aria-label="筛选值"
                              placeholder={
                                filter.op === "in"
                                  ? "多个值用逗号分隔，如 1,2,3"
                                  : filter.op === "like"
                                    ? "包含关键词，如 总部%"
                                    : "筛选值"
                              }
                            />
                          )}
                        </div>
                      );
                    })}
                  </div>
                )}
              </div>
            </>
          ) : null}

          {step === 3 ? (
            <>
              <div className="flex flex-col gap-2">
                <div className="text-sm font-medium">图表类型</div>
                <ToggleGroup
                  type="single"
                  value={chart}
                  onValueChange={(value) => {
                    if (value) {
                      setChart(value as ReportChartType);
                    }
                  }}
                  variant="outline"
                  className="grid w-full grid-cols-2 gap-2"
                  aria-label="图表类型"
                >
                  {(Object.keys(CHART_ICONS) as ReportChartType[]).map(
                    (value) => {
                      const Icon = CHART_ICONS[value];
                      return (
                        <ToggleGroupItem
                          key={value}
                          value={value}
                          className="h-11 gap-2"
                        >
                          <Icon className="size-4" />
                          {REPORT_CHART_LABELS[value]}
                        </ToggleGroupItem>
                      );
                    },
                  )}
                </ToggleGroup>
                <FieldDescription>
                  饼图取第一个度量；移动端预览与详情自动降级为表格。
                </FieldDescription>
              </div>

              <div className="rounded-lg border p-3 text-xs text-muted-foreground">
                配置摘要：{reportConfigSummary({
                  dimensions,
                  metrics,
                  filters: buildConfigSummaryFilters(filters),
                  chart,
                })}
              </div>

              <FieldDescription>
                保存后回到列表，点击报表名称进入详情执行 run_report（按你的权限过滤数据）。
              </FieldDescription>
            </>
          ) : null}
        </div>

        <SheetFooter className="flex-row justify-end gap-2">
          {step > 1 ? (
            <Button
              variant="outline"
              onClick={() => setStep((prev) => (prev - 1) as 1 | 2 | 3)}
            >
              上一步
            </Button>
          ) : (
            <Button
              variant="outline"
              className="h-8"
              onClick={() => onOpenChange(false)}
            >
              取消
            </Button>
          )}
          {step < 3 ? (
            <Button
              onClick={() => setStep((prev) => (prev + 1) as 1 | 2 | 3)}
              disabled={step === 1 && sourceView === ""}
            >
              下一步
            </Button>
          ) : (
            <Button
              onClick={() => void handleSave()}
              disabled={saving}
              className="h-8"
            >
              {saving ? (
                <Loader2Icon className="size-3.5 animate-spin" data-icon="inline-start" />
              ) : (
                <SaveIcon className="size-3.5" data-icon="inline-start" />
              )}
              保存报表
            </Button>
          )}
        </SheetFooter>
      </SheetContent>
    </Sheet>
  );
}

/** 摘要预览的筛选计数占位（沿用 reportConfigSummary 的「筛选：N 项」语义） */
function buildConfigSummaryFilters(filters: DraftFilter[]): ReportConfig["filters"] {
  return filters.map((filter) => ({
    column: filter.column,
    op: filter.op,
    value: "",
  }));
}
