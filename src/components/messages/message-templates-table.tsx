"use client";

// 消息中心 · 通知文案模板（工单 message/006 页面，消费 004+005 的 registry / 模板 RPC）
//
// 数据：message_event_registry（事件 + 可用变量）、message_templates（版本化）、
//       message_template_current（当前版本指针）；三者 admin SELECT（RLS 收口），
//       写全经 public 管理 RPC（upsert / publish / rollback）。
// 交互：列表按 event_key 分组展示 current 版本；Sheet 编辑（事件/渠道锁定、可用变量 Badge、
//       等宽字体模板编辑、预览 tab 三渠道并列、历史版本 tab 回滚）。
// 语义：published 版本不可改；「保存草稿」新建/续编草稿，「发布」把草稿设为 current；
//       回滚 = 复制旧版本为新版本并置 current（后端保证历史保留）。

import * as React from "react";
import {
  FileTextIcon,
  HistoryIcon,
  Loader2Icon,
  PlusIcon,
  RotateCcwIcon,
  SaveIcon,
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
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Textarea } from "@/components/ui/textarea";
import type { Database } from "@/lib/database.types";
import {
  asTemplateChannel,
  asTemplateStatus,
  TEMPLATE_CHANNEL_LABELS,
  TEMPLATE_CHANNEL_OPTIONS,
  TEMPLATE_STATUS_BADGE_CLASSES,
  TEMPLATE_STATUS_LABELS,
  translateMessageTemplateErrorMessage,
  type TemplateChannel,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type RegistryRow =
  Database["public"]["Tables"]["message_event_registry"]["Row"];
type TemplateRow = Database["public"]["Tables"]["message_templates"]["Row"];
type TemplateResult =
  Database["public"]["Functions"]["upsert_message_template"]["Returns"];

const CHANNELS: TemplateChannel[] = ["inbox", "email", "push"];

const pointerKey = (eventKey: string, channel: string) =>
  `${eventKey}|${channel}`;

const formatDateTime = (value: string) =>
  new Date(value).toLocaleString("zh-CN", { hour12: false });

/** registry.available_vars（jsonb）→ string[]，过滤非字符串项 */
function varNames(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];
}

/**
 * 前端实时渲染 {{var}}：与后端 app.render_message_template 语义一致——
 * 未提供（或 JSON null）的变量保留占位符原文，不报错。
 */
function renderTemplate(tpl: string, vars: Record<string, unknown>): string {
  return tpl.replace(/\{\{([^{}]+)\}\}/g, (match, key: string) => {
    const value = vars[key];
    if (value === undefined || value === null) {
      return match;
    }
    return typeof value === "object" ? JSON.stringify(value) : String(value);
  });
}

/** 预览样例值（按常见变量给贴近业务的默认值，其余回退「示例」） */
const SAMPLE_VALUES: Record<string, string> = {
  initiator: "张三",
  title: "请假申请（2026-10-08 至 2026-10-09）",
  comment: "同意，注意交接",
  publisher: "系统管理员",
  task_name: "每日订单同步",
  status: "成功",
  rows: "128",
  finished_at: "2026-10-05 09:30",
  endpoint: "https://example.com/hooks/erp",
  event: "order.updated",
  attempt: "3",
  error: "连接超时",
  report_name: "用户统计月报",
  download_url: "https://example.com/export/abc",
};

function defaultSampleJson(vars: string[]): string {
  const sample: Record<string, string> = {};
  for (const name of vars) {
    sample[name] = SAMPLE_VALUES[name] ?? "示例";
  }
  return JSON.stringify(sample, null, 2);
}

