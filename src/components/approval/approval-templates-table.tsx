"use client";

// 审批中心 · 审批模板（工单 approval/008 页面 + 009 部分：字段设计器/版本化/预览/停用）
//
// 数据：approval_form_templates（admin SELECT，RLS）+ approval_usage_counts（实例引用数）；
//       写全经管理 RPC（upsert/publish/disable/new_version，admin 校验在 DB 侧）。
// 语义：仅 draft 可编辑；published 内容冻结，「新版本」复制为 v+1 draft；
//       同 code 可同时多个 published（实例绑具体版本，发布新版不影响旧实例）；
//       停用需无进行中实例引用（服务端校验并返回实例数）。
// 交互：列表按 code 分组折叠历史版本；Sheet = 字段列表 + 属性面板 + 预览 tab。

import * as React from "react";
import {
  ArrowDownIcon,
  ArrowUpIcon,
  BanIcon,
  ChevronDownIcon,
  ChevronRightIcon,
  EyeIcon,
  FilePlus2Icon,
  FileTextIcon,
  FlaskConicalIcon,
  GitBranchIcon,
  Loader2Icon,
  PencilIcon,
  PlusIcon,
  RefreshCwIcon,
  RocketIcon,
  Trash2Icon,
} from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Checkbox } from "@/components/ui/checkbox";
import { Field, FieldDescription, FieldLabel } from "@/components/ui/field";
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
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Textarea } from "@/components/ui/textarea";
import type { Database } from "@/lib/database.types";
import { translateApprovalErrorMessage } from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";
import { cn } from "cn";

import {
  CONFIG_STATUS_BADGE_CLASSES,
  CONFIG_STATUS_LABELS,
  FIELD_TYPE_LABELS,
  FIELD_TYPE_OPTIONS,
  asConfigStatus,
  asFieldType,
  fieldsFromSchema,
  fieldsToSchema,
  newDesignerField,
  splitOptions,
  validateDesignerFields,
  type DesignerField,
} from "./approval-config-utils";
import { formatDateTime, sourceModuleLabel } from "./approval-utils";

type TemplateRow =
  Database["public"]["Tables"]["approval_form_templates"]["Row"];
type UsageRow =
  Database["public"]["Functions"]["approval_usage_counts"]["Returns"][number];

const TEMPLATE_CODE_RE = /^[a-z0-9][a-z0-9_.-]*$/;

type SheetMode = "create" | "edit" | "view";

function StatusBadge({ status }: { status: string }) {
  const value = asConfigStatus(status);
  return (
    <Badge variant="outline" className={CONFIG_STATUS_BADGE_CLASSES[value]}>
      {CONFIG_STATUS_LABELS[value]}
    </Badge>
  );
}

