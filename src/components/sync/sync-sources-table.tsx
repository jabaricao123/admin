"use client";

import * as React from "react";
import {
  DatabaseZapIcon,
  FileSpreadsheetIcon,
  GlobeIcon,
  Loader2Icon,
  PlugZapIcon,
  SaveIcon,
  ShieldCheckIcon,
  ShieldXIcon,
} from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
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
  asServiceVerifyStatus,
  asSyncSourceType,
  asSyncStatus,
  SERVICE_VERIFY_STATUS_BADGE_CLASSES,
  SERVICE_VERIFY_STATUS_LABELS,
  SYNC_SOURCE_TYPE_BADGE_CLASSES,
  SYNC_SOURCE_TYPE_LABELS,
  SYNC_STATUS_BADGE_CLASSES,
  SYNC_STATUS_LABELS,
  translateSyncErrorMessage,
  type SyncSourceType,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type SourceRow =
  Database["public"]["Functions"]["get_sync_sources"]["Returns"][number];
type UpsertSourceArgs =
  Database["public"]["Functions"]["upsert_sync_source"]["Args"];

type SourceForm = {
  name: string;
  type: SyncSourceType;
  apiBaseUrl: string;
  apiAuthType: string;
  apiToken: string;
  apiTimeout: string;
  dbEngine: string;
  dbHost: string;
  dbPort: string;
  dbDatabase: string;
  dbUsername: string;
  dbPassword: string;
  excelTemplatePath: string;
};

type TestResult = {
  ok?: boolean;
  message?: string;
  verify_status?: string;
  last_verified_at?: string | null;
};

const API_AUTH_TYPES = [
  { value: "bearer", label: "Bearer Token" },
  { value: "header", label: "自定义 Header" },
  { value: "basic", label: "Basic 认证" },
  { value: "none", label: "无需鉴权" },
];

const DB_ENGINES = [
  { value: "postgres", label: "PostgreSQL" },
  { value: "mysql", label: "MySQL" },
];

const EMPTY_FORM: SourceForm = {
  name: "",
  type: "api",
  apiBaseUrl: "",
  apiAuthType: "bearer",
  apiToken: "",
  apiTimeout: "30",
  dbEngine: "postgres",
  dbHost: "",
  dbPort: "5432",
  dbDatabase: "",
  dbUsername: "",
  dbPassword: "",
  excelTemplatePath: "",
};

const formatDateTime = (value: string | null) =>
  value ? new Date(value).toLocaleString("zh-CN", { hour12: false }) : "—";

const asText = (value: unknown): string => {
  if (value === null || value === undefined) {
    return "";
  }
  return typeof value === "string" ? value : String(value);
};

const asConfig = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};

const summarize = (row: SourceRow): string => {
  const config = asConfig(row.config);
  if (row.type === "api") {
    return asText(config.base_url) || "未配置 base URL";
  }
  if (row.type === "db") {
    const host = asText(config.host);
    if (!host) {
      return "未配置主机";
    }
    const port = asText(config.port);
    const database = asText(config.database);
    return `${host}${port ? `:${port}` : ""}${database ? `/${database}` : ""}`;
  }
  return asText(config.template_path) || "未上传模板";
};

const buildConfig = (form: SourceForm): Record<string, unknown> => {
  if (form.type === "api") {
    const timeout = Number(form.apiTimeout);
    return {
      base_url: form.apiBaseUrl.trim(),
      auth_type: form.apiAuthType,
      ...(Number.isFinite(timeout) && timeout > 0
        ? { timeout_seconds: Math.floor(timeout) }
        : {}),
    };
  }
  if (form.type === "db") {
    return {
      engine: form.dbEngine,
      host: form.dbHost.trim(),
      port: form.dbPort.trim(),
      database: form.dbDatabase.trim(),
      username: form.dbUsername.trim(),
    };
  }
  return { template_path: form.excelTemplatePath };
};

