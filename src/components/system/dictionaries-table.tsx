"use client";

// 系统管理 · 字典管理（工单 system/009 数据层 + 字典管理页面）
//
// 数据：get_dict_catalog（admin，左侧导航）/ get_dict_items（admin，含停用项）；
//       写经 upsert_dict_meta（新字典登记用途说明）、upsert_dict_item（value 禁改）、
//       disable_dict_item。消费侧读取口是 get_dict（仅 active，见 system/010 改造）。
// 交互：左侧 dict_key 导航 + 右侧项 Table；配色列用 Badge 预览（color_class 即 Badge 类名）；
//       整行可点 → 右侧 Sheet 编辑（value 只读）；新增字典 Sheet（用途说明必填 + 首项）。
// 移动端（<1024px）：导航横向滚动，项列表渲染卡片。

import * as React from "react";
import { BookMarkedIcon, Loader2Icon, PlusIcon, SaveIcon } from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardAction,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
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
import { InfoHint } from "@/components/info-hint";
import type { Database } from "@/lib/database.types";
import { translateSystemErrorMessage } from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type CatalogRow =
  Database["public"]["Functions"]["get_dict_catalog"]["Returns"][number];
type ItemRow =
  Database["public"]["Functions"]["get_dict_items"]["Returns"][number];
type DictItemStatus = "active" | "disabled";

const DICT_STATUS_LABELS: Record<DictItemStatus, string> = {
  active: "启用",
  disabled: "停用",
};

const DICT_STATUS_BADGE_CLASSES: Record<DictItemStatus, string> = {
  active:
    "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  disabled:
    "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
};

function asDictItemStatus(value: string): DictItemStatus {
  return value === "disabled" ? "disabled" : "active";
}

/**
 * 配色预设：className 与 src/lib/dictionaries.ts 现有 Badge 类逐字一致，
 * 直接存入 system_dictionaries.color_class 供消费方 className 使用。
 */
