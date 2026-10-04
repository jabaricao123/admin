"use client";

import * as React from "react";
import {
  ArrowLeftIcon,
  ArrowRightIcon,
  CheckIcon,
  FlaskConicalIcon,
  HistoryIcon,
  Loader2Icon,
  PlusIcon,
  SaveIcon,
  Trash2Icon,
  WorkflowIcon,
} from "lucide-react";
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
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Textarea } from "@/components/ui/textarea";
import { useIsMobile } from "@/hooks/use-mobile";
import { cn } from "@/lib/utils";
import type { Database, Json } from "@/lib/database.types";
import {
  asServiceVerifyStatus,
  asSyncConflictPolicy,
  asSyncDirection,
  asSyncRunStatus,
  asSyncStatus,
  asSyncTargetTable,
  SERVICE_VERIFY_STATUS_BADGE_CLASSES,
  SERVICE_VERIFY_STATUS_LABELS,
  SYNC_CONFLICT_POLICY_DESCRIPTIONS,
  SYNC_CONFLICT_POLICY_LABELS,
  SYNC_CONFLICT_POLICY_OPTIONS,
  SYNC_DIRECTION_OPTIONS,
  SYNC_RUN_STATUS_BADGE_CLASSES,
  SYNC_RUN_STATUS_LABELS,
  SYNC_SOURCE_TYPE_LABELS,
  SYNC_STATUS_BADGE_CLASSES,
  SYNC_STATUS_LABELS,
  SYNC_TARGET_FIELD_OPTIONS,
  SYNC_TARGET_TABLE_LABELS,
  SYNC_TARGET_TABLE_OPTIONS,
  translateSyncErrorMessage,
  type SyncConflictPolicy,
  type SyncDirection,
  type SyncStatus,
  type SyncTargetTable,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type TaskRow =
  Database["public"]["Functions"]["get_sync_tasks"]["Returns"][number];
type SourceRow =
  Database["public"]["Functions"]["get_sync_sources"]["Returns"][number];
type RunSummary =
  Database["public"]["Functions"]["get_sync_task_run_summaries"]["Returns"][number];
type UpsertTaskArgs =
  Database["public"]["Functions"]["upsert_sync_task"]["Args"];

type MappingDraft = {
  sourceField: string;
  targetField: string;
};

type TaskForm = {
  name: string;
  sourceId: string;
  targetTable: SyncTargetTable;
  direction: SyncDirection;
  mappings: MappingDraft[];
  conflictPolicy: SyncConflictPolicy;
  status: SyncStatus;
};

type DryRunNote = { code?: string; message?: string };

type DryRunResult = {
  insert?: number;
  update?: number;
  conflict?: number;
  skip?: number;
  sample_rows?: number;
  match_field?: string;
  conflict_policy?: string;
  notes?: DryRunNote[];
};

const STEP_LABELS = ["选择数据源", "目标与方向", "字段映射", "冲突与试跑"];

const EMPTY_FORM: TaskForm = {
  name: "",
  sourceId: "",
  targetTable: "departments",
  direction: "pull",
  mappings: [{ sourceField: "", targetField: "name" }],
  conflictPolicy: "skip",
  status: "active",
};

const asText = (value: unknown): string => {
  if (value === null || value === undefined) {
    return "";
  }
  return typeof value === "string" ? value : String(value);
};

const toMappings = (value: unknown, target: SyncTargetTable): MappingDraft[] => {
  const fallback = SYNC_TARGET_FIELD_OPTIONS[target][0]?.value ?? "name";
  if (!Array.isArray(value)) {
    return [{ sourceField: "", targetField: fallback }];
  }
  const drafts = value.flatMap((item) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      return [];
    }
    const record = item as Record<string, unknown>;
    const sourceField = asText(record.source_field);
    const targetField = asText(record.target_field);
    if (!sourceField && !targetField) {
      return [];
    }
    return [{ sourceField, targetField }];
  });
  return drafts.length ? drafts : [{ sourceField: "", targetField: fallback }];
};

const parseCsvLine = (line: string): string[] => {
  const cells: string[] = [];
  let current = "";
  let inQuotes = false;
  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];
    if (inQuotes) {
      if (char === '"') {
        if (line[index + 1] === '"') {
          current += '"';
          index += 1;
        } else {
          inQuotes = false;
        }
      } else {
        current += char;
      }
    } else if (char === '"') {
      inQuotes = true;
    } else if (char === ",") {
      cells.push(current);
      current = "";
    } else {
      current += char;
    }
  }
  cells.push(current);
  return cells.map((cell) => cell.trim());
};

