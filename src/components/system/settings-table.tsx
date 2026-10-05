"use client";

// 系统管理 · 参数配置（工单 system/007 数据层 + system/008 页面）
//
// 数据：get_all_settings（admin，分组列表）/ get_setting_history（admin，历史）；
//       编辑与新增经 public.upsert_setting（admin，函数内类型校验 + 写历史 + 审计）。
// 交互（DESIGN §4）：分组 Table（组标题行 + 数据行），整行可点打开右侧 Sheet 编辑；
//       按类型渲染控件（bool Switch / number Input / string Input / json 等宽 Textarea）；
//       Sheet 内「历史」按钮打开变更历史 Sheet；新增参数按钮在内容区工具栏。
// 校验：前端与服务端一致——说明必填、值类型匹配（json 仅对象/数组，number 可解析）。
// 移动端（<1024px）：按分组渲染卡片，整卡可点。

import * as React from "react";
import { HistoryIcon, Loader2Icon, PlusIcon, SaveIcon } from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
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
import { Switch } from "@/components/ui/switch";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Textarea } from "@/components/ui/textarea";
import type { Database, Json } from "@/lib/database.types";
import { translateSystemErrorMessage } from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type SettingRow =
  Database["public"]["Functions"]["get_all_settings"]["Returns"][number];
type HistoryRow =
  Database["public"]["Functions"]["get_setting_history"]["Returns"][number];
type SettingValueType = "bool" | "number" | "string" | "json";

const VALUE_TYPE_LABELS: Record<SettingValueType, string> = {
  bool: "开关",
  number: "数字",
  string: "文本",
  json: "JSON",
};

const VALUE_TYPE_OPTIONS = (
  Object.keys(VALUE_TYPE_LABELS) as SettingValueType[]
).map((value) => ({ value, label: VALUE_TYPE_LABELS[value] }));

const BOOL_ON_BADGE =
  "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300";
const BOOL_OFF_BADGE =
  "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400";

function asSettingValueType(value: string): SettingValueType {
  if (value === "bool" || value === "number" || value === "json") {
    return value;
  }
  return "string";
}

const formatDateTime = (value: string) =>
  new Date(value).toLocaleString("zh-CN", { hour12: false });

/** 表格/卡片中的当前值预览（json 由 CSS 截断，title 展示全文） */
function formatValuePreview(row: SettingRow): string {
  const value = row.value;
  if (value === null || value === undefined) {
    return "—";
  }
  if (typeof value === "string") {
    return value === "" ? "（空字符串）" : value;
  }
  if (typeof value === "boolean") {
    return value ? "开启" : "关闭";
  }
  if (typeof value === "number") {
    return String(value);
  }
  return JSON.stringify(value);
}

/** 历史中的值展示：NULL（新建前）显示破折号 */
function formatHistoryValue(value: unknown): string {
  if (value === null || value === undefined) {
    return "—";
  }
  if (typeof value === "string") {
    return value === "" ? '""' : value;
  }
  return JSON.stringify(value);
}

type SettingForm = {
  key: string;
  groupName: string;
  valueType: SettingValueType;
  description: string;
  boolValue: boolean;
  textValue: string;
  numberValue: string;
  jsonValue: string;
};

const EMPTY_FORM: SettingForm = {
  key: "",
  groupName: "",
  valueType: "string",
  description: "",
  boolValue: false,
  textValue: "",
  numberValue: "",
  jsonValue: "{}",
};

function formFromRow(row: SettingRow): SettingForm {
  const valueType = asSettingValueType(row.value_type);
  const value = row.value;
  return {
    key: row.key,
    groupName: row.group_name,
    valueType,
    description: row.description,
    boolValue: value === true,
    textValue: typeof value === "string" ? value : "",
    numberValue: typeof value === "number" ? String(value) : "",
    jsonValue: valueType === "json" ? JSON.stringify(value, null, 2) : "{}",
  };
}

type ParsedValue =
  | { ok: true; value: Json }
  | { ok: false; message: string };

/** 前端按与服务端一致的类型规则把表单解析为 jsonb 值 */
function parseFormValue(form: SettingForm): ParsedValue {
  switch (form.valueType) {
    case "bool":
      return { ok: true, value: form.boolValue };
    case "number": {
      const text = form.numberValue.trim();
      if (text === "" || Number.isNaN(Number(text))) {
        return { ok: false, message: "请输入有效数字" };
      }
      return { ok: true, value: Number(text) };
    }
    case "string":
      return { ok: true, value: form.textValue };
    case "json": {
      const text = form.jsonValue.trim();
      if (text === "") {
        return { ok: false, message: "请输入 JSON 值" };
      }
      try {
        const parsed: unknown = JSON.parse(text);
        if (parsed === null || typeof parsed !== "object") {
          return { ok: false, message: "JSON 类型仅支持对象或数组" };
        }
        return { ok: true, value: parsed as Json };
      } catch {
        return { ok: false, message: "JSON 格式不正确" };
      }
    }
  }
}