const COLOR_PRESETS = [
  {
    id: "emerald",
    label: "绿 · 启用/成功",
    className:
      "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  },
  {
    id: "zinc",
    label: "灰 · 停用/中性",
    className:
      "border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400",
  },
  {
    id: "red",
    label: "红 · 危险/删除",
    className:
      "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300",
  },
  {
    id: "amber",
    label: "黄 · 警告/待处理",
    className:
      "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300",
  },
  {
    id: "blue",
    label: "蓝 · 进行中/信息",
    className:
      "border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-900/60 dark:bg-blue-950/60 dark:text-blue-300",
  },
  {
    id: "violet",
    label: "紫 · 计划/分类",
    className:
      "border-violet-200 bg-violet-50 text-violet-700 dark:border-violet-900/60 dark:bg-violet-950/60 dark:text-violet-300",
  },
  {
    id: "cyan",
    label: "青 · 辅助",
    className:
      "border-cyan-200 bg-cyan-50 text-cyan-700 dark:border-cyan-900/60 dark:bg-cyan-950/60 dark:text-cyan-300",
  },
  {
    id: "indigo",
    label: "靛 · 客户/外部",
    className:
      "border-indigo-200 bg-indigo-50 text-indigo-700 dark:border-indigo-900/60 dark:bg-indigo-950/60 dark:text-indigo-300",
  },
] as const;

/** Select 不接受空字符串 value，用哨兵表示「无配色」 */
const NONE_COLOR = "__none__";

const COLOR_OPTIONS = [
  ...COLOR_PRESETS.map((preset) => ({
    value: preset.className,
    label: preset.label,
  })),
  { value: NONE_COLOR, label: "无配色（纯描边）" },
];

type ItemForm = {
  mode: "create" | "edit";
  dictKey: string;
  value: string;
  label: string;
  sortOrder: string;
  colorClass: string;
  status: DictItemStatus;
};

const EMPTY_ITEM_FORM: ItemForm = {
  mode: "create",
  dictKey: "",
  value: "",
  label: "",
  sortOrder: "0",
  colorClass: "",
  status: "active",
};

type CreateDictForm = {
  dictKey: string;
  description: string;
  value: string;
  label: string;
  sortOrder: string;
  colorClass: string;
  status: DictItemStatus;
};

const EMPTY_CREATE_FORM: CreateDictForm = {
  dictKey: "",
  description: "",
  value: "",
  label: "",
  sortOrder: "10",
  colorClass: "",
  status: "active",
};

function colorSelectValue(colorClass: string): string {
  return colorClass === "" ? NONE_COLOR : colorClass;
}

function ColorPreview({ label, colorClass }: { label: string; colorClass: string }) {
  return (
    <Badge variant="outline" className={colorClass === "" ? undefined : colorClass}>
      {label === "" ? "预览" : label}
    </Badge>
  );
}

export function DictionariesTable() {
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [catalog, setCatalog] = React.useState<CatalogRow[]>([]);
  const [selectedKey, setSelectedKey] = React.useState<string>("");
  const [items, setItems] = React.useState<ItemRow[]>([]);
  const [itemsLoading, setItemsLoading] = React.useState(false);
  const [itemsError, setItemsError] = React.useState<string | null>(null);

  const [itemOpen, setItemOpen] = React.useState(false);
  const [itemForm, setItemForm] = React.useState<ItemForm>(EMPTY_ITEM_FORM);
  const [savingItem, setSavingItem] = React.useState(false);

  const [createOpen, setCreateOpen] = React.useState(false);
  const [createForm, setCreateForm] =
    React.useState<CreateDictForm>(EMPTY_CREATE_FORM);
  const [creating, setCreating] = React.useState(false);

  const selectedKeyRef = React.useRef("");
  React.useEffect(() => {
    selectedKeyRef.current = selectedKey;
  }, [selectedKey]);

  const loadItems = React.useCallback(async (key: string) => {
    setItemsLoading(true);
    setItemsError(null);
    const supabase = createClient();
    const { data, error: loadError } = await supabase.rpc("get_dict_items", {
      p_dict_key: key,
    });

    if (loadError) {
      setItemsError(loadError.message);
      setItems([]);
      setItemsLoading(false);
      return;
    }

    setItems(data ?? []);
    setItemsLoading(false);
  }, []);

  const loadCatalog = React.useCallback(
    async (preferKey?: string, options?: { silent?: boolean }) => {
      if (!options?.silent) {
        setLoading(true);
      }
      setError(null);
      const supabase = createClient();
      const { data, error: loadError } =
        await supabase.rpc("get_dict_catalog");

      if (loadError) {
        setError(loadError.message);
        setLoading(false);
        return;
      }

      const rows = data ?? [];
      setCatalog(rows);
      const nextKey =
        preferKey || selectedKeyRef.current || rows[0]?.dict_key || "";
      setSelectedKey(nextKey);
      if (nextKey !== "") {
        await loadItems(nextKey);
      } else {
        setItems([]);
      }
      setLoading(false);
    },
    [loadItems],
  );

  React.useEffect(() => {
    void loadCatalog();
  }, [loadCatalog]);

  const selectedMeta = catalog.find((row) => row.dict_key === selectedKey);

  const selectDict = (key: string) => {
    setSelectedKey(key);
    void loadItems(key);
  };

  const openEditItem = (row: ItemRow) => {
    setItemForm({
      mode: "edit",
      dictKey: selectedKey,
      value: row.value,
      label: row.label,
      sortOrder: String(row.sort_order),
      colorClass: row.color_class ?? "",
      status: asDictItemStatus(row.status),
    });
    setItemOpen(true);
  };

  const openCreateItem = () => {
    setItemForm({ ...EMPTY_ITEM_FORM, dictKey: selectedKey });
    setItemOpen(true);
  };

  const openCreateDict = () => {
    setCreateForm(EMPTY_CREATE_FORM);
    setCreateOpen(true);
  };

  const parseSortOrder = (text: string): number | null => {
    const trimmed = text.trim();
    if (trimmed === "") {
      return 0;
    }
    const parsed = Number(trimmed);
    return Number.isInteger(parsed) ? parsed : null;
  };

  const handleSaveItem = async () => {
    if (itemForm.dictKey === "") {
      toast.error("请先在左侧选择字典");
      return;
    }
    const value = itemForm.value.trim();
    const label = itemForm.label.trim();
    if (value === "") {
      toast.error("字典项 value 不能为空");
      return;
    }
    if (label === "") {
      toast.error("字典项 label 不能为空");
      return;
    }
    const sortOrder = parseSortOrder(itemForm.sortOrder);
    if (sortOrder === null) {
      toast.error("排序需为整数");
      return;
    }

    setSavingItem(true);
    const supabase = createClient();
    const { error: saveError } = await supabase.rpc("upsert_dict_item", {
      p_dict_key: itemForm.dictKey,
      p_value: value,
      p_label: label,
      p_sort_order: sortOrder,
      p_color_class: itemForm.colorClass,
      p_status: itemForm.status,
    });
    setSavingItem(false);

    if (saveError) {
      toast.error(translateSystemErrorMessage(saveError.message));
      return;
    }

    toast.success(itemForm.mode === "create" ? "字典项已创建" : "字典项已保存");
    setItemOpen(false);
    void loadCatalog(itemForm.dictKey, { silent: true });
  };

  const handleCreateDict = async () => {
    const dictKey = createForm.dictKey.trim();
    const description = createForm.description.trim();
    const value = createForm.value.trim();
    const label = createForm.label.trim();

    if (dictKey === "") {
      toast.error("字典标识不能为空");
      return;
    }
    if (description === "") {
      toast.error("字典用途说明不能为空");
      return;
    }
    if (value === "") {
      toast.error("首项 value 不能为空");
      return;
    }
    if (label === "") {
      toast.error("首项 label 不能为空");
      return;
    }
    const sortOrder = parseSortOrder(createForm.sortOrder);
    if (sortOrder === null) {
      toast.error("排序需为整数");
      return;
    }

    setCreating(true);
    const supabase = createClient();
    const { error: metaError } = await supabase.rpc("upsert_dict_meta", {
      p_dict_key: dictKey,
      p_description: description,
    });
    if (metaError) {
      setCreating(false);
      toast.error(translateSystemErrorMessage(metaError.message));
      return;
    }

    const { error: itemError } = await supabase.rpc("upsert_dict_item", {
      p_dict_key: dictKey,
      p_value: value,
      p_label: label,
      p_sort_order: sortOrder,
      p_color_class: createForm.colorClass,
      p_status: createForm.status,
    });
    setCreating(false);

    if (itemError) {
      toast.error(translateSystemErrorMessage(itemError.message));
      return;
    }

    toast.success("字典已创建");
    setCreateOpen(false);
    void loadCatalog(dictKey, { silent: true });
  };

  if (loading) {
    return (
      <div className="flex flex-col gap-0.5 p-0 md:p-6">
        <div className="grid gap-4 lg:grid-cols-[260px_minmax(0,1fr)]">
          <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
            <CardContent className="flex flex-col gap-3 p-4 md:p-6">
              {Array.from({ length: 4 }).map((_, index) => (
                <Skeleton key={index} className="h-16 w-full" />
              ))}
            </CardContent>
          </Card>
          <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
            <CardContent className="flex flex-col gap-3 p-4 md:p-6">
              {Array.from({ length: 6 }).map((_, index) => (
                <Skeleton key={index} className="h-9 w-full" />
              ))}
            </CardContent>
          </Card>
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex flex-col gap-0.5 p-0 md:p-6">
        <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
          <CardContent className="flex flex-col items-center gap-2 py-16 text-sm">
            <p className="text-destructive">
              加载失败：{translateSystemErrorMessage(error)}
            </p>
            <Button variant="outline" onClick={() => void loadCatalog()}>
              重试
            </Button>
          </CardContent>
        </Card>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-0.5 p-0 md:p-6">
      <div className="grid gap-4 lg:grid-cols-[260px_minmax(0,1fr)]">
        {/* 左侧：字典分组导航 */}
        <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card gap-3! py-3!">
          <CardHeader>
            <CardTitle className="flex items-center gap-1.5">
              字典分组
              <InfoHint>
                共 {catalog.length} 个字典；新增字典需登记用途说明
              </InfoHint>
            </CardTitle>
            <CardAction>
              <Button type="button" size="sm" onClick={openCreateDict}>
                <PlusIcon data-icon="inline-start" />
                新增字典
              </Button>
            </CardAction>
          </CardHeader>
          <CardContent className="p-4 md:p-6">
            {catalog.length === 0 ? (
              <p className="py-6 text-center text-sm text-muted-foreground">
                暂无字典
              </p>
            ) : (
              <div className="flex flex-row gap-2 overflow-x-auto pb-1 lg:flex-col lg:overflow-visible lg:pb-0">
                {catalog.map((row) => {
                  const active = row.dict_key === selectedKey;
                  return (
                    <button
                      key={row.dict_key}
                      type="button"
                      onClick={() => selectDict(row.dict_key)}
                      className={`flex min-w-[180px] flex-col gap-1 rounded-xl border p-3 text-left transition-colors focus-visible:outline-none lg:min-w-0 ${
                        active
                          ? "border-primary bg-accent"
                          : "hover:border-primary"
                      }`}
                    >
                      <span className="flex items-center justify-between gap-2">
                        <span className="font-mono text-xs">{row.dict_key}</span>
                        <Badge variant="outline">
                          {row.active_count}/{row.item_count}
                        </Badge>
                      </span>
                      <span className="line-clamp-2 text-xs text-muted-foreground">
                        {row.description}
                      </span>
                    </button>
                  );
                })}
              </div>
            )}
          </CardContent>
        </Card>

        {/* 右侧：字典项 Table */}
        <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card gap-3! py-3!">
          <CardHeader>
            <CardTitle className="flex items-center gap-2 font-mono text-base">
              <BookMarkedIcon className="size-4 text-muted-foreground" />
              {selectedKey === "" ? "字典项" : selectedKey}
              <InfoHint>
                {selectedMeta
                  ? selectedMeta.description
                  : "从左侧选择字典；value 建后不可改，停用项不再下发但存量展示不受影响"}
              </InfoHint>
            </CardTitle>
            <CardAction className="flex items-center gap-2">
              <Button
                type="button"
                size="sm"
                onClick={openCreateItem}
                disabled={selectedKey === ""}
              >
                <PlusIcon data-icon="inline-start" />
                新增字典项
              </Button>
            </CardAction>
          </CardHeader>
          <CardContent className="p-4 md:p-6">
            {selectedKey === "" ? (
              <p className="py-10 text-center text-sm text-muted-foreground">
                先新增或选择一个字典
              </p>
            ) : itemsLoading ? (
              <div className="flex flex-col gap-3">
                {Array.from({ length: 4 }).map((_, index) => (
                  <Skeleton key={index} className="h-9 w-full" />
                ))}
              </div>
            ) : itemsError ? (
              <div className="flex flex-col items-center gap-2 py-10 text-sm">
                <p className="text-destructive">
                  加载失败：{translateSystemErrorMessage(itemsError)}
                </p>
                <Button
                  variant="outline"
                  onClick={() => void loadItems(selectedKey)}
                >
                  重试
                </Button>
              </div>
            ) : items.length === 0 ? (
              <p className="py-10 text-center text-sm text-muted-foreground">
                该字典暂无项，点击右上角「新增字典项」创建
              </p>
            ) : (
              <>
                {/* 桌面：项 Table，整行可点编辑 */}
                <div className="hidden overflow-x-auto lg:block">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead className="text-center">value</TableHead>
                        <TableHead className="text-center">label</TableHead>
                        <TableHead className="text-center">排序</TableHead>
                        <TableHead className="text-center">配色预览</TableHead>
                        <TableHead className="text-center">状态</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {items.map((row) => {
                        const status = asDictItemStatus(row.status);
                        return (
                          <TableRow
                            key={row.value}
                            className="cursor-pointer"
                            onClick={() => openEditItem(row)}
                            tabIndex={0}
                            onKeyDown={(event) => {
                              if (event.key === "Enter") {
                                openEditItem(row);
                              }
                            }}
                          >
                            <TableCell className="text-left font-mono text-xs">
                              {row.value}
                            </TableCell>
                            <TableCell className="text-center">
                              {row.label}
                            </TableCell>
                            <TableCell className="text-center text-muted-foreground">
                              {row.sort_order}
                            </TableCell>
                            <TableCell className="text-center">
                              <ColorPreview
                                label={row.label}
                                colorClass={row.color_class ?? ""}
                              />
                            </TableCell>
                            <TableCell className="text-center">
                              <Badge
                                variant="outline"
                                className={DICT_STATUS_BADGE_CLASSES[status]}
                              >
                                {DICT_STATUS_LABELS[status]}
                              </Badge>
                            </TableCell>
                          </TableRow>
                        );
                      })}
                    </TableBody>
                  </Table>
                </div>

                {/* 移动端：项卡片 */}
                <div className="flex flex-col gap-2 lg:hidden">
                  {items.map((row) => {
                    const status = asDictItemStatus(row.status);
                    return (
                      <button
                        key={row.value}
                        type="button"
                        onClick={() => openEditItem(row)}
                        className="flex flex-col gap-2 rounded-xl border p-4 text-left transition-colors hover:border-primary focus-visible:border-primary focus-visible:outline-none"
                      >
                        <div className="flex items-center justify-between gap-2">
                          <span className="font-mono text-xs">{row.value}</span>
                          <Badge
                            variant="outline"
                            className={DICT_STATUS_BADGE_CLASSES[status]}
                          >
                            {DICT_STATUS_LABELS[status]}
                          </Badge>
                        </div>
                        <div className="flex items-center justify-between gap-2">
                          <span className="text-sm">{row.label}</span>
                          <ColorPreview
                            label={row.label}
                            colorClass={row.color_class ?? ""}
                          />
                        </div>
                        <div className="text-xs text-muted-foreground">
                          排序 {row.sort_order}
                        </div>
                      </button>
                    );
                  })}
                </div>
              </>
            )}
          </CardContent>
        </Card>
      </div>

      {/* 编辑 / 新增字典项 Sheet（value 建后不可改） */}
      <Sheet
        open={itemOpen}
        onOpenChange={(open) => {
          if (!savingItem) {
            setItemOpen(open);
          }
        }}
      >
        <SheetContent
          side="right"
          className="w-full sm:max-w-[480px]"
        >
          <SheetHeader className="border-b">
            <SheetTitle>
              {itemForm.mode === "create" ? "新增字典项" : "编辑字典项"}
            </SheetTitle>
            <SheetDescription className="font-mono text-xs">
              {itemForm.dictKey}
            </SheetDescription>
          </SheetHeader>
          <div className="flex flex-1 flex-col gap-4 overflow-y-auto px-4">
            <Field>
              <FieldLabel htmlFor="dict-item-value">value</FieldLabel>
              <Input
                id="dict-item-value"
                value={itemForm.value}
                onChange={(event) =>
                  setItemForm((prev) => ({ ...prev, value: event.target.value }))
                }
                placeholder="如 active"
                autoComplete="off"
                disabled={itemForm.mode === "edit"}
                className="h-11 font-mono lg:h-8"
              />
              <FieldDescription>
                {itemForm.mode === "edit"
                  ? "value 建后不可改（被业务数据引用）"
                  : "建后不可改，请确认命名"}
              </FieldDescription>
            </Field>
            <Field>
              <FieldLabel htmlFor="dict-item-label">label</FieldLabel>
              <Input
                id="dict-item-label"
                value={itemForm.label}
                onChange={(event) =>
                  setItemForm((prev) => ({ ...prev, label: event.target.value }))
                }
                placeholder="展示文案"
                autoComplete="off"
                className="h-11 lg:h-8"
              />
            </Field>
            <Field>
              <FieldLabel htmlFor="dict-item-sort">排序</FieldLabel>
              <Input
                id="dict-item-sort"
                inputMode="numeric"
                value={itemForm.sortOrder}
                onChange={(event) =>
                  setItemForm((prev) => ({
                    ...prev,
                    sortOrder: event.target.value,
                  }))
                }
                placeholder="10"
                autoComplete="off"
                className="h-11 lg:h-8"
              />
              <FieldDescription>升序，同序按 value</FieldDescription>
            </Field>
            <Field>
              <FieldLabel htmlFor="dict-item-color">配色</FieldLabel>
              <Select
                value={colorSelectValue(itemForm.colorClass)}
                onValueChange={(value) =>
                  setItemForm((prev) => ({
                    ...prev,
                    colorClass: value === NONE_COLOR ? "" : value,
                  }))
                }
              >
                <SelectTrigger
                  id="dict-item-color"
                  className="h-11 w-full lg:h-8"
                  aria-label="配色类名"
                >
                  <SelectValue placeholder="选择配色" />
                </SelectTrigger>
                <SelectContent>
                  {COLOR_OPTIONS.map((option) => (
                    <SelectItem key={option.value} value={option.value}>
                      {option.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <FieldDescription>
                <span className="flex items-center gap-2">
                  预览：
                  <ColorPreview
                    label={itemForm.label}
                    colorClass={itemForm.colorClass}
                  />
                </span>
              </FieldDescription>
            </Field>
            <Field>
              <FieldLabel htmlFor="dict-item-status">状态</FieldLabel>
              <Select
                value={itemForm.status}
                onValueChange={(value) =>
                  setItemForm((prev) => ({
                    ...prev,
                    status: asDictItemStatus(value),
                  }))
                }
              >
                <SelectTrigger
                  id="dict-item-status"
                  className="h-11 w-full lg:h-8"
                  aria-label="字典项状态"
                >
                  <SelectValue placeholder="选择状态" />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="active">启用</SelectItem>
                  <SelectItem value="disabled">停用（不再下发）</SelectItem>
                </SelectContent>
              </Select>
            </Field>
          </div>
          <SheetFooter className="flex-row items-center justify-end gap-2 border-t">
            <Button
              type="button"
              variant="outline"
              className="h-8"
              onClick={() => setItemOpen(false)}
              disabled={savingItem}
            >
              取消
            </Button>
            <Button
              type="button"
              className="h-8"
              onClick={() => void handleSaveItem()}
              disabled={savingItem}
            >
              {savingItem ? (
                <Loader2Icon className="size-3.5 animate-spin" data-icon="inline-start" />
              ) : (
                <SaveIcon className="size-3.5" data-icon="inline-start" />
              )}
              保存
            </Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>

      {/* 新增字典 Sheet：用途说明必填 + 首项 */}
      <Sheet
        open={createOpen}
        onOpenChange={(open) => {
          if (!creating) {
            setCreateOpen(open);
          }
        }}
      >
        <SheetContent
          side="right"
          className="w-full sm:max-w-[480px]"
        >
          <SheetHeader className="border-b">
            <SheetTitle>新增字典</SheetTitle>
            <SheetDescription className="text-xs">
              登记 dict_key 与用途说明，并创建首项；后续项在字典详情页添加
            </SheetDescription>
          </SheetHeader>
          <div className="flex flex-1 flex-col gap-4 overflow-y-auto px-4">
            <Field>
              <FieldLabel htmlFor="dict-key">dict_key</FieldLabel>
              <Input
                id="dict-key"
                value={createForm.dictKey}
                onChange={(event) =>
                  setCreateForm((prev) => ({
                    ...prev,
                    dictKey: event.target.value,
                  }))
                }
                placeholder="如 common.status"
                autoComplete="off"
                className="h-11 font-mono lg:h-8"
              />
              <FieldDescription>约定 &lt;域&gt;.&lt;名字&gt;，如 common.status</FieldDescription>
            </Field>
            <Field>
              <FieldLabel htmlFor="dict-description">用途说明（必填）</FieldLabel>
              <Input
                id="dict-description"
                value={createForm.description}
                onChange={(event) =>
                  setCreateForm((prev) => ({
                    ...prev,
                    description: event.target.value,
                  }))
                }
                placeholder="这个字典用于哪些模块、语义是什么"
                autoComplete="off"
                className="h-11 lg:h-8"
              />
            </Field>

            <div className="rounded-xl border p-3">
              <div className="mb-3 text-sm font-medium">首项</div>
              <div className="flex flex-col gap-4">
                <Field>
                  <FieldLabel htmlFor="dict-first-value">value</FieldLabel>
                  <Input
                    id="dict-first-value"
                    value={createForm.value}
                    onChange={(event) =>
                      setCreateForm((prev) => ({
                        ...prev,
                        value: event.target.value,
                      }))
                    }
                    placeholder="如 active"
                    autoComplete="off"
                    className="h-11 font-mono lg:h-8"
                  />
                </Field>
                <Field>
                  <FieldLabel htmlFor="dict-first-label">label</FieldLabel>
                  <Input
                    id="dict-first-label"
                    value={createForm.label}
                    onChange={(event) =>
                      setCreateForm((prev) => ({
                        ...prev,
                        label: event.target.value,
                      }))
                    }
                    placeholder="如 启用"
                    autoComplete="off"
                    className="h-11 lg:h-8"
                  />
                </Field>
                <Field>
                  <FieldLabel htmlFor="dict-first-sort">排序</FieldLabel>
                  <Input
                    id="dict-first-sort"
                    inputMode="numeric"
                    value={createForm.sortOrder}
                    onChange={(event) =>
                      setCreateForm((prev) => ({
                        ...prev,
                        sortOrder: event.target.value,
                      }))
                    }
                    placeholder="10"
                    autoComplete="off"
                    className="h-11 lg:h-8"
                  />
                </Field>
                <Field>
                  <FieldLabel htmlFor="dict-first-color">配色</FieldLabel>
                  <Select
                    value={colorSelectValue(createForm.colorClass)}
                    onValueChange={(value) =>
                      setCreateForm((prev) => ({
                        ...prev,
                        colorClass: value === NONE_COLOR ? "" : value,
                      }))
                    }
                  >
                    <SelectTrigger
                      id="dict-first-color"
                      className="h-11 w-full lg:h-8"
                      aria-label="首项配色类名"
                    >
                      <SelectValue placeholder="选择配色" />
                    </SelectTrigger>
                    <SelectContent>
                      {COLOR_OPTIONS.map((option) => (
                        <SelectItem key={option.value} value={option.value}>
                          {option.label}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </Field>
              </div>
            </div>
          </div>
          <SheetFooter className="flex-row items-center justify-end gap-2 border-t">
            <Button
              type="button"
              variant="outline"
              className="h-11 lg:h-8"
              onClick={() => setCreateOpen(false)}
              disabled={creating}
            >
              取消
            </Button>
            <Button
              type="button"
              className="h-11 lg:h-8"
              onClick={() => void handleCreateDict()}
              disabled={creating}
            >
              {creating ? (
                <Loader2Icon className="size-3.5 animate-spin" data-icon="inline-start" />
              ) : (
                <SaveIcon className="size-3.5" data-icon="inline-start" />
              )}
              创建
            </Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>
    </div>
  );
}
