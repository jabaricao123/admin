"use client";

// 系统管理 · 短信服务配置（工单 system/005 页面）
//
// 数据：get_service_status（admin，provider/access_key_id/sign_name/enabled + 凭据掩码）、
//       upsert_service_config（service='sms'）、test_sms_config（通道未启用禁用测试）、
//       system_sms_templates 表（RLS admin 直读）+ upsert_sms_template / disable_sms_template。
// 契约（docs/modules/system/services-sms.md）：配置表单 + 模板列表（Table + Sheet）+ 预留 Banner；
//       通道停用时测试按钮禁用并说明；模板只登记不管理服务商后台。

import * as React from "react";
import {
  BanIcon,
  InfoIcon,
  Loader2Icon,
  MessageSquareIcon,
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
import {
  Field,
  FieldContent,
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
import { Switch } from "@/components/ui/switch";
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
  asServiceVerifyStatus,
  asSmsProvider,
  asSmsTemplateStatus,
  SERVICE_VERIFY_STATUS_BADGE_CLASSES,
  SERVICE_VERIFY_STATUS_LABELS,
  SMS_PROVIDER_OPTIONS,
  SMS_TEMPLATE_STATUS_BADGE_CLASSES,
  SMS_TEMPLATE_STATUS_LABELS,
  SMS_TEMPLATE_STATUS_OPTIONS,
  translateSystemErrorMessage,
  type ServiceVerifyStatus,
  type SmsProvider,
  type SmsTemplateStatus,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type SmsTemplateRow = Pick<
  Database["public"]["Tables"]["system_sms_templates"]["Row"],
  "id" | "name" | "scene" | "provider_code" | "status" | "updated_at"
>;

type UpsertServiceConfigArgs =
  Database["public"]["Functions"]["upsert_service_config"]["Args"];
type UpsertSmsTemplateArgs =
  Database["public"]["Functions"]["upsert_sms_template"]["Args"];

type ConfigForm = {
  provider: SmsProvider;
  accessKeyId: string;
  secret: string;
  signName: string;
  enabled: boolean;
};

type TemplateForm = {
  id: string | null;
  name: string;
  scene: string;
  providerCode: string;
  status: SmsTemplateStatus;
};

type UpsertResult = {
  verify_status?: string;
  verified_at?: string | null;
};

type TestResult = {
  ok?: boolean;
  message?: string;
  verify_status?: string;
  verified_at?: string | null;
};

const EMPTY_CONFIG: ConfigForm = {
  provider: "aliyun",
  accessKeyId: "",
  secret: "",
  signName: "",
  enabled: false,
};

const EMPTY_TEMPLATE: TemplateForm = {
  id: null,
  name: "",
  scene: "",
  providerCode: "",
  status: "active",
};

const formatDateTime = (value: string) =>
  new Date(value).toLocaleString("zh-CN", { hour12: false });

const asText = (value: unknown): string => {
  if (value === null || value === undefined) {
    return "";
  }
  return typeof value === "string" ? value : String(value);
};

/** 与服务端掩码规则一致：**** + 明文尾 4 位 */
const maskSecret = (secret: string): string => `****${secret.slice(-4)}`;

export function SmsConfigPanel() {
  // ---- 通道配置 ----
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [configured, setConfigured] = React.useState(false);
  const [form, setForm] = React.useState<ConfigForm>(EMPTY_CONFIG);
  const [credentialsMasked, setCredentialsMasked] = React.useState<
    string | null
  >(null);
  const [verifyStatus, setVerifyStatus] =
    React.useState<ServiceVerifyStatus>("unverified");
  const [verifiedAt, setVerifiedAt] = React.useState<string | null>(null);
  const [saving, setSaving] = React.useState(false);
  const [testing, setTesting] = React.useState(false);
  const [testPhone, setTestPhone] = React.useState("");

  // ---- 模板登记 ----
  const [templates, setTemplates] = React.useState<SmsTemplateRow[]>([]);
  const [templatesLoading, setTemplatesLoading] = React.useState(true);
  const [templatesError, setTemplatesError] = React.useState<string | null>(
    null,
  );
  const [sheetOpen, setSheetOpen] = React.useState(false);
  const [templateForm, setTemplateForm] =
    React.useState<TemplateForm>(EMPTY_TEMPLATE);
  const [savingTemplate, setSavingTemplate] = React.useState(false);
  const [disablingTemplate, setDisablingTemplate] = React.useState(false);

  const loadTemplates = React.useCallback(async () => {
    setTemplatesLoading(true);
    setTemplatesError(null);
    const supabase = createClient();
    const { data, error: templatesLoadError } = await supabase
      .from("system_sms_templates")
      .select("id, name, scene, provider_code, status, updated_at")
      .order("updated_at", { ascending: false });

    if (templatesLoadError) {
      setTemplatesError(templatesLoadError.message);
      setTemplatesLoading(false);
      return;
    }
    setTemplates((data ?? []) as SmsTemplateRow[]);
    setTemplatesLoading(false);
  }, []);

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

    const row = (data ?? []).find((item) => item.service === "sms");
    if (row) {
      const config = (row.config ?? {}) as Record<string, unknown>;
      setForm({
        provider: asSmsProvider(asText(config.provider)),
        accessKeyId: asText(config.access_key_id),
        secret: "",
        signName: asText(config.sign_name),
        enabled: config.enabled === true,
      });
      setCredentialsMasked(row.credentials_masked ?? null);
      setVerifyStatus(asServiceVerifyStatus(row.verify_status));
      setVerifiedAt(
        typeof row.verified_at === "string" ? row.verified_at : null,
      );
      setConfigured(true);
    } else {
      setForm(EMPTY_CONFIG);
      setCredentialsMasked(null);
      setVerifyStatus("unverified");
      setVerifiedAt(null);
      setConfigured(false);
    }
    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
    void loadTemplates();
  }, [load, loadTemplates]);

  const handleSave = async () => {
    const accessKeyId = form.accessKeyId.trim();
    const signName = form.signName.trim();
    const nextSecret = form.secret;
    const wasVerified = verifyStatus === "verified";

    setSaving(true);
    const supabase = createClient();
    // 生成物未表达 text 参数可为 NULL（NULL=不修改凭据），运行时允许传 null
    const args = {
      p_service: "sms",
      p_config: {
        provider: form.provider,
        access_key_id: accessKeyId,
        sign_name: signName,
        enabled: form.enabled,
      },
      p_credentials: nextSecret === "" ? null : nextSecret,
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
    if (nextSecret !== "") {
      setCredentialsMasked(maskSecret(nextSecret));
      setForm((prev) => ({ ...prev, secret: "" }));
    }

    toast.success("短信配置已保存");
    if (wasVerified && nextStatus === "unverified") {
      toast.info("配置内容已变更，验证状态已降为「待验证」，请重新测试");
    }
  };

  const handleTest = async () => {
    const phone = testPhone.trim();
    if (phone === "") {
      toast.error("请输入测试手机号");
      return;
    }

    setTesting(true);
    const supabase = createClient();
    const { data, error: testError } = await supabase.rpc("test_sms_config", {
      p_phone: phone,
    });
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
    } else {
      toast.error(result?.message ?? "配置校验未通过");
    }
  };

  const openCreateTemplate = () => {
    setTemplateForm(EMPTY_TEMPLATE);
    setSheetOpen(true);
  };

  const openEditTemplate = (row: SmsTemplateRow) => {
    setTemplateForm({
      id: row.id,
      name: row.name,
      scene: row.scene,
      providerCode: row.provider_code,
      status: asSmsTemplateStatus(row.status),
    });
    setSheetOpen(true);
  };

  const handleSaveTemplate = async () => {
    const name = templateForm.name.trim();
    const scene = templateForm.scene.trim();
    const providerCode = templateForm.providerCode.trim();

    if (name === "") {
      toast.error("模板名称不能为空");
      return;
    }
    if (scene === "") {
      toast.error("模板场景不能为空");
      return;
    }
    if (providerCode === "") {
      toast.error("模板 Code 不能为空");
      return;
    }

    setSavingTemplate(true);
    const supabase = createClient();
    const { error: saveError } = await supabase.rpc(
      "upsert_sms_template",
      {
        p_id: templateForm.id,
        p_name: name,
        p_scene: scene,
        p_provider_code: providerCode,
        p_status: templateForm.status,
      } as UpsertSmsTemplateArgs,
    );
    setSavingTemplate(false);

    if (saveError) {
      toast.error(translateSystemErrorMessage(saveError.message));
      return;
    }

    toast.success(templateForm.id ? "模板已保存" : "模板已登记");
    setSheetOpen(false);
    void loadTemplates();
  };

  const handleDisableTemplate = async () => {
    if (!templateForm.id) {
      return;
    }
    setDisablingTemplate(true);
    const supabase = createClient();
    const { error: disableError } = await supabase.rpc("disable_sms_template", {
      p_id: templateForm.id,
    });
    setDisablingTemplate(false);

    if (disableError) {
      toast.error(translateSystemErrorMessage(disableError.message));
      return;
    }

    toast.success("模板已停用");
    setSheetOpen(false);
    void loadTemplates();
  };

  if (loading) {
    return (
      <div className="flex flex-col p-0 md:gap-6 md:p-6">
        <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
          <CardHeader>
            <Skeleton className="h-5 w-24" />
            <Skeleton className="h-4 w-72 max-w-full" />
          </CardHeader>
          <CardContent className="flex flex-col gap-4 p-4 md:p-6">
            <div className="grid gap-4 lg:grid-cols-2">
              {Array.from({ length: 4 }).map((_, index) => (
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
      <div className="flex flex-col p-0 md:gap-6 md:p-6">
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

  const testDisabled = !configured || !form.enabled || testing;

  return (
    <div className="flex flex-col gap-4 p-0 md:gap-6 md:p-6">
      {/* 预留状态 Banner（services-sms.md：首期仅配置面骨架） */}
      <div className="flex items-start gap-2 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-200">
        <InfoIcon className="mt-0.5 size-4 shrink-0" />
        <p>
          短信通道为预留能力（商业化启用前仅完成配置面骨架）。当前「测试发送」仅校验配置完整性，
          不会真实发送短信；通道停用时 message 发送自动跳过短信渠道、降级为站内信。
        </p>
      </div>

      {/* 通道配置 */}
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardHeader>
          <CardTitle>短信服务</CardTitle>
          <CardDescription>
            服务商凭据与签名配置；凭据加密存储、界面仅显示掩码，保存后经测试验证
          </CardDescription>
        </CardHeader>
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
                <FieldLabel htmlFor="sms-provider">服务商</FieldLabel>
                <Select
                  value={form.provider}
                  onValueChange={(value) =>
                    setForm((prev) => ({
                      ...prev,
                      provider: asSmsProvider(value),
                    }))
                  }
                >
                  <SelectTrigger
                    id="sms-provider"
                    className="h-11 w-full lg:h-8"
                  >
                    <SelectValue placeholder="选择短信服务商" />
                  </SelectTrigger>
                  <SelectContent>
                    {SMS_PROVIDER_OPTIONS.map((option) => (
                      <SelectItem key={option.value} value={option.value}>
                        {option.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </Field>
              <Field>
                <FieldLabel htmlFor="sms-sign-name">短信签名</FieldLabel>
                <Input
                  id="sms-sign-name"
                  value={form.signName}
                  onChange={(event) =>
                    setForm((prev) => ({
                      ...prev,
                      signName: event.target.value,
                    }))
                  }
                  placeholder="服务商后台已审核的签名，如「企业管理系统」"
                  autoComplete="off"
                  className="h-11 lg:h-8"
                />
              </Field>

              <Field>
                <FieldLabel htmlFor="sms-access-key-id">
                  AccessKey ID
                </FieldLabel>
                <Input
                  id="sms-access-key-id"
                  value={form.accessKeyId}
                  onChange={(event) =>
                    setForm((prev) => ({
                      ...prev,
                      accessKeyId: event.target.value,
                    }))
                  }
                  placeholder="服务商控制台 AccessKey ID"
                  autoComplete="off"
                  className="h-11 lg:h-8"
                />
              </Field>
              <Field>
                <FieldLabel htmlFor="sms-access-key-secret">
                  AccessKey Secret
                </FieldLabel>
                <Input
                  id="sms-access-key-secret"
                  type="password"
                  value={form.secret}
                  onChange={(event) =>
                    setForm((prev) => ({ ...prev, secret: event.target.value }))
                  }
                  placeholder={
                    credentialsMasked
                      ? `已保存 ${credentialsMasked}，留空不修改`
                      : "服务商控制台 AccessKey Secret"
                  }
                  autoComplete="new-password"
                  className="h-11 lg:h-8"
                />
                <FieldDescription>
                  {credentialsMasked
                    ? `已保存凭据 ${credentialsMasked}；留空表示不修改，输入新值将整体替换`
                    : "当前未配置凭据；保存后加密存储，不回显明文"}
                </FieldDescription>
              </Field>

              <Field
                orientation="horizontal"
                className="rounded-lg border p-3 lg:col-span-2"
              >
                <FieldContent>
                  <FieldLabel htmlFor="sms-enabled">启用短信通道</FieldLabel>
                  <FieldDescription>
                    停用时 message 发送自动跳过短信渠道（降级站内信，不报错）；
                    测试发送需先启用通道
                  </FieldDescription>
                </FieldContent>
                <Switch
                  id="sms-enabled"
                  checked={form.enabled}
                  onCheckedChange={(checked) =>
                    setForm((prev) => ({ ...prev, enabled: checked }))
                  }
                />
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
                {`测试发送 = 校验 provider / AccessKey / 签名完整性；真实发送待商业化启用后接入。${
                  form.enabled ? "" : "（通道未启用，测试按钮已禁用）"
                }`}
              </p>
              <div className="flex flex-col gap-2 sm:flex-row">
                <Input
                  type="tel"
                  value={testPhone}
                  onChange={(event) => setTestPhone(event.target.value)}
                  placeholder="测试手机号，如 12345678901"
                  aria-label="测试手机号"
                  autoComplete="off"
                  disabled={testDisabled}
                  className="h-11 sm:max-w-xs lg:h-8"
                />
                <Button
                  type="button"
                  variant="outline"
                  onClick={() => void handleTest()}
                  disabled={testDisabled}
                  className="h-11 lg:h-8"
                >
                  {testing ? (
                    <Loader2Icon
                      className="animate-spin"
                      data-icon="inline-start"
                    />
                  ) : (
                    <SendIcon data-icon="inline-start" />
                  )}
                  测试发送
                </Button>
              </div>
            </div>

            <div className="flex justify-end">
              <Button
                type="submit"
                disabled={saving}
                className="h-11 w-full sm:w-auto lg:h-8"
              >
                {saving ? (
                  <Loader2Icon
                    className="animate-spin"
                    data-icon="inline-start"
                  />
                ) : (
                  <SaveIcon data-icon="inline-start" />
                )}
                保存
              </Button>
            </div>
          </form>
        </CardContent>
      </Card>

      {/* 模板登记表 */}
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardHeader>
          <CardTitle>短信模板登记</CardTitle>
          <CardDescription>
            登记服务商后台已审核模板（名称、场景、模板 Code、状态）；只登记，不管理服务商后台
          </CardDescription>
          <CardAction className="flex items-center gap-2">
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => void loadTemplates()}
              disabled={templatesLoading}
              aria-label="刷新模板列表"
            >
              <RefreshCwIcon
                className={templatesLoading ? "animate-spin" : undefined}
                data-icon="inline-start"
              />
              刷新
            </Button>
            <Button type="button" size="sm" onClick={openCreateTemplate}>
              <PlusIcon data-icon="inline-start" />
              新增模板
            </Button>
          </CardAction>
        </CardHeader>
        <CardContent className="p-4 md:p-6">
          {templatesLoading ? (
            <div className="flex flex-col gap-3">
              {Array.from({ length: 4 }).map((_, index) => (
                <Skeleton key={index} className="h-9 w-full" />
              ))}
            </div>
          ) : templatesError ? (
            <div className="flex flex-col items-center gap-2 py-10 text-sm">
              <p className="text-destructive">
                加载失败：{translateSystemErrorMessage(templatesError)}
              </p>
              <Button variant="outline" onClick={() => void loadTemplates()}>
                重试
              </Button>
            </div>
          ) : templates.length === 0 ? (
            <p className="py-10 text-center text-sm text-muted-foreground">
              暂无登记模板，点击右上角「新增模板」登记
            </p>
          ) : (
            <>
              {/* 桌面：Table（整行可点打开 Sheet） */}
              <div className="hidden overflow-x-auto lg:block">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead className="text-center">模板名称</TableHead>
                      <TableHead className="text-center">场景</TableHead>
                      <TableHead className="text-center">模板 Code</TableHead>
                      <TableHead className="text-center">状态</TableHead>
                      <TableHead className="text-center">更新时间</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {templates.map((row) => {
                      const status = asSmsTemplateStatus(row.status);
                      return (
                        <TableRow
                          key={row.id}
                          className="cursor-pointer"
                          onClick={() => openEditTemplate(row)}
                          tabIndex={0}
                          onKeyDown={(event) => {
                            if (event.key === "Enter") {
                              openEditTemplate(row);
                            }
                          }}
                        >
                          <TableCell className="text-left font-medium">
                            {row.name}
                          </TableCell>
                          <TableCell>{row.scene}</TableCell>
                          <TableCell className="font-mono text-xs">
                            {row.provider_code}
                          </TableCell>
                          <TableCell>
                            <Badge
                              variant="outline"
                              className={
                                SMS_TEMPLATE_STATUS_BADGE_CLASSES[status]
                              }
                            >
                              {SMS_TEMPLATE_STATUS_LABELS[status]}
                            </Badge>
                          </TableCell>
                          <TableCell className="text-muted-foreground">
                            {formatDateTime(row.updated_at)}
                          </TableCell>
                        </TableRow>
                      );
                    })}
                  </TableBody>
                </Table>
              </div>

              {/* 移动端（<1024px）：整卡可点 */}
              <div className="flex flex-col gap-3 lg:hidden">
                {templates.map((row) => {
                  const status = asSmsTemplateStatus(row.status);
                  return (
                    <button
                      key={row.id}
                      type="button"
                      onClick={() => openEditTemplate(row)}
                      className="rounded-xl border bg-card p-4 text-left shadow-sm transition-colors hover:border-primary focus-visible:border-primary focus-visible:outline-none"
                    >
                      <div className="flex items-center justify-between gap-2">
                        <span className="font-medium">{row.name}</span>
                        <Badge
                          variant="outline"
                          className={SMS_TEMPLATE_STATUS_BADGE_CLASSES[status]}
                        >
                          {SMS_TEMPLATE_STATUS_LABELS[status]}
                        </Badge>
                      </div>
                      <div className="mt-3 flex flex-col gap-1.5 text-sm">
                        <div className="flex justify-between gap-3">
                          <span className="text-muted-foreground">场景</span>
                          <span>{row.scene}</span>
                        </div>
                        <div className="flex justify-between gap-3">
                          <span className="text-muted-foreground">
                            模板 Code
                          </span>
                          <span className="font-mono text-xs">
                            {row.provider_code}
                          </span>
                        </div>
                        <div className="flex justify-between gap-3">
                          <span className="text-muted-foreground">更新时间</span>
                          <span className="text-muted-foreground">
                            {formatDateTime(row.updated_at)}
                          </span>
                        </div>
                      </div>
                    </button>
                  );
                })}
              </div>
            </>
          )}
        </CardContent>
      </Card>

      {/* 模板编辑 Sheet（桌面/移动统一右侧 35vw） */}
      <Sheet open={sheetOpen} onOpenChange={setSheetOpen}>
        <SheetContent
          side="right"
          className="w-[35vw] min-w-[320px] max-w-[480px]"
        >
          <SheetHeader>
            <SheetTitle>
              {templateForm.id ? "编辑短信模板" : "新增短信模板"}
            </SheetTitle>
            <SheetDescription>
              仅登记服务商后台已审核模板；模板 Code 为服务商控制台登记值
            </SheetDescription>
          </SheetHeader>
          <form
            className="flex flex-1 flex-col gap-4 px-4"
            onSubmit={(event) => {
              event.preventDefault();
              void handleSaveTemplate();
            }}
          >
            <Field>
              <FieldLabel htmlFor="sms-template-name">模板名称</FieldLabel>
              <Input
                id="sms-template-name"
                value={templateForm.name}
                onChange={(event) =>
                  setTemplateForm((prev) => ({
                    ...prev,
                    name: event.target.value,
                  }))
                }
                placeholder="如：登录验证码"
                autoComplete="off"
              />
            </Field>
            <Field>
              <FieldLabel htmlFor="sms-template-scene">使用场景</FieldLabel>
              <Input
                id="sms-template-scene"
                value={templateForm.scene}
                onChange={(event) =>
                  setTemplateForm((prev) => ({
                    ...prev,
                    scene: event.target.value,
                  }))
                }
                placeholder="如：login_code / approval_notice"
                autoComplete="off"
              />
            </Field>
            <Field>
              <FieldLabel htmlFor="sms-template-code">模板 Code</FieldLabel>
              <Input
                id="sms-template-code"
                value={templateForm.providerCode}
                onChange={(event) =>
                  setTemplateForm((prev) => ({
                    ...prev,
                    providerCode: event.target.value,
                  }))
                }
                placeholder="如：SMS_154950909"
                autoComplete="off"
                className="font-mono"
              />
            </Field>
            <Field>
              <FieldLabel htmlFor="sms-template-status">状态</FieldLabel>
              <Select
                value={templateForm.status}
                onValueChange={(value) =>
                  setTemplateForm((prev) => ({
                    ...prev,
                    status: asSmsTemplateStatus(value),
                  }))
                }
              >
                <SelectTrigger id="sms-template-status" className="w-full">
                  <SelectValue placeholder="选择状态" />
                </SelectTrigger>
                <SelectContent>
                  {SMS_TEMPLATE_STATUS_OPTIONS.map((option) => (
                    <SelectItem key={option.value} value={option.value}>
                      {option.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>

            <SheetFooter className="mt-auto px-0">
              {templateForm.id && templateForm.status === "active" ? (
                <Button
                  type="button"
                  variant="destructive"
                  onClick={() => void handleDisableTemplate()}
                  disabled={disablingTemplate || savingTemplate}
                  className="sm:mr-auto"
                >
                  {disablingTemplate ? (
                    <Loader2Icon
                      className="animate-spin"
                      data-icon="inline-start"
                    />
                  ) : (
                    <BanIcon data-icon="inline-start" />
                  )}
                  停用
                </Button>
              ) : null}
              <Button
                type="button"
                variant="outline"
                onClick={() => setSheetOpen(false)}
              >
                取消
              </Button>
              <Button type="submit" disabled={savingTemplate}>
                {savingTemplate ? (
                  <Loader2Icon
                    className="animate-spin"
                    data-icon="inline-start"
                  />
                ) : (
                  <MessageSquareIcon data-icon="inline-start" />
                )}
                保存
              </Button>
            </SheetFooter>
          </form>
        </SheetContent>
      </Sheet>
    </div>
  );
}