/** 前端解析样本文件：JSON（数组或对象）与 CSV（首行为表头）；xlsx 请先另存为 CSV */
const parseSampleFile = async (
  file: File,
): Promise<Record<string, unknown>[]> => {
  const text = (await file.text()).trim();
  if (!text) {
    return [];
  }

  if (text.startsWith("[") || text.startsWith("{")) {
    const parsed: unknown = JSON.parse(text);
    const rows = Array.isArray(parsed) ? parsed : [parsed];
    return rows.filter(
      (row): row is Record<string, unknown> =>
        Boolean(row) && typeof row === "object" && !Array.isArray(row),
    );
  }

  const lines = text.split(/\r?\n/).filter((line) => line.trim() !== "");
  if (lines.length < 2) {
    return [];
  }
  const headers = parseCsvLine(lines[0]);
  return lines.slice(1).map((line) => {
    const cells = parseCsvLine(line);
    const row: Record<string, unknown> = {};
    headers.forEach((header, index) => {
      row[header] = cells[index] ?? "";
    });
    return row;
  });
};

export function SyncTasksTable() {
  const isMobile = useIsMobile();
  const [tasks, setTasks] = React.useState<TaskRow[]>([]);
  const [sources, setSources] = React.useState<SourceRow[]>([]);
  const [runSummaries, setRunSummaries] = React.useState<
    Record<string, RunSummary>
  >({});
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [sheetOpen, setSheetOpen] = React.useState(false);
  const [editing, setEditing] = React.useState<TaskRow | null>(null);
  const [step, setStep] = React.useState(1);
  const [form, setForm] = React.useState<TaskForm>(EMPTY_FORM);
  const [sampleText, setSampleText] = React.useState("");
  const [dryResult, setDryResult] = React.useState<DryRunResult | null>(null);
  const [saving, setSaving] = React.useState(false);
  const [dryRunning, setDryRunning] = React.useState(false);
  const [rollingBack, setRollingBack] = React.useState(false);

  const loadTasks = React.useCallback(async (): Promise<TaskRow[]> => {
    const supabase = createClient();
    const { data, error: loadError } = await supabase.rpc("get_sync_tasks");
    if (loadError) {
      throw new Error(loadError.message);
    }
    return data ?? [];
  }, []);

  const load = React.useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const supabase = createClient();
      const [taskRes, sourceRes, runRes] = await Promise.all([
        supabase.rpc("get_sync_tasks"),
        supabase.rpc("get_sync_sources"),
        supabase.rpc("get_sync_task_run_summaries"),
      ]);
      if (taskRes.error) {
        setError(taskRes.error.message);
        setTasks([]);
      } else {
        setTasks(taskRes.data ?? []);
      }
      setSources(sourceRes.error ? [] : (sourceRes.data ?? []));
      const summaryMap: Record<string, RunSummary> = {};
      for (const summary of runRes.error ? [] : (runRes.data ?? [])) {
        summaryMap[summary.task_id] = summary;
      }
      setRunSummaries(summaryMap);
    } catch (loadError) {
      setError(
        loadError instanceof Error ? loadError.message : String(loadError),
      );
      setTasks([]);
      setRunSummaries({});
    }
    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const selectedSource = React.useMemo(
    () => sources.find((source) => source.id === form.sourceId) ?? null,
    [sources, form.sourceId],
  );

  const sourceReady = selectedSource
    ? asServiceVerifyStatus(selectedSource.verify_status) === "verified" &&
      asSyncStatus(selectedSource.status) === "active"
    : false;

  const sampleFieldKeys = React.useMemo(() => {
    const text = sampleText.trim();
    if (!text) {
      return [];
    }
    try {
      const parsed: unknown = JSON.parse(text);
      const rows = Array.isArray(parsed) ? parsed : [parsed];
      const first = rows.find(
        (row): row is Record<string, unknown> =>
          Boolean(row) && typeof row === "object" && !Array.isArray(row),
      );
      return first ? Object.keys(first) : [];
    } catch {
      return [];
    }
  }, [sampleText]);

  const openCreate = () => {
    setEditing(null);
    setForm(EMPTY_FORM);
    setStep(1);
    setSampleText("");
    setDryResult(null);
    setSheetOpen(true);
  };

  const openEdit = (row: TaskRow) => {
    const target = asSyncTargetTable(row.target_table);
    setEditing(row);
    setForm({
      name: row.name,
      sourceId: row.source_id,
      targetTable: target,
      direction: asSyncDirection(row.direction),
      mappings: toMappings(row.field_mapping, target),
      conflictPolicy: asSyncConflictPolicy(row.conflict_policy),
      status: asSyncStatus(row.status),
    });
    setStep(1);
    setSampleText("");
    setDryResult(null);
    setSheetOpen(true);
  };

  const closeSheet = () => {
    setSheetOpen(false);
    setEditing(null);
    setForm(EMPTY_FORM);
    setStep(1);
    setSampleText("");
    setDryResult(null);
  };

  const validateStep = (current: number): boolean => {
    if (current === 1) {
      if (!form.name.trim()) {
        toast.error("任务名称不能为空");
        return false;
      }
      if (!form.sourceId) {
        toast.error("请选择数据源");
        return false;
      }
    }
    if (current === 3) {
      const complete = form.mappings.filter(
        (mapping) => mapping.sourceField.trim() && mapping.targetField,
      );
      if (complete.length === 0) {
        toast.error("至少配置一条完整的字段映射");
        return false;
      }
      if (
        form.mappings.some(
          (mapping) => !mapping.sourceField.trim() || !mapping.targetField,
        )
      ) {
        toast.error("存在未填写完整的映射行，请补齐或删除");
        return false;
      }
    }
    return true;
  };

  const nextStep = () => {
    if (!validateStep(step)) {
      return;
    }
    setStep((prev) => Math.min(4, prev + 1));
  };

  const previousStep = () => {
    setStep((prev) => Math.max(1, prev - 1));
  };

  const persistTask = async (options?: {
    silent?: boolean;
  }): Promise<TaskRow | null> => {
    if (!validateStep(1) || !validateStep(2) || !validateStep(3)) {
      return null;
    }

    setSaving(true);
    const supabase = createClient();
    const args = {
      p_id: editing?.id ?? null,
      p_name: form.name.trim(),
      p_source_id: form.sourceId,
      p_target_table: form.targetTable,
      p_direction: form.direction,
      p_field_mapping: form.mappings.map((mapping) => ({
        source_field: mapping.sourceField.trim(),
        target_field: mapping.targetField,
      })),
      p_conflict_policy: form.conflictPolicy,
      p_status: form.status,
    };
    const { data, error: saveError } = await supabase.rpc(
      "upsert_sync_task",
      args as UpsertTaskArgs,
    );
    setSaving(false);

    if (saveError) {
      toast.error(translateSyncErrorMessage(saveError.message));
      return null;
    }

    const result = (data ?? null) as { id?: string } | null;
    let saved: TaskRow | null = null;
    try {
      const nextTasks = await loadTasks();
      setTasks(nextTasks);
      saved = nextTasks.find((task) => task.id === result?.id) ?? null;
    } catch {
      saved = null;
    }
    if (saved) {
      setEditing(saved);
    }
    if (!options?.silent) {
      toast.success(editing ? "已保存" : "已新增");
    }
    return saved;
  };

  const handleSave = async () => {
    await persistTask();
  };

  const handleRollback = async () => {
    if (!editing || editing.config_version <= 1) {
      return;
    }
    const confirmed = window.confirm(
      `确定回滚任务「${editing.name}」到上一版配置？回滚会生成新版本 v${editing.config_version + 1}。`,
    );
    if (!confirmed) {
      return;
    }

    setRollingBack(true);
    const supabase = createClient();
    const { data, error: rollbackError } = await supabase.rpc(
      "rollback_sync_task",
      { p_task_id: editing.id },
    );
    setRollingBack(false);

    if (rollbackError) {
      toast.error(translateSyncErrorMessage(rollbackError.message));
      return;
    }

    const result = (data ?? null) as { config_version?: number } | null;
    const nextTasks = await loadTasks();
    setTasks(nextTasks);
    const row = nextTasks.find((task) => task.id === editing.id) ?? null;
    if (row) {
      setEditing(row);
      const target = asSyncTargetTable(row.target_table);
      setForm({
        name: row.name,
        sourceId: row.source_id,
        targetTable: target,
        direction: asSyncDirection(row.direction),
        mappings: toMappings(row.field_mapping, target),
        conflictPolicy: asSyncConflictPolicy(row.conflict_policy),
        status: asSyncStatus(row.status),
      });
    }
    toast.success(`已回滚到上一版（新版本 v${result?.config_version ?? "?"}）`);
  };

  const handleDryRun = async () => {
    let sample: unknown = [];
    const text = sampleText.trim();
    if (text) {
      try {
        sample = JSON.parse(text);
      } catch {
        toast.error("样本不是合法 JSON 文本");
        return;
      }
    }
    if (!Array.isArray(sample)) {
      toast.error("样本需为 JSON 数组（每行一个对象）");
      return;
    }

    setDryRunning(true);
    let taskId = editing?.id ?? null;
    if (!taskId) {
      const saved = await persistTask({ silent: true });
      if (!saved) {
        setDryRunning(false);
        return;
      }
      taskId = saved.id;
      toast.success("任务已作为草稿保存，继续试跑");
    }

    const supabase = createClient();
    const { data, error: dryRunError } = await supabase.rpc(
      "dry_run_sync_task",
      { p_task_id: taskId, p_sample: sample as Json },
    );
    setDryRunning(false);

    if (dryRunError) {
      toast.error(translateSyncErrorMessage(dryRunError.message));
      return;
    }

    setDryResult((data ?? null) as DryRunResult | null);
  };

  const handleSampleFile = async (
    event: React.ChangeEvent<HTMLInputElement>,
  ) => {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) {
      return;
    }
    try {
      const rows = await parseSampleFile(file);
      if (rows.length === 0) {
        toast.error("未从文件中解析出样本行");
        return;
      }
      setSampleText(JSON.stringify(rows, null, 2));
      setDryResult(null);
      toast.success(`已解析 ${rows.length} 行样本`);
    } catch {
      toast.error("样本文件解析失败（支持 JSON / CSV；xlsx 请先另存为 CSV）");
    }
  };

  const changeTargetTable = (target: SyncTargetTable) => {
    setForm((prev) => {
      if (prev.targetTable === target) {
        return prev;
      }
      const fallback = SYNC_TARGET_FIELD_OPTIONS[target][0]?.value ?? "name";
      return {
        ...prev,
        targetTable: target,
        mappings: prev.mappings.map((mapping) => ({
          sourceField: mapping.sourceField,
          targetField: fallback,
        })),
      };
    });
    setDryResult(null);
  };

  const targetFieldOptions = SYNC_TARGET_FIELD_OPTIONS[form.targetTable];

  /** 「最近执行」列：读 sync_runs 最新一条摘要（get_sync_task_run_summaries） */
  const renderLastRun = (taskId: string) => {
    const summary = runSummaries[taskId];
    if (!summary) {
      return <span className="text-xs text-muted-foreground">—</span>;
    }
    const status = asSyncRunStatus(summary.status);
    const time = summary.started_at
      ? new Date(summary.started_at).toLocaleString("zh-CN", {
          month: "2-digit",
          day: "2-digit",
          hour: "2-digit",
          minute: "2-digit",
          hour12: false,
        })
      : "";
    return (
      <span className="flex items-center justify-center gap-2">
        <Badge
          variant="outline"
          className={SYNC_RUN_STATUS_BADGE_CLASSES[status]}
        >
          {SYNC_RUN_STATUS_LABELS[status]}
        </Badge>
        <span className="text-xs text-muted-foreground">{time}</span>
      </span>
    );
  };

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex items-center justify-end gap-2">
            <Button
              onClick={openCreate}
              className="h-11 flex-1 lg:h-8 lg:flex-none"
            >
              <PlusIcon data-icon="inline-start" />
              新增任务
            </Button>
          </div>

          {loading ? (
            <div className="flex flex-col gap-2">
              {Array.from({ length: 4 }).map((_, index) => (
                <Skeleton key={index} className="h-12 w-full" />
              ))}
            </div>
          ) : error ? (
            <div className="flex flex-col items-center gap-2 py-8 text-sm">
              <p className="text-destructive">
                加载失败：{translateSyncErrorMessage(error)}
              </p>
              <Button variant="outline" onClick={() => void load()}>
                重试
              </Button>
            </div>
          ) : tasks.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <WorkflowIcon className="size-8 opacity-60" />
              <span>暂无同步任务，点击「新增任务」创建</span>
            </div>
          ) : isMobile ? (
            <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
              {tasks.map((row) => {
                const status = asSyncStatus(row.status);
                return (
                  <button
                    key={row.id}
                    type="button"
                    data-slot="sync-task-card"
                    onClick={() => openEdit(row)}
                    className="flex w-full flex-col gap-2 rounded-xl border bg-card p-3 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                  >
                    <div className="flex items-start justify-between gap-3">
                      <div className="min-w-0">
                        <div className="truncate font-medium">{row.name}</div>
                        <div className="truncate text-xs leading-tight text-muted-foreground">
                          {row.source_name} · v{row.config_version}
                        </div>
                      </div>
                      <Badge
                        variant="outline"
                        className={SYNC_STATUS_BADGE_CLASSES[status]}
                      >
                        {SYNC_STATUS_LABELS[status]}
                      </Badge>
                    </div>
                    <div className="flex flex-wrap items-center gap-1.5">
                      <Badge variant="outline">
                        {SYNC_TARGET_TABLE_LABELS[
                          asSyncTargetTable(row.target_table)
                        ]}
                      </Badge>
                      <Badge variant="outline">
                        {asSyncDirection(row.direction) === "push"
                          ? "推送"
                          : "拉取"}
                      </Badge>
                      <Badge variant="outline">
                        {SYNC_CONFLICT_POLICY_LABELS[
                          asSyncConflictPolicy(row.conflict_policy)
                        ]}
                      </Badge>
                    </div>
                    <div className="flex items-center justify-between gap-4 text-sm">
                      <span className="text-muted-foreground">最近执行</span>
                      {renderLastRun(row.id)}
                    </div>
                  </button>
                );
              })}
            </div>
          ) : (
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="text-center">任务名</TableHead>
                    <TableHead className="text-center">数据源</TableHead>
                    <TableHead className="text-center">目标表</TableHead>
                    <TableHead className="text-center">方向</TableHead>
                    <TableHead className="text-center">冲突策略</TableHead>
                    <TableHead className="text-center">状态</TableHead>
                    <TableHead className="text-center">版本</TableHead>
                    <TableHead className="text-center">最近执行</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {tasks.map((row) => {
                    const status = asSyncStatus(row.status);
                    return (
                      <TableRow
                        key={row.id}
                        className="cursor-pointer"
                        onClick={() => openEdit(row)}
                      >
                        <TableCell className="text-center font-medium">
                          {row.name}
                        </TableCell>
                        <TableCell className="text-center">
                          {row.source_name}
                        </TableCell>
                        <TableCell className="text-center">
                          {
                            SYNC_TARGET_TABLE_LABELS[
                              asSyncTargetTable(row.target_table)
                            ]
                          }
                        </TableCell>
                        <TableCell className="text-center">
                          {asSyncDirection(row.direction) === "push"
                            ? "推送"
                            : "拉取"}
                        </TableCell>
                        <TableCell className="text-center">
                          {
                            SYNC_CONFLICT_POLICY_LABELS[
                              asSyncConflictPolicy(row.conflict_policy)
                            ]
                          }
                        </TableCell>
                        <TableCell className="text-center">
                          <Badge
                            variant="outline"
                            className={SYNC_STATUS_BADGE_CLASSES[status]}
                          >
                            {SYNC_STATUS_LABELS[status]}
                          </Badge>
                        </TableCell>
                        <TableCell className="text-center text-xs text-muted-foreground">
                          v{row.config_version}
                        </TableCell>
                        <TableCell className="text-center">
                          {renderLastRun(row.id)}
                        </TableCell>
                      </TableRow>
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
          className="w-full overflow-hidden sm:max-w-3xl"
        >
          <SheetHeader>
            <SheetTitle>{editing ? "编辑同步任务" : "新增同步任务"}</SheetTitle>
            <SheetDescription className="flex flex-wrap items-center gap-2">
              {editing ? (
                <>
                  <span className="font-medium text-foreground">
                    {editing.name}
                  </span>
                  <Badge variant="outline">
                    <HistoryIcon data-icon="inline-start" />v
                    {editing.config_version}
                  </Badge>
                </>
              ) : (
                <span>四步向导：选源 → 目标与方向 → 字段映射 → 冲突策略与试跑</span>
              )}
            </SheetDescription>
          </SheetHeader>

          <div className="flex items-center gap-1 overflow-x-auto px-4">
            {STEP_LABELS.map((label, index) => {
              const stepNumber = index + 1;
              const active = step === stepNumber;
              const done = step > stepNumber;
              return (
                <React.Fragment key={label}>
                  <div
                    className={cn(
                      "flex shrink-0 items-center gap-1.5 text-xs",
                      active
                        ? "font-medium text-foreground"
                        : "text-muted-foreground",
                    )}
                  >
                    <span
                      className={cn(
                        "flex size-5 items-center justify-center rounded-full border text-[11px]",
                        active
                          ? "border-primary bg-primary text-primary-foreground"
                          : done
                            ? "border-emerald-500 text-emerald-600"
                            : "border-border",
                      )}
                    >
                      {done ? <CheckIcon className="size-3" /> : stepNumber}
                    </span>
                    <span className="hidden sm:inline">{label}</span>
                  </div>
                  {index < STEP_LABELS.length - 1 ? (
                    <span className="h-px w-4 shrink-0 bg-border" />
                  ) : null}
                </React.Fragment>
              );
            })}
          </div>

          <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-4">
            {step === 1 ? (
              <>
                <Field>
                  <FieldLabel htmlFor="sync-task-name">任务名称</FieldLabel>
                  <Input
                    id="sync-task-name"
                    value={form.name}
                    onChange={(event) =>
                      setForm((prev) => ({ ...prev, name: event.target.value }))
                    }
                    placeholder="如：CRM 部门同步"
                  />
                </Field>
                <Field>
                  <FieldLabel htmlFor="sync-task-source">数据源</FieldLabel>
                  {sources.length === 0 ? (
                    <FieldDescription>
                      暂无数据源，请先到「数据源配置」页创建
                    </FieldDescription>
                  ) : (
                    <>
                      <Select
                        value={form.sourceId}
                        onValueChange={(value) =>
                          setForm((prev) => ({ ...prev, sourceId: value }))
                        }
                      >
                        <SelectTrigger id="sync-task-source" className="w-full">
                          <SelectValue placeholder="选择数据源" />
                        </SelectTrigger>
                        <SelectContent>
                          {sources.map((source) => (
                            <SelectItem key={source.id} value={source.id}>
                              {source.name}（
                              {
                                SYNC_SOURCE_TYPE_LABELS[
                                  source.type === "db" || source.type === "excel"
                                    ? source.type
                                    : "api"
                                ]
                              }
                              ·{" "}
                              {
                                SERVICE_VERIFY_STATUS_LABELS[
                                  asServiceVerifyStatus(source.verify_status)
                                ]
                              }
                              ）
                            </SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                      {selectedSource ? (
                        <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
                          <Badge
                            variant="outline"
                            className={
                              SERVICE_VERIFY_STATUS_BADGE_CLASSES[
                                asServiceVerifyStatus(
                                  selectedSource.verify_status,
                                )
                              ]
                            }
                          >
                            {
                              SERVICE_VERIFY_STATUS_LABELS[
                                asServiceVerifyStatus(
                                  selectedSource.verify_status,
                                )
                              ]
                            }
                          </Badge>
                          <Badge
                            variant="outline"
                            className={
                              SYNC_STATUS_BADGE_CLASSES[
                                asSyncStatus(selectedSource.status)
                              ]
                            }
                          >
                            {
                              SYNC_STATUS_LABELS[
                                asSyncStatus(selectedSource.status)
                              ]
                            }
                          </Badge>
                          {!sourceReady ? (
                            <span className="text-amber-600 dark:text-amber-400">
                              该数据源未验证通过（或已停用）：任务只能保存为「停用」草稿
                            </span>
                          ) : null}
                        </div>
                      ) : null}
                    </>
                  )}
                </Field>
              </>
            ) : null}

            {step === 2 ? (
              <>
                <Field>
                  <FieldLabel htmlFor="sync-task-target">目标表</FieldLabel>
                  <Select
                    value={form.targetTable}
                    onValueChange={(value) =>
                      changeTargetTable(value as SyncTargetTable)
                    }
                  >
                    <SelectTrigger id="sync-task-target" className="w-full">
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {SYNC_TARGET_TABLE_OPTIONS.map((option) => (
                        <SelectItem key={option.value} value={option.value}>
                          {option.label}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <FieldDescription>
                    白名单：departments / positions / profiles；
                    profiles 按既有 email 匹配且仅更新不新建
                  </FieldDescription>
                </Field>
                <Field>
                  <FieldLabel htmlFor="sync-task-direction">同步方向</FieldLabel>
                  <Select
                    value={form.direction}
                    onValueChange={(value) =>
                      setForm((prev) => ({
                        ...prev,
                        direction: value as SyncDirection,
                      }))
                    }
                  >
                    <SelectTrigger id="sync-task-direction" className="w-full">
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {SYNC_DIRECTION_OPTIONS.map((option) => (
                        <SelectItem key={option.value} value={option.value}>
                          {option.label}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </Field>
              </>
            ) : null}

            {step === 3 ? (
              <>
                <div className="flex items-center justify-between gap-2">
                  <div>
                    <div className="text-sm font-medium">字段映射</div>
                    <p className="text-xs text-muted-foreground">
                      左侧为源字段名（可来自样本），右侧为目标字段（
                      {SYNC_TARGET_TABLE_LABELS[form.targetTable]}白名单）
                    </p>
                  </div>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    onClick={() =>
                      setForm((prev) => ({
                        ...prev,
                        mappings: [
                          ...prev.mappings,
                          {
                            sourceField: "",
                            targetField:
                              SYNC_TARGET_FIELD_OPTIONS[prev.targetTable][0]
                                ?.value ?? "name",
                          },
                        ],
                      }))
                    }
                  >
                    <PlusIcon data-icon="inline-start" />
                    添加映射
                  </Button>
                </div>
                <datalist id="sync-sample-fields">
                  {sampleFieldKeys.map((key) => (
                    <option key={key} value={key} />
                  ))}
                </datalist>
                <div className="flex flex-col gap-2">
                  {form.mappings.map((mapping, index) => (
                    <div key={index} className="flex items-center gap-2">
                      <Input
                        value={mapping.sourceField}
                        list="sync-sample-fields"
                        onChange={(event) =>
                          setForm((prev) => ({
                            ...prev,
                            mappings: prev.mappings.map((item, itemIndex) =>
                              itemIndex === index
                                ? { ...item, sourceField: event.target.value }
                                : item,
                            ),
                          }))
                        }
                        placeholder="源字段名"
                        aria-label={`第 ${index + 1} 行源字段`}
                        autoComplete="off"
                      />
                      <ArrowRightIcon className="size-4 shrink-0 text-muted-foreground" />
                      <Select
                        value={mapping.targetField}
                        onValueChange={(value) =>
                          setForm((prev) => ({
                            ...prev,
                            mappings: prev.mappings.map((item, itemIndex) =>
                              itemIndex === index
                                ? { ...item, targetField: value }
                                : item,
                            ),
                          }))
                        }
                      >
                        <SelectTrigger
                          className="w-44 shrink-0"
                          aria-label={`第 ${index + 1} 行目标字段`}
                        >
                          <SelectValue placeholder="目标字段" />
                        </SelectTrigger>
                        <SelectContent>
                          {targetFieldOptions.map((option) => (
                            <SelectItem key={option.value} value={option.value}>
                              {option.label}
                            </SelectItem>
                          ))}
                        </SelectContent>
                      </Select>
                      <Button
                        type="button"
                        variant="ghost"
                        size="icon"
                        aria-label="删除该映射行"
                        disabled={form.mappings.length <= 1}
                        onClick={() =>
                          setForm((prev) => ({
                            ...prev,
                            mappings: prev.mappings.filter(
                              (_, itemIndex) => itemIndex !== index,
                            ),
                          }))
                        }
                      >
                        <Trash2Icon />
                      </Button>
                    </div>
                  ))}
                </div>
                {form.targetTable === "profiles" ? (
                  <p className="text-xs text-muted-foreground">
                    用户档案目标字段不含 role / status：角色走权限管理单通道，启停用走用户管理
                    RPC（INDEX 规则 7）
                  </p>
                ) : null}
              </>
            ) : null}

            {step === 4 ? (
              <>
                <Field>
                  <FieldLabel htmlFor="sync-task-policy">冲突策略</FieldLabel>
                  <Select
                    value={form.conflictPolicy}
                    onValueChange={(value) =>
                      setForm((prev) => ({
                        ...prev,
                        conflictPolicy: value as SyncConflictPolicy,
                      }))
                    }
                  >
                    <SelectTrigger id="sync-task-policy" className="w-full">
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {SYNC_CONFLICT_POLICY_OPTIONS.map((option) => (
                        <SelectItem key={option.value} value={option.value}>
                          {option.label}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                  <FieldDescription>
                    {SYNC_CONFLICT_POLICY_DESCRIPTIONS[form.conflictPolicy]}
                  </FieldDescription>
                </Field>

                <Field>
                  <FieldLabel htmlFor="sync-task-status">任务状态</FieldLabel>
                  <Select
                    value={form.status}
                    onValueChange={(value) =>
                      setForm((prev) => ({
                        ...prev,
                        status: value as SyncStatus,
                      }))
                    }
                  >
                    <SelectTrigger id="sync-task-status" className="w-full">
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="active">启用</SelectItem>
                      <SelectItem value="disabled">停用（草稿）</SelectItem>
                    </SelectContent>
                  </Select>
                  <FieldDescription>
                    {sourceReady
                      ? "启用任务要求数据源已启用且验证通过"
                      : "当前数据源未验证通过（或已停用）：启用保存会被服务端拒绝，请先选择停用或去验证数据源"}
                  </FieldDescription>
                </Field>

                <div className="flex flex-col gap-3 rounded-xl border p-4">
                  <div className="text-sm font-medium">试跑（dry-run）</div>
                  <p className="text-xs text-muted-foreground">
                    粘贴 JSON 样本（每行一个对象，键可用源字段名），或上传
                    JSON / CSV 文件；试跑仅统计将新增 / 更新 / 冲突 / 跳过的行数，不写业务表
                  </p>
                  <Textarea
                    rows={5}
                    value={sampleText}
                    onChange={(event) => {
                      setSampleText(event.target.value);
                      setDryResult(null);
                    }}
                    placeholder='[{"dept_name":"研发中心","parent":"总部"},{"dept_name":"新部门"}]'
                    aria-label="试跑样本 JSON"
                    className="font-mono text-xs"
                  />
                  <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
                    <Input
                      type="file"
                      accept=".json,.csv,.txt"
                      onChange={(event) => void handleSampleFile(event)}
                      aria-label="上传样本文件"
                      className="sm:max-w-xs"
                    />
                    <Button
                      type="button"
                      variant="outline"
                      onClick={() => void handleDryRun()}
                      disabled={dryRunning || saving}
                      className="h-11 lg:h-8"
                    >
                      {dryRunning ? (
                        <Loader2Icon
                          className="animate-spin"
                          data-icon="inline-start"
                        />
                      ) : (
                        <FlaskConicalIcon data-icon="inline-start" />
                      )}
                      运行试跑
                    </Button>
                  </div>

                  {dryResult ? (
                    <div className="flex flex-col gap-3">
                      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
                        {[
                          {
                            label: "新增",
                            value: dryResult.insert ?? 0,
                            className: "text-emerald-600 dark:text-emerald-400",
                          },
                          {
                            label: "更新",
                            value: dryResult.update ?? 0,
                            className: "text-blue-600 dark:text-blue-400",
                          },
                          {
                            label: "冲突",
                            value: dryResult.conflict ?? 0,
                            className: "text-amber-600 dark:text-amber-400",
                          },
                          {
                            label: "跳过",
                            value: dryResult.skip ?? 0,
                            className: "text-muted-foreground",
                          },
                        ].map((item) => (
                          <div
                            key={item.label}
                            className="rounded-xl border p-3 text-center"
                          >
                            <div
                              className={cn(
                                "text-2xl font-semibold",
                                item.className,
                              )}
                            >
                              {item.value}
                            </div>
                            <div className="text-xs text-muted-foreground">
                              {item.label}
                            </div>
                          </div>
                        ))}
                      </div>
                      <p className="text-xs text-muted-foreground">
                        样本 {dryResult.sample_rows ?? 0} 行 · 匹配键{" "}
                        {dryResult.match_field ?? "—"} · 策略{" "}
                        {dryResult.conflict_policy
                          ? SYNC_CONFLICT_POLICY_LABELS[
                              asSyncConflictPolicy(dryResult.conflict_policy)
                            ]
                          : "—"}
                      </p>
                      {(dryResult.notes ?? []).length > 0 ? (
                        <ul className="flex list-disc flex-col gap-1 pl-4 text-xs text-muted-foreground">
                          {(dryResult.notes ?? []).map((note, index) => (
                            <li key={`${note.code ?? "note"}-${index}`}>
                              {note.message}
                            </li>
                          ))}
                        </ul>
                      ) : null}
                    </div>
                  ) : null}
                </div>
              </>
            ) : null}
          </div>

          <SheetFooter className="flex-row justify-end gap-2">
            {editing && editing.config_version > 1 ? (
              <Button
                variant="outline"
                className="mr-auto"
                onClick={() => void handleRollback()}
                disabled={rollingBack || saving}
              >
                {rollingBack ? (
                  <Loader2Icon
                    className="animate-spin"
                    data-icon="inline-start"
                  />
                ) : (
                  <HistoryIcon data-icon="inline-start" />
                )}
                回滚上一版
              </Button>
            ) : null}
            <Button
              variant="outline"
              onClick={step > 1 ? previousStep : closeSheet}
              className="h-11 lg:h-8"
            >
              {step > 1 ? (
                <>
                  <ArrowLeftIcon data-icon="inline-start" />
                  上一步
                </>
              ) : (
                "取消"
              )}
            </Button>
            {step < 4 ? (
              <Button onClick={nextStep} disabled={saving}>
                下一步
                <ArrowRightIcon data-icon="inline-end" />
              </Button>
            ) : (
              <Button
                onClick={() => void handleSave()}
                disabled={saving}
                className="h-11 lg:h-8"
              >
                {saving ? (
                  <Loader2Icon
                    className="animate-spin"
                    data-icon="inline-start"
                  />
                ) : (
                  <SaveIcon data-icon="inline-start" />
                )}
                保存任务
              </Button>
            )}
          </SheetFooter>
        </SheetContent>
      </Sheet>
    </div>
  );
}