/** 按 value_type 渲染值编辑控件 */
function ValueEditor({
  form,
  onChange,
  idPrefix,
}: {
  form: SettingForm;
  onChange: (next: SettingForm) => void;
  idPrefix: string;
}) {
  switch (form.valueType) {
    case "bool":
      return (
        <div className="flex h-11 items-center gap-3 lg:h-8">
          <Switch
            id={`${idPrefix}-value-bool`}
            checked={form.boolValue}
            onCheckedChange={(checked) =>
              onChange({ ...form, boolValue: checked })
            }
          />
          <span className="text-sm text-muted-foreground">
            {form.boolValue ? "开启" : "关闭"}
          </span>
        </div>
      );
    case "number":
      return (
        <Input
          id={`${idPrefix}-value-number`}
          inputMode="decimal"
          value={form.numberValue}
          onChange={(event) =>
            onChange({ ...form, numberValue: event.target.value })
          }
          placeholder="如 20"
          autoComplete="off"
          className="h-11 lg:h-8"
        />
      );
    case "string":
      return (
        <Input
          id={`${idPrefix}-value-string`}
          value={form.textValue}
          onChange={(event) =>
            onChange({ ...form, textValue: event.target.value })
          }
          placeholder="参数值（允许空字符串）"
          autoComplete="off"
          className="h-11 lg:h-8"
        />
      );
    case "json":
      return (
        <Textarea
          id={`${idPrefix}-value-json`}
          value={form.jsonValue}
          onChange={(event) =>
            onChange({ ...form, jsonValue: event.target.value })
          }
          rows={7}
          spellCheck={false}
          className="font-mono text-xs"
          placeholder='{"key": "value"}'
        />
      );
  }
}