export function MessageTemplatesTable() {
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [registry, setRegistry] = React.useState<RegistryRow[]>([]);
  const [templates, setTemplates] = React.useState<TemplateRow[]>([]);
  const [currentIds, setCurrentIds] = React.useState<Record<string, string>>(
    {},
  );

  // Sheet 状态
  const [sheetOpen, setSheetOpen] = React.useState(false);
  const [locked, setLocked] = React.useState(true);
  const [formEventKey, setFormEventKey] = React.useState("");
  const [formChannel, setFormChannel] =
    React.useState<TemplateChannel>("inbox");
  const [formSubject, setFormSubject] = React.useState("");
  const [formBody, setFormBody] = React.useState("");
  const [draftId, setDraftId] = React.useState<string | null>(null);
  const [sampleJson, setSampleJson] = React.useState("{}");
  const [activeTab, setActiveTab] = React.useState("edit");
  const [saving, setSaving] = React.useState(false);
  const [publishing, setPublishing] = React.useState(false);
  const [rollingBackId, setRollingBackId] = React.useState<string | null>(null);

  const load = React.useCallback(async (options?: { silent?: boolean }) => {
    if (!options?.silent) {
      setLoading(true);
    }
    setError(null);

    const supabase = createClient();
    const [registryResult, templateResult, currentResult] = await Promise.all([
      supabase.from("message_event_registry").select("*").order("event_key"),
      supabase
        .from("message_templates")
        .select("*")
        .order("event_key")
        .order("channel")
        .order("version", { ascending: false }),
      supabase.from("message_template_current").select("*"),
    ]);

    const firstError =
      registryResult.error ?? templateResult.error ?? currentResult.error;
    if (firstError) {
      setError(firstError.message);
      setLoading(false);
      return;
    }

    setRegistry(registryResult.data ?? []);
    setTemplates(templateResult.data ?? []);
    const pointers: Record<string, string> = {};
    for (const row of currentResult.data ?? []) {
      pointers[pointerKey(row.event_key, row.channel)] = row.template_id;
    }
    setCurrentIds(pointers);
    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const versionsFor = React.useCallback(
    (eventKey: string, channel: string) =>
      templates
        .filter((row) => row.event_key === eventKey && row.channel === channel)
        .sort((a, b) => b.version - a.version),
    [templates],
  );

  const currentFor = React.useCallback(
    (eventKey: string, channel: string): TemplateRow | null => {
      const id = currentIds[pointerKey(eventKey, channel)];
      if (!id) {
        return null;
      }
      return templates.find((row) => row.id === id) ?? null;
    },
    [templates, currentIds],
  );

  const draftFor = React.useCallback(
    (eventKey: string, channel: string): TemplateRow | null =>
      versionsFor(eventKey, channel).find((row) => row.status === "draft") ??
      null,
    [versionsFor],
  );

  const registryVars = React.useCallback(
    (eventKey: string): string[] => {
      const event = registry.find((row) => row.event_key === eventKey);
      return varNames(event?.available_vars);
    },
    [registry],
  );

  const openEditor = (
    eventKey: string,
    channel: TemplateChannel,
    tab: "edit" | "history" = "edit",
  ) => {
    const draft = draftFor(eventKey, channel);
    const current = currentFor(eventKey, channel);
    const source = draft ?? current;
    setFormEventKey(eventKey);
    setFormChannel(channel);
    setFormSubject(source?.subject_tpl ?? "");
    setFormBody(source?.body_tpl ?? "");
    setDraftId(draft?.id ?? null);
    setLocked(true);
    setSampleJson(defaultSampleJson(registryVars(eventKey)));
    setActiveTab(tab);
    setSheetOpen(true);
  };

  const openCreate = () => {
    const first = registry[0];
    setFormEventKey(first?.event_key ?? "");
    setFormChannel("inbox");
    setFormSubject("");
    setFormBody("");
    setDraftId(null);
    setLocked(false);
    setSampleJson(defaultSampleJson(varNames(first?.available_vars)));
    setActiveTab("edit");
    setSheetOpen(true);
  };

  const closeSheet = () => {
    setSheetOpen(false);
    setDraftId(null);
    setFormSubject("");
    setFormBody("");
    setSampleJson("{}");
  };

  const editingVersion = React.useMemo(() => {
    if (draftId) {
      return templates.find((row) => row.id === draftId) ?? null;
    }
    return null;
  }, [draftId, templates]);

  /** 保存草稿：有草稿续编，否则新建 version=max+1；返回保存后的行 */
  const saveDraft = async (): Promise<TemplateResult | null> => {
    if (!formEventKey) {
      toast.error("请选择事件");
      return null;
    }
    if (!formSubject.trim()) {
      toast.error("标题模板不能为空");
      return null;
    }

    setSaving(true);
    const supabase = createClient();
    const { data, error: saveError } = await supabase.rpc(
      "upsert_message_template",
      {
        p_event_key: formEventKey,
        p_channel: formChannel,
        p_subject_tpl: formSubject,
        p_body_tpl: formBody,
        p_id: draftId ?? undefined,
      },
    );
    setSaving(false);

    if (saveError) {
      toast.error(translateMessageTemplateErrorMessage(saveError.message));
      return null;
    }

    setDraftId(data.id);
    setLocked(true);
    return data;
  };

  const handleSaveDraft = async () => {
    const saved = await saveDraft();
    if (!saved) {
      return;
    }
    toast.success(`草稿已保存（v${saved.version}）`);
    void load({ silent: true });
  };

  const handlePublish = async () => {
    const saved = await saveDraft();
    if (!saved) {
      return;
    }

    setPublishing(true);
    const supabase = createClient();
    const { data, error: publishError } = await supabase.rpc(
      "publish_message_template",
      { p_id: saved.id },
    );
    setPublishing(false);

    if (publishError) {
      toast.error(translateMessageTemplateErrorMessage(publishError.message));
      return;
    }

    toast.success(`已发布 v${data.version}，站内信即刻按新模板渲染`);
    setDraftId(null);
    void load({ silent: true });
  };

  const handleRollback = async (row: TemplateRow) => {
    const confirmed = window.confirm(
      `确定回滚到 v${row.version}？将复制为新版本并立即生效（历史版本全部保留）。`,
    );
    if (!confirmed) {
      return;
    }

    setRollingBackId(row.id);
    const supabase = createClient();
    const { data, error: rollbackError } = await supabase.rpc(
      "rollback_message_template",
      { p_id: row.id },
    );
    setRollingBackId(null);

    if (rollbackError) {
      toast.error(translateMessageTemplateErrorMessage(rollbackError.message));
      return;
    }

    setFormSubject(data.subject_tpl);
    setFormBody(data.body_tpl);
    setDraftId(null);
    toast.success(`已回滚：复制 v${row.version} 为 v${data.version} 并生效`);
    void load({ silent: true });
  };

  /** 样例变量解析（预览 tab；解析失败不阻塞编辑） */
  const sampleVars = React.useMemo(() => {
    try {
      const parsed: unknown = JSON.parse(sampleJson);
      if (
        parsed === null ||
        typeof parsed !== "object" ||
        Array.isArray(parsed)
      ) {
        return { ok: false as const, message: "样例变量必须是 JSON 对象" };
      }
      return { ok: true as const, vars: parsed as Record<string, unknown> };
    } catch {
      return { ok: false as const, message: "样例变量 JSON 解析失败" };
    }
  }, [sampleJson]);

  /** 三渠道预览：当前编辑渠道用实时输入；其余渠道取 current（无则草稿） */
  const previewChannels = CHANNELS.map((channel) => {
    if (channel === formChannel) {
      return {
        channel,
        live: true,
        configured: formSubject !== "" || formBody !== "",
        subject: formSubject,
        body: formBody,
      };
    }
    const source =
      currentFor(formEventKey, channel) ?? draftFor(formEventKey, channel);
    return {
      channel,
      live: false,
      configured: source !== null,
      subject: source?.subject_tpl ?? "",
      body: source?.body_tpl ?? "",
    };
  });

  const historyVersions = versionsFor(formEventKey, formChannel);
  const currentId = currentIds[pointerKey(formEventKey, formChannel)] ?? null;
  const availableVars = registryVars(formEventKey);

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex items-center justify-between gap-2">
            <span className="text-sm text-muted-foreground">
              共 {registry.length} 个已注册事件
            </span>
            <div className="flex items-center gap-2">
              <Button
                onClick={openCreate}
                disabled={registry.length === 0}
                className="h-11 lg:h-8"
              >
                <PlusIcon data-icon="inline-start" />
                新增模板
              </Button>
            </div>
          </div>

          {loading ? (
            <div className="flex flex-col gap-3">
              {Array.from({ length: 3 }).map((_, index) => (
                <Skeleton key={index} className="h-40 w-full" />
              ))}
            </div>
          ) : error ? (
            <div className="flex flex-col items-center gap-2 py-8 text-sm">
              <p className="text-destructive">
                加载失败：{translateMessageTemplateErrorMessage(error)}
              </p>
              <Button variant="outline" onClick={() => void load()}>
                重试
              </Button>
            </div>
          ) : registry.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <FileTextIcon className="size-8 opacity-60" />
              <span>暂无已注册事件</span>
            </div>
          ) : (
            <div className="flex flex-col gap-3">
              {registry.map((event) => {
                const vars = varNames(event.available_vars);
                return (
                  <Card key={event.event_key} className="shadow-xs gap-3! py-3!">
                    <CardHeader className="gap-1 pb-2">
                      <div className="flex flex-wrap items-center gap-2">
                        <CardTitle className="font-mono text-sm">
                          {event.event_key}
                        </CardTitle>
                        <Badge variant="outline">{event.module}</Badge>
                      </div>
                      {event.description ? (
                        <CardDescription>{event.description}</CardDescription>
                      ) : null}
                      {vars.length > 0 ? (
                        <div className="flex flex-wrap items-center gap-1 pt-1">
                          <span className="text-xs text-muted-foreground">
                            可用变量
                          </span>
                          {vars.map((name) => (
                            <Badge
                              key={name}
                              variant="ghost"
                              className="font-mono text-[11px]"
                            >
                              {`{{${name}}}`}
                            </Badge>
                          ))}
                        </div>
                      ) : null}
                    </CardHeader>
                    <CardContent className="divide-y">
                      {CHANNELS.map((channel) => {
                        const current = currentFor(event.event_key, channel);
                        const draft = draftFor(event.event_key, channel);
                        const latest = current ?? draft;
                        const versions = versionsFor(event.event_key, channel);
                        return (
                          <div
                            key={channel}
                            className="flex flex-wrap items-center gap-x-3 gap-y-2 py-3"
                          >
                            <span className="w-12 text-sm font-medium">
                              {TEMPLATE_CHANNEL_LABELS[channel]}
                            </span>
                            {latest ? (
                              <>
                                <span className="font-mono text-sm">
                                  v{latest.version}
                                </span>
                                <Badge
                                  variant="outline"
                                  className={
                                    TEMPLATE_STATUS_BADGE_CLASSES[
                                      asTemplateStatus(latest.status)
                                    ]
                                  }
                                >
                                  {
                                    TEMPLATE_STATUS_LABELS[
                                      asTemplateStatus(latest.status)
                                    ]
                                  }
                                </Badge>
                                {draft && current && draft.id !== current.id ? (
                                  <Badge
                                    variant="outline"
                                    className={
                                      TEMPLATE_STATUS_BADGE_CLASSES.draft
                                    }
                                  >
                                    草稿 v{draft.version}
                                  </Badge>
                                ) : null}
                                <span className="text-xs text-muted-foreground">
                                  {formatDateTime(latest.updated_at)}
                                </span>
                              </>
                            ) : (
                              <Badge variant="ghost">未配置</Badge>
                            )}
                            <div className="ml-auto flex items-center gap-1">
                              <Button
                                size="sm"
                                variant={latest ? "outline" : "default"}
                                onClick={() =>
                                  openEditor(event.event_key, channel)
                                }
                                className="h-9 lg:h-8"
                              >
                                {latest ? "编辑" : "新建"}
                              </Button>
                              {versions.length > 0 ? (
                                <Button
                                  size="sm"
                                  variant="ghost"
                                  onClick={() =>
                                    openEditor(
                                      event.event_key,
                                      channel,
                                      "history",
                                    )
                                  }
                                  className="h-9 lg:h-8"
                                >
                                  <HistoryIcon data-icon="inline-start" />
                                  历史版本
                                </Button>
                              ) : null}
                            </div>
                          </div>
                        );
                      })}
                    </CardContent>
                  </Card>
                );
              })}
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
          className="w-full gap-0 sm:w-[52vw] sm:min-w-[420px] sm:max-w-[780px]"
        >
          <SheetHeader className="border-b">
            <SheetTitle>{locked ? "编辑通知模板" : "新增通知模板"}</SheetTitle>
            <SheetDescription className="flex flex-col gap-1">
              <span className="font-mono text-xs">
                {formEventKey || "（未选择事件）"} ·{" "}
                {TEMPLATE_CHANNEL_LABELS[formChannel]}
              </span>
              <span className="text-xs">
                {locked
                  ? "事件与渠道创建后不可修改；已发布版本内容冻结，保存将生成新草稿版本"
                  : "选择事件与渠道；发布后事件与渠道不可修改"}
              </span>
            </SheetDescription>
          </SheetHeader>

          <Tabs
            value={activeTab}
            onValueChange={setActiveTab}
            className="min-h-0 flex-1 gap-0 px-4"
          >
            <TabsList className="mt-3 w-full">
              <TabsTrigger value="edit">编辑</TabsTrigger>
              <TabsTrigger value="preview">预览</TabsTrigger>
              <TabsTrigger value="history">
                历史版本
                {historyVersions.length > 0
                  ? `（${historyVersions.length}）`
                  : ""}
              </TabsTrigger>
            </TabsList>

            {/* 编辑 */}
            <TabsContent
              value="edit"
              className="flex min-h-0 flex-col gap-4 overflow-y-auto pt-4 pb-2"
            >
              <Field>
                <FieldLabel htmlFor="template-event">事件</FieldLabel>
                <Select
                  value={formEventKey}
                  onValueChange={(value) => {
                    setFormEventKey(value);
                    setSampleJson(defaultSampleJson(registryVars(value)));
                  }}
                  disabled={locked}
                >
                  <SelectTrigger id="template-event" className="w-full">
                    <SelectValue placeholder="选择已注册事件" />
                  </SelectTrigger>
                  <SelectContent>
                    {registry.map((event) => (
                      <SelectItem key={event.event_key} value={event.event_key}>
                        {event.event_key}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <FieldDescription>
                  未注册事件不可建模板；新事件由各模块经 register_message_event
                  登记
                </FieldDescription>
              </Field>

              <Field>
                <FieldLabel htmlFor="template-channel">渠道</FieldLabel>
                <Select
                  value={formChannel}
                  onValueChange={(value) =>
                    setFormChannel(asTemplateChannel(value))
                  }
                  disabled={locked}
                >
                  <SelectTrigger id="template-channel" className="w-full">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {TEMPLATE_CHANNEL_OPTIONS.map((option) => (
                      <SelectItem key={option.value} value={option.value}>
                        {option.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <FieldDescription>
                  邮件 / 推送实际投递在 message/009，本期各渠道模板独立维护
                </FieldDescription>
              </Field>

              {availableVars.length > 0 ? (
                <div className="flex flex-wrap items-center gap-1 rounded-lg border bg-muted/40 p-2">
                  <span className="px-1 text-xs text-muted-foreground">
                    可用变量
                  </span>
                  {availableVars.map((name) => (
                    <Badge
                      key={name}
                      variant="secondary"
                      className="font-mono text-[11px]"
                    >
                      {`{{${name}}}`}
                    </Badge>
                  ))}
                </div>
              ) : null}

              <Field>
                <FieldLabel htmlFor="template-subject">标题模板</FieldLabel>
                <Input
                  id="template-subject"
                  value={formSubject}
                  onChange={(event) => setFormSubject(event.target.value)}
                  placeholder="如：待办：{{title}}"
                  className="font-mono"
                />
              </Field>

              <Field>
                <FieldLabel htmlFor="template-body">正文模板</FieldLabel>
                <Textarea
                  id="template-body"
                  rows={8}
                  value={formBody}
                  onChange={(event) => setFormBody(event.target.value)}
                  placeholder={"如：发起人 {{initiator}} 提交的申请待你处理"}
                  className="font-mono"
                />
                <FieldDescription>
                  未提供的变量在发送时保留占位符原文（降级显示，不报错）
                </FieldDescription>
              </Field>
            </TabsContent>

            {/* 预览：样例变量 + 三渠道并列 */}
            <TabsContent
              value="preview"
              className="flex min-h-0 flex-col gap-4 overflow-y-auto pt-4 pb-2"
            >
              <Field>
                <FieldLabel htmlFor="template-sample">
                  样例变量（JSON）
                </FieldLabel>
                <Textarea
                  id="template-sample"
                  rows={6}
                  value={sampleJson}
                  onChange={(event) => setSampleJson(event.target.value)}
                  className="font-mono"
                  spellCheck={false}
                />
                <FieldDescription>
                  仅用于本地预览，不保存；未提供的变量按占位符原文展示
                </FieldDescription>
              </Field>

              {!sampleVars.ok ? (
                <p className="text-sm text-destructive">{sampleVars.message}</p>
              ) : null}

              <div className="grid gap-3 lg:grid-cols-3">
                {previewChannels.map((panel) => (
                  <div
                    key={panel.channel}
                    className="flex min-w-0 flex-col gap-2 rounded-lg border bg-card p-3"
                  >
                    <div className="flex items-center gap-2">
                      <span className="text-sm font-medium">
                        {TEMPLATE_CHANNEL_LABELS[panel.channel]}
                      </span>
                      {panel.live ? (
                        <Badge variant="secondary" className="text-[11px]">
                          编辑中
                        </Badge>
                      ) : null}
                    </div>
                    {!panel.configured ? (
                      <p className="text-xs text-muted-foreground">
                        该渠道尚未配置模板
                      </p>
                    ) : !sampleVars.ok ? (
                      <p className="text-xs text-muted-foreground">
                        修正样例变量后展示渲染结果
                      </p>
                    ) : (
                      <>
                        <div className="text-sm font-medium break-words">
                          {renderTemplate(panel.subject, sampleVars.vars)}
                        </div>
                        <div className="text-xs whitespace-pre-wrap text-muted-foreground">
                          {renderTemplate(panel.body, sampleVars.vars)}
                        </div>
                      </>
                    )}
                  </div>
                ))}
              </div>
            </TabsContent>

            {/* 历史版本：版本列表 + 回滚 */}
            <TabsContent
              value="history"
              className="flex min-h-0 flex-col gap-2 overflow-y-auto pt-4 pb-2"
            >
              {historyVersions.length === 0 ? (
                <p className="py-8 text-center text-sm text-muted-foreground">
                  该事件与渠道暂无任何版本
                </p>
              ) : (
                historyVersions.map((row) => {
                  const status = asTemplateStatus(row.status);
                  const isCurrent = row.id === currentId;
                  return (
                    <div
                      key={row.id}
                      className="flex flex-wrap items-center gap-x-3 gap-y-2 rounded-lg border p-3"
                    >
                      <span className="font-mono text-sm">v{row.version}</span>
                      <Badge
                        variant="outline"
                        className={TEMPLATE_STATUS_BADGE_CLASSES[status]}
                      >
                        {TEMPLATE_STATUS_LABELS[status]}
                      </Badge>
                      {isCurrent ? (
                        <Badge variant="secondary" className="text-[11px]">
                          当前生效
                        </Badge>
                      ) : null}
                      <span className="text-xs text-muted-foreground">
                        {formatDateTime(row.updated_at)}
                      </span>
                      <div className="ml-auto">
                        {isCurrent ? null : (
                          <Button
                            size="sm"
                            variant="outline"
                            className="h-9 lg:h-8"
                            disabled={rollingBackId !== null}
                            onClick={() => void handleRollback(row)}
                          >
                            {rollingBackId === row.id ? (
                              <Loader2Icon
                                className="animate-spin"
                                data-icon="inline-start"
                              />
                            ) : (
                              <RotateCcwIcon data-icon="inline-start" />
                            )}
                            回滚到 v{row.version}
                          </Button>
                        )}
                      </div>
                    </div>
                  );
                })
              )}
            </TabsContent>
          </Tabs>

          <SheetFooter className="flex-row items-center justify-end gap-2 border-t">
            <span className="mr-auto text-xs text-muted-foreground">
              {editingVersion
                ? `正在编辑草稿 v${editingVersion.version}`
                : currentFor(formEventKey, formChannel)
                  ? `当前 v${currentFor(formEventKey, formChannel)?.version}（保存将新建草稿）`
                  : "尚未配置"}
            </span>
            <Button
              variant="outline"
              className="h-8"
              onClick={() => void handleSaveDraft()}
              disabled={saving || publishing}
            >
              {saving ? (
                <Loader2Icon
                  className="size-3.5 animate-spin"
                  data-icon="inline-start"
                />
              ) : (
                <SaveIcon className="size-3.5" data-icon="inline-start" />
              )}
              保存草稿
            </Button>
            <Button
              className="h-8"
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
        </SheetContent>
      </Sheet>
    </div>
  );
}
