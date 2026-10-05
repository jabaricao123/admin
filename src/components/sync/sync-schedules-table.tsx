"use client";

import * as React from "react";
import {
  CalendarClockIcon,
  CalendarPlusIcon,
  CopyIcon,
  KeyRoundIcon,
  Loader2Icon,
  PlayIcon,
  SaveIcon,
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
import { Sheet, SheetContent, SheetDescription, SheetFooter, SheetHeader, SheetTitle } from "@/components/ui/sheet";
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
import { useIsMobile } from "@/hooks/use-mobile";
import { cn } from "@/lib/utils";
import type { Database, Json } from "@/lib/database.types";
import {
  asSyncScheduleStatus,
  asSyncTriggerType,
  describeCronExpr,
  SYNC_CRON_PRESET_LABELS,
  SYNC_CRON_PRESET_OPTIONS,
  SYNC_SCHEDULE_STATUS_BADGE_CLASSES,
  SYNC_SCHEDULE_STATUS_LABELS,
  SYNC_TARGET_TABLE_LABELS,
  asSyncTargetTable,
  SYNC_TRIGGER_TYPE_LABELS,
  SYNC_TRIGGER_TYPE_OPTIONS,
  SYNC_WARNING_TEXT_CLASS,
  SYNC_WEEKDAY_LABELS,
  translateSyncErrorMessage,
  type SyncCronPreset,
  type SyncTriggerType,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type ScheduleRow =
  Database["public"]["Functions"]["get_sync_schedules"]["Returns"][number];
type TaskRow =
  Database["public"]["Functions"]["get_sync_tasks"]["Returns"][number];

type ScheduleForm = {
  taskId: string;
  triggerType: SyncTriggerType;
  preset: SyncCronPreset;
  dailyTime: string;
  weekday: string;
  customCron: string;
  timezone: string;
  status: "active" | "disabled";
};

const EMPTY_FORM: ScheduleForm = {
  taskId: "",
  triggerType: "manual",
  preset: "daily",
  dailyTime: "09:00",
  weekday: "1",
  customCron: "0 9 * * *",
  timezone: "Asia/Shanghai",
  status: "active",
};

const formatDateTime = (value: string | null | undefined): string => {
  if (!value) {
    return "—";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }
  return date.toLocaleString("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
};

const splitTime = (time: string): { hour: string; minute: string } => {
  const [hour = "09", minute = "00"] = time.split(":");
  return { hour, minute };
};

/** 由预设构建 cron 表达式 */
const buildCronExpr = (form: ScheduleForm): string => {
  if (form.preset === "hourly") {
    return "0 * * * *";
  }
  if (form.preset === "custom") {
    return form.customCron.trim();
  }
  const { hour, minute } = splitTime(form.dailyTime);
  if (form.preset === "weekly") {
    return `${Number(minute)} ${Number(hour)} * * ${form.weekday}`;
  }
  return `${Number(minute)} ${Number(hour)} * * *`;
};

/** 反向解析已有表达式到表单（不匹配预设时落 custom） */
const parseCronExpr = (
  expr: string | null | undefined,
): { preset: SyncCronPreset; dailyTime: string; weekday: string } => {
  const value = (expr ?? "").trim();
  if (value === "0 * * * *") {
    return { preset: "hourly", dailyTime: "09:00", weekday: "1" };
  }
  const parts = value.split(/\s+/);
  if (
    parts.length === 5 &&
    /^\d{1,2}$/.test(parts[0]) &&
    /^\d{1,2}$/.test(parts[1]) &&
    parts[2] === "*" &&
    parts[3] === "*"
  ) {
    const dailyTime = `${parts[1].padStart(2, "0")}:${parts[0].padStart(2, "0")}`;
    if (parts[4] === "*") {
      return { preset: "daily", dailyTime, weekday: "1" };
    }
    if (/^\d$/.test(parts[4])) {
      return { preset: "weekly", dailyTime, weekday: parts[4] };
    }
  }
  return { preset: "custom", dailyTime: "09:00", weekday: "1" };
};

export function SyncSchedulesTable() {
  const isMobile = useIsMobile();
  const [schedules, setSchedules] = React.useState<ScheduleRow[]>([]);
  const [tasks, setTasks] = React.useState<TaskRow[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [sheetOpen, setSheetOpen] = React.useState(false);
  const [editing, setEditing] = React.useState<ScheduleRow | null>(null);
  const [form, setForm] = React.useState<ScheduleForm>(EMPTY_FORM);
  const [generatedToken, setGeneratedToken] = React.useState<string | null>(
    null,
  );
  const [saving, setSaving] = React.useState(false);
  const [togglingId, setTogglingId] = React.useState<string | null>(null);
  const [sampleText, setSampleText] = React.useState("");
  const [running, setRunning] = React.useState(false);

  const load = React.useCallback(async (): Promise<ScheduleRow[]> => {
    setLoading(true);
    setError(null);
    let items: ScheduleRow[] = [];
    try {
      const supabase = createClient();
      const [scheduleRes, taskRes] = await Promise.all([
        supabase.rpc("get_sync_schedules"),
        supabase.rpc("get_sync_tasks"),
      ]);
      if (scheduleRes.error) {
        setError(scheduleRes.error.message);
        setSchedules([]);
      } else {
        items = scheduleRes.data ?? [];
        setSchedules(items);
      }
      setTasks(taskRes.error ? [] : (taskRes.data ?? []));
    } catch (loadError) {
      setError(
        loadError instanceof Error ? loadError.message : String(loadError),
      );
      setSchedules([]);
    }
    setLoading(false);
    return items;
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const openCreate = () => {
    setEditing(null);
    setForm(EMPTY_FORM);
    setGeneratedToken(null);
    setSampleText("");
    setSheetOpen(true);
  };

  const openEdit = (row: ScheduleRow) => {
    const trigger = asSyncTriggerType(row.trigger_type);
    const cron = parseCronExpr(row.cron_expr);
    setEditing(row);
    setForm({
      taskId: row.task_id,
      triggerType: trigger,
      preset: cron.preset,
      dailyTime: cron.dailyTime,
      weekday: cron.weekday,
      customCron: (row.cron_expr ?? "").trim() || "0 9 * * *",
      timezone: row.timezone || "Asia/Shanghai",
      status: asSyncScheduleStatus(row.status) === "active" ? "active" : "disabled",
    });
    setGeneratedToken(null);
    setSampleText("");
    setSheetOpen(true);
  };

  const closeSheet = () => {
    setSheetOpen(false);
    setEditing(null);
    setGeneratedToken(null);
    setSampleText("");
  };

  const applySaved = (data: Json | null) => {
    const result = (data ?? null) as {
      id?: string;
      status?: string;
      webhook_token?: string | null;
    } | null;
    if (result?.webhook_token) {
      setGeneratedToken(result.webhook_token);
    }
    return result;
  };

  const handleSave = async () => {
    if (!form.taskId) {
      toast.error("请选择同步任务");
      return;
    }
    if (form.triggerType === "cron" && !buildCronExpr(form)) {
      toast.error("请填写 cron 表达式");
      return;
    }

    setSaving(true);
    const supabase = createClient();
    const { data, error: saveError } = await supabase.rpc(
      "upsert_sync_schedule",
      {
        p_task_id: form.taskId,
        p_trigger_type: form.triggerType,
        p_cron_expr:
          form.triggerType === "cron" ? buildCronExpr(form) : undefined,
        p_timezone: form.timezone.trim() || "Asia/Shanghai",
        p_status: form.status,
        p_regenerate_token: false,
      },
    );
    setSaving(false);

    if (saveError) {
      toast.error(translateSyncErrorMessage(saveError.message));
      return;
    }

    const result = applySaved(data);
    if (result?.status === "disabled_pending_unschedule") {
      toast.success("已停用，当次执行完成后将注销定时任务");
    } else {
      toast.success(editing ? "已保存" : "已创建调度");
    }
    const items = await load();

    // 用服务端最新行回填编辑态：Sheet 状态 Select 与后端一致（含停用待注销瞬态）
    if (editing) {
      const updated = items.find((item) => item.id === editing.id) ?? null;
      if (updated) {
        setEditing(updated);
        setForm((prev) => ({
          ...prev,
          status:
            asSyncScheduleStatus(updated.status) === "active"
              ? "active"
              : "disabled",
        }));
      }
    }
  };

  const handleRegenerateToken = async () => {
    if (!form.taskId) {
      return;
    }
    setSaving(true);
    const supabase = createClient();
    const { data, error: rotateError } = await supabase.rpc(
      "upsert_sync_schedule",
      {
        p_task_id: form.taskId,
        p_trigger_type: form.triggerType,
        p_cron_expr:
          form.triggerType === "cron" ? buildCronExpr(form) : undefined,
        p_timezone: form.timezone.trim() || "Asia/Shanghai",
        p_status: form.status,
        p_regenerate_token: true,
      },
    );
    setSaving(false);
    if (rotateError) {
      toast.error(translateSyncErrorMessage(rotateError.message));
      return;
    }
    applySaved(data);
    toast.success("token 已重置，旧 token 立即失效");
    await load();
  };

  const handleToggle = async (row: ScheduleRow, enabled: boolean) => {
    setTogglingId(row.id);
    const supabase = createClient();
    const { data, error: toggleError } = await supabase.rpc(
      "set_sync_schedule_status",
      {
        p_task_id: row.task_id,
        p_status: enabled ? "active" : "disabled",
      },
    );
    setTogglingId(null);

    if (toggleError) {
      toast.error(translateSyncErrorMessage(toggleError.message));
      return;
    }

    const result = (data ?? null) as {
      status?: string;
      webhook_token?: string | null;
    } | null;

    // 先取服务端最新行，再用新行打开 Sheet（三态：active/disabled/disabled_pending_unschedule）
    const items = await load();
    const updated = items.find((item) => item.id === row.id) ?? row;

    if (!enabled) {
      toast.success(
        asSyncScheduleStatus(result?.status ?? updated.status) ===
          "disabled_pending_unschedule"
          ? "已停用，当次执行完成后将注销定时任务"
          : "已停用",
      );
      return;
    }

    if (result?.webhook_token) {
      openEdit(updated);
      setGeneratedToken(result.webhook_token);
      toast.success("已启用并生成 webhook token");
      return;
    }
    toast.success("已启用");
  };

  const handleManualRun = async () => {
    if (!form.taskId) {
      toast.error("请先选择同步任务并保存调度");
      return;
    }
    let sample: unknown = [];
    const text = sampleText.trim();
    if (text) {
      try {
        sample = JSON.parse(text);
      } catch {
        toast.error("样本不是合法 JSON 文本");
        return;
      }
      if (!Array.isArray(sample)) {
        toast.error("样本需为 JSON 数组（每行一个对象）");
        return;
      }
    }

    setRunning(true);
    const supabase = createClient();
    const { error: runError } = await supabase.rpc("run_sync_task", {
      p_task_id: form.taskId,
      p_sample: sample as Json,
    });
    setRunning(false);

    if (runError) {
      toast.error(translateSyncErrorMessage(runError.message));
      return;
    }
    toast.success("已触发一次执行，可在「执行记录」页查看");
    await load();
  };

  const handleCopyToken = async (token: string) => {
    try {
      await navigator.clipboard.writeText(token);
      toast.success("已复制到剪贴板");
    } catch {
      toast.error("复制失败，请手动选择复制");
    }
  };

  const renderStatusBadge = (status: string) => {
    const normalized = asSyncScheduleStatus(status);
    return (
      <Badge
        variant="outline"
        className={SYNC_SCHEDULE_STATUS_BADGE_CLASSES[normalized]}
      >
        {SYNC_SCHEDULE_STATUS_LABELS[normalized]}
      </Badge>
    );
  };

  const renderCronSummary = (row: ScheduleRow) => {
    const trigger = asSyncTriggerType(row.trigger_type);
    if (trigger === "cron") {
      return describeCronExpr(row.cron_expr);
    }
    if (trigger === "webhook") {
      return row.has_token ? "token 已生成" : "token 待生成";
    }
    return "仅手动触发";
  };

  const cronPreview =
    form.triggerType === "cron" ? buildCronExpr(form) : null;

  return (
    <div className="flex flex-col gap-2 p-0 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex items-center justify-end gap-2">
            <Button
              onClick={openCreate}
              className="h-11 flex-1 lg:h-8 lg:flex-none"
              disabled={tasks.length === 0}
            >
              <CalendarPlusIcon data-icon="inline-start" />
              新建调度
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
          ) : schedules.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <CalendarClockIcon className="size-8 opacity-60" />
              <span>
                {tasks.length === 0
                  ? "暂无同步任务，请先到「同步任务」页创建"
                  : "暂无调度，点击「新建调度」配置触发方式"}
              </span>
            </div>
          ) : isMobile ? (
            <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
              {schedules.map((row) => {
                const enabled =
                  asSyncScheduleStatus(row.status) === "active";
                return (
                  <div
                    key={row.id}
                    data-slot="sync-schedule-card"
                    className="flex w-full flex-col gap-2 rounded-xl border bg-card p-3 text-left shadow-xs transition-colors hover:border-primary/50"
                  >
                    <div
                      role="button"
                      tabIndex={0}
                      aria-label={`编辑调度 ${row.task_name}`}
                      onClick={() => openEdit(row)}
                      onKeyDown={(event) => {
                        if (event.key === "Enter" || event.key === " ") {
                          event.preventDefault();
                          openEdit(row);
                        }
                      }}
                      className="flex cursor-pointer flex-col gap-2 rounded-lg focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                    >
                      <div className="flex items-start justify-between gap-3">
                        <div className="min-w-0">
                          <div className="truncate font-medium">
                            {row.task_name}
                          </div>
                          <div className="truncate text-xs leading-tight text-muted-foreground">
                            {renderCronSummary(row)} · {row.timezone}
                          </div>
                        </div>
                        {renderStatusBadge(row.status)}
                      </div>
                      <div className="flex flex-wrap items-center gap-1.5">
                        <Badge variant="outline">
                          {
                            SYNC_TRIGGER_TYPE_LABELS[
                              asSyncTriggerType(row.trigger_type)
                            ]
                          }
                        </Badge>
                        <Badge variant="outline">
                          {
                            SYNC_TARGET_TABLE_LABELS[
                              asSyncTargetTable(row.target_table)
                            ]
                          }
                        </Badge>
                      </div>
                      <div className="flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted-foreground">
                        <span>上次：{formatDateTime(row.last_run_at)}</span>
                        <span>下次：{formatDateTime(row.next_run_at)}</span>
                      </div>
                    </div>
                    {/* 移动卡片启停入口（桌面端行内 Switch 已移除，启停统一收口 Sheet 状态） */}
                    <div className="flex items-center justify-between gap-4 text-sm">
                      <span className="text-muted-foreground">启停</span>
                      <Switch
                        checked={enabled}
                        disabled={togglingId === row.id}
                        aria-label={`${enabled ? "停用" : "启用"}调度`}
                        onCheckedChange={(checked) =>
                          void handleToggle(row, checked)
                        }
                      />
                    </div>
                  </div>
                );
              })}
            </div>
          ) : (
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="text-center">任务</TableHead>
                    <TableHead className="text-center">触发方式</TableHead>
                    <TableHead className="text-center">调度摘要</TableHead>
                    <TableHead className="text-center">时区</TableHead>
                    <TableHead className="text-center">状态</TableHead>
                    <TableHead className="text-center">上次执行</TableHead>
                    <TableHead className="text-center">下次执行</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {schedules.map((row) => (
                    <TableRow
                      key={row.id}
                      className="cursor-pointer"
                      role="button"
                      tabIndex={0}
                      aria-label={`编辑调度 ${row.task_name}`}
                      onClick={() => openEdit(row)}
                      onKeyDown={(event) => {
                        if (event.key === "Enter" || event.key === " ") {
                          event.preventDefault();
                          openEdit(row);
                        }
                      }}
                    >
                      <TableCell className="text-center font-medium">
                        {row.task_name}
                      </TableCell>
                      <TableCell className="text-center">
                        <Badge variant="outline">
                          {
                            SYNC_TRIGGER_TYPE_LABELS[
                              asSyncTriggerType(row.trigger_type)
                            ]
                          }
                        </Badge>
                      </TableCell>
                      <TableCell className="text-center text-xs">
                        {renderCronSummary(row)}
                      </TableCell>
                      <TableCell className="text-center text-xs text-muted-foreground">
                        {row.timezone}
                      </TableCell>
                      <TableCell className="text-center">
                        {renderStatusBadge(row.status)}
                      </TableCell>
                      <TableCell className="text-center text-xs text-muted-foreground">
                        {formatDateTime(row.last_run_at)}
                      </TableCell>
                      <TableCell className="text-center text-xs text-muted-foreground">
                        {formatDateTime(row.next_run_at)}
                      </TableCell>
                    </TableRow>
                  ))}
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
          className="w-full overflow-hidden sm:max-w-[560px]"
        >
          <SheetHeader>
            <SheetTitle>{editing ? "编辑调度" : "新建调度"}</SheetTitle>
            <SheetDescription>
              {editing
                ? `任务：${editing.task_name}`
                : "为同步任务选择触发方式；cron 预设优先，高级模式可直接填写表达式"}
            </SheetDescription>
          </SheetHeader>

          <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-4">
            {editing ? null : (
              <Field>
                <FieldLabel htmlFor="sync-schedule-task">同步任务</FieldLabel>
                <Select
                  value={form.taskId}
                  onValueChange={(value) =>
                    setForm((prev) => ({ ...prev, taskId: value }))
                  }
                >
                  <SelectTrigger id="sync-schedule-task" className="w-full min-h-11 lg:min-h-8">
                    <SelectValue placeholder="选择同步任务" />
                  </SelectTrigger>
                  <SelectContent>
                    {tasks.map((task) => {
                      const exists = schedules.some(
                        (item) => item.task_id === task.id,
                      );
                      return (
                        <SelectItem key={task.id} value={task.id}>
                          {task.name}
                          {exists ? "（已有调度，将覆盖）" : ""}
                        </SelectItem>
                      );
                    })}
                  </SelectContent>
                </Select>
              </Field>
            )}

            <Field>
              <FieldLabel htmlFor="sync-schedule-trigger">触发方式</FieldLabel>
              <Select
                value={form.triggerType}
                onValueChange={(value) =>
                  setForm((prev) => ({
                    ...prev,
                    triggerType: value as SyncTriggerType,
                  }))
                }
              >
                <SelectTrigger id="sync-schedule-trigger" className="w-full min-h-11 lg:min-h-8">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {SYNC_TRIGGER_TYPE_OPTIONS.map((option) => (
                    <SelectItem key={option.value} value={option.value}>
                      {option.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <FieldDescription>
                手动＝仅页面触发；定时＝注册 pg_cron；Webhook＝外部携 token 调用
              </FieldDescription>
            </Field>

            {form.triggerType === "cron" ? (
              <div className="flex flex-col gap-3 rounded-xl border p-4">
                <div className="text-sm font-medium">定时配置</div>
                <Field>
                  <FieldLabel htmlFor="sync-schedule-preset">频率预设</FieldLabel>
                  <Select
                    value={form.preset}
                    onValueChange={(value) =>
                      setForm((prev) => ({
                        ...prev,
                        preset: value as SyncCronPreset,
                      }))
                    }
                  >
                    <SelectTrigger id="sync-schedule-preset" className="w-full min-h-11 lg:min-h-8">
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {SYNC_CRON_PRESET_OPTIONS.map((option) => (
                        <SelectItem key={option.value} value={option.value}>
                          {option.label}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </Field>

                {form.preset === "daily" || form.preset === "weekly" ? (
                  <div className="flex items-end gap-2">
                    {form.preset === "weekly" ? (
                      <Field className="flex-1">
                        <FieldLabel htmlFor="sync-schedule-weekday">
                          星期
                        </FieldLabel>
                        <Select
                          value={form.weekday}
                          onValueChange={(value) =>
                            setForm((prev) => ({
                              ...prev,
                              weekday: value,
                            }))
                          }
                        >
                          <SelectTrigger
                            id="sync-schedule-weekday"
                            className="w-full min-h-11 lg:min-h-8"
                          >
                            <SelectValue />
                          </SelectTrigger>
                          <SelectContent>
                            {SYNC_WEEKDAY_LABELS.map((item) => (
                              <SelectItem key={item.value} value={item.value}>
                                {item.label}
                              </SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                      </Field>
                    ) : null}
                    <Field className="flex-1">
                      <FieldLabel htmlFor="sync-schedule-time">时间</FieldLabel>
                      <Input
                        className="h-11 lg:h-8"
                        id="sync-schedule-time"
                        type="time"
                        value={form.dailyTime}
                        onChange={(event) =>
                          setForm((prev) => ({
                            ...prev,
                            dailyTime: event.target.value || "09:00",
                          }))
                        }
                      />
                    </Field>
                  </div>
                ) : null}

                {form.preset === "custom" ? (
                  <Field>
                    <FieldLabel htmlFor="sync-schedule-cron">
                      cron 表达式
                    </FieldLabel>
                    <Input
                      id="sync-schedule-cron"
                      value={form.customCron}
                      onChange={(event) =>
                        setForm((prev) => ({
                          ...prev,
                          customCron: event.target.value,
                        }))
                      }
                      placeholder="0 9 * * 1-5"
                      className="h-11 font-mono text-xs lg:h-8"
                      autoComplete="off"
                    />
                    <FieldDescription>
                      五段数字语法（分 时 日 月 周）；不支持名称与 @ 宏
                    </FieldDescription>
                  </Field>
                ) : null}

                <div className="text-xs text-muted-foreground">
                  将注册：{SYNC_CRON_PRESET_LABELS[form.preset]} ·{" "}
                  <code className="font-mono">{cronPreview || "—"}</code>
                </div>
              </div>
            ) : null}

            {form.triggerType === "webhook" ? (
              <div className="flex flex-col gap-3 rounded-xl border p-4">
                <div className="text-sm font-medium">Webhook token</div>
                {generatedToken ? (
                  <div className="flex flex-col gap-2">
                    <p className={cn("text-xs", SYNC_WARNING_TEXT_CLASS)}>
                      新 token 仅显示这一次，请立即复制保存；旧 token 已失效。
                    </p>
                    <div className="flex items-center gap-2">
                      <Input
                        readOnly
                        value={generatedToken}
                        className="h-11 font-mono text-xs lg:h-8"
                        aria-label="webhook token"
                      />
                      <Button
                        variant="outline"
                        size="icon"
                        aria-label="复制 token"
                        onClick={() => void handleCopyToken(generatedToken)}
                      >
                        <CopyIcon />
                      </Button>
                    </div>
                  </div>
                ) : (
                  <>
                    <p className="text-xs text-muted-foreground">
                      {editing?.has_token
                        ? "token 已生成（仅显示一次）。如已遗失可重置，旧 token 立即失效。"
                        : "保存后自动生成 token（仅显示一次）。"}
                    </p>
                    {editing?.has_token ? (
                      <Button
                        variant="outline"
                        onClick={() => void handleRegenerateToken()}
                        disabled={saving}
                      >
                        <KeyRoundIcon data-icon="inline-start" />
                        重置 token
                      </Button>
                    ) : null}
                  </>
                )}
                <p className="text-xs text-muted-foreground">
                  外部系统调用数据库公开端点 <code>trigger_sync_webhook</code>{" "}
                  传入 token 即触发；限流 60 次/分钟。
                </p>
              </div>
            ) : null}

            <Field>
              <FieldLabel htmlFor="sync-schedule-timezone">时区</FieldLabel>
              <Input
                className="h-11 lg:h-8"
                id="sync-schedule-timezone"
                value={form.timezone}
                onChange={(event) =>
                  setForm((prev) => ({ ...prev, timezone: event.target.value }))
                }
                placeholder="Asia/Shanghai"
                autoComplete="off"
              />
              <FieldDescription>cron 计算时区，默认 Asia/Shanghai</FieldDescription>
            </Field>

            <Field>
              <FieldLabel htmlFor="sync-schedule-status">状态</FieldLabel>
              <Select
                value={form.status}
                onValueChange={(value) =>
                  setForm((prev) => ({
                    ...prev,
                    status: value as "active" | "disabled",
                  }))
                }
              >
                <SelectTrigger id="sync-schedule-status" className="w-full min-h-11 lg:min-h-8">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="active">启用</SelectItem>
                  <SelectItem value="disabled">停用</SelectItem>
                </SelectContent>
              </Select>
              <FieldDescription>
                启用要求任务启用且数据源验证通过；停用时进行中的当次跑完后再注销
              </FieldDescription>
            </Field>

            {editing ? (
              <div className="flex flex-col gap-3 rounded-xl border p-4">
                <div className="text-sm font-medium">立即执行一次</div>
                <p className="text-xs text-muted-foreground">
                  v1 执行输入为样本行（与试跑一致）；不填则空跑并记录。受单任务并发
                  1 限制。
                </p>
                <Textarea
                  rows={4}
                  value={sampleText}
                  onChange={(event) => setSampleText(event.target.value)}
                  placeholder='[{"dept_name":"研发中心"}]'
                  aria-label="手动触发样本 JSON"
                  className="font-mono text-xs"
                />
                <Button
                  variant="outline"
                  onClick={() => void handleManualRun()}
                  disabled={running}
                  className="self-start"
                >
                  {running ? (
                    <Loader2Icon
                      className="animate-spin"
                      data-icon="inline-start"
                    />
                  ) : (
                    <PlayIcon data-icon="inline-start" />
                  )}
                  立即执行
                </Button>
              </div>
            ) : null}
          </div>

          <SheetFooter className="flex-row justify-end gap-2">
            <Button
              variant="outline"
              onClick={closeSheet}
              className="h-11 lg:h-8"
            >
              取消
            </Button>
            <Button
              onClick={() => void handleSave()}
              disabled={saving}
              className="h-11 lg:h-8"
            >
              {saving ? (
                <Loader2Icon
                  className="size-3.5 animate-spin"
                  data-icon="inline-start"
                />
              ) : (
                <SaveIcon className="size-3.5" data-icon="inline-start" />
              )}
              保存调度
            </Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>
    </div>
  );
}
