"use client";

// 报表中心 · 报表订阅（report/006）
// 列表：报表名 / 频率（cron→中文预设回显）/ 渠道 / 接收范围 / 状态 / 上次执行 / 下次执行。
// 新增编辑 Sheet：选报表（我的+公共）→ 频率预设（每小时/每天/每周/每月）→ 渠道（站内信/邮件）
//   → 接收范围（自己/按角色）；频率只给预设，cron 由 upsert_report_subscription 映射落表。
// 行/卡片整卡可点打开执行历史 Sheet：runs 列表（状态/耗时/失败原因）+ 手动执行一次 + 失败重发；
//   编辑/启停/删除动作集中在 Sheet 底部（列表页行内无按钮，DESIGN §4.3）。
// 删除走确认 Sheet（逻辑删：保留执行历史并注销 pg_cron job）；执行身份由后端注入订阅属主。

import * as React from "react";
import {
  BellRingIcon,
  CalendarClockIcon,
  CalendarPlusIcon,
  Loader2Icon,
  PencilIcon,
  PlayIcon,
  RotateCcwIcon,
  SaveIcon,
  Trash2Icon,
  UsersIcon,
} from "lucide-react";
import { toast } from "sonner";

import {
  ReportEmptyState,
  ReportErrorState,
  ReportLoadingSkeleton,
} from "@/components/report/report-shared";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
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
import { Switch } from "@/components/ui/switch";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { useIsMobile } from "@/hooks/use-mobile";
import { formatDateTime } from "@/lib/audit";
import type { Database } from "@/lib/database.types";
import {
  asReportSubscriptionRunStatus,
  asReportSubscriptionStatus,
  describeCronExpr,
  REPORT_CHANNEL_LABELS,
  REPORT_SUBSCRIPTION_PRESET_OPTIONS,
  REPORT_SUBSCRIPTION_RUN_STATUS_BADGE_CLASSES,
  REPORT_SUBSCRIPTION_RUN_STATUS_LABELS,
  REPORT_SUBSCRIPTION_STATUS_BADGE_CLASSES,
  REPORT_SUBSCRIPTION_STATUS_LABELS,
  REPORT_WEEKDAY_LABELS,
  type ReportChannel,
  type ReportSubscriptionPreset,
} from "@/lib/dictionaries";
import { translateReportErrorMessage } from "@/lib/report";
import { createClient } from "@/lib/supabase/client";

type SubscriptionRow =
  Database["public"]["Functions"]["get_report_subscriptions"]["Returns"][number];
type RunRow =
  Database["public"]["Tables"]["report_subscription_runs"]["Row"];
type DefinitionOption = Pick<
  Database["public"]["Tables"]["report_definitions"]["Row"],
  "id" | "name" | "visibility" | "owner_id"
>;
type RoleOption = Pick<Database["public"]["Tables"]["roles"]["Row"], "code" | "name">;

type UpsertSubscriptionArgs =
  Database["public"]["Functions"]["upsert_report_subscription"]["Args"];

type SubscriptionForm = {
  reportDefId: string;
  preset: ReportSubscriptionPreset;
  time: string; // HH:mm（daily/weekly）
  weekday: string; // 0..6（weekly；0=周日）
  channels: ReportChannel[];
  recipientMode: "self" | "role";
  roleCode: string;
};

const EMPTY_FORM: SubscriptionForm = {
  reportDefId: "",
  preset: "daily",
  time: "09:00",
  weekday: "1",
  channels: ["inbox"],
  recipientMode: "self",
  roleCode: "",
};

/** cron → 表单预设（仅解析 RPC 写入的四种形态；异常时回退每天 09:00） */
const parseSubscriptionCron = (
  expr: string | null | undefined,
): { preset: ReportSubscriptionPreset; time: string; weekday: string } => {
  const value = (expr ?? "").trim();
  if (value === "0 * * * *") {
    return { preset: "hourly", time: "09:00", weekday: "1" };
  }
  const parts = value.split(/\s+/);
  if (
    parts.length === 5 &&
    /^\d{1,2}$/.test(parts[0]) &&
    /^\d{1,2}$/.test(parts[1])
  ) {
    const time = `${parts[1].padStart(2, "0")}:${parts[0].padStart(2, "0")}`;
    if (parts[2] === "1" && parts[3] === "*" && parts[4] === "*") {
      return { preset: "monthly", time, weekday: "1" };
    }
    if (parts[2] === "*" && parts[3] === "*") {
      if (parts[4] === "*") {
        return { preset: "daily", time, weekday: "1" };
      }
      if (/^\d$/.test(parts[4])) {
        return { preset: "weekly", time, weekday: parts[4] };
      }
    }
  }
  return { preset: "daily", time: "09:00", weekday: "1" };
};