/** 预览 tab：按 schema 渲染只读表单样例 */
function PreviewField({ field }: { field: DesignerField }) {
  const options = splitOptions(field.options);
  return (
    <Field>
      <FieldLabel>
        {field.label || field.key || "未命名字段"}
        {field.required ? (
          <span className="text-destructive">*</span>
        ) : null}
      </FieldLabel>
      {field.type === "select" ? (
        <Select value={field.defaultValue || options[0] || ""} disabled>
          <SelectTrigger className="w-full">
            <SelectValue placeholder="（无选项）" />
          </SelectTrigger>
          <SelectContent>
            {options.map((option) => (
              <SelectItem key={option} value={option}>
                {option}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      ) : field.type === "multiselect" ? (
        options.length === 0 ? (
          <p className="text-sm text-muted-foreground">（无选项）</p>
        ) : (
          <div className="flex flex-wrap gap-3 rounded-lg border p-3">
            {options.map((option) => {
              const checked = splitOptions(field.defaultValue).includes(option);
              return (
                <label
                  key={option}
                  className="flex items-center gap-2 text-sm"
                >
                  <Checkbox checked={checked} disabled />
                  {option}
                </label>
              );
            })}
          </div>
        )
      ) : (
        <Input
          type={
            field.type === "number"
              ? "number"
              : field.type === "date"
                ? "date"
                : "text"
          }
          value={field.defaultValue}
          placeholder={field.type === "date" ? "" : "请输入"}
          disabled
        />
      )}
      <FieldDescription className="font-mono text-xs">
        {field.key} · {FIELD_TYPE_LABELS[field.type]}
        {field.required ? " · 必填" : ""}
      </FieldDescription>
    </Field>
  );
}

export function ApprovalTemplatesTable() {
  const [templates, setTemplates] = React.useState<TemplateRow[]>([]);
  const [usage, setUsage] = React.useState<UsageRow[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [expandedCodes, setExpandedCodes] = React.useState<Set<string>>(
    new Set(),
  );
  const [busyId, setBusyId] = React.useState<string | null>(null);

  // Sheet 设计器状态
  const [sheetOpen, setSheetOpen] = React.useState(false);
  const [sheetMode, setSheetMode] = React.useState<SheetMode>("create");
  const [editingId, setEditingId] = React.useState<string | null>(null);
  const [editingVersion, setEditingVersion] = React.useState<number | null>(null);
  const [activeTab, setActiveTab] = React.useState("design");
  const [formName, setFormName] = React.useState("");
  const [formCode, setFormCode] = React.useState("");
  const [formModule, setFormModule] = React.useState("");
  const [fields, setFields] = React.useState<DesignerField[]>([]);
  const [selectedFieldId, setSelectedFieldId] = React.useState<string | null>(
    null,
  );
  const [saving, setSaving] = React.useState(false);
  const [publishing, setPublishing] = React.useState(false);

  const readOnly = sheetMode === "view";

  const load = React.useCallback(async (options?: { silent?: boolean }) => {
    if (!options?.silent) {
      setLoading(true);
    }
    setError(null);
    const supabase = createClient();
    const [listResult, usageResult] = await Promise.all([
      supabase
        .from("approval_form_templates")
        .select("*")
        .order("code")
        .order("version", { ascending: false }),
      supabase.rpc("approval_usage_counts"),
    ]);
    const firstError = listResult.error ?? usageResult.error;
    if (firstError) {
      setError(firstError.message);
      setLoading(false);
      return;
    }
    setTemplates(listResult.data ?? []);
    setUsage(usageResult.data ?? []);
    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const usageByTemplate = React.useMemo(() => {
    const map = new Map<string, { total: number; running: number }>();
    for (const row of usage) {
      map.set(row.template_version_id, {
        total: Number(row.total_count),
        running: Number(row.running_count),
      });
    }
    return map;
  }, [usage]);

  const groups = React.useMemo(() => {
    const map = new Map<string, TemplateRow[]>();
    for (const row of templates) {
      const list = map.get(row.code) ?? [];
      list.push(row);
      map.set(row.code, list);
    }
    return Array.from(map.entries()).map(([code, rows]) => ({
      code,
      rows: [...rows].sort((a, b) => b.version - a.version),
    }));
  }, [templates]);

  const selectedField = React.useMemo(
    () => fields.find((field) => field.id === selectedFieldId) ?? null,
    [fields, selectedFieldId],
  );

  // -------------------------------------------------------------------------
  // 设计器操作
  // -------------------------------------------------------------------------
  const openCreate = () => {
    const starter = newDesignerField({
      key: "title",
      label: "申请标题",
      type: "text",
      required: true,
    });
    setSheetMode("create");
    setEditingId(null);
    setEditingVersion(null);
    setFormName("");
    setFormCode("");
    setFormModule("");
    setFields([starter]);
    setSelectedFieldId(starter.id);
    setActiveTab("design");
    setSheetOpen(true);
  };

  const openRow = (row: TemplateRow, mode: SheetMode) => {
    const parsed = fieldsFromSchema(row.schema);
    const initial = parsed.length > 0 ? parsed : [newDesignerField()];
    setSheetMode(mode);
    setEditingId(row.id);
    setEditingVersion(row.version);
    setFormName(row.name);
    setFormCode(row.code);
    setFormModule(row.module);
    setFields(initial);
    setSelectedFieldId(initial[0]?.id ?? null);
    setActiveTab("design");
    setSheetOpen(true);
  };

  const closeSheet = () => {
    setSheetOpen(false);
    setEditingId(null);
    setEditingVersion(null);
    setFields([]);
    setSelectedFieldId(null);
  };

  const updateField = (id: string, patch: Partial<DesignerField>) => {
    setFields((prev) =>
      prev.map((field) => (field.id === id ? { ...field, ...patch } : field)),
    );
  };

  const moveField = (index: number, delta: -1 | 1) => {
    setFields((prev) => {
      const target = index + delta;
      if (target < 0 || target >= prev.length) {
        return prev;
      }
      const next = [...prev];
      [next[index], next[target]] = [next[target], next[index]];
      return next;
    });
  };

  const addField = () => {
    const field = newDesignerField();
    setFields((prev) => [...prev, field]);
    setSelectedFieldId(field.id);
  };

  const removeField = (id: string) => {
    setFields((prev) => {
      const next = prev.filter((field) => field.id !== id);
      setSelectedFieldId((current) =>
        current === id ? (next[0]?.id ?? null) : current,
      );
      return next;
    });
  };

  /** 校验并保存草稿；成功返回保存后的行 */
  const saveDraft = React.useCallback(async (): Promise<TemplateRow | null> => {
    if (!formName.trim()) {
      toast.error("模板名称不能为空");
      return null;
    }
    if (!TEMPLATE_CODE_RE.test(formCode.trim())) {
      toast.error("code 仅允许小写字母、数字、点、下划线与连字符");
      return null;
    }
    if (!formModule.trim()) {
      toast.error("来源模块不能为空");
      return null;
    }
    const fieldError = validateDesignerFields(fields);
    if (fieldError) {
      toast.error(fieldError);
      return null;
    }

    setSaving(true);
    const supabase = createClient();
    const { data, error: saveError } = await supabase.rpc(
      "upsert_form_template",
      {
        p_name: formName.trim(),
        p_code: formCode.trim(),
        p_module: formModule.trim(),
        p_schema: fieldsToSchema(fields),
        p_id: editingId ?? undefined,
      },
    );
    setSaving(false);

    if (saveError) {
      toast.error(translateApprovalErrorMessage(saveError.message));
      return null;
    }
    setEditingId(data.id);
    setEditingVersion(data.version);
    return data;
  }, [editingId, fields, formCode, formModule, formName]);

  const handleSaveDraft = async () => {
    const saved = await saveDraft();
    if (!saved) {
      return;
    }
    toast.success(`草稿已保存（${saved.code} v${saved.version}）`);
    void load({ silent: true });
  };

  const handlePublish = async () => {
    const saved = await saveDraft();
    if (!saved) {
      return;
    }
    setPublishing(true);
    const { error: publishError } = await createClient().rpc(
      "publish_form_template",
      { p_id: saved.id },
    );
    setPublishing(false);
    if (publishError) {
      toast.error(translateApprovalErrorMessage(publishError.message));
      return;
    }
    toast.success(`已发布 ${saved.code} v${saved.version}，业务模块可提交`);
    void load({ silent: true });
  };

  const handleNewVersion = async (row: TemplateRow) => {
    if (
      !window.confirm(
        `基于 ${row.code} v${row.version} 创建 v${row.version + 1} 草稿？旧版本保持不变。`,
      )
    ) {
      return;
    }
    setBusyId(row.id);
    const { data, error: versionError } = await createClient().rpc(
      "new_form_template_version",
      { p_id: row.id },
    );
    setBusyId(null);
    if (versionError) {
      toast.error(translateApprovalErrorMessage(versionError.message));
      return;
    }
    toast.success(`已创建 v${data.version} 草稿`);
    await load({ silent: true });
    openRow(data, "edit");
  };

  const handleDisable = async (row: TemplateRow) => {
    if (
      !window.confirm(
        `停用 ${row.code} v${row.version}？停用后不可恢复；仍有进行中实例引用时会被拒绝。`,
      )
    ) {
      return;
    }
    setBusyId(row.id);
    const { error: disableError } = await createClient().rpc(
      "disable_form_template",
      { p_id: row.id },
    );
    setBusyId(null);
    if (disableError) {
      toast.error(translateApprovalErrorMessage(disableError.message));
      return;
    }
    toast.success("模板已停用");
    void load({ silent: true });
  };

  /** 列表直接发布草稿（服务端会复校 schema） */
  const handlePublishRow = async (row: TemplateRow) => {
    setBusyId(row.id);
    const { error: publishError } = await createClient().rpc(
      "publish_form_template",
      { p_id: row.id },
    );
    setBusyId(null);
    if (publishError) {
      toast.error(translateApprovalErrorMessage(publishError.message));
      return;
    }
    toast.success(`已发布 ${row.code} v${row.version}`);
    void load({ silent: true });
  };

  const toggleExpanded = (code: string) => {
    setExpandedCodes((prev) => {
      const next = new Set(prev);
      if (next.has(code)) {
        next.delete(code);
      } else {
        next.add(code);
      }
      return next;
    });
  };

  // -------------------------------------------------------------------------
  // 行操作（最新版与历史版共用）
  // -------------------------------------------------------------------------
  const renderActions = (row: TemplateRow) => {
    const status = asConfigStatus(row.status);
    const busy = busyId === row.id;
    return (
      <div className="flex flex-wrap items-center justify-end gap-1">
        {status === "draft" ? (
          <>
            <Button
              size="sm"
              variant="outline"
              className="h-9 lg:h-8"
              onClick={() => openRow(row, "edit")}
            >
              <PencilIcon data-icon="inline-start" />
              编辑
            </Button>
            <Button
              size="sm"
              variant="outline"
              className="h-9 lg:h-8"
              disabled={busy}
              onClick={() => void handlePublishRow(row)}
            >
              {busy ? (
                <Loader2Icon
                  className="animate-spin"
                  data-icon="inline-start"
                />
              ) : (
                <RocketIcon data-icon="inline-start" />
              )}
              发布
            </Button>
          </>
        ) : (
          <>
            <Button
              size="sm"
              variant="outline"
              className="h-9 lg:h-8"
              onClick={() => openRow(row, "view")}
            >
              <EyeIcon data-icon="inline-start" />
              查看
            </Button>
            <Button
              size="sm"
              variant="outline"
              className="h-9 lg:h-8"
              disabled={busy}
              onClick={() => void handleNewVersion(row)}
            >
              {busy ? (
                <Loader2Icon
                  className="animate-spin"
                  data-icon="inline-start"
                />
              ) : (
                <GitBranchIcon data-icon="inline-start" />
              )}
              新版本
            </Button>
            {status === "published" ? (
              <Button
                size="sm"
                variant="outline"
                className="h-9 lg:h-8"
                disabled={busy}
                onClick={() => void handleDisable(row)}
              >
                <BanIcon data-icon="inline-start" />
                停用
              </Button>
            ) : null}
          </>
        )}
      </div>
    );
  };

  const renderGroupRow = (row: TemplateRow, isHistory: boolean) => {
    const counts = usageByTemplate.get(row.id);
    return (
      <TableRow
        key={row.id}
        className={isHistory ? "bg-muted/40" : undefined}
      >
        <TableCell className="max-w-[220px]">
          <div className="flex items-center gap-1.5">
            {isHistory ? (
              <span className="pl-5 text-xs text-muted-foreground">
                v{row.version}
              </span>
            ) : (
              <span className="truncate font-medium">{row.name}</span>
            )}
          </div>
        </TableCell>
        <TableCell className="font-mono text-xs">{row.code}</TableCell>
        <TableCell className="text-sm">
          {sourceModuleLabel(row.module)}
        </TableCell>
        <TableCell className="font-mono text-sm">v{row.version}</TableCell>
        <TableCell>
          <StatusBadge status={row.status} />
        </TableCell>
        <TableCell className="text-sm">
          {counts ? (
            <span>
              {counts.total}
              <span className="text-xs text-muted-foreground">
                （进行中 {counts.running}）
              </span>
            </span>
          ) : (
            "0"
          )}
        </TableCell>
        <TableCell className="text-xs text-muted-foreground">
          {formatDateTime(row.updated_at)}
        </TableCell>
        <TableCell>{renderActions(row)}</TableCell>
      </TableRow>
    );
  };

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardHeader>
          <CardTitle>审批模板</CardTitle>
          <CardDescription>
            定义业务单据提交审批时填写的字段；仅草稿可编辑，发布后 schema
            冻结，需通过「新版本」演进。进行中实例始终按提交时的版本渲染。
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex items-center justify-between gap-2">
            <span className="text-sm text-muted-foreground">
              共 {groups.length} 个模板（{templates.length} 个版本）
            </span>
            <div className="flex items-center gap-2">
              <Button
                variant="outline"
                size="icon"
                onClick={() => void load()}
                disabled={loading}
                aria-label="刷新模板列表"
                className="h-11 w-11 lg:h-8 lg:w-8"
              >
                <RefreshCwIcon
                  className={loading ? "animate-spin" : undefined}
                />
              </Button>
              <Button onClick={openCreate} className="h-11 lg:h-8">
                <PlusIcon data-icon="inline-start" />
                新增模板
              </Button>
            </div>
          </div>

          {loading ? (
            <div className="flex flex-col gap-3">
              {Array.from({ length: 3 }).map((_, index) => (
                <Skeleton key={index} className="h-12 w-full" />
              ))}
            </div>
          ) : error ? (
            <div className="flex flex-col items-center gap-2 py-8 text-sm">
              <p className="text-destructive">
                加载失败：{translateApprovalErrorMessage(error)}
              </p>
              <Button variant="outline" onClick={() => void load()}>
                重试
              </Button>
            </div>
          ) : groups.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <FilePlus2Icon className="size-8 opacity-60" />
              <span>暂无审批表单模板</span>
            </div>
          ) : (
            <div className="overflow-x-auto rounded-lg border">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>名称</TableHead>
                    <TableHead>code</TableHead>
                    <TableHead>模块</TableHead>
                    <TableHead>版本</TableHead>
                    <TableHead>状态</TableHead>
                    <TableHead>实例引用</TableHead>
                    <TableHead>更新时间</TableHead>
                    <TableHead className="text-right">操作</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {groups.map((group) => {
                    const latest = group.rows[0];
                    const expanded = expandedCodes.has(group.code);
                    return (
                      <React.Fragment key={group.code}>
                        <TableRow>
                          <TableCell className="max-w-[240px]">
                            <button
                              type="button"
                              onClick={() => toggleExpanded(group.code)}
                              className="flex items-center gap-1.5 text-left"
                            >
                              {group.rows.length > 1 ? (
                                expanded ? (
                                  <ChevronDownIcon className="size-4 shrink-0" />
                                ) : (
                                  <ChevronRightIcon className="size-4 shrink-0" />
                                )
                              ) : (
                                <FileTextIcon className="size-4 shrink-0 text-muted-foreground" />
                              )}
                              <span className="truncate font-medium">
                                {latest.name}
                              </span>
                              {group.rows.length > 1 ? (
                                <Badge
                                  variant="ghost"
                                  className="text-[11px] text-muted-foreground"
                                >
                                  {group.rows.length} 个版本
                                </Badge>
                              ) : null}
                            </button>
                          </TableCell>
                          <TableCell className="font-mono text-xs">
                            {latest.code}
                          </TableCell>
                          <TableCell className="text-sm">
                            {sourceModuleLabel(latest.module)}
                          </TableCell>
                          <TableCell className="font-mono text-sm">
                            v{latest.version}
                          </TableCell>
                          <TableCell>
                            <StatusBadge status={latest.status} />
                          </TableCell>
                          <TableCell className="text-sm">
                            {(() => {
                              const counts = usageByTemplate.get(latest.id);
                              return counts ? (
                                <span>
                                  {counts.total}
                                  <span className="text-xs text-muted-foreground">
                                    （进行中 {counts.running}）
                                  </span>
                                </span>
                              ) : (
                                "0"
                              );
                            })()}
                          </TableCell>
                          <TableCell className="text-xs text-muted-foreground">
                            {formatDateTime(latest.updated_at)}
                          </TableCell>
                          <TableCell>{renderActions(latest)}</TableCell>
                        </TableRow>
                        {expanded
                          ? group.rows
                              .slice(1)
                              .map((row) => renderGroupRow(row, true))
                          : null}
                      </React.Fragment>
                    );
                  })}
                </TableBody>
              </Table>
            </div>
          )}
        </CardContent>
      </Card>

      <Sheet
        open={sheetOpen}
        onOpenChange={(open) => {
          if (!open) {
            closeSheet();
          }
        }}
      >
        <SheetContent
          side="right"
          className="w-full gap-0 sm:w-[68vw] sm:min-w-[480px] sm:max-w-[960px]"
        >
          <SheetHeader className="border-b">
            <SheetTitle>
              {sheetMode === "create"
                ? "新增审批模板"
                : sheetMode === "edit"
                  ? `编辑模板 v${editingVersion ?? "?"}`
                  : `查看模板 v${editingVersion ?? "?"}`}
            </SheetTitle>
            <SheetDescription className="flex flex-col gap-1">
              <span className="font-mono text-xs">
                {formCode || "（未设置 code）"} ·{" "}
                {formModule
                  ? sourceModuleLabel(formModule)
                  : "（未设置模块）"}
              </span>
              <span className="text-xs">
                {sheetMode === "view"
                  ? "已发布内容冻结：如需修改请使用「新版本」复制为草稿"
                  : "仅草稿可编辑；发布后 schema 冻结，进行中实例按旧版本渲染"}
              </span>
            </SheetDescription>
          </SheetHeader>

          <Tabs
            value={activeTab}
            onValueChange={setActiveTab}
            className="min-h-0 flex-1 gap-0 px-4"
          >
            <TabsList className="mt-3 w-full">
              <TabsTrigger value="design">字段设计</TabsTrigger>
              <TabsTrigger value="preview">预览</TabsTrigger>
            </TabsList>

            {/* 字段设计 */}
            <TabsContent
              value="design"
              className="flex min-h-0 flex-col gap-4 overflow-y-auto pt-4 pb-2"
            >
              <div className="grid gap-3 sm:grid-cols-3">
                <Field>
                  <FieldLabel htmlFor="tpl-name">模板名称</FieldLabel>
                  <Input
                    id="tpl-name"
                    value={formName}
                    onChange={(event) => setFormName(event.target.value)}
                    placeholder="如：请假申请"
                    disabled={readOnly}
                  />
                </Field>
                <Field>
                  <FieldLabel htmlFor="tpl-code">code</FieldLabel>
                  <Input
                    id="tpl-code"
                    value={formCode}
                    onChange={(event) => setFormCode(event.target.value)}
                    placeholder="如：hr.leave"
                    className="font-mono"
                    disabled={readOnly}
                  />
                  <FieldDescription>
                    业务模块提交时按 code 取最新发布版
                  </FieldDescription>
                </Field>
                <Field>
                  <FieldLabel htmlFor="tpl-module">来源模块</FieldLabel>
                  <Input
                    id="tpl-module"
                    value={formModule}
                    onChange={(event) => setFormModule(event.target.value)}
                    placeholder="如：demo"
                    className="font-mono"
                    disabled={readOnly}
                  />
                  <FieldDescription>
                    与 submit_instance 的 module 入参一致
                  </FieldDescription>
                </Field>
              </div>

              <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_20rem]">
                <div className="flex flex-col gap-2">
                  <p className="text-xs text-muted-foreground lg:hidden">
                    移动端建议仅做字段增删排序，复杂字段属性请在桌面端编辑；预览不受影响。
                  </p>
                  {fields.length === 0 ? (
                    <p className="rounded-lg border border-dashed p-6 text-center text-sm text-muted-foreground">
                      暂无字段，点击下方「添加字段」
                    </p>
                  ) : (
                    fields.map((field, index) => {
                      const selected = field.id === selectedFieldId;
                      return (
                        <div
                          key={field.id}
                          role="button"
                          tabIndex={0}
                          onClick={() => setSelectedFieldId(field.id)}
                          onKeyDown={(event) => {
                            if (event.key === "Enter" || event.key === " ") {
                              event.preventDefault();
                              setSelectedFieldId(field.id);
                            }
                          }}
                          className={cn(
                            "flex cursor-pointer items-center gap-2 rounded-lg border p-3 transition-colors",
                            selected
                              ? "border-primary bg-primary/5"
                              : "hover:bg-muted/50",
                          )}
                        >
                          <span className="w-5 shrink-0 text-center text-xs text-muted-foreground">
                            {index + 1}
                          </span>
                          <div className="min-w-0 flex-1">
                            <div className="flex items-center gap-1.5">
                              <span className="truncate text-sm font-medium">
                                {field.label || "未命名字段"}
                              </span>
                              {field.required ? (
                                <Badge
                                  variant="outline"
                                  className="border-red-200 bg-red-50 text-[10px] text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300"
                                >
                                  必填
                                </Badge>
                              ) : null}
                            </div>
                            <div className="truncate font-mono text-xs text-muted-foreground">
                              {field.key || "（未设置字段名）"} ·{" "}
                              {FIELD_TYPE_LABELS[field.type]}
                            </div>
                          </div>
                          <div
                            className="flex shrink-0 items-center"
                            onClick={(event) => event.stopPropagation()}
                          >
                            <Button
                              type="button"
                              size="icon"
                              variant="ghost"
                              className="size-8"
                              aria-label="上移字段"
                              disabled={readOnly || index === 0}
                              onClick={() => moveField(index, -1)}
                            >
                              <ArrowUpIcon className="size-4" />
                            </Button>
                            <Button
                              type="button"
                              size="icon"
                              variant="ghost"
                              className="size-8"
                              aria-label="下移字段"
                              disabled={readOnly || index === fields.length - 1}
                              onClick={() => moveField(index, 1)}
                            >
                              <ArrowDownIcon className="size-4" />
                            </Button>
                            <Button
                              type="button"
                              size="icon"
                              variant="ghost"
                              className="size-8 text-destructive"
                              aria-label="删除字段"
                              disabled={readOnly}
                              onClick={() => removeField(field.id)}
                            >
                              <Trash2Icon className="size-4" />
                            </Button>
                          </div>
                        </div>
                      );
                    })
                  )}
                  {!readOnly ? (
                    <Button
                      type="button"
                      variant="outline"
                      onClick={addField}
                      className="h-11 lg:h-9"
                    >
                      <PlusIcon data-icon="inline-start" />
                      添加字段
                    </Button>
                  ) : null}
                </div>

                {/* 属性面板 */}
                <div className="rounded-lg border p-4">
                  {selectedField ? (
                    <div className="flex flex-col gap-4">
                      <Field>
                        <FieldLabel htmlFor="field-label">标签</FieldLabel>
                        <Input
                          id="field-label"
                          value={selectedField.label}
                          onChange={(event) =>
                            updateField(selectedField.id, {
                              label: event.target.value,
                            })
                          }
                          disabled={readOnly}
                        />
                      </Field>
                      <Field>
                        <FieldLabel htmlFor="field-key">字段名</FieldLabel>
                        <Input
                          id="field-key"
                          value={selectedField.key}
                          onChange={(event) =>
                            updateField(selectedField.id, {
                              key: event.target.value,
                            })
                          }
                          className="font-mono"
                          placeholder="如：start_date"
                          disabled={readOnly}
                        />
                        <FieldDescription>
                          字母/下划线开头，仅字母数字下划线；提交数据以此为准
                        </FieldDescription>
                      </Field>
                      <Field>
                        <FieldLabel htmlFor="field-type">类型</FieldLabel>
                        <Select
                          value={selectedField.type}
                          onValueChange={(value) =>
                            updateField(selectedField.id, {
                              type: asFieldType(value),
                            })
                          }
                          disabled={readOnly}
                        >
                          <SelectTrigger id="field-type" className="w-full">
                            <SelectValue />
                          </SelectTrigger>
                          <SelectContent>
                            {FIELD_TYPE_OPTIONS.map((option) => (
                              <SelectItem
                                key={option.value}
                                value={option.value}
                              >
                                {option.label}
                              </SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                        <FieldDescription>
                          附件类型依赖对象存储，本期暂不开放
                        </FieldDescription>
                      </Field>
                      <Field orientation="horizontal">
                        <Checkbox
                          id="field-required"
                          checked={selectedField.required}
                          onCheckedChange={(checked) =>
                            updateField(selectedField.id, {
                              required: checked === true,
                            })
                          }
                          disabled={readOnly}
                        />
                        <FieldLabel htmlFor="field-required">必填</FieldLabel>
                      </Field>
                      <Field>
                        <FieldLabel htmlFor="field-default">默认值</FieldLabel>
                        <Input
                          id="field-default"
                          value={selectedField.defaultValue}
                          onChange={(event) =>
                            updateField(selectedField.id, {
                              defaultValue: event.target.value,
                            })
                          }
                          placeholder="可选"
                          disabled={readOnly}
                        />
                      </Field>
                      {selectedField.type === "select" ||
                      selectedField.type === "multiselect" ? (
                        <Field>
                          <FieldLabel htmlFor="field-options">
                            选项（逗号分隔）
                          </FieldLabel>
                          <Textarea
                            id="field-options"
                            rows={3}
                            value={selectedField.options}
                            onChange={(event) =>
                              updateField(selectedField.id, {
                                options: event.target.value,
                              })
                            }
                            placeholder="选项一, 选项二"
                            disabled={readOnly}
                          />
                        </Field>
                      ) : null}
                    </div>
                  ) : (
                    <p className="py-8 text-center text-sm text-muted-foreground">
                      点击左侧字段编辑属性
                    </p>
                  )}
                </div>
              </div>
            </TabsContent>

            {/* 预览 */}
            <TabsContent
              value="preview"
              className="flex min-h-0 flex-col gap-4 overflow-y-auto pt-4 pb-2"
            >
              <p className="flex items-center gap-1.5 text-sm text-muted-foreground">
                <FlaskConicalIcon className="size-4" />
                按当前 schema 渲染表单样例（默认值与占位示例，不产生数据）
              </p>
              {fields.length === 0 ? (
                <p className="rounded-lg border border-dashed p-8 text-center text-sm text-muted-foreground">
                  暂无字段可预览
                </p>
              ) : (
                <div className="flex max-w-2xl flex-col gap-4 rounded-lg border p-4">
                  {fields.map((field) => (
                    <PreviewField key={field.id} field={field} />
                  ))}
                </div>
              )}
            </TabsContent>
          </Tabs>

          {sheetMode !== "view" ? (
            <SheetFooter className="flex-row items-center justify-end gap-2 border-t">
              <span className="mr-auto text-xs text-muted-foreground">
                {editingId
                  ? `正在编辑草稿 v${editingVersion ?? "?"}`
                  : "保存后将创建 v1 草稿"}
              </span>
              <Button
                variant="outline"
                className="h-11 lg:h-8"
                onClick={() => void handleSaveDraft()}
                disabled={saving || publishing}
              >
                {saving ? (
                  <Loader2Icon
                    className="animate-spin"
                    data-icon="inline-start"
                  />
                ) : null}
                保存草稿
              </Button>
              <Button
                className="h-11 lg:h-8"
                onClick={() => void handlePublish()}
                disabled={saving || publishing}
              >
                {publishing ? (
                  <Loader2Icon
                    className="animate-spin"
                    data-icon="inline-start"
                  />
                ) : null}
                发布
              </Button>
            </SheetFooter>
          ) : null}
        </SheetContent>
      </Sheet>
    </div>
  );
}