export function SettingsTable() {
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [settings, setSettings] = React.useState<SettingRow[]>([]);

  const [formOpen, setFormOpen] = React.useState(false);
  const [formMode, setFormMode] = React.useState<"create" | "edit">("create");
  const [form, setForm] = React.useState<SettingForm>(EMPTY_FORM);
  const [saving, setSaving] = React.useState(false);

  const [historyOpen, setHistoryOpen] = React.useState(false);
  const [historyKey, setHistoryKey] = React.useState("");
  const [history, setHistory] = React.useState<HistoryRow[]>([]);
  const [historyLoading, setHistoryLoading] = React.useState(false);
  const [historyError, setHistoryError] = React.useState<string | null>(null);

  const load = React.useCallback(async (options?: { silent?: boolean }) => {
    if (!options?.silent) {
      setLoading(true);
    }
    setError(null);
    const supabase = createClient();
    const { data, error: loadError } = await supabase.rpc("get_all_settings");

    if (loadError) {
      setError(loadError.message);
      setLoading(false);
      return;
    }

    setSettings(data ?? []);
    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const groups = React.useMemo(() => {
    const byGroup = new Map<string, SettingRow[]>();
    for (const row of settings) {
      const list = byGroup.get(row.group_name);
      if (list) {
        list.push(row);
      } else {
        byGroup.set(row.group_name, [row]);
      }
    }
    return Array.from(byGroup.entries()).sort(([a], [b]) =>
      a.localeCompare(b, "zh-Hans-CN"),
    );
  }, [settings]);

  const openCreate = () => {
    setFormMode("create");
    setForm(EMPTY_FORM);
    setFormOpen(true);
  };

  const openEdit = (row: SettingRow) => {
    setFormMode("edit");
    setForm(formFromRow(row));
    setFormOpen(true);
  };

  const handleSave = async () => {
    const key = form.key.trim();
    const groupName = form.groupName.trim();
    const description = form.description.trim();

    if (key === "") {
      toast.error("参数 key 不能为空");
      return;
    }
    if (groupName === "") {
      toast.error("参数分组不能为空");
      return;
    }
    if (description === "") {
      toast.error("参数说明不能为空（防无主参数）");
      return;
    }
    const parsed = parseFormValue(form);
    if (!parsed.ok) {
      toast.error(parsed.message);
      return;
    }

    setSaving(true);
    const supabase = createClient();
    const { error: saveError } = await supabase.rpc("upsert_setting", {
      p_key: key,
      p_value: parsed.value,
      p_group_name: groupName,
      p_value_type: form.valueType,
      p_description: description,
    });
    setSaving(false);

    if (saveError) {
      toast.error(translateSystemErrorMessage(saveError.message));
      return;
    }

    toast.success(formMode === "create" ? "参数已创建" : "参数已保存");
    setFormOpen(false);
    void load({ silent: true });
  };

  const openHistory = async (key: string) => {
    setHistoryKey(key);
    setHistoryOpen(true);
    setHistoryLoading(true);
    setHistoryError(null);

    const supabase = createClient();
    const { data, error: historyLoadError } = await supabase.rpc(
      "get_setting_history",
      { p_key: key },
    );

    if (historyLoadError) {
      setHistoryError(historyLoadError.message);
      setHistory([]);
      setHistoryLoading(false);
      return;
    }

    setHistory(data ?? []);
    setHistoryLoading(false);
  };

  const isEmpty = !loading && !error && settings.length === 0;

  return (
    <div className="flex flex-col gap-2 p-0 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex items-center justify-end gap-2">
            <Button type="button" size="sm" onClick={openCreate}>
              <PlusIcon data-icon="inline-start" />
              新增参数
            </Button>
          </div>
          {loading ? (
            <div className="flex flex-col gap-3">
              {Array.from({ length: 6 }).map((_, index) => (
                <Skeleton key={index} className="h-9 w-full" />
              ))}
            </div>
          ) : error ? (
            <div className="flex flex-col items-center gap-2 py-10 text-sm">
              <p className="text-destructive">
                加载失败：{translateSystemErrorMessage(error)}
              </p>
              <Button variant="outline" onClick={() => void load()}>
                重试
              </Button>
            </div>
          ) : isEmpty ? (
            <p className="py-10 text-center text-sm text-muted-foreground">
              暂无参数，点击右上角「新增参数」创建
            </p>
          ) : (
            <>
              {/* 桌面：分组 Table（组标题行 + 数据行，整行可点编辑） */}
              <div className="hidden overflow-x-auto lg:block">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead className="text-center">参数</TableHead>
                      <TableHead className="text-center">当前值</TableHead>
                      <TableHead className="text-center">类型</TableHead>
                      <TableHead className="text-center">说明</TableHead>
                      <TableHead className="text-center">更新时间</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {groups.map(([group, rows]) => (
                      <React.Fragment key={group}>
                        <TableRow className="bg-muted/50 hover:bg-muted/50">
                          <TableCell
                            colSpan={5}
                            className="text-left text-xs font-medium text-muted-foreground"
                          >
                            {group} · {rows.length} 项
                          </TableCell>
                        </TableRow>
                        {rows.map((row) => {
                          const valueType = asSettingValueType(row.value_type);
                          return (
                            <TableRow
                              key={row.key}
                              className="cursor-pointer"
                              onClick={() => openEdit(row)}
                              tabIndex={0}
                              onKeyDown={(event) => {
                                if (event.key === "Enter") {
                                  openEdit(row);
                                }
                              }}
                            >
                              <TableCell className="text-left font-mono text-xs">
                                {row.key}
                              </TableCell>
                              <TableCell className="text-center">
                                {valueType === "bool" ? (
                                  <Badge
                                    variant="outline"
                                    className={
                                      row.value === true
                                        ? BOOL_ON_BADGE
                                        : BOOL_OFF_BADGE
                                    }
                                  >
                                    {row.value === true ? "开启" : "关闭"}
                                  </Badge>
                                ) : (
                                  <span
                                    className="inline-block max-w-[220px] truncate align-middle font-mono text-xs"
                                    title={formatValuePreview(row)}
                                  >
                                    {formatValuePreview(row)}
                                  </span>
                                )}
                              </TableCell>
                              <TableCell className="text-center">
                                <Badge variant="outline">
                                  {VALUE_TYPE_LABELS[valueType]}
                                </Badge>
                              </TableCell>
                              <TableCell className="text-center text-muted-foreground">
                                {row.description}
                              </TableCell>
                              <TableCell className="text-center text-xs text-muted-foreground">
                                {formatDateTime(row.updated_at)}
                              </TableCell>
                            </TableRow>
                          );
                        })}
                      </React.Fragment>
                    ))}
                  </TableBody>
                </Table>
              </div>

              {/* 移动端：按分组卡片，整卡可点 */}
              <div className="flex flex-col gap-4 lg:hidden">
                {groups.map(([group, rows]) => (
                  <div key={group} className="flex flex-col gap-2">
                    <div className="text-xs font-medium text-muted-foreground">
                      {group} · {rows.length} 项
                    </div>
                    {rows.map((row) => {
                      const valueType = asSettingValueType(row.value_type);
                      return (
                        <button
                          key={row.key}
                          type="button"
                          onClick={() => openEdit(row)}
                          className="flex flex-col gap-2 rounded-xl border p-4 text-left transition-colors hover:border-primary focus-visible:border-primary focus-visible:outline-none"
                        >
                          <div className="flex items-center justify-between gap-2">
                            <span className="font-mono text-xs">{row.key}</span>
                            <Badge variant="outline">
                              {VALUE_TYPE_LABELS[valueType]}
                            </Badge>
                          </div>
                          <div className="flex items-center justify-between gap-2 text-sm">
                            <span className="text-muted-foreground">当前值</span>
                            {valueType === "bool" ? (
                              <Badge
                                variant="outline"
                                className={
                                  row.value === true
                                    ? BOOL_ON_BADGE
                                    : BOOL_OFF_BADGE
                                }
                              >
                                {row.value === true ? "开启" : "关闭"}
                              </Badge>
                            ) : (
                              <span className="max-w-[60%] truncate font-mono text-xs font-medium">
                                {formatValuePreview(row)}
                              </span>
                            )}
                          </div>
                          <div className="text-xs text-muted-foreground">
                            {row.description}
                          </div>
                          <div className="text-xs text-muted-foreground">
                            更新于 {formatDateTime(row.updated_at)}
                          </div>
                        </button>
                      );
                    })}
                  </div>
                ))}
              </div>
            </>
          )}
        </CardContent>
      </Card>

      {/* 编辑 / 新增 Sheet */}
      <Sheet
        open={formOpen}
        onOpenChange={(open) => {
          if (!saving) {
            setFormOpen(open);
          }
        }}
      >
        <SheetContent
          side="right"
          className="w-full sm:max-w-[480px]"
        >
          <SheetHeader className="border-b">
            <SheetTitle>
              {formMode === "create" ? "新增参数" : "编辑参数"}
            </SheetTitle>
            <SheetDescription className="font-mono text-xs">
              {formMode === "create" ? "新建全局键值参数" : form.key}
            </SheetDescription>
          </SheetHeader>
          <div className="flex flex-1 flex-col gap-4 overflow-y-auto px-4">
            {formMode === "create" ? (
              <>
                <Field>
                  <FieldLabel htmlFor="setting-key">Key</FieldLabel>
                  <Input
                    id="setting-key"
                    value={form.key}
                    onChange={(event) =>
                      setForm((prev) => ({ ...prev, key: event.target.value }))
                    }
                    placeholder="如 page_size_default"
                    autoComplete="off"
                    className="h-11 font-mono lg:h-8"
                  />
                  <FieldDescription>
                    建议小写字母、数字与下划线；建后为消费方引用标识
                  </FieldDescription>
                </Field>
                <Field>
                  <FieldLabel htmlFor="setting-group">分组</FieldLabel>
                  <Input
                    id="setting-group"
                    value={form.groupName}
                    onChange={(event) =>
                      setForm((prev) => ({
                        ...prev,
                        groupName: event.target.value,
                      }))
                    }
                    placeholder="如 通用 / 安全 / 集成"
                    autoComplete="off"
                    className="h-11 lg:h-8"
                    list="setting-group-options"
                  />
                  <datalist id="setting-group-options">
                    {Array.from(
                      new Set(settings.map((row) => row.group_name)),
                    ).map((group) => (
                      <option key={group} value={group} />
                    ))}
                  </datalist>
                </Field>
                <Field>
                  <FieldLabel htmlFor="setting-value-type">类型</FieldLabel>
                  <Select
                    value={form.valueType}
                    onValueChange={(value) =>
                      setForm((prev) => ({
                        ...prev,
                        valueType: asSettingValueType(value),
                      }))
                    }
                  >
                    <SelectTrigger
                      id="setting-value-type"
                      className="h-11 w-full lg:h-8"
                      aria-label="参数类型"
                    >
                      <SelectValue placeholder="选择类型" />
                    </SelectTrigger>
                    <SelectContent>
                      {VALUE_TYPE_OPTIONS.map((option) => (
                        <SelectItem key={option.value} value={option.value}>
                          {option.label}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </Field>
              </>
            ) : (
              <div className="grid grid-cols-2 gap-4">
                <Field>
                  <FieldLabel>分组</FieldLabel>
                  <div className="flex h-11 items-center text-sm lg:h-8">
                    {form.groupName}
                  </div>
                </Field>
                <Field>
                  <FieldLabel>类型</FieldLabel>
                  <div className="flex h-11 items-center lg:h-8">
                    <Badge variant="outline">
                      {VALUE_TYPE_LABELS[form.valueType]}
                    </Badge>
                  </div>
                </Field>
              </div>
            )}

            <Field>
              <FieldLabel>值</FieldLabel>
              <ValueEditor form={form} onChange={setForm} idPrefix="setting" />
              <FieldDescription>
                {form.valueType === "json"
                  ? "JSON 类型仅支持对象或数组"
                  : form.valueType === "number"
                    ? "支持整数与小数"
                    : form.valueType === "bool"
                      ? "开关值保存为 true / false"
                      : "文本类型允许空字符串"}
              </FieldDescription>
            </Field>
            <Field>
              <FieldLabel htmlFor="setting-description">说明（必填）</FieldLabel>
              <Input
                id="setting-description"
                value={form.description}
                onChange={(event) =>
                  setForm((prev) => ({
                    ...prev,
                    description: event.target.value,
                  }))
                }
                placeholder="这个参数控制什么"
                autoComplete="off"
                className="h-11 lg:h-8"
              />
              <FieldDescription>
                防无主参数：说明为空无法创建
              </FieldDescription>
            </Field>
          </div>
          <SheetFooter className="flex-row items-center border-t">
            {formMode === "edit" ? (
              <Button
                type="button"
                variant="outline"
                className="mr-auto h-8"
                onClick={() => void openHistory(form.key)}
              >
                <HistoryIcon data-icon="inline-start" />
                历史
              </Button>
            ) : null}
            <Button
              type="button"
              variant="outline"
              className="h-8"
              onClick={() => setFormOpen(false)}
              disabled={saving}
            >
              取消
            </Button>
            <Button
              type="button"
              className="h-8"
              onClick={() => void handleSave()}
              disabled={saving}
            >
              {saving ? (
                <Loader2Icon className="size-3.5 animate-spin" data-icon="inline-start" />
              ) : (
                <SaveIcon className="size-3.5" data-icon="inline-start" />
              )}
              保存
            </Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>

      {/* 变更历史 Sheet（自编辑 Sheet 打开） */}
      <Sheet open={historyOpen} onOpenChange={setHistoryOpen}>
        <SheetContent
          side="right"
          className="w-full sm:max-w-[480px]"
        >
          <SheetHeader className="border-b">
            <SheetTitle>变更历史</SheetTitle>
            <SheetDescription className="font-mono text-xs">
              {historyKey}
            </SheetDescription>
          </SheetHeader>
          <div className="flex-1 overflow-y-auto px-4">
            {historyLoading ? (
              <div className="flex flex-col gap-3">
                {Array.from({ length: 4 }).map((_, index) => (
                  <Skeleton key={index} className="h-9 w-full" />
                ))}
              </div>
            ) : historyError ? (
              <div className="flex flex-col items-center gap-2 py-10 text-sm">
                <p className="text-destructive">
                  历史加载失败：{translateSystemErrorMessage(historyError)}
                </p>
                <Button
                  variant="outline"
                  onClick={() => void openHistory(historyKey)}
                >
                  重试
                </Button>
              </div>
            ) : history.length === 0 ? (
              <p className="py-10 text-center text-sm text-muted-foreground">
                暂无变更历史
              </p>
            ) : (
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="text-center">时间</TableHead>
                    <TableHead className="text-center">操作人</TableHead>
                    <TableHead className="text-center">变更</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {history.map((item) => (
                    <TableRow key={item.id}>
                      <TableCell className="text-center text-xs whitespace-nowrap">
                        {formatDateTime(item.changed_at)}
                      </TableCell>
                      <TableCell className="text-center text-xs">
                        {item.changed_by_name ?? "—"}
                      </TableCell>
                      <TableCell className="text-left">
                        <div className="font-mono text-xs break-all opacity-50 line-through">
                          {formatHistoryValue(item.old_value)}
                        </div>
                        <div className="font-mono text-xs break-all">
                          {formatHistoryValue(item.new_value)}
                        </div>
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </div>
        </SheetContent>
      </Sheet>
    </div>
  );
}