/** 预设 + 时间 → 页面预览文案（不向普通用户暴露 cron 原文） */
const presetSummary = (form: SubscriptionForm): string => {
  if (form.preset === "hourly") {
    return "每小时";
  }
  if (form.preset === "weekly") {
    const weekday =
      REPORT_WEEKDAY_LABELS.find((item) => item.value === form.weekday)?.label ??
      `周${form.weekday}`;
    return `每${weekday} ${form.time}`;
  }
  if (form.preset === "monthly") {
    return `每月 1 日 ${form.time}`;
  }
  return `每天 ${form.time}`;
};

export function ReportSubscriptions({
  currentUserId,
}: {
  currentUserId: string;
}) {
  const isMobile = useIsMobile();
  const [rows, setRows] = React.useState<SubscriptionRow[]>([]);
  const [definitions, setDefinitions] = React.useState<DefinitionOption[]>([]);
  const [roles, setRoles] = React.useState<RoleOption[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);

  const [sheetOpen, setSheetOpen] = React.useState(false);
  const [editing, setEditing] = React.useState<SubscriptionRow | null>(null);
  const [form, setForm] = React.useState<SubscriptionForm>(EMPTY_FORM);
  const [saving, setSaving] = React.useState(false);
  const [togglingId, setTogglingId] = React.useState<string | null>(null);
  const [deletingId, setDeletingId] = React.useState<string | null>(null);
  const [confirmDeleteFor, setConfirmDeleteFor] =
    React.useState<SubscriptionRow | null>(null);

  const [historyFor, setHistoryFor] = React.useState<SubscriptionRow | null>(
    null,
  );
  const [runs, setRuns] = React.useState<RunRow[]>([]);
  const [runsLoading, setRunsLoading] = React.useState(false);
  const [running, setRunning] = React.useState(false);

  const load = React.useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const supabase = createClient();
      const [subsRes, defsRes, rolesRes] = await Promise.all([
        supabase.rpc("get_report_subscriptions"),
        supabase
          .from("report_definitions")
          .select("id,name,visibility,owner_id")
          .order("name"),
        supabase.from("roles").select("code,name").order("name"),
      ]);

      if (subsRes.error) {
        setError(subsRes.error.message);
        setRows([]);
      } else {
        setRows(subsRes.data ?? []);
      }
      setDefinitions(defsRes.error ? [] : (defsRes.data ?? []));
      setRoles(rolesRes.error ? [] : (rolesRes.data ?? []));
    } catch (loadError) {
      setError(
        loadError instanceof Error ? loadError.message : String(loadError),
      );
      setRows([]);
    }
    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const loadRuns = React.useCallback(async (subscriptionId: string) => {
    setRunsLoading(true);
    try {
      const { data, error: runsError } = await createClient()
        .from("report_subscription_runs")
        .select("*")
        .eq("subscription_id", subscriptionId)
        .order("created_at", { ascending: false })
        .order("id", { ascending: false })
        .limit(50);
      if (runsError) {
        toast.error(translateReportErrorMessage(runsError.message));
        setRuns([]);
      } else {
        setRuns(data ?? []);
      }
    } catch (runsError) {
      toast.error(
        runsError instanceof Error ? runsError.message : String(runsError),
      );
      setRuns([]);
    }
    setRunsLoading(false);
  }, []);

  const openCreate = () => {
    setEditing(null);
    setForm(EMPTY_FORM);
    setSheetOpen(true);
  };

  const openEdit = (row: SubscriptionRow) => {
    const parsed = parseSubscriptionCron(row.cron_expr);
    setEditing(row);
    setForm({
      reportDefId: row.report_def_id,
      preset: parsed.preset,
      time: parsed.time,
      weekday: parsed.weekday,
      channels:
        row.channels.length > 0
          ? (row.channels.filter(
              (channel): channel is ReportChannel =>
                channel === "inbox" || channel === "email",
            ) as ReportChannel[])
          : ["inbox"],
      recipientMode: row.recipients === "self" ? "self" : "role",
      roleCode:
        row.recipients === "self" ? "" : row.recipients.replace(/^role:/, ""),
    });
    setSheetOpen(true);
  };

  const closeSheet = () => {
    setSheetOpen(false);
    setEditing(null);
  };

  const openHistory = (row: SubscriptionRow) => {
    setHistoryFor(row);
    void loadRuns(row.id);
  };

  const closeHistory = () => {
    setHistoryFor(null);
    setRuns([]);
  };

  const toggleChannel = (channel: ReportChannel, checked: boolean) => {
    setForm((prev) => {
      if (checked) {
        return prev.channels.includes(channel)
          ? prev
          : { ...prev, channels: [...prev.channels, channel] };
      }
      return { ...prev, channels: prev.channels.filter((c) => c !== channel) };
    });
  };

  const handleSave = async () => {
    if (!form.reportDefId) {
      toast.error("请选择报表");
      return;
    }
    if (form.channels.length === 0) {
      toast.error("至少选择一个投递渠道");
      return;
    }
    if (form.recipientMode === "role" && !form.roleCode) {
      toast.error("请选择接收角色");
      return;
    }

    const recipients =
      form.recipientMode === "self" ? "self" : `role:${form.roleCode}`;

    setSaving(true);
    const { error: saveError } = await createClient().rpc(
      "upsert_report_subscription",
      {
        p_id: editing?.id ?? null,
        p_report_def_id: form.reportDefId,
        p_preset: form.preset,
        p_time: form.preset === "hourly" ? undefined : form.time,
        p_weekday: form.preset === "weekly" ? Number(form.weekday) : undefined,
        p_channels: form.channels,
        p_recipients: recipients,
      } as unknown as UpsertSubscriptionArgs,
    );
    setSaving(false);

    if (saveError) {
      toast.error(translateReportErrorMessage(saveError.message));
      return;
    }

    toast.success(editing ? "已保存" : "已创建订阅");
    closeSheet();
    await load();
  };

  const handleToggle = async (row: SubscriptionRow, enabled: boolean) => {
    setTogglingId(row.id);
    const { error: toggleError } = await createClient().rpc(
      "set_report_subscription_status",
      { p_subscription_id: row.id, p_status: enabled ? "active" : "disabled" },
    );
    setTogglingId(null);

    if (toggleError) {
      toast.error(translateReportErrorMessage(toggleError.message));
      return;
    }
    toast.success(enabled ? "已启用" : "已停用（定时任务已注销）");
    await load();
  };

  const handleDelete = async (row: SubscriptionRow) => {
    setDeletingId(row.id);
    const { error: deleteError } = await createClient().rpc(
      "delete_report_subscription",
      { p_subscription_id: row.id },
    );
    setDeletingId(null);

    if (deleteError) {
      toast.error(translateReportErrorMessage(deleteError.message));
      return;
    }
    toast.success("已删除（历史保留）");
    setConfirmDeleteFor(null);
    if (historyFor?.id === row.id) {
      closeHistory();
    }
    await load();
  };

  const handleRunNow = async (row: SubscriptionRow) => {
    setRunning(true);
    const { error: runError } = await createClient().rpc(
      "run_report_subscription_now",
      { p_subscription_id: row.id },
    );
    setRunning(false);

    if (runError) {
      toast.error(translateReportErrorMessage(runError.message));
      return;
    }
    toast.success("已执行一次，结果已投递；可在执行历史查看");
    await Promise.all([load(), loadRuns(row.id)]);
  };

  const roleName = (code: string): string =>
    roles.find((role) => role.code === code)?.name ?? code;

  const definitionLabel = (def: DefinitionOption): string => {
    if (def.owner_id === currentUserId) {
      return `${def.name}（我的）`;
    }
    if (def.visibility === "public") {
      return `${def.name}（公共）`;
    }
    return `${def.name}（他人私有）`;
  };

  const renderStatusBadge = (status: string) => {
    const normalized = asReportSubscriptionStatus(status);
    return (
      <Badge
        variant="outline"
        className={REPORT_SUBSCRIPTION_STATUS_BADGE_CLASSES[normalized]}
      >
        {REPORT_SUBSCRIPTION_STATUS_LABELS[normalized]}
      </Badge>
    );
  };

  const renderRunStatusBadge = (status: string) => {
    const normalized = asReportSubscriptionRunStatus(status);
    return (
      <Badge
        variant="outline"
        className={REPORT_SUBSCRIPTION_RUN_STATUS_BADGE_CLASSES[normalized]}
      >
        {REPORT_SUBSCRIPTION_RUN_STATUS_LABELS[normalized]}
      </Badge>
    );
  };

  const renderChannels = (row: SubscriptionRow) => (
    <div className="flex flex-wrap items-center justify-center gap-1">
      {row.channels.map((channel) => (
        <Badge key={channel} variant="outline">
          {REPORT_CHANNEL_LABELS[channel as ReportChannel] ?? channel}
        </Badge>
      ))}
    </div>
  );

  const renderRecipients = (row: SubscriptionRow) =>
    row.recipients === "self" ? (
      <span className="inline-flex items-center gap-1 text-xs text-muted-foreground">
        <BellRingIcon className="size-3.5" />
        自己
      </span>
    ) : (
      <span className="inline-flex items-center gap-1 text-xs text-muted-foreground">
        <UsersIcon className="size-3.5" />
        角色：{roleName(row.recipients.replace(/^role:/, ""))}
      </span>
    );

  /** 历史 Sheet 内操作使用列表最新行，启停后 Switch/按钮状态保持同步 */
  const historyRow = historyFor
    ? (rows.find((row) => row.id === historyFor.id) ?? historyFor)
    : null;

  const renderLastRun = (row: SubscriptionRow) => {
    if (!row.last_run_status || !row.last_run_at) {
      return <span className="text-xs text-muted-foreground">—</span>;
    }
    return (
      <div className="flex flex-col items-center gap-1">
        {renderRunStatusBadge(row.last_run_status)}
        <span className="text-xs text-muted-foreground">
          {formatDateTime(row.last_run_at)}
          {row.last_run_duration_ms === null
            ? ""
            : ` · ${row.last_run_duration_ms}ms`}
        </span>
      </div>
    );
  };

  return (
    <div className="flex flex-col gap-0.5 p-0 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex items-center justify-end gap-2">
            <Button
              onClick={openCreate}
              className="h-11 flex-1 lg:h-8 lg:flex-none"
              disabled={definitions.length === 0}
            >
              <CalendarPlusIcon data-icon="inline-start" />
              新建订阅
            </Button>
          </div>

          {loading ? (
            <ReportLoadingSkeleton rows={4} />
          ) : error ? (
            <ReportErrorState
              message={translateReportErrorMessage(error)}
              onRetry={() => void load()}
            />
          ) : rows.length === 0 ? (
            <ReportEmptyState
              icon={CalendarClockIcon}
              title={
                definitions.length === 0
                  ? "暂无可订阅的报表，请先到「自定义报表」创建"
                  : "暂无订阅，点击「新建订阅」配置报表推送"
              }
            />
          ) : isMobile ? (
            <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
              {rows.map((row) => (
                <button
                  key={row.id}
                  type="button"
                  onClick={() => openHistory(row)}
                  aria-label={`查看订阅 ${row.report_name} 的执行历史`}
                  className="flex w-full flex-col gap-2 rounded-xl border bg-card p-3 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                >
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <div className="truncate font-medium">
                        {row.report_name}
                      </div>
                      <div className="truncate text-xs leading-tight text-muted-foreground">
                        {describeCronExpr(row.cron_expr)} · 下次{" "}
                        {formatDateTime(row.next_run_at)}
                      </div>
                    </div>
                    {renderStatusBadge(row.status)}
                  </div>
                  <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-muted-foreground">
                    {renderRecipients(row)}
                    {renderChannels(row)}
                  </div>
                  <div className="text-xs text-muted-foreground">
                    上次 {formatDateTime(row.last_run_at)}
                  </div>
                </button>
              ))}
            </div>
          ) : (
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="text-center">报表</TableHead>
                    <TableHead className="text-center">频率</TableHead>
                    <TableHead className="text-center">渠道</TableHead>
                    <TableHead className="text-center">接收范围</TableHead>
                    <TableHead className="text-center">状态</TableHead>
                    <TableHead className="text-center">上次执行</TableHead>
                    <TableHead className="text-center">下次执行</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {rows.map((row) => (
                    <TableRow
                      key={row.id}
                      className="cursor-pointer"
                      role="button"
                      tabIndex={0}
                      aria-label={`查看订阅 ${row.report_name} 的执行历史`}
                      onClick={() => openHistory(row)}
                      onKeyDown={(event) => {
                        if (event.key === "Enter" || event.key === " ") {
                          event.preventDefault();
                          openHistory(row);
                        }
                      }}
                    >
                      <TableCell className="text-center">
                        <div className="flex items-center justify-center gap-2">
                          <span className="font-medium">{row.report_name}</span>
                          <Badge variant="outline" className="text-xs">
                            {row.report_visibility === "public" ? "公共" : "私有"}
                          </Badge>
                        </div>
                      </TableCell>
                      <TableCell className="text-center text-xs">
                        {describeCronExpr(row.cron_expr)}
                      </TableCell>
                      <TableCell className="text-center">
                        {renderChannels(row)}
                      </TableCell>
                      <TableCell className="text-center">
                        {renderRecipients(row)}
                      </TableCell>
                      <TableCell className="text-center">
                        {renderStatusBadge(row.status)}
                      </TableCell>
                      <TableCell className="text-center">
                        {renderLastRun(row)}
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

      {/* 新增 / 编辑 Sheet */}
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
          className="w-full overflow-hidden sm:max-w-2xl"
        >
          <SheetHeader>
            <SheetTitle>{editing ? "编辑订阅" : "新建订阅"}</SheetTitle>
            <SheetDescription>
              {editing
                ? `报表：${editing.report_name}`
                : "选择报表与频率；频率只提供预设，系统自动生成调度计划"}
            </SheetDescription>
          </SheetHeader>

          <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-4">
            <Field>
              <FieldLabel htmlFor="report-sub-def">报表</FieldLabel>
              <Select
                value={form.reportDefId}
                onValueChange={(value) =>
                  setForm((prev) => ({ ...prev, reportDefId: value }))
                }
              >
                <SelectTrigger id="report-sub-def" className="w-full">
                  <SelectValue placeholder="选择报表（我的 + 公共）" />
                </SelectTrigger>
                <SelectContent>
                  {definitions.map((def) => (
                    <SelectItem key={def.id} value={def.id}>
                      {definitionLabel(def)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <FieldDescription>
                仅可选择「我的报表」或「公共报表」；订阅后按订阅属主的数据权限生成
              </FieldDescription>
            </Field>

            <Field>
              <FieldLabel htmlFor="report-sub-preset">频率</FieldLabel>
              <Select
                value={form.preset}
                onValueChange={(value) =>
                  setForm((prev) => ({
                    ...prev,
                    preset: value as ReportSubscriptionPreset,
                  }))
                }
              >
                <SelectTrigger id="report-sub-preset" className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {REPORT_SUBSCRIPTION_PRESET_OPTIONS.map((option) => (
                    <SelectItem key={option.value} value={option.value}>
                      {option.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <FieldDescription>
                将按「{presetSummary(form)}」生成（Asia/Shanghai）
              </FieldDescription>
            </Field>

            {form.preset === "weekly" ? (
              <Field>
                <FieldLabel htmlFor="report-sub-weekday">星期</FieldLabel>
                <Select
                  value={form.weekday}
                  onValueChange={(value) =>
                    setForm((prev) => ({ ...prev, weekday: value }))
                  }
                >
                  <SelectTrigger id="report-sub-weekday" className="w-full">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {REPORT_WEEKDAY_LABELS.map((item) => (
                      <SelectItem key={item.value} value={item.value}>
                        {item.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </Field>
            ) : null}

            {form.preset !== "hourly" ? (
              <Field>
                <FieldLabel htmlFor="report-sub-time">时间</FieldLabel>
                <Input
                  id="report-sub-time"
                  type="time"
                  value={form.time}
                  onChange={(event) =>
                    setForm((prev) => ({
                      ...prev,
                      time: event.target.value || "09:00",
                    }))
                  }
                />
              </Field>
            ) : null}

            <Field>
              <FieldLabel>投递渠道</FieldLabel>
              <div className="flex flex-col gap-2 rounded-xl border p-3">
                <label className="flex cursor-pointer items-start gap-2 text-sm">
                  <Checkbox
                    checked={form.channels.includes("inbox")}
                    onCheckedChange={(checked) =>
                      toggleChannel("inbox", checked === true)
                    }
                    aria-label="站内信渠道"
                  />
                  <span>
                    站内信
                    <span className="block text-xs text-muted-foreground">
                      结果摘要写入 message 收件箱（必达）
                    </span>
                  </span>
                </label>
                <label className="flex cursor-pointer items-start gap-2 text-sm">
                  <Checkbox
                    checked={form.channels.includes("email")}
                    onCheckedChange={(checked) =>
                      toggleChannel("email", checked === true)
                    }
                    aria-label="邮件渠道"
                  />
                  <span>
                    邮件
                    <span className="block text-xs text-muted-foreground">
                      经 message 渠道分发（当前降级为站内信，message
                      渠道接入后按此偏好投递，不在本模块直发）
                    </span>
                  </span>
                </label>
              </div>
            </Field>

            <Field>
              <FieldLabel htmlFor="report-sub-recipient">接收范围</FieldLabel>
              <Select
                value={form.recipientMode}
                onValueChange={(value) =>
                  setForm((prev) => ({
                    ...prev,
                    recipientMode: value as "self" | "role",
                  }))
                }
              >
                <SelectTrigger id="report-sub-recipient" className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="self">自己（订阅属主）</SelectItem>
                  <SelectItem value="role">按角色（该角色全部用户）</SelectItem>
                </SelectContent>
              </Select>
            </Field>

            {form.recipientMode === "role" ? (
              <Field>
                <FieldLabel htmlFor="report-sub-role">接收角色</FieldLabel>
                <Select
                  value={form.roleCode}
                  onValueChange={(value) =>
                    setForm((prev) => ({ ...prev, roleCode: value }))
                  }
                >
                  <SelectTrigger id="report-sub-role" className="w-full">
                    <SelectValue placeholder="选择角色" />
                  </SelectTrigger>
                  <SelectContent>
                    {roles.map((role) => (
                      <SelectItem key={role.code} value={role.code}>
                        {role.name}（{role.code}）
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <FieldDescription>
                  执行时向该角色全部启用用户逐一发送站内信
                </FieldDescription>
              </Field>
            ) : null}
          </div>

          <SheetFooter className="flex-row justify-end gap-2">
            <Button
              variant="outline"
              className="h-8"
              onClick={closeSheet}
            >
              取消
            </Button>
            <Button
              onClick={() => void handleSave()}
              disabled={saving}
              className="h-8"
            >
              {saving ? (
                <Loader2Icon
                  className="size-3.5 animate-spin"
                  data-icon="inline-start"
                />
              ) : (
                <SaveIcon className="size-3.5" data-icon="inline-start" />
              )}
              保存订阅
            </Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>

      {/* 执行历史 Sheet */}
      <Sheet
        open={historyFor !== null}
        onOpenChange={(open) => {
          if (!open) {
            closeHistory();
          }
        }}
      >
        <SheetContent
          side="right"
          className="w-full overflow-hidden sm:max-w-2xl"
        >
          <SheetHeader>
            <SheetTitle>执行历史</SheetTitle>
            <SheetDescription>
              {historyFor
                ? `${historyFor.report_name} · ${describeCronExpr(historyFor.cron_expr)}`
                : ""}
            </SheetDescription>
          </SheetHeader>

          <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-4">
            <div className="flex items-center gap-2">
              <Button
                variant="outline"
                className="h-11 lg:h-8"
                onClick={() => historyRow && void handleRunNow(historyRow)}
                disabled={running}
              >
                {running ? (
                  <Loader2Icon
                    className="animate-spin"
                    data-icon="inline-start"
                  />
                ) : (
                  <PlayIcon data-icon="inline-start" />
                )}
                手动执行一次
              </Button>
            </div>

            <p className="text-xs text-muted-foreground">
              执行身份注入订阅属主，数据按属主权限过滤；停用订阅仍可手动执行（用于失败重发）。
            </p>

            {runsLoading ? (
              <ReportLoadingSkeleton rows={3} />
            ) : runs.length === 0 ? (
              <ReportEmptyState
                icon={CalendarClockIcon}
                title="暂无执行记录"
              />
            ) : (
              <div className="flex flex-col gap-2">
                {runs.map((run) => {
                  const normalized = asReportSubscriptionRunStatus(run.status);
                  return (
                    <div
                      key={run.id}
                      className="flex flex-col gap-2 rounded-xl border p-3"
                    >
                      <div className="flex items-center justify-between gap-3">
                        <div className="flex items-center gap-2">
                          {renderRunStatusBadge(run.status)}
                          <span className="text-xs text-muted-foreground">
                            {formatDateTime(run.created_at)}
                            {run.duration_ms === null
                              ? ""
                              : ` · ${run.duration_ms}ms`}
                          </span>
                        </div>
                        {normalized === "failed" && historyRow ? (
                          <Button
                            variant="outline"
                            size="sm"
                            disabled={running}
                            onClick={() => void handleRunNow(historyRow)}
                          >
                            <RotateCcwIcon data-icon="inline-start" />
                            失败重发
                          </Button>
                        ) : null}
                      </div>
                      {run.error ? (
                        <p className="text-xs break-all text-destructive">
                          {run.error}
                        </p>
                      ) : null}
                    </div>
                  );
                })}
              </div>
            )}
          </div>

          <SheetFooter className="flex-row flex-wrap items-center justify-between gap-2">
            <div className="flex flex-wrap items-center gap-2">
              {historyRow ? (
                <>
                  <Button
                    variant="outline"
                    className="h-11 lg:h-8"
                    onClick={() => {
                      const row = historyRow;
                      closeHistory();
                      openEdit(row);
                    }}
                  >
                    <PencilIcon data-icon="inline-start" />
                    编辑
                  </Button>
                  <div className="flex min-h-11 items-center gap-2 lg:min-h-8">
                    <Switch
                      checked={
                        asReportSubscriptionStatus(historyRow.status) === "active"
                      }
                      disabled={togglingId === historyRow.id}
                      aria-label={`${
                        asReportSubscriptionStatus(historyRow.status) === "active"
                          ? "停用"
                          : "启用"
                      }订阅`}
                      onCheckedChange={(checked) =>
                        void handleToggle(historyRow, checked)
                      }
                    />
                    <span className="text-sm text-muted-foreground">
                      {asReportSubscriptionStatus(historyRow.status) === "active"
                        ? "启用中"
                        : "已停用"}
                    </span>
                  </div>
                  <Button
                    variant="destructive"
                    className="h-11 lg:h-8"
                    disabled={deletingId === historyRow.id}
                    onClick={() => setConfirmDeleteFor(historyRow)}
                  >
                    <Trash2Icon data-icon="inline-start" />
                    删除
                  </Button>
                </>
              ) : null}
            </div>
            <Button
              variant="outline"
              className="h-11 lg:h-8"
              onClick={closeHistory}
            >
              关闭
            </Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>

      {/* 删除确认 Sheet（替代 window.confirm；逻辑删说明与动作一致） */}
      <Sheet
        open={confirmDeleteFor !== null}
        onOpenChange={(open) => {
          if (!open) {
            setConfirmDeleteFor(null);
          }
        }}
      >
        <SheetContent side="right" className="w-full sm:max-w-[480px]">
          <SheetHeader>
            <SheetTitle>删除订阅</SheetTitle>
            <SheetDescription>
              {confirmDeleteFor
                ? `确定删除订阅「${confirmDeleteFor.report_name}」？删除为逻辑删除：保留执行历史并注销定时任务。`
                : ""}
            </SheetDescription>
          </SheetHeader>
          <SheetFooter className="flex-row justify-end gap-2">
            <Button
              variant="outline"
              className="h-11 lg:h-8"
              onClick={() => setConfirmDeleteFor(null)}
            >
              取消
            </Button>
            <Button
              variant="destructive"
              className="h-11 lg:h-8"
              disabled={deletingId === confirmDeleteFor?.id}
              onClick={() =>
                confirmDeleteFor && void handleDelete(confirmDeleteFor)
              }
            >
              {deletingId === confirmDeleteFor?.id ? (
                <Loader2Icon
                  className="animate-spin"
                  data-icon="inline-start"
                />
              ) : (
                <Trash2Icon data-icon="inline-start" />
              )}
              删除
            </Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>
    </div>
  );
}
