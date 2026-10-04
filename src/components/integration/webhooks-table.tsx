"use client";

import * as React from "react";
import {
  CopyIcon,
  Loader2Icon,
  PlusIcon,
  SearchIcon,
  SendIcon,
  ShieldAlertIcon,
  TrashIcon,
  WebhookIcon,
} from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
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
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { useIsMobile } from "@/hooks/use-mobile";
import type { Database } from "@/lib/database.types";
import {
  DELIVERY_STATUS_BADGE_CLASSES,
  asDeliveryStatus,
  asWebhookStatus,
  translateIntegrationErrorMessage,
  WEBHOOK_BACKOFF_LABELS,
  WEBHOOK_BACKOFF_OPTIONS,
  WEBHOOK_EVENT_GROUPS,
  WEBHOOK_EVENT_LABELS,
  WEBHOOK_MAX_ATTEMPTS_OPTIONS,
  WEBHOOK_STATUS_BADGE_CLASSES,
  WEBHOOK_STATUS_LABELS,
  WEBHOOK_STATUS_OPTIONS,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type WebhookRow =
  Database["public"]["Functions"]["get_webhooks"]["Returns"][number];
type UpdateWebhookArgs =
  Database["public"]["Functions"]["update_webhook"]["Args"];
type DeliveryRow = Pick<
  Database["public"]["Tables"]["webhook_deliveries"]["Row"],
  "webhook_id" | "http_status" | "status" | "attempted_at"
>;
type ProfileRow = Pick<
  Database["public"]["Tables"]["profiles"]["Row"],
  "id" | "full_name" | "email"
>;

type SecretResult = {
  id: string;
  name: string;
  url: string;
  events: string[];
  retry_policy: { max_attempts?: number; backoff?: string };
  status: string;
  secret: string;
  headers_masked: Record<string, string> | null;
};

type HeaderRow = { key: string; value: string };

type WebhookForm = {
  name: string;
  url: string;
  events: string[];
  maxAttempts: string;
  backoff: string;
  headerRows: HeaderRow[];
};

type TestState =
  | { phase: "idle" }
  | { phase: "testing" }
  | { phase: "ok"; httpStatus: number | null; elapsedMs: number }
  | { phase: "failed"; httpStatus: number | null; elapsedMs: number; reason: string }
  | { phase: "pending"; elapsedMs: number };

const PAGE_SIZE = 20;
const ALL = "all";
const TEST_TIMEOUT_MS = 15_000;
const TEST_POLL_MS = 2_000;

const EMPTY_FORM: WebhookForm = {
  name: "",
  url: "",
  events: [],
  maxAttempts: "3",
  backoff: "exponential",
  headerRows: [],
};

const formatDateTime = (value: string | null) =>
  value
    ? new Date(value).toLocaleString("zh-CN", { hour12: false })
    : "—";

/** URL 掩码：保留头部与尾部，中间省略（列表展示用） */
const maskUrl = (url: string) =>
  url.length <= 44 ? url : `${url.slice(0, 30)}…${url.slice(-10)}`;

const asEvents = (value: unknown): string[] =>
  Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];

const asHeadersMasked = (value: unknown): Record<string, string> | null => {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  const entries = Object.entries(value as Record<string, unknown>).filter(
    (entry): entry is [string, string] => typeof entry[1] === "string",
  );
  return entries.length > 0 ? Object.fromEntries(entries) : null;
};

const asRetryPolicy = (
  value: unknown,
): { max_attempts?: number; backoff?: string } =>
  value && typeof value === "object" && !Array.isArray(value)
    ? (value as { max_attempts?: number; backoff?: string })
    : {};

const sleep = (ms: number) =>
  new Promise<void>((resolve) => setTimeout(resolve, ms));

