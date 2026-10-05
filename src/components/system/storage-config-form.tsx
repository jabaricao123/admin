"use client";

import * as React from "react";
import {
  HardDriveIcon,
  Loader2Icon,
  SaveIcon,
  ShieldCheckIcon,
} from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
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
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableFooter,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { InfoHint } from "@/components/info-hint";
import type { Database } from "@/lib/database.types";
import {
  asServiceVerifyStatus,
  SERVICE_VERIFY_STATUS_BADGE_CLASSES,
  SERVICE_VERIFY_STATUS_LABELS,
  translateSystemErrorMessage,
  type ServiceVerifyStatus,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type UpsertServiceConfigArgs =
  Database["public"]["Functions"]["upsert_service_config"]["Args"];

type StorageUsageRow =
  Database["public"]["Functions"]["get_storage_usage"]["Returns"][number];

type StorageForm = {
  provider: string;
  endpoint: string;
  region: string;
  bucket: string;
  accessKey: string;
  secretKey: string;
  signedUrlTtlMinutes: string;
  maxFileSizeMb: string;
  mimeWhitelist: string;
};

type UpsertResult = {
  verify_status?: string;
  verified_at?: string | null;
  credentials_set?: boolean;
};

type TestResult = {
  ok?: boolean;
  message?: string;
  verify_status?: string;
  verified_at?: string | null;
};

const PROVIDERS = [
  { value: "supabase-storage", label: "Supabase Storage（默认）" },
  { value: "s3", label: "S3 兼容存储" },
] as const;

const EMPTY_FORM: StorageForm = {
  provider: "supabase-storage",
  endpoint: "",
  region: "",
  bucket: "",
  accessKey: "",
  secretKey: "",
  signedUrlTtlMinutes: "60",
  maxFileSizeMb: "50",
  mimeWhitelist: "",
};

const formatDateTime = (value: string) =>
  new Date(value).toLocaleString("zh-CN", { hour12: false });

const asText = (value: unknown): string => {
  if (value === null || value === undefined) {
    return "";
  }
  return typeof value === "string" ? value : String(value);
};

const formatBytes = (value: number): string => {
  if (!Number.isFinite(value) || value <= 0) {
    return "0 B";
  }
  const units = ["B", "KB", "MB", "GB", "TB"];
  const exponent = Math.min(
    Math.floor(Math.log(value) / Math.log(1024)),
    units.length - 1,
  );
  const size = value / 1024 ** exponent;
  return `${size >= 10 || exponent === 0 ? size.toFixed(0) : size.toFixed(1)} ${units[exponent]}`;
};

export function StorageConfigForm() {
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [configured, setConfigured] = React.useState(false);
  const [form, setForm] = React.useState<StorageForm>(EMPTY_FORM);
  const [credentialsSet, setCredentialsSet] = React.useState(false);
  const [verifyStatus, setVerifyStatus] =
    React.useState<ServiceVerifyStatus>("unverified");
  const [verifiedAt, setVerifiedAt] = React.useState<string | null>(null);
  const [saving, setSaving] = React.useState(false);
  const [testing, setTesting] = React.useState(false);
  const [usage, setUsage] = React.useState<StorageUsageRow[]>([]);
  const [usageLoading, setUsageLoading] = React.useState(true);
  const [usageError, setUsageError] = React.useState<string | null>(null);

  const load = React.useCallback(async () => {
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const { data, error: loadError } =
      await supabase.rpc("get_service_status");

    if (loadError) {
      setError(loadError.message);
      setLoading(false);
      return;
    }

    const row = (data ?? []).find((item) => item.service === "storage");
    if (row) {
      const config = (row.config ?? {}) as Record<string, unknown>;
      setForm({
        provider: asText(config.provider) || EMPTY_FORM.provider,
        endpoint: asText(config.endpoint),
        region: asText(config.region),
        bucket: asText(config.bucket),
        accessKey: "",
        secretKey: "",
        signedUrlTtlMinutes:
          asText(config.signed_url_ttl_minutes) ||
          EMPTY_FORM.signedUrlTtlMinutes,
        maxFileSizeMb:
          asText(config.max_file_size_mb) || EMPTY_FORM.maxFileSizeMb,
        mimeWhitelist: Array.isArray(config.mime_whitelist)
          ? (config.mime_whitelist as unknown[]).map(asText).join(", ")
          : asText(config.mime_whitelist),
      });
      setCredentialsSet((row.credentials_masked ?? null) !== null);
      setVerifyStatus(asServiceVerifyStatus(row.verify_status));
      setVerifiedAt(
        typeof row.verified_at === "string" ? row.verified_at : null,
      );
      setConfigured(true);
    } else {
      setForm(EMPTY_FORM);
      setCredentialsSet(false);
      setVerifyStatus("unverified");
      setVerifiedAt(null);
      setConfigured(false);
    }
    setLoading(false);
  }, []);

  const loadUsage = React.useCallback(async () => {
    setUsageLoading(true);
    setUsageError(null);
    const supabase = createClient();
    const { data, error: usageLoadError } =
      await supabase.rpc("get_storage_usage");

    if (usageLoadError) {
      setUsageError(usageLoadError.message);
      setUsage([]);
      setUsageLoading(false);
      return;
    }

    setUsage(data ?? []);
    setUsageLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
    void loadUsage();
  }, [load, loadUsage]);

  const handleSave = async () => {
    const endpoint = form.endpoint.trim();
    const bucket = form.bucket.trim();

    const ttlText = form.signedUrlTtlMinutes.trim();
    let ttl: number | null = null;
    if (ttlText !== "") {
      const parsed = Number(ttlText);
      if (!Number.isInteger(parsed) || parsed < 1 || parsed > 10080) {
        toast.error("签名 URL 有效期需为 1-10080 分钟的整数");
        return;
      }
      ttl = parsed;
    }

    const maxText = form.maxFileSizeMb.trim();
    let maxMb: number | null = null;
    if (maxText !== "") {
      const parsed = Number(maxText);
      if (!Number.isInteger(parsed) || parsed < 1 || parsed > 10240) {
        toast.error("单文件大小上限需为 1-10240 MB 的整数");
        return;
      }
      maxMb = parsed;
    }

    const accessKey = form.accessKey.trim();
    const secretKey = form.secretKey;
    if ((accessKey === "") !== (secretKey === "")) {
      toast.error("access_key 与 secret_key 需同时填写");
      return;
    }

    const mimeWhitelist = Array.from(
      new Set(
        form.mimeWhitelist
          .split(/[,，\s]+/)
          .map((item) => item.trim())
          .filter(Boolean),
      ),
    );

    const wasVerified = verifyStatus === "verified";
    // 凭据按 JSON 文本整体加密存储（access_key + secret_key 成对）；空 = 不修改
    const nextCredentials =
      accessKey === ""
        ? null
        : JSON.stringify({ access_key: accessKey, secret_key: secretKey });

    setSaving(true);
    const supabase = createClient();
    // 生成物未表达 text 参数可为 NULL（NULL=不修改凭据），运行时允许传 null
    const args = {
      p_service: "storage",
      p_config: {
        provider: form.provider,
        endpoint,
        region: form.region.trim(),
        bucket,
        signed_url_ttl_minutes: ttl,
        max_file_size_mb: maxMb,
        mime_whitelist: mimeWhitelist,
      },
      p_credentials: nextCredentials,
    };
    const { data, error: saveError } = await supabase.rpc(
      "upsert_service_config",
      args as UpsertServiceConfigArgs,
    );
    setSaving(false);

    if (saveError) {
      toast.error(translateSystemErrorMessage(saveError.message));
      return;
    }

    const result = (data ?? null) as UpsertResult | null;
    const nextStatus = asServiceVerifyStatus(
      result?.verify_status ?? "unverified",
    );
    setVerifyStatus(nextStatus);
    setVerifiedAt(
      typeof result?.verified_at === "string" ? result.verified_at : null,
    );
    setConfigured(true);
    if (nextCredentials !== null) {
      setCredentialsSet(true);
      setForm((prev) => ({ ...prev, accessKey: "", secretKey: "" }));
    }

    toast.success("对象存储配置已保存");
    if (wasVerified && nextStatus === "unverified") {
      toast.info("配置内容已变更，验证状态已降为「待验证」，请重新测试验证");
    }
  };

  const handleTest = async () => {
    setTesting(true);
    const supabase = createClient();
    const { data, error: testError } = await supabase.rpc(
      "test_storage_config",
    );
    setTesting(false);

    if (testError) {
      toast.error(translateSystemErrorMessage(testError.message));
      return;
    }

    const result = (data ?? null) as TestResult | null;
    setVerifyStatus(asServiceVerifyStatus(result?.verify_status ?? "failed"));
    setVerifiedAt(
      typeof result?.verified_at === "string" ? result.verified_at : null,
    );

    if (result?.ok) {
      toast.success(result.message ?? "配置校验通过");
      void loadUsage();
    } else {
      toast.error(result?.message ?? "配置校验未通过");
    }
  };

  const usageTotals = usage.reduce(
    (acc, item) => ({
      objectCount: acc.objectCount + Number(item.object_count ?? 0),
      totalBytes: acc.totalBytes + Number(item.total_bytes ?? 0),
    }),
    { objectCount: 0, totalBytes: 0 },
  );

  if (loading) {
    return (
      <div className="flex flex-col gap-2 p-0 md:p-6">
        <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
          <CardContent className="flex flex-col gap-4 p-4 md:p-6">
            <div className="grid gap-4 lg:grid-cols-2">
              {Array.from({ length: 8 }).map((_, index) => (
                <div key={index} className="flex flex-col gap-2">
                  <Skeleton className="h-4 w-20" />
                  <Skeleton className="h-11 w-full lg:h-8" />
                </div>
              ))}
            </div>
            <Skeleton className="h-28 w-full" />
          </CardContent>
        </Card>
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex flex-col gap-2 p-0 md:p-6">
        <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
          <CardContent className="flex flex-col items-center gap-2 py-16 text-sm">
            <p className="text-destructive">
              加载失败：{translateSystemErrorMessage(error)}
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
    <div className="flex flex-col gap-2 p-0 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="p-4 md:p-6">
          <form
            className="flex flex-col gap-6"
            onSubmit={(event) => {
              event.preventDefault();
              void handleSave();
            }}
          >
            <div className="grid gap-4 lg:grid-cols-2">
              <Field>
                <FieldLabel htmlFor="storage-provider">Provider</FieldLabel>
                <Select
                  value={form.provider}
                  onValueChange={(value) =>
                    setForm((prev) => ({ ...prev, provider: value }))
                  }
                >
                  <SelectTrigger
                    id="storage-provider"
                    className="h-11 w-full lg:h-8"
                    aria-label="存储 Provider"
                  >
                    <SelectValue placeholder="选择 Provider" />
                  </SelectTrigger>
                  <SelectContent>
                    {PROVIDERS.map((option) => (
                      <SelectItem key={option.value} value={option.value}>
                        {option.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <FieldDescription>
                  默认 Supabase Storage；自建 MinIO / 云厂商对象存储选 S3 兼容
                </FieldDescription>
              </Field>
              <Field>
                <FieldLabel htmlFor="storage-bucket">Bucket</FieldLabel>
                <Input
                  id="storage-bucket"
                  value={form.bucket}
                  onChange={(event) =>
                    setForm((prev) => ({ ...prev, bucket: event.target.value }))
                  }
                  placeholder="exports"
                  autoComplete="off"
                  className="h-11 lg:h-8"
                />
                <FieldDescription>
                  导出文件默认 exports；已初始化 exports / sync-templates /
                  attachments
                </FieldDescription>
              </Field>

              <Field className="lg:col-span-2">
                <FieldLabel htmlFor="storage-endpoint">Endpoint</FieldLabel>
                <Input
                  id="storage-endpoint"
                  value={form.endpoint}
                  onChange={(event) =>
                    setForm((prev) => ({
                      ...prev,
                      endpoint: event.target.value,
                    }))
                  }
                  placeholder="https://s3.example.com 或 Supabase 项目地址"
                  autoComplete="off"
                  className="h-11 lg:h-8"
                />
              </Field>
              <Field>
                <FieldLabel htmlFor="storage-region">Region</FieldLabel>
                <Input
                  id="storage-region"
                  value={form.region}
                  onChange={(event) =>
                    setForm((prev) => ({ ...prev, region: event.target.value }))
                  }
                  placeholder="如 cn-north-1（S3 兼容时填写）"
                  autoComplete="off"
                  className="h-11 lg:h-8"
                />
              </Field>

              <Field>
                <FieldLabel htmlFor="storage-access-key">Access Key</FieldLabel>
                <Input
                  id="storage-access-key"
                  value={form.accessKey}
                  onChange={(event) =>
                    setForm((prev) => ({
                      ...prev,
                      accessKey: event.target.value,
                    }))
                  }
                  placeholder={
                    credentialsSet
                      ? "已保存凭据，留空不修改"
                      : "S3 Access Key（Supabase Storage 可留空）"
                  }
                  autoComplete="off"
                  className="h-11 lg:h-8"
                />
              </Field>
              <Field>
                <FieldLabel htmlFor="storage-secret-key">Secret Key</FieldLabel>
                <Input
                  id="storage-secret-key"
                  type="password"
                  value={form.secretKey}
                  onChange={(event) =>
                    setForm((prev) => ({
                      ...prev,
                      secretKey: event.target.value,
                    }))
                  }
                  placeholder={
                    credentialsSet
                      ? "已保存凭据，留空不修改"
                      : "S3 Secret Key（Supabase Storage 可留空）"
                  }
                  autoComplete="new-password"
                  className="h-11 lg:h-8"
                />
                <FieldDescription>
                  {credentialsSet
                    ? "已保存凭据（不回显明文）；留空表示不修改，修改时两项需同时填写"
                    : "当前未配置凭据；保存后加密存储，不回显明文"}
                </FieldDescription>
              </Field>

              <Field>
                <FieldLabel htmlFor="storage-ttl">签名 URL 有效期（分钟）</FieldLabel>
                <Input
                  id="storage-ttl"
                  inputMode="numeric"
                  value={form.signedUrlTtlMinutes}
                  onChange={(event) =>
                    setForm((prev) => ({
                      ...prev,
                      signedUrlTtlMinutes: event.target.value,
                    }))
                  }
                  placeholder="60"
                  autoComplete="off"
                  className="h-11 lg:h-8"
                />
                <FieldDescription>
                  导出/附件签发的签名 URL 默认有效时长，拖过即 403
                </FieldDescription>
              </Field>
              <Field>
                <FieldLabel htmlFor="storage-max-size">
                  单文件大小上限（MB）
                </FieldLabel>
                <Input
                  id="storage-max-size"
                  inputMode="numeric"
                  value={form.maxFileSizeMb}
                  onChange={(event) =>
                    setForm((prev) => ({
                      ...prev,
                      maxFileSizeMb: event.target.value,
                    }))
                  }
                  placeholder="50"
                  autoComplete="off"
                  className="h-11 lg:h-8"
                />
                <FieldDescription>超限上传由消费方拒绝</FieldDescription>
              </Field>
              <Field className="lg:col-span-2">
                <FieldLabel htmlFor="storage-mime">
                  MIME 白名单（逗号分隔）
                </FieldLabel>
                <Input
                  id="storage-mime"
                  value={form.mimeWhitelist}
                  onChange={(event) =>
                    setForm((prev) => ({
                      ...prev,
                      mimeWhitelist: event.target.value,
                    }))
                  }
                  placeholder="text/csv, application/pdf, image/png"
                  autoComplete="off"
                  className="h-11 lg:h-8"
                />
                <FieldDescription>
                  留空表示不限制；导出 CSV / Excel 模板为默认场景
                </FieldDescription>
              </Field>
            </div>

            <div className="flex flex-col gap-3 rounded-xl border p-4">
              <div className="flex flex-wrap items-center gap-2">
                <span className="text-sm font-medium">验证状态</span>
                <Badge
                  variant="outline"
                  className={SERVICE_VERIFY_STATUS_BADGE_CLASSES[verifyStatus]}
                >
                  {SERVICE_VERIFY_STATUS_LABELS[verifyStatus]}
                </Badge>
                <span className="text-xs text-muted-foreground">
                  {verifiedAt
                    ? `最近验证：${formatDateTime(verifiedAt)}`
                    : configured
                      ? "尚未测试验证"
                      : "尚未保存配置"}
                </span>
              </div>
              <p className="text-xs text-muted-foreground">
                {`测试验证 = 校验 provider / endpoint / bucket 完整性，并确认目标 bucket 存在（连通性实测待出站运行时上线后启用）。`}
              </p>
              <div className="flex">
                <Button
                  type="button"
                  variant="outline"
                  onClick={() => void handleTest()}
                  disabled={testing || !configured}
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
                  测试验证
                </Button>
              </div>
            </div>

            <div className="flex justify-end">
              <Button
                type="submit"
                disabled={saving}
                className="h-8 w-full sm:w-auto"
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
            </div>
          </form>
        </CardContent>
      </Card>

      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card gap-3! py-3!">
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <HardDriveIcon className="size-4 text-muted-foreground" />
            Bucket 用量
            <InfoHint>
              storage.objects 聚合：文件数与占用字节（含空 bucket）
            </InfoHint>
          </CardTitle>
        </CardHeader>
        <CardContent className="p-4 md:p-6">
          {usageLoading ? (
            <div className="flex flex-col gap-3">
              {Array.from({ length: 3 }).map((_, index) => (
                <Skeleton key={index} className="h-8 w-full" />
              ))}
            </div>
          ) : usageError ? (
            <div className="flex flex-col items-center gap-2 py-8 text-sm">
              <p className="text-destructive">
                用量加载失败：{translateSystemErrorMessage(usageError)}
              </p>
              <Button variant="outline" onClick={() => void loadUsage()}>
                重试
              </Button>
            </div>
          ) : usage.length === 0 ? (
            <p className="py-8 text-center text-sm text-muted-foreground">
              暂无可统计的 bucket
            </p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="text-center">Bucket</TableHead>
                  <TableHead className="text-center">文件数</TableHead>
                  <TableHead className="text-center">占用</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {usage.map((item) => (
                  <TableRow key={item.bucket_id}>
                    <TableCell className="text-center font-medium">
                      {item.bucket_id}
                    </TableCell>
                    <TableCell className="text-center">
                      {item.object_count}
                    </TableCell>
                    <TableCell className="text-center">
                      {formatBytes(Number(item.total_bytes ?? 0))}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
              <TableFooter>
                <TableRow>
                  <TableCell className="text-center">合计</TableCell>
                  <TableCell className="text-center">
                    {usageTotals.objectCount}
                  </TableCell>
                  <TableCell className="text-center">
                    {formatBytes(usageTotals.totalBytes)}
                  </TableCell>
                </TableRow>
              </TableFooter>
            </Table>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