export function SyncSourcesTable() {
  const isMobile = useIsMobile();
  const [rows, setRows] = React.useState<SourceRow[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [sheetOpen, setSheetOpen] = React.useState(false);
  const [editing, setEditing] = React.useState<SourceRow | null>(null);
  const [form, setForm] = React.useState<SourceForm>(EMPTY_FORM);
  const [saving, setSaving] = React.useState(false);
  const [testing, setTesting] = React.useState(false);
  const [uploading, setUploading] = React.useState(false);

  const load = React.useCallback(async (): Promise<SourceRow[]> => {
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const { data, error: loadError } = await supabase.rpc("get_sync_sources");

    if (loadError) {
      setError(loadError.message);
      setRows([]);
      setLoading(false);
      return [];
    }

    const items = data ?? [];
    setRows(items);
    setLoading(false);
    return items;
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const openCreate = () => {
    setEditing(null);
    setForm(EMPTY_FORM);
    setSheetOpen(true);
  };

  const openEdit = (row: SourceRow) => {
    const config = asConfig(row.config);
    setEditing(row);
    setForm({
      name: row.name,
      type: asSyncSourceType(row.type),
      apiBaseUrl: asText(config.base_url),
      apiAuthType: asText(config.auth_type) || "bearer",
      apiToken: "",
      apiTimeout: asText(config.timeout_seconds) || "30",
      dbEngine: asText(config.engine) || "postgres",
      dbHost: asText(config.host),
      dbPort: asText(config.port) || "5432",
      dbDatabase: asText(config.database),
      dbUsername: asText(config.username),
      dbPassword: "",
      excelTemplatePath: asText(config.template_path),
    });
    setSheetOpen(true);
  };

  const closeSheet = () => {
    setSheetOpen(false);
    setEditing(null);
    setForm(EMPTY_FORM);
  };

  const upsert = async (): Promise<SourceRow | null> => {
    const name = form.name.trim();
    if (!name) {
      toast.error("数据源名称不能为空");
      return null;
    }

    if (form.type === "db" && form.dbPort.trim() !== "") {
      const port = Number(form.dbPort);
      if (!Number.isInteger(port) || port < 1 || port > 65535) {
        toast.error("端口需为 1-65535 的整数");
        return null;
      }
    }

    const credentials =
      form.type === "api"
        ? form.apiToken
        : form.type === "db"
          ? form.dbPassword
          : null;

    setSaving(true);
    const supabase = createClient();
    // 生成物未表达 text 参数可为 NULL（NULL/空串=保留凭据），运行时允许传 null
    const args = {
      p_id: editing?.id ?? null,
      p_name: name,
      p_type: form.type,
      p_config: buildConfig(form),
      p_credentials: credentials === "" ? null : credentials,
      p_status: null,
    };
    const { data, error: saveError } = await supabase.rpc(
      "upsert_sync_source",
      args as unknown as UpsertSourceArgs,
    );
    setSaving(false);

    if (saveError) {
      toast.error(translateSyncErrorMessage(saveError.message));
      return null;
    }

    const result = (data ?? null) as { id?: string } | null;
    const items = await load();
    const row = items.find((item) => item.id === result?.id) ?? null;

    if (credentials) {
      setForm((prev) =>
        prev.type === "api"
          ? { ...prev, apiToken: "" }
          : { ...prev, dbPassword: "" },
      );
    }

    toast.success(editing ? "已保存" : "已新增");
    if (row) {
      setEditing(row);
    }
    return row;
  };

  const handleSave = async () => {
    await upsert();
  };

  const handleTest = async () => {
    if (!editing) {
      return;
    }

    setTesting(true);
    const supabase = createClient();
    const { data, error: testError } = await supabase.rpc(
      "test_sync_source",
      { p_id: editing.id },
    );
    setTesting(false);

    if (testError) {
      toast.error(translateSyncErrorMessage(testError.message));
      return;
    }

    const result = (data ?? null) as TestResult | null;
    const items = await load();
    const row = items.find((item) => item.id === editing.id) ?? null;
    if (row) {
      setEditing(row);
    }

    if (result?.ok) {
      toast.success(result.message ?? "验证通过");
    } else {
      toast.error(result?.message ?? "验证未通过");
    }
  };

  const handleDisable = async () => {
    if (!editing) {
      return;
    }

    const confirmed = window.confirm(
      `确定停用数据源「${editing.name}」？停用后将不可用于启用中的同步任务。`,
    );
    if (!confirmed) {
      return;
    }

    setSaving(true);
    const supabase = createClient();
    const { error: disableError } = await supabase.rpc("disable_sync_source", {
      p_id: editing.id,
    });
    setSaving(false);

    if (disableError) {
      toast.error(translateSyncErrorMessage(disableError.message));
      return;
    }

    toast.success("已停用");
    const items = await load();
    const row = items.find((item) => item.id === editing.id) ?? null;
    if (row) {
      setEditing(row);
    }
  };

  const handleEnable = async () => {
    if (!editing) {
      return;
    }
    setSaving(true);
    const supabase = createClient();
    const args = {
      p_id: editing.id,
      p_name: form.name.trim(),
      p_type: form.type,
      p_config: buildConfig(form),
      p_credentials: null,
      p_status: "active",
    };
    const { error: enableError } = await supabase.rpc(
      "upsert_sync_source",
      args as unknown as UpsertSourceArgs,
    );
    setSaving(false);

    if (enableError) {
      toast.error(translateSyncErrorMessage(enableError.message));
      return;
    }

    toast.success("已启用（配置变更后请重新测试验证）");
    const items = await load();
    const row = items.find((item) => item.id === editing.id) ?? null;
    if (row) {
      setEditing(row);
    }
  };

  const handleTemplateUpload = async (
    event: React.ChangeEvent<HTMLInputElement>,
  ) => {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) {
      return;
    }

    setUploading(true);
    try {
      const supabase = createClient();
      const extension = file.name.includes(".")
        ? file.name.slice(file.name.lastIndexOf("."))
        : "";
      // HTTP（非安全上下文）下 crypto.randomUUID 不存在：退回时间戳 + 随机串，文件名唯一性足够
      const unique =
        crypto.randomUUID?.() ??
        `${Date.now()}-${Math.random().toString(36).slice(2)}`;
      const path = `templates/${unique}${extension}`;
      const { error: uploadError } = await supabase.storage
        .from("sync-templates")
        .upload(path, file, { upsert: false });

      if (uploadError) {
        toast.error(`模板上传失败：${uploadError.message}`);
        return;
      }

      setForm((prev) => ({ ...prev, excelTemplatePath: path }));
      toast.success("模板已上传，保存后生效");
    } catch (uploadError) {
      toast.error(
        `模板上传失败：${
          uploadError instanceof Error ? uploadError.message : String(uploadError)
        }`,
      );
    } finally {
      setUploading(false);
    }
  };

  const typeIcon = (type: SyncSourceType) => {
    if (type === "api") {
      return <GlobeIcon className="size-4" />;
    }
    if (type === "db") {
      return <DatabaseZapIcon className="size-4" />;
    }
    return <FileSpreadsheetIcon className="size-4" />;
  };

  return (
    <div className="flex flex-col gap-2 p-0 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex items-center justify-end gap-2">
            <Button
              onClick={openCreate}
              className="h-11 flex-1 lg:h-8 lg:flex-none"
            >
              <PlugZapIcon data-icon="inline-start" />
              新增数据源
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
          ) : rows.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <PlugZapIcon className="size-8 opacity-60" />
              <span>暂无数据源，点击「新增数据源」创建</span>
            </div>
          ) : isMobile ? (
            <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
              {rows.map((row) => {
                const type = asSyncSourceType(row.type);
                const verify = asServiceVerifyStatus(row.verify_status);
                const status = asSyncStatus(row.status);
                return (
                  <button
                    key={row.id}
                    type="button"
                    data-slot="sync-source-card"
                    onClick={() => openEdit(row)}
                    className="flex w-full flex-col gap-2 rounded-xl border bg-card p-3 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                  >
                    <div className="flex items-start justify-between gap-3">
                      <div className="min-w-0">
                        <div className="truncate font-medium">{row.name}</div>
                        <div className="truncate font-mono text-xs leading-tight text-muted-foreground">
                          {summarize(row)}
                        </div>
                      </div>
                      <div className="flex shrink-0 flex-col items-end gap-1">
                        <Badge
                          variant="outline"
                          className={SYNC_SOURCE_TYPE_BADGE_CLASSES[type]}
                        >
                          {SYNC_SOURCE_TYPE_LABELS[type]}
                        </Badge>
                        <Badge
                          variant="outline"
                          className={SERVICE_VERIFY_STATUS_BADGE_CLASSES[verify]}
                        >
                          {SERVICE_VERIFY_STATUS_LABELS[verify]}
                        </Badge>
                      </div>
                    </div>
                    <div className="flex items-center justify-between gap-4 text-sm">
                      <span className="text-muted-foreground">状态</span>
                      <Badge
                        variant="outline"
                        className={SYNC_STATUS_BADGE_CLASSES[status]}
                      >
                        {SYNC_STATUS_LABELS[status]}
                      </Badge>
                    </div>
                    <div className="flex items-center justify-between gap-4 text-sm">
                      <span className="text-muted-foreground">最近验证</span>
                      <span>{formatDateTime(row.last_verified_at)}</span>
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
                    <TableHead className="text-center">类型</TableHead>
                    <TableHead className="text-center">连接摘要</TableHead>
                    <TableHead className="text-center">验证状态</TableHead>
                    <TableHead className="text-center">状态</TableHead>
                    <TableHead className="text-center">最近验证</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {rows.map((row) => {
                    const type = asSyncSourceType(row.type);
                    const verify = asServiceVerifyStatus(row.verify_status);
                    const status = asSyncStatus(row.status);
                    return (
                      <TableRow
                        key={row.id}
                        className="cursor-pointer"
                        role="button"
                        tabIndex={0}
                        aria-label={`编辑数据源 ${row.name}`}
                        onClick={() => openEdit(row)}
                        onKeyDown={(event) => {
                          if (event.key === "Enter" || event.key === " ") {
                            event.preventDefault();
                            openEdit(row);
                          }
                        }}
                      >
                        <TableCell className="text-center font-medium">
                          <span className="inline-flex items-center gap-2">
                            {typeIcon(type)}
                            {row.name}
                          </span>
                        </TableCell>
                        <TableCell className="text-center">
                          <Badge
                            variant="outline"
                            className={SYNC_SOURCE_TYPE_BADGE_CLASSES[type]}
                          >
                            {SYNC_SOURCE_TYPE_LABELS[type]}
                          </Badge>
                        </TableCell>
                        <TableCell className="max-w-[280px] truncate text-center font-mono text-xs text-muted-foreground">
                          {summarize(row)}
                        </TableCell>
                        <TableCell className="text-center">
                          <Badge
                            variant="outline"
                            className={
                              SERVICE_VERIFY_STATUS_BADGE_CLASSES[verify]
                            }
                          >
                            {SERVICE_VERIFY_STATUS_LABELS[verify]}
                          </Badge>
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
                          {formatDateTime(row.last_verified_at)}
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
          className="w-full overflow-hidden sm:max-w-[480px]"
        >
          <SheetHeader>
            <SheetTitle>{editing ? "编辑数据源" : "新增数据源"}</SheetTitle>
            <SheetDescription>
              {editing
                ? "修改配置或重新测试验证；凭据留空表示不修改"
                : "按类型填写连接信息；可保存草稿，测试连接后生效"}
            </SheetDescription>
          </SheetHeader>

          <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-4">
            <Field>
              <FieldLabel htmlFor="sync-source-name">名称</FieldLabel>
              <Input
                className="h-11 lg:h-8"
                id="sync-source-name"
                value={form.name}
                onChange={(event) =>
                  setForm((prev) => ({ ...prev, name: event.target.value }))
                }
                placeholder="如：CRM 客户接口"
              />
            </Field>

            <Field>
              <FieldLabel htmlFor="sync-source-type">类型</FieldLabel>
              <Select
                value={form.type}
                onValueChange={(value) =>
                  setForm((prev) => ({
                    ...prev,
                    type: value as SyncSourceType,
                  }))
                }
              >
                <SelectTrigger
                  id="sync-source-type"
                  className="w-full min-h-11 lg:min-h-8"
                >
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {(Object.keys(SYNC_SOURCE_TYPE_LABELS) as SyncSourceType[]).map(
                    (value) => (
                      <SelectItem key={value} value={value}>
                        {SYNC_SOURCE_TYPE_LABELS[value]}
                      </SelectItem>
                    ),
                  )}
                </SelectContent>
              </Select>
            </Field>

            {form.type === "api" ? (
              <>
                <Field>
                  <FieldLabel htmlFor="sync-api-url">Base URL</FieldLabel>
                  <Input
                    className="h-11 lg:h-8"
                    id="sync-api-url"
                    value={form.apiBaseUrl}
                    onChange={(event) =>
                      setForm((prev) => ({
                        ...prev,
                        apiBaseUrl: event.target.value,
                      }))
                    }
                    placeholder="https://api.example.com/v1"
                    autoComplete="off"
                  />
                </Field>
                <Field>
                  <FieldLabel htmlFor="sync-api-auth">鉴权方式</FieldLabel>
                  <Select
                    value={form.apiAuthType}
                    onValueChange={(value) =>
                      setForm((prev) => ({ ...prev, apiAuthType: value }))
                    }
                  >
                    <SelectTrigger
                      id="sync-api-auth"
                      className="w-full min-h-11 lg:min-h-8"
                    >
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {API_AUTH_TYPES.map((option) => (
                        <SelectItem key={option.value} value={option.value}>
                          {option.label}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </Field>
                <Field>
                  <FieldLabel htmlFor="sync-api-token">
                    Token / 密钥
                  </FieldLabel>
                  <Input
                    className="h-11 lg:h-8"
                    id="sync-api-token"
                    type="password"
                    value={form.apiToken}
                    onChange={(event) =>
                      setForm((prev) => ({
                        ...prev,
                        apiToken: event.target.value,
                      }))
                    }
                    placeholder={
                      editing?.credentials_masked
                        ? `已保存 ${editing.credentials_masked}，留空不修改`
                        : "鉴权 Token（加密存储）"
                    }
                    autoComplete="new-password"
                  />
                  <FieldDescription>
                    {editing?.credentials_masked
                      ? `已保存凭据 ${editing.credentials_masked}；留空表示不修改，输入新值将整体替换`
                      : "保存后加密存储，界面不回显明文"}
                  </FieldDescription>
                </Field>
                <Field>
                  <FieldLabel htmlFor="sync-api-timeout">
                    超时（秒，可选）
                  </FieldLabel>
                  <Input
                    className="h-11 lg:h-8"
                    id="sync-api-timeout"
                    inputMode="numeric"
                    value={form.apiTimeout}
                    onChange={(event) =>
                      setForm((prev) => ({
                        ...prev,
                        apiTimeout: event.target.value,
                      }))
                    }
                    placeholder="30"
                    autoComplete="off"
                  />
                </Field>
              </>
            ) : null}

            {form.type === "db" ? (
              <>
                <Field>
                  <FieldLabel htmlFor="sync-db-engine">引擎</FieldLabel>
                  <Select
                    value={form.dbEngine}
                    onValueChange={(value) =>
                      setForm((prev) => ({ ...prev, dbEngine: value }))
                    }
                  >
                    <SelectTrigger
                      id="sync-db-engine"
                      className="w-full min-h-11 lg:min-h-8"
                    >
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {DB_ENGINES.map((option) => (
                        <SelectItem key={option.value} value={option.value}>
                          {option.label}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </Field>
                <Field>
                  <FieldLabel htmlFor="sync-db-host">主机</FieldLabel>
                  <Input
                    className="h-11 lg:h-8"
                    id="sync-db-host"
                    value={form.dbHost}
                    onChange={(event) =>
                      setForm((prev) => ({ ...prev, dbHost: event.target.value }))
                    }
                    placeholder="db.example.com"
                    autoComplete="off"
                  />
                </Field>
                <div className="grid grid-cols-2 gap-4">
                  <Field>
                    <FieldLabel htmlFor="sync-db-port">端口</FieldLabel>
                    <Input
                      className="h-11 lg:h-8"
                      id="sync-db-port"
                      inputMode="numeric"
                      value={form.dbPort}
                      onChange={(event) =>
                        setForm((prev) => ({
                          ...prev,
                          dbPort: event.target.value,
                        }))
                      }
                      placeholder="5432"
                      autoComplete="off"
                    />
                  </Field>
                  <Field>
                    <FieldLabel htmlFor="sync-db-database">库名</FieldLabel>
                    <Input
                      className="h-11 lg:h-8"
                      id="sync-db-database"
                      value={form.dbDatabase}
                      onChange={(event) =>
                        setForm((prev) => ({
                          ...prev,
                          dbDatabase: event.target.value,
                        }))
                      }
                      placeholder="erp"
                      autoComplete="off"
                    />
                  </Field>
                </div>
                <Field>
                  <FieldLabel htmlFor="sync-db-username">账号</FieldLabel>
                  <Input
                    className="h-11 lg:h-8"
                    id="sync-db-username"
                    value={form.dbUsername}
                    onChange={(event) =>
                      setForm((prev) => ({
                        ...prev,
                        dbUsername: event.target.value,
                      }))
                    }
                    placeholder="sync_reader"
                    autoComplete="off"
                  />
                </Field>
                <Field>
                  <FieldLabel htmlFor="sync-db-password">密码</FieldLabel>
                  <Input
                    className="h-11 lg:h-8"
                    id="sync-db-password"
                    type="password"
                    value={form.dbPassword}
                    onChange={(event) =>
                      setForm((prev) => ({
                        ...prev,
                        dbPassword: event.target.value,
                      }))
                    }
                    placeholder={
                      editing?.credentials_masked
                        ? `已保存 ${editing.credentials_masked}，留空不修改`
                        : "数据库密码（加密存储）"
                    }
                    autoComplete="new-password"
                  />
                </Field>
              </>
            ) : null}

            {form.type === "excel" ? (
              <Field>
                <FieldLabel htmlFor="sync-excel-upload">Excel 模板</FieldLabel>
                <div className="flex flex-col gap-2">
                  <Input
                    className="h-11 lg:h-8"
                    id="sync-excel-upload"
                    type="file"
                    accept=".xlsx,.xls,.csv"
                    onChange={(event) => void handleTemplateUpload(event)}
                    disabled={uploading}
                  />
                  <FieldDescription>
                    {uploading
                      ? "上传中…"
                      : form.excelTemplatePath
                        ? `已选择模板：${form.excelTemplatePath}`
                        : "上传至 sync-templates 存储桶；测试验证仅校验模板文件存在（Excel 源免连通性测试）"}
                  </FieldDescription>
                  {form.excelTemplatePath ? (
                    <p className="font-mono text-xs text-muted-foreground">
                      {form.excelTemplatePath}
                    </p>
                  ) : null}
                </div>
              </Field>
            ) : null}

            <div className="flex flex-col gap-3 rounded-xl border p-4">
              <div className="flex flex-wrap items-center gap-2">
                <span className="text-sm font-medium">验证状态</span>
                <Badge
                  variant="outline"
                  className={
                    SERVICE_VERIFY_STATUS_BADGE_CLASSES[
                      asServiceVerifyStatus(editing?.verify_status ?? "unverified")
                    ]
                  }
                >
                  {
                    SERVICE_VERIFY_STATUS_LABELS[
                      asServiceVerifyStatus(
                        editing?.verify_status ?? "unverified",
                      )
                    ]
                  }
                </Badge>
                <span className="text-xs text-muted-foreground">
                  {editing
                    ? `最近验证：${formatDateTime(editing.last_verified_at)}`
                    : "保存后可测试验证"}
                </span>
              </div>
              {editing ? (
                <div className="flex flex-col gap-2 sm:flex-row">
                  <Button
                    type="button"
                    variant="outline"
                    onClick={() => void handleTest()}
                    disabled={testing || saving}
                    className="h-11 lg:h-8"
                  >
                    {testing ? (
                      <Loader2Icon
                        className="animate-spin"
                        data-icon="inline-start"
                      />
                    ) : (
                      <ShieldCheckIcon data-icon="inline-start" />
                    )}
                    测试连接
                  </Button>
                  {asSyncStatus(editing.status) === "active" ? (
                    <Button
                      type="button"
                      variant="outline"
                      onClick={() => void handleDisable()}
                      disabled={saving || testing}
                      className="h-11 text-destructive hover:text-destructive lg:h-8"
                    >
                      <ShieldXIcon data-icon="inline-start" />
                      停用
                    </Button>
                  ) : (
                    <Button
                      type="button"
                      variant="outline"
                      onClick={() => void handleEnable()}
                      disabled={saving || testing}
                      className="h-11 lg:h-8"
                    >
                      <ShieldCheckIcon data-icon="inline-start" />
                      启用
                    </Button>
                  )}
                </div>
              ) : null}
              <p className="text-xs text-muted-foreground">
                api 校验 base_url、db 校验 host/port/database、excel 校验模板对象存在；真实出网探测待
                sync/005 执行器上线后启用
              </p>
            </div>
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
              disabled={saving || uploading}
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
              保存
            </Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>
    </div>
  );
}