export function WebhooksTable() {
  const isMobile = useIsMobile();
  const [rows, setRows] = React.useState<WebhookRow[]>([]);
  const [latestDeliveries, setLatestDeliveries] = React.useState<
    Map<string, DeliveryRow>
  >(new Map());
  const [creatorNames, setCreatorNames] = React.useState<Map<string, string>>(
    new Map(),
  );
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [search, setSearch] = React.useState("");
  const [statusFilter, setStatusFilter] = React.useState(ALL);
  const [page, setPage] = React.useState(1);

  const [sheetOpen, setSheetOpen] = React.useState(false);
  const [editing, setEditing] = React.useState<WebhookRow | null>(null);
  const [form, setForm] = React.useState<WebhookForm>(EMPTY_FORM);
  const [secretResult, setSecretResult] = React.useState<SecretResult | null>(
    null,
  );
  const [saving, setSaving] = React.useState(false);
  const [testState, setTestState] = React.useState<TestState>({
    phase: "idle",
  });
  const testRunRef = React.useRef(0);

  const load = React.useCallback(async (): Promise<WebhookRow[]> => {
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const [hooksRes, deliveriesRes, profilesRes] = await Promise.all([
      supabase.rpc("get_webhooks"),
      supabase
        .from("webhook_deliveries")
        .select("webhook_id, http_status, status, attempted_at")
        .order("attempted_at", { ascending: false })
        .limit(1000),
      supabase.from("profiles").select("id, full_name, email"),
    ]);

    if (hooksRes.error) {
      setError(hooksRes.error.message);
      setRows([]);
      setLoading(false);
      return [];
    }

    const items = (hooksRes.data ?? []) as WebhookRow[];
    setRows(items);

    // 前端聚合：投递按 attempted_at 倒序，每个端点第一条即最近一次
    if (!deliveriesRes.error) {
      const map = new Map<string, DeliveryRow>();
      for (const delivery of (deliveriesRes.data ?? []) as DeliveryRow[]) {
        if (!map.has(delivery.webhook_id)) {
          map.set(delivery.webhook_id, delivery);
        }
      }
      setLatestDeliveries(map);
    }

    if (!profilesRes.error) {
      const map = new Map<string, string>();
      for (const profile of (profilesRes.data ?? []) as ProfileRow[]) {
        map.set(
          profile.id,
          profile.full_name ?? profile.email?.split("@")[0] ?? "未知用户",
        );
      }
      setCreatorNames(map);
    }

    setLoading(false);
    return items;
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const filtered = React.useMemo(() => {
    const keyword = search.trim().toLowerCase();
    return rows.filter((row) => {
      if (statusFilter !== ALL && row.status !== statusFilter) {
        return false;
      }
      if (keyword) {
        const haystack = `${row.name} ${row.url}`.toLowerCase();
        if (!haystack.includes(keyword)) {
          return false;
        }
      }
      return true;
    });
  }, [rows, search, statusFilter]);

  React.useEffect(() => {
    setPage(1);
  }, [search, statusFilter]);

  const pageCount = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const currentPage = Math.min(page, pageCount);
  const pagedRows = filtered.slice(
    (currentPage - 1) * PAGE_SIZE,
    currentPage * PAGE_SIZE,
  );

  const openCreate = () => {
    testRunRef.current += 1;
    setEditing(null);
    setForm(EMPTY_FORM);
    setSecretResult(null);
    setTestState({ phase: "idle" });
    setSheetOpen(true);
  };

  const openEdit = (row: WebhookRow) => {
    testRunRef.current += 1;
    const retry = asRetryPolicy(row.retry_policy);
    setEditing(row);
    setForm({
      name: row.name,
      url: row.url,
      events: asEvents(row.events),
      maxAttempts: String(retry.max_attempts ?? 3),
      backoff: retry.backoff === "linear" ? "linear" : "exponential",
      headerRows: [],
    });
    setSecretResult(null);
    setTestState({ phase: "idle" });
    setSheetOpen(true);
  };

  const closeSheet = () => {
    testRunRef.current += 1;
    setSheetOpen(false);
    setEditing(null);
    setForm(EMPTY_FORM);
    setSecretResult(null);
    setTestState({ phase: "idle" });
  };

  const toggleEvent = (event: string, checked: boolean) => {
    setForm((prev) => ({
      ...prev,
      events: checked
        ? [...new Set([...prev.events, event])]
        : prev.events.filter((value) => value !== event),
    }));
  };

  const updateHeaderRow = (
    index: number,
    patch: Partial<HeaderRow>,
  ) => {
    setForm((prev) => ({
      ...prev,
      headerRows: prev.headerRows.map((row, rowIndex) =>
        rowIndex === index ? { ...row, ...patch } : row,
      ),
    }));
  };

  const addHeaderRow = () => {
    setForm((prev) => ({
      ...prev,
      headerRows: [...prev.headerRows, { key: "", value: "" }],
    }));
  };

  const removeHeaderRow = (index: number) => {
    setForm((prev) => ({
      ...prev,
      headerRows: prev.headerRows.filter((_, rowIndex) => rowIndex !== index),
    }));
  };

  const copyText = async (text: string, label: string) => {
    try {
      await navigator.clipboard.writeText(text);
      toast.success(`${label}已复制`);
    } catch {
      toast.error("复制失败，请手动选择并复制");
    }
  };

  const collectHeaders = (): {
    ok: boolean;
    headers: Record<string, string> | null;
  } => {
    const headers: Record<string, string> = {};
    for (const row of form.headerRows) {
      const key = row.key.trim();
      if (!key && !row.value) {
        continue;
      }
      if (!key) {
        toast.error("自定义 header 的键不能为空");
        return { ok: false, headers: null };
      }
      headers[key] = row.value;
    }
    return {
      ok: true,
      headers: Object.keys(headers).length > 0 ? headers : null,
    };
  };

  const validate = (): boolean => {
    if (!form.name.trim()) {
      toast.error("请输入 Webhook 名称");
      return false;
    }
    const url = form.url.trim();
    if (!/^https:\/\/[^\s]+$/.test(url)) {
      toast.error("URL 必须以 https:// 开头且不含空白字符");
      return false;
    }
    if (form.events.length === 0) {
      toast.error("请至少订阅一个事件");
      return false;
    }
    return true;
  };

  const handleSave = async () => {
    if (!validate()) {
      return;
    }
    const headers = collectHeaders();
    if (!headers.ok) {
      return;
    }
    const headerPayload = headers.headers;

    const retryPolicy = {
      max_attempts: Number(form.maxAttempts),
      backoff: form.backoff,
    };
    setSaving(true);
    const supabase = createClient();

    if (editing) {
      const args = {
        p_id: editing.id,
        p_name: form.name.trim(),
        p_url: form.url.trim(),
        p_events: form.events,
        p_retry_policy: retryPolicy,
        p_headers: headerPayload,
      } as unknown as UpdateWebhookArgs;
      const { error: saveError } = await supabase.rpc("update_webhook", args);
      setSaving(false);

      if (saveError) {
        toast.error(translateIntegrationErrorMessage(saveError.message));
        return;
      }

      toast.success("已保存");
      setForm((prev) => ({ ...prev, headerRows: [] }));
      const items = await load();
      setEditing(items.find((item) => item.id === editing.id) ?? null);
      return;
    }

    const { data, error: createError } = await supabase.rpc("create_webhook", {
      p_name: form.name.trim(),
      p_url: form.url.trim(),
      p_events: form.events,
      p_retry_policy: retryPolicy,
      p_headers: headerPayload,
    });
    setSaving(false);

    if (createError) {
      toast.error(translateIntegrationErrorMessage(createError.message));
      return;
    }

    const result = (data ?? null) as unknown as SecretResult | null;
    if (!result?.secret) {
      toast.error("创建失败：服务端未返回 secret，请重试");
      return;
    }

    setSecretResult({
      ...result,
      events: asEvents(result.events),
      headers_masked: asHeadersMasked(result.headers_masked),
    });
    toast.success("已创建，请立即保存 secret");
    await load();
  };

  const handleToggleStatus = async () => {
    if (!editing) {
      return;
    }
    const isActive = editing.status === "active";
    if (isActive) {
      const confirmed = window.confirm(
        `确定停用 Webhook「${editing.name}」？停用后该端点不再收到事件。`,
      );
      if (!confirmed) {
        return;
      }
    }

    setSaving(true);
    const supabase = createClient();
    const { error: toggleError } = isActive
      ? await supabase.rpc("disable_webhook", { p_id: editing.id })
      : await supabase.rpc("enable_webhook", { p_id: editing.id });
    setSaving(false);

    if (toggleError) {
      toast.error(translateIntegrationErrorMessage(toggleError.message));
      return;
    }

    toast.success(isActive ? "已停用" : "已启用");
    const items = await load();
    setEditing(items.find((item) => item.id === editing.id) ?? null);
  };

  const handleTest = async () => {
    if (!editing) {
      return;
    }

    const runId = testRunRef.current + 1;
    testRunRef.current = runId;
    setTestState({ phase: "testing" });

    const supabase = createClient();
    const { data, error: testError } = await supabase.rpc("test_webhook", {
      p_webhook_id: editing.id,
    });

    if (testError) {
      toast.error(translateIntegrationErrorMessage(testError.message));
      setTestState({ phase: "idle" });
      return;
    }

    const requestId = Number(
      (data as { request_id?: number } | null)?.request_id ?? NaN,
    );
    if (!Number.isFinite(requestId)) {
      toast.error("测试投递失败：未取得 request_id");
      setTestState({ phase: "idle" });
      return;
    }

    const startedAt = Date.now();
    for (;;) {
      const remaining = TEST_TIMEOUT_MS - (Date.now() - startedAt);
      if (remaining <= 0) {
        break;
      }
      await sleep(Math.min(TEST_POLL_MS, remaining));
      if (testRunRef.current !== runId) {
        return;
      }

      const { data: result, error: resultError } = await supabase.rpc(
        "webhook_test_result",
        { p_request_id: requestId },
      );
      if (resultError) {
        toast.error(translateIntegrationErrorMessage(resultError.message));
        setTestState({ phase: "idle" });
        return;
      }

      const response = (result ?? null) as {
        responded?: boolean;
        ok?: boolean;
        http_status?: number | null;
        timed_out?: boolean;
        error?: string | null;
      } | null;

      if (response?.responded) {
        const elapsedMs = Date.now() - startedAt;
        if (response.ok) {
          setTestState({
            phase: "ok",
            httpStatus: response.http_status ?? null,
            elapsedMs,
          });
        } else {
          setTestState({
            phase: "failed",
            httpStatus: response.http_status ?? null,
            elapsedMs,
            reason: response.timed_out
              ? "请求超时（pg_net）"
              : (response.error ??
                (response.http_status
                  ? `HTTP ${response.http_status}`
                  : "投递失败")),
          });
        }
        return;
      }

      if (Date.now() - startedAt >= TEST_TIMEOUT_MS) {
        break;
      }
    }

    if (testRunRef.current === runId) {
      setTestState({ phase: "pending", elapsedMs: Date.now() - startedAt });
    }
  };

  const creatorName = (id: string | null) =>
    id ? (creatorNames.get(id) ?? "已离职用户") : "—";

  const eventCountBadge = (events: string[]) => (
    <span className="inline-flex items-center gap-1">
      <Badge variant="outline" className="border-violet-200 bg-violet-50 text-violet-700 dark:border-violet-900/60 dark:bg-violet-950/60 dark:text-violet-300">
        {events.length} 个事件
      </Badge>
    </span>
  );

  const deliveryBadge = (webhookId: string) => {
    const delivery = latestDeliveries.get(webhookId);
    if (!delivery) {
      return <span className="text-xs text-muted-foreground">—</span>;
    }
    const status = asDeliveryStatus(delivery.status);
    const label =
      status === "done"
        ? "已送达"
        : status === "delivering"
          ? "投递中"
          : delivery.http_status
            ? `HTTP ${delivery.http_status}`
            : "失败";
    return (
      <span className="inline-flex flex-col items-center gap-0.5">
        <Badge
          variant="outline"
          className={DELIVERY_STATUS_BADGE_CLASSES[status]}
        >
          {label}
        </Badge>
        <span className="text-[10px] text-muted-foreground">
          {formatDateTime(delivery.attempted_at)}
        </span>
      </span>
    );
  };

  const existingHeaders = editing ? asHeadersMasked(editing.headers_masked) : null;

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
            <div className="relative flex-1 sm:max-w-xs">
              <SearchIcon className="absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder="搜索名称 / URL"
                className="h-11 pl-8 text-base lg:h-8 lg:text-sm"
                aria-label="搜索 Webhook 名称或 URL"
              />
            </div>
            <Select value={statusFilter} onValueChange={setStatusFilter}>
              <SelectTrigger
                className="h-11 w-full sm:w-32 lg:h-8"
                aria-label="按状态筛选"
              >
                <SelectValue placeholder="全部状态" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL}>全部状态</SelectItem>
                {WEBHOOK_STATUS_OPTIONS.map((option) => (
                  <SelectItem key={option.value} value={option.value}>
                    {option.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <div className="flex items-center gap-2 sm:ml-auto">
              <Button
                onClick={openCreate}
                className="h-11 flex-1 sm:flex-none lg:h-8"
              >
                <WebhookIcon data-icon="inline-start" />
                新增 Webhook
              </Button>
            </div>
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
                加载失败：{translateIntegrationErrorMessage(error)}
              </p>
              <Button variant="outline" onClick={() => void load()}>
                重试
              </Button>
            </div>
          ) : filtered.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <WebhookIcon className="size-8 opacity-60" />
              <span>
                {rows.length === 0
                  ? "暂无 Webhook，点击「新增 Webhook」创建"
                  : "没有匹配的 Webhook，试试调整搜索或筛选"}
              </span>
            </div>
          ) : isMobile ? (
            <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:px-0">
              {pagedRows.map((row) => {
                const status = asWebhookStatus(row.status);
                const events = asEvents(row.events);
                return (
                  <button
                    key={row.id}
                    type="button"
                    data-slot="webhook-card"
                    onClick={() => openEdit(row)}
                    className="flex w-full flex-col gap-2.5 rounded-xl border bg-card p-4 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                  >
                    <div className="flex items-start justify-between gap-3">
                      <div className="min-w-0">
                        <div className="truncate font-medium">{row.name}</div>
                        <div
                          className="truncate font-mono text-xs text-muted-foreground"
                          title={row.url}
                        >
                          {maskUrl(row.url)}
                        </div>
                      </div>
                      <Badge
                        variant="outline"
                        className={WEBHOOK_STATUS_BADGE_CLASSES[status]}
                      >
                        {WEBHOOK_STATUS_LABELS[status]}
                      </Badge>
                    </div>
                    <div className="flex flex-wrap items-center gap-1">
                      {eventCountBadge(events)}
                      {events.slice(0, 2).map((event) => (
                        <Badge key={event} variant="outline">
                          {WEBHOOK_EVENT_LABELS[event] ?? event}
                        </Badge>
                      ))}
                      {events.length > 2 ? (
                        <span className="text-xs text-muted-foreground">
                          +{events.length - 2}
                        </span>
                      ) : null}
                    </div>
                    <div className="flex items-center justify-between gap-4 text-sm">
                      <span className="text-muted-foreground">最近投递</span>
                      {deliveryBadge(row.id)}
                    </div>
                    <div className="flex items-center justify-between gap-4 text-sm">
                      <span className="text-muted-foreground">创建人</span>
                      <span>{creatorName(row.created_by)}</span>
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
                    <TableHead className="text-center">名称</TableHead>
                    <TableHead className="text-center">目标 URL</TableHead>
                    <TableHead className="text-center">订阅事件</TableHead>
                    <TableHead className="text-center">状态</TableHead>
                    <TableHead className="text-center">最近投递</TableHead>
                    <TableHead className="text-center">创建人</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {pagedRows.map((row) => {
                    const status = asWebhookStatus(row.status);
                    const events = asEvents(row.events);
                    return (
                      <TableRow
                        key={row.id}
                        className="cursor-pointer"
                        onClick={() => openEdit(row)}
                      >
                        <TableCell className="text-center font-medium">
                          {row.name}
                        </TableCell>
                        <TableCell
                          className="max-w-[280px] truncate text-center font-mono text-xs text-muted-foreground"
                          title={row.url}
                        >
                          {maskUrl(row.url)}
                        </TableCell>
                        <TableCell className="text-center">
                          {eventCountBadge(events)}
                        </TableCell>
                        <TableCell className="text-center">
                          <Badge
                            variant="outline"
                            className={WEBHOOK_STATUS_BADGE_CLASSES[status]}
                          >
                            {WEBHOOK_STATUS_LABELS[status]}
                          </Badge>
                        </TableCell>
                        <TableCell className="text-center">
                          {deliveryBadge(row.id)}
                        </TableCell>
                        <TableCell className="text-center text-xs text-muted-foreground">
                          {creatorName(row.created_by)}
                        </TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </div>
          )}

          {!loading && !error && filtered.length > 0 ? (
            <div className="flex items-center justify-between gap-2 text-sm text-muted-foreground">
              <span>
                {filtered.length === rows.length
                  ? `共 ${filtered.length} 条 · 第 ${currentPage} / ${pageCount} 页`
                  : `匹配 ${filtered.length} 条（共 ${rows.length} 条）· 第 ${currentPage} / ${pageCount} 页`}
              </span>
              <div className="flex items-center gap-2">
                <Button
                  variant="outline"
                  disabled={currentPage <= 1}
                  onClick={() => setPage(currentPage - 1)}
                  className="h-11 px-4 lg:h-8 lg:px-3"
                >
                  上一页
                </Button>
                <Button
                  variant="outline"
                  disabled={currentPage >= pageCount}
                  onClick={() => setPage(currentPage + 1)}
                  className="h-11 px-4 lg:h-8 lg:px-3"
                >
                  下一页
                </Button>
              </div>
            </div>
          ) : null}
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
          className="w-full sm:max-w-[480px]"
        >
          <SheetHeader>
            <SheetTitle>
              {secretResult
                ? "Webhook 已创建"
                : editing
                  ? "编辑 Webhook"
                  : "新增 Webhook"}
            </SheetTitle>
            <SheetDescription>
              {secretResult
                ? "secret 仅此一次展示，关闭后不可再查看"
                : editing
                  ? "修改订阅配置；自定义 header 留空表示保持原值"
                  : "填写目标地址、订阅事件与重试策略；创建后一次性展示 secret"}
            </SheetDescription>
          </SheetHeader>

          <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-4">
            {secretResult ? (
              <div className="flex flex-col gap-4">
                <div className="flex items-start gap-2 rounded-xl border border-amber-300/60 bg-amber-50 p-3 text-sm text-amber-800 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-200">
                  <ShieldAlertIcon className="mt-0.5 size-4 shrink-0" />
                  <p>
                    secret 用于接收端验签（HMAC-SHA256），仅此一次展示，关闭后不可再查看。请立即复制并安全交付。
                  </p>
                </div>

                <div className="flex flex-col gap-2 rounded-xl border p-4">
                  <div className="text-sm text-muted-foreground">
                    {secretResult.name}
                  </div>
                  <div className="font-mono text-lg break-all">
                    {secretResult.secret}
                  </div>
                  <Button
                    variant="outline"
                    onClick={() => void copyText(secretResult.secret, "secret")}
                    className="h-11 lg:h-8"
                  >
                    <CopyIcon data-icon="inline-start" />
                    复制 secret
                  </Button>
                </div>

                <div className="flex flex-col gap-3 rounded-xl border p-4 text-sm">
                  <div className="flex items-center justify-between gap-4">
                    <span className="text-muted-foreground">目标 URL</span>
                    <span className="truncate font-mono text-xs">
                      {secretResult.url}
                    </span>
                  </div>
                  <div className="flex items-center justify-between gap-4">
                    <span className="text-muted-foreground">订阅事件</span>
                    <span className="flex flex-wrap justify-end gap-1">
                      {secretResult.events.map((event) => (
                        <Badge key={event} variant="outline">
                          {WEBHOOK_EVENT_LABELS[event] ?? event}
                        </Badge>
                      ))}
                    </span>
                  </div>
                  {secretResult.headers_masked ? (
                    <div className="flex items-start justify-between gap-4">
                      <span className="text-muted-foreground">
                        自定义 header
                      </span>
                      <span className="flex flex-col items-end gap-1 font-mono text-xs">
                        {Object.entries(secretResult.headers_masked).map(
                          ([key, value]) => (
                            <span key={key}>
                              {key}: {value}
                            </span>
                          ),
                        )}
                      </span>
                    </div>
                  ) : null}
                </div>

                <div className="rounded-xl border bg-muted/40 p-3 text-xs text-muted-foreground">
                  验签说明：投递请求头 <code>x-webhook-signature</code> ={" "}
                  hex(HMAC-SHA256(secret, 原始请求体))，
                  <code>x-webhook-event</code> 为事件名；接收端用同一 secret
                  对原始字节做同样计算并做防时序攻击比较。
                </div>
              </div>
            ) : (
              <>
                <Field>
                  <FieldLabel htmlFor="webhook-name">名称</FieldLabel>
                  <Input
                    id="webhook-name"
                    value={form.name}
                    onChange={(event) =>
                      setForm((prev) => ({ ...prev, name: event.target.value }))
                    }
                    placeholder="如：ERP 审批回调"
                    autoComplete="off"
                  />
                </Field>

                <Field>
                  <FieldLabel htmlFor="webhook-url">目标 URL</FieldLabel>
                  <Input
                    id="webhook-url"
                    value={form.url}
                    onChange={(event) =>
                      setForm((prev) => ({ ...prev, url: event.target.value }))
                    }
                    placeholder="https://hooks.example.com/callback"
                    autoComplete="off"
                  />
                  <FieldDescription>
                    仅支持 https；投递内容为 JSON 事件信封。
                  </FieldDescription>
                </Field>

                <Field>
                  <FieldLabel>订阅事件</FieldLabel>
                  <div className="flex flex-col gap-3">
                    {WEBHOOK_EVENT_GROUPS.map((group) => (
                      <div
                        key={group.module}
                        className="flex flex-col gap-2 rounded-lg border p-3"
                      >
                        <div className="text-sm font-medium">{group.label}</div>
                        {group.events.map((event) => (
                          <label
                            key={event.value}
                            htmlFor={`webhook-event-${event.value}`}
                            className="flex cursor-pointer items-center gap-3"
                          >
                            <Checkbox
                              id={`webhook-event-${event.value}`}
                              checked={form.events.includes(event.value)}
                              onCheckedChange={(checked) =>
                                toggleEvent(event.value, checked === true)
                              }
                            />
                            <span className="flex flex-col">
                              <span className="text-sm">{event.label}</span>
                              <span className="font-mono text-xs text-muted-foreground">
                                {event.value}
                              </span>
                            </span>
                          </label>
                        ))}
                      </div>
                    ))}
                  </div>
                  <FieldDescription>
                    事件清单按模块分组（v1 固定清单）；未订阅的事件不会投递。
                  </FieldDescription>
                </Field>

                <div className="grid grid-cols-2 gap-4">
                  <Field>
                    <FieldLabel htmlFor="webhook-max-attempts">
                      最大尝试次数
                    </FieldLabel>
                    <Select
                      value={form.maxAttempts}
                      onValueChange={(value) =>
                        setForm((prev) => ({ ...prev, maxAttempts: value }))
                      }
                    >
                      <SelectTrigger
                        id="webhook-max-attempts"
                        className="w-full"
                      >
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        {WEBHOOK_MAX_ATTEMPTS_OPTIONS.map((option) => (
                          <SelectItem key={option.value} value={option.value}>
                            {option.label}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </Field>
                  <Field>
                    <FieldLabel htmlFor="webhook-backoff">退避方式</FieldLabel>
                    <Select
                      value={form.backoff}
                      onValueChange={(value) =>
                        setForm((prev) => ({ ...prev, backoff: value }))
                      }
                    >
                      <SelectTrigger id="webhook-backoff" className="w-full">
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        {WEBHOOK_BACKOFF_OPTIONS.map((option) => (
                          <SelectItem key={option.value} value={option.value}>
                            {option.label}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </Field>
                </div>
                <p className="-mt-2 text-xs text-muted-foreground">
                  当前策略：
                  {WEBHOOK_BACKOFF_LABELS[form.backoff] ??
                    WEBHOOK_BACKOFF_LABELS.exponential}
                  ，最多 {form.maxAttempts} 次尝试；失败终态会通知创建人。
                </p>

                <Field>
                  <FieldLabel>自定义请求头（可选）</FieldLabel>
                  {existingHeaders && form.headerRows.length === 0 ? (
                    <div className="flex flex-col gap-1 rounded-lg border bg-muted/40 p-3">
                      <div className="text-xs text-muted-foreground">
                        已配置（脱敏展示）：
                      </div>
                      {Object.entries(existingHeaders).map(([key, value]) => (
                        <div
                          key={key}
                          className="flex items-center justify-between gap-2 font-mono text-xs"
                        >
                          <span className="truncate">{key}</span>
                          <span className="text-muted-foreground">{value}</span>
                        </div>
                      ))}
                    </div>
                  ) : null}
                  <div className="flex flex-col gap-2">
                    {form.headerRows.map((row, index) => (
                      <div key={index} className="flex items-center gap-2">
                        <Input
                          value={row.key}
                          onChange={(event) =>
                            updateHeaderRow(index, { key: event.target.value })
                          }
                          placeholder="Header 名"
                          className="flex-1 font-mono text-xs"
                          autoComplete="off"
                          aria-label={`第 ${index + 1} 个请求头的名称`}
                        />
                        <Input
                          type="password"
                          value={row.value}
                          onChange={(event) =>
                            updateHeaderRow(index, {
                              value: event.target.value,
                            })
                          }
                          placeholder="值（掩码输入）"
                          className="flex-1 font-mono text-xs"
                          autoComplete="new-password"
                          aria-label={`第 ${index + 1} 个请求头的值`}
                        />
                        <Button
                          variant="ghost"
                          size="icon"
                          onClick={() => removeHeaderRow(index)}
                          aria-label={`删除第 ${index + 1} 个请求头`}
                          className="h-11 w-11 shrink-0 lg:h-8 lg:w-8"
                        >
                          <TrashIcon />
                        </Button>
                      </div>
                    ))}
                    <Button
                      variant="outline"
                      onClick={addHeaderRow}
                      className="h-11 lg:h-8"
                    >
                      <PlusIcon data-icon="inline-start" />
                      添加请求头
                    </Button>
                  </div>
                  <FieldDescription>
                    输入任意键值对将整体替换现有配置（值加密落库、界面仅掩码）；全部留空则保持不变。值可从环境变量注入，如 Authorization: Bearer xxx。
                  </FieldDescription>
                </Field>

                <div className="rounded-xl border bg-muted/40 p-3 text-xs text-muted-foreground">
                  签名说明：每端点独立 secret，投递带{" "}
                  <code>x-webhook-signature</code>（HMAC-SHA256）与{" "}
                  <code>x-webhook-event</code> 头；创建后可在结果页复制
                  secret。
                </div>

                {editing ? (
                  <div className="flex flex-col gap-3 rounded-xl border p-4">
                    <div className="flex items-center justify-between gap-2">
                      <span className="text-sm font-medium">测试投递</span>
                      <Badge
                        variant="outline"
                        className={
                          WEBHOOK_STATUS_BADGE_CLASSES[
                            asWebhookStatus(editing.status)
                          ]
                        }
                      >
                        {WEBHOOK_STATUS_LABELS[asWebhookStatus(editing.status)]}
                      </Badge>
                    </div>
                    <p className="text-xs text-muted-foreground">
                      向目标地址发送 ping 事件（携带同样签名头），验证连通性；每
                      2 秒轮询结果，最多等待 15 秒。
                    </p>
                    <div className="flex flex-col gap-2 sm:flex-row">
                      <Button
                        variant="outline"
                        onClick={() => void handleTest()}
                        disabled={testState.phase === "testing" || saving}
                        className="h-11 lg:h-8"
                      >
                        {testState.phase === "testing" ? (
                          <Loader2Icon
                            className="animate-spin"
                            data-icon="inline-start"
                          />
                        ) : (
                          <SendIcon data-icon="inline-start" />
                        )}
                        {testState.phase === "testing"
                          ? "测试中…"
                          : "测试投递"}
                      </Button>
                      <Button
                        variant="outline"
                        onClick={() => void handleToggleStatus()}
                        disabled={saving || testState.phase === "testing"}
                        className="h-11 lg:h-8"
                      >
                        {editing.status === "active" ? "停用" : "启用"}
                      </Button>
                    </div>

                    {testState.phase === "ok" ? (
                      <p className="text-sm text-emerald-600 dark:text-emerald-400">
                        投递成功：HTTP {testState.httpStatus ?? "2xx"} · 耗时{" "}
                        {testState.elapsedMs} ms
                      </p>
                    ) : null}
                    {testState.phase === "failed" ? (
                      <p className="text-sm text-destructive">
                        投递失败：{testState.reason}
                        {testState.httpStatus
                          ? `（HTTP ${testState.httpStatus}）`
                          : ""}{" "}
                        · 耗时 {testState.elapsedMs} ms
                      </p>
                    ) : null}
                    {testState.phase === "pending" ? (
                      <p className="text-sm text-amber-600 dark:text-amber-400">
                        15 秒内未收到响应，请检查目标地址连通性；可在投递明细中复查。
                      </p>
                    ) : null}
                  </div>
                ) : null}
              </>
            )}
          </div>

          <SheetFooter>
            {secretResult ? (
              <>
                <Button
                  variant="outline"
                  onClick={() => void copyText(secretResult.secret, "secret")}
                  className="h-11 lg:h-8"
                >
                  <CopyIcon data-icon="inline-start" />
                  复制 secret
                </Button>
                <Button onClick={closeSheet} className="h-11 lg:h-8">
                  完成
                </Button>
              </>
            ) : (
              <>
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
                      className="animate-spin"
                      data-icon="inline-start"
                    />
                  ) : null}
                  {editing ? "保存" : "创建"}
                </Button>
              </>
            )}
          </SheetFooter>
        </SheetContent>
      </Sheet>
    </div>
  );
}
