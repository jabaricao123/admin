"use client";

// 系统管理 · 公告管理（工单 system/014 页面，消费 system/013 的状态机 RPC）
//
// 数据：get_announcements（admin，含发布人姓名）；写经 upsert_announcement（草稿）/
//       publish_announcement（发布，可选站内信）/ offline_announcement（下线）。
// 状态机：draft→published→offline/archived；仅草稿可编辑；archived 由到期自动归档。
// 展示：横幅为主（published_announcements_v 由 dashboard 消费），站内信通知为可选开关；
//       Sheet 内提供桌面/移动简单预览框。
// 移动端（<1024px）：列表渲染卡片（整卡可点打开 Sheet）。

import * as React from "react";
import {
  BanIcon,
  Loader2Icon,
  PinIcon,
  PlusIcon,
  RefreshCwIcon,
  SaveIcon,
  SendIcon,
} from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardAction,
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
import { Textarea } from "@/components/ui/textarea";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { Database } from "@/lib/database.types";
import {
  announcementAudienceLabel,
  ANNOUNCEMENT_AUDIENCE_OPTIONS,
  ANNOUNCEMENT_STATUS_BADGE_CLASSES,
  ANNOUNCEMENT_STATUS_LABELS,
  asAnnouncementStatus,
  translateAnnouncementErrorMessage,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type AnnouncementRow =
  Database["public"]["Functions"]["get_announcements"]["Returns"][number];
type UpsertAnnouncementArgs =
  Database["public"]["Functions"]["upsert_announcement"]["Args"];

const AMBER_BADGE =
  "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300";

function formatDateTime(value: string | null | undefined): string {
  if (!value) {
    return "—";
  }
  return new Date(value).toLocaleString("zh-CN", { hour12: false });
}

/** 生效时段展示：开始 ~ 结束；草稿可能为空 */
function formatPeriod(row: AnnouncementRow): string {
  if (!row.starts_at || !row.ends_at) {
    return "未设置";
  }
  return `${formatDateTime(row.starts_at)} ~ ${formatDateTime(row.ends_at)}`;
}

/** timestamptz → datetime-local 输入值（本地时区） */
function toDateTimeLocal(value: string | null | undefined): string {
  if (!value) {
    return "";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "";
  }
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(
    date.getDate(),
  )}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

/** datetime-local 输入值 → ISO（无效输入返回 null） */
function fromDateTimeLocal(value: string): string | null {
  if (!value) {
    return null;
  }
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

type FormState = {
  title: string;
  content: string;
  startsAt: string;
  endsAt: string;
  audience: string;
  pinned: boolean;
  notify: boolean;
};

const EMPTY_FORM: FormState = {
  title: "",
  content: "",
  startsAt: "",
  endsAt: "",
  audience: "all",
  pinned: false,
  notify: false,
};

export function AnnouncementsTable() {
  const [rows, setRows] = React.useState<AnnouncementRow[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);

  const [sheetOpen, setSheetOpen] = React.useState(false);
  const [editing, setEditing] = React.useState<AnnouncementRow | null>(null);
  const [form, setForm] = React.useState<FormState>(EMPTY_FORM);
  const [saving, setSaving] = React.useState(false);
  const [publishing, setPublishing] = React.useState(false);
  const [offlining, setOfflining] = React.useState(false);

  const editingStatus = editing
    ? asAnnouncementStatus(editing.status)
    : null;
  const editable = editing === null || editingStatus === "draft";
  const busy = saving || publishing || offlining;

  const load = React.useCallback(async (options?: { silent?: boolean }) => {
    if (!options?.silent) {
      setLoading(true);
    }
    setError(null);

    const supabase = createClient();
    const { data, error: loadError } =
      await supabase.rpc("get_announcements");

    if (loadError) {
      setError(loadError.message);
      setLoading(false);
      return;
    }

    setRows(data ?? []);
    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const openCreate = () => {
    setEditing(null);
    setForm(EMPTY_FORM);
    setSheetOpen(true);
  };

  const openEdit = (row: AnnouncementRow) => {
    setEditing(row);
    setForm({
      title: row.title,
      content: row.content,
      startsAt: toDateTimeLocal(row.starts_at),
      endsAt: toDateTimeLocal(row.ends_at),
      audience: row.audience,
      pinned: row.pinned,
      notify: false,
    });
    setSheetOpen(true);
  };

  /** 保存草稿（新建或编辑），成功返回公告 id */
  const saveDraft = async (): Promise<string | null> => {
    const title = form.title.trim();
    const content = form.content.trim();
    if (title === "") {
      toast.error("公告标题不能为空");
      return null;
    }
    if (content === "") {
      toast.error("公告正文不能为空");
      return null;
    }

    const startsAt = fromDateTimeLocal(form.startsAt);
    const endsAt = fromDateTimeLocal(form.endsAt);
    if (startsAt && endsAt && new Date(endsAt) <= new Date(startsAt)) {
      toast.error("生效时段不合法：结束时间必须晚于开始时间");
      return null;
    }

    setSaving(true);
    const supabase = createClient();
    const args = {
      p_title: title,
      p_content: content,
      p_starts_at: startsAt,
      p_ends_at: endsAt,
      p_audience: form.audience,
      p_pinned: form.pinned,
      p_id: editing?.id ?? null,
    };
    const { data, error: saveError } = await supabase.rpc(
      "upsert_announcement",
      args as UpsertAnnouncementArgs,
    );
    setSaving(false);

    if (saveError) {
      toast.error(translateAnnouncementErrorMessage(saveError.message));
      return null;
    }

    const result = (data ?? null) as { id?: string } | null;
    if (!result?.id) {
      toast.error("保存成功但未返回公告 id，请刷新后重试");
      return null;
    }
    return result.id;
  };

  const handleSave = async () => {
    const id = await saveDraft();
    if (!id) {
      return;
    }
    toast.success(editing ? "公告已保存" : "草稿已创建");
    setSheetOpen(false);
    void load({ silent: true });
  };

  const handlePublish = async () => {
    if (!form.startsAt || !form.endsAt) {
      toast.error("发布前请先填写生效时段（开始与结束时间）");
      return;
    }
    const id = await saveDraft();
    if (!id) {
      return;
    }

    setPublishing(true);
    const supabase = createClient();
    const { data, error: publishError } = await supabase.rpc(
      "publish_announcement",
      { p_id: id, p_notify: form.notify },
    );
    setPublishing(false);

    if (publishError) {
      toast.error(translateAnnouncementErrorMessage(publishError.message));
      return;
    }

    const result = (data ?? null) as { notified?: number } | null;
    const notified = result?.notified ?? 0;
    toast.success(
      notified > 0 ? `公告已发布，已发送 ${notified} 条站内信` : "公告已发布",
    );
    setSheetOpen(false);
    void load({ silent: true });
  };

  const handleOffline = async () => {
    if (!editing) {
      return;
    }
    setOfflining(true);
    const supabase = createClient();
    const { error: offlineError } = await supabase.rpc("offline_announcement", {
      p_id: editing.id,
    });
    setOfflining(false);

    if (offlineError) {
      toast.error(translateAnnouncementErrorMessage(offlineError.message));
      return;
    }

    toast.success("公告已下线");
    setSheetOpen(false);
    void load({ silent: true });
  };

  if (loading) {
    return (
      <div className="flex flex-col gap-4 p-4 lg:gap-6 lg:p-6">
        <Skeleton className="h-20 w-full" />
        <Skeleton className="h-72 w-full" />
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex flex-col p-4 lg:p-6">
        <Card>
          <CardContent className="flex flex-col items-center gap-2 py-16 text-sm">
            <p className="text-destructive">
              加载失败：{translateAnnouncementErrorMessage(error)}
            </p>
            <Button variant="outline" onClick={() => void load()}>
              重试
            </Button>
          </CardContent>
        </Card>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-4 p-4 lg:gap-6 lg:p-6">
      <Card>
        <CardHeader>
          <CardTitle>公告列表（{rows.length}）</CardTitle>
          <CardDescription>
            草稿可编辑发布；已发布公告展示在工作台横幅，站内信通知为可选；到期自动归档
          </CardDescription>
          <CardAction className="flex items-center gap-2">
            <Button
              variant="outline"
              size="sm"
              onClick={() => void load({ silent: true })}
              disabled={loading}
            >
              <RefreshCwIcon
                className={loading ? "animate-spin" : undefined}
                data-icon="inline-start"
              />
              刷新
            </Button>
            <Button size="sm" onClick={openCreate}>
              <PlusIcon data-icon="inline-start" />
              新建公告
            </Button>
          </CardAction>
        </CardHeader>
        <CardContent>
          {rows.length === 0 ? (
            <p className="py-10 text-center text-sm text-muted-foreground">
              暂无公告，点击右上角「新建公告」创建
            </p>
          ) : (
            <>
              <div className="hidden overflow-x-auto lg:block">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead className="text-center">标题</TableHead>
                      <TableHead className="text-center">生效时段</TableHead>
                      <TableHead className="text-center">范围</TableHead>
                      <TableHead className="text-center">状态</TableHead>
                      <TableHead className="text-center">发布人</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {rows.map((row) => {
                      const status = asAnnouncementStatus(row.status);
                      return (
                        <TableRow
                          key={row.id}
                          className="cursor-pointer"
                          onClick={() => openEdit(row)}
                          tabIndex={0}
                          onKeyDown={(event) => {
                            if (event.key === "Enter") {
                              openEdit(row);
                            }
                          }}
                        >
                          <TableCell className="text-left">
                            <span className="flex items-center gap-2">
                              {row.pinned ? (
                                <PinIcon className="size-3.5 shrink-0 text-amber-600" />
                              ) : null}
                              <span className="line-clamp-1">{row.title}</span>
                            </span>
                          </TableCell>
                          <TableCell className="text-center text-xs text-muted-foreground">
                            {formatPeriod(row)}
                          </TableCell>
                          <TableCell className="text-center text-xs">
                            {announcementAudienceLabel(row.audience)}
                          </TableCell>
                          <TableCell className="text-center">
                            <Badge
                              variant="outline"
                              className={
                                ANNOUNCEMENT_STATUS_BADGE_CLASSES[status]
                              }
                            >
                              {ANNOUNCEMENT_STATUS_LABELS[status]}
                            </Badge>
                          </TableCell>
                          <TableCell className="text-center text-xs text-muted-foreground">
                            {row.publisher_name ?? "—"}
                          </TableCell>
                        </TableRow>
                      );
                    })}
                  </TableBody>
                </Table>
              </div>

              {/* 移动端：卡片（整卡可点打开 Sheet） */}
              <div className="flex flex-col gap-2 lg:hidden">
                {rows.map((row) => {
                  const status = asAnnouncementStatus(row.status);
                  return (
                    <button
                      key={row.id}
                      type="button"
                      onClick={() => openEdit(row)}
                      className="flex flex-col gap-2 rounded-xl border p-4 text-left transition-colors hover:border-primary focus-visible:border-primary focus-visible:outline-none"
                    >
                      <div className="flex items-start justify-between gap-2">
                        <span className="flex items-center gap-2 text-sm font-medium">
                          {row.pinned ? (
                            <PinIcon className="size-3.5 shrink-0 text-amber-600" />
                          ) : null}
                          {row.title}
                        </span>
                        <Badge
                          variant="outline"
                          className={ANNOUNCEMENT_STATUS_BADGE_CLASSES[status]}
                        >
                          {ANNOUNCEMENT_STATUS_LABELS[status]}
                        </Badge>
                      </div>
                      <div className="text-xs text-muted-foreground">
                        {formatPeriod(row)}
                      </div>
                      <div className="flex items-center justify-between text-xs text-muted-foreground">
                        <span>{announcementAudienceLabel(row.audience)}</span>
                        <span>{row.publisher_name ?? "—"}</span>
                      </div>
                    </button>
                  );
                })}
              </div>
            </>
          )}
        </CardContent>
      </Card>

      {/* 编辑 / 预览 Sheet（桌面与移动同组件同视觉） */}
      <Sheet
        open={sheetOpen}
        onOpenChange={(open) => {
          if (!busy) {
            setSheetOpen(open);
          }
        }}
      >
        <SheetContent
          side="right"
          className="w-[35vw] min-w-[320px] max-w-[480px]"
        >
          <SheetHeader className="border-b">
            <SheetTitle>
              {editing === null
                ? "新建公告"
                : editable
                  ? "编辑草稿"
                  : "公告详情"}
            </SheetTitle>
            <SheetDescription>
              {editing === null
                ? "保存草稿后可发布；发布时可选站内信通知"
                : editable
                  ? "仅草稿可编辑；发布后展示在工作台横幅"
                  : "非草稿状态只读；已发布公告可下线"}
            </SheetDescription>
          </SheetHeader>

          <div className="flex flex-1 flex-col gap-4 overflow-y-auto px-4">
            <Field>
              <FieldLabel htmlFor="announcement-title">标题</FieldLabel>
              <Input
                id="announcement-title"
                value={form.title}
                onChange={(event) =>
                  setForm((prev) => ({ ...prev, title: event.target.value }))
                }
                placeholder="公告标题"
                autoComplete="off"
                disabled={!editable || busy}
                className="h-11 lg:h-8"
              />
            </Field>

            <Field>
              <FieldLabel htmlFor="announcement-content">正文</FieldLabel>
              <Textarea
                id="announcement-content"
                value={form.content}
                onChange={(event) =>
                  setForm((prev) => ({ ...prev, content: event.target.value }))
                }
                placeholder={"支持 markdown 子集：换行、列表、加粗、链接"}
                rows={6}
                disabled={!editable || busy}
              />
              <FieldDescription>
                富文本 v1 以受限 markdown 文本存储与展示
              </FieldDescription>
            </Field>

            <div className="grid grid-cols-2 gap-3">
              <Field>
                <FieldLabel htmlFor="announcement-starts">生效开始</FieldLabel>
                <Input
                  id="announcement-starts"
                  type="datetime-local"
                  value={form.startsAt}
                  onChange={(event) =>
                    setForm((prev) => ({
                      ...prev,
                      startsAt: event.target.value,
                    }))
                  }
                  disabled={!editable || busy}
                  className="h-11 lg:h-8"
                />
              </Field>
              <Field>
                <FieldLabel htmlFor="announcement-ends">生效结束</FieldLabel>
                <Input
                  id="announcement-ends"
                  type="datetime-local"
                  value={form.endsAt}
                  onChange={(event) =>
                    setForm((prev) => ({
                      ...prev,
                      endsAt: event.target.value,
                    }))
                  }
                  disabled={!editable || busy}
                  className="h-11 lg:h-8"
                />
              </Field>
            </div>

            <Field>
              <FieldLabel htmlFor="announcement-audience">可见范围</FieldLabel>
              <Select
                value={form.audience}
                onValueChange={(value) =>
                  setForm((prev) => ({ ...prev, audience: value }))
                }
                disabled={!editable || busy}
              >
                <SelectTrigger
                  id="announcement-audience"
                  className="h-11 w-full lg:h-8"
                >
                  <SelectValue placeholder="选择范围" />
                </SelectTrigger>
                <SelectContent>
                  {ANNOUNCEMENT_AUDIENCE_OPTIONS.map((option) => (
                    <SelectItem key={option.value} value={option.value}>
                      {option.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>

            <label className="flex cursor-pointer items-center gap-3 rounded-lg border p-3 text-sm has-data-checked:border-primary/40 has-data-checked:bg-primary/5">
              <Checkbox
                checked={form.pinned}
                onCheckedChange={(checked) =>
                  setForm((prev) => ({ ...prev, pinned: checked === true }))
                }
                disabled={!editable || busy}
              />
              <span className="flex items-center gap-2">
                <PinIcon className="size-4 text-muted-foreground" />
                置顶展示（横幅排序优先）
              </span>
            </label>

            {editable ? (
              <label className="flex cursor-pointer items-center gap-3 rounded-lg border p-3 text-sm has-data-checked:border-primary/40 has-data-checked:bg-primary/5">
                <Checkbox
                  checked={form.notify}
                  onCheckedChange={(checked) =>
                    setForm((prev) => ({ ...prev, notify: checked === true }))
                  }
                  disabled={busy}
                />
                <span className="flex flex-col">
                  <span>同时发送站内信通知</span>
                  <span className="text-xs text-muted-foreground">
                    可选；横幅为主展示位，默认不群发站内信
                  </span>
                </span>
              </label>
            ) : null}

            {/* 预览：桌面 / 移动简单预览框 */}
            <div className="flex flex-col gap-2">
              <div className="text-sm font-medium">预览</div>
              <div className="rounded-xl border p-3">
                <div className="mb-2 text-xs text-muted-foreground">
                  桌面横幅
                </div>
                <div className="rounded-lg border bg-accent/60 p-3">
                  <PreviewBody form={form} />
                </div>
              </div>
              <div className="rounded-xl border p-3">
                <div className="mb-2 text-xs text-muted-foreground">移动横幅</div>
                <div className="mx-auto w-56 rounded-lg border bg-accent/60 p-3">
                  <PreviewBody form={form} compact />
                </div>
              </div>
            </div>
          </div>

          <SheetFooter className="flex-row items-center justify-end gap-2 border-t">
            <Button
              type="button"
              variant="outline"
              className="h-11 lg:h-8"
              onClick={() => setSheetOpen(false)}
              disabled={busy}
            >
              {editable ? "取消" : "关闭"}
            </Button>

            {editable ? (
              <>
                <Button
                  type="button"
                  variant="outline"
                  className="h-11 lg:h-8"
                  onClick={() => void handleSave()}
                  disabled={busy}
                >
                  {saving ? (
                    <Loader2Icon
                      className="animate-spin"
                      data-icon="inline-start"
                    />
                  ) : (
                    <SaveIcon data-icon="inline-start" />
                  )}
                  保存草稿
                </Button>
                <Button
                  type="button"
                  className="h-11 lg:h-8"
                  onClick={() => void handlePublish()}
                  disabled={busy}
                >
                  {publishing ? (
                    <Loader2Icon
                      className="animate-spin"
                      data-icon="inline-start"
                    />
                  ) : (
                    <SendIcon data-icon="inline-start" />
                  )}
                  发布
                </Button>
              </>
            ) : editingStatus === "published" ? (
              <Button
                type="button"
                variant="outline"
                className="h-11 lg:h-8"
                onClick={() => void handleOffline()}
                disabled={busy}
              >
                {offlining ? (
                  <Loader2Icon
                    className="animate-spin"
                    data-icon="inline-start"
                  />
                ) : (
                  <BanIcon data-icon="inline-start" />
                )}
                下线
              </Button>
            ) : null}
          </SheetFooter>
        </SheetContent>
      </Sheet>
    </div>
  );
}

function PreviewBody({
  form,
  compact = false,
}: {
  form: FormState;
  compact?: boolean;
}) {
  return (
    <div className="flex flex-col gap-1">
      <div className="flex items-start gap-2">
        {form.pinned ? (
          <PinIcon className="mt-0.5 size-3.5 shrink-0 text-amber-600" />
        ) : null}
        <span
          className={
            compact ? "text-sm font-medium" : "text-base font-semibold"
          }
        >
          {form.title.trim() === "" ? "公告标题" : form.title}
        </span>
      </div>
      <p className="line-clamp-3 whitespace-pre-wrap text-xs text-muted-foreground">
        {form.content.trim() === "" ? "公告正文预览…" : form.content}
      </p>
      <div className="mt-1 flex items-center gap-2 text-[10px] text-muted-foreground">
        <Badge variant="outline" className={AMBER_BADGE}>
          {announcementAudienceLabel(form.audience)}
        </Badge>
        {form.startsAt || form.endsAt ? (
          <span>
            {formatDateTime(fromDateTimeLocal(form.startsAt))} ~{" "}
            {formatDateTime(fromDateTimeLocal(form.endsAt))}
          </span>
        ) : null}
      </div>
    </div>
  );
}
