"use client";

import * as React from "react";
import { Loader2Icon, SaveIcon, SendIcon } from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import {
  Field,
  FieldContent,
  FieldDescription,
  FieldLabel,
} from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { Switch } from "@/components/ui/switch";
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

type MailForm = {
  host: string;
  port: string;
  secure: boolean;
  username: string;
  password: string;
  fromAddr: string;
  fromName: string;
  replyTo: string;
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

const EMPTY_FORM: MailForm = {
  host: "",
  port: "587",
  secure: true,
  username: "",
  password: "",
  fromAddr: "",
  fromName: "",
  replyTo: "",
};

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const formatDateTime = (value: string) =>
  new Date(value).toLocaleString("zh-CN", { hour12: false });

const asText = (value: unknown): string => {
  if (value === null || value === undefined) {
    return "";
  }
  return typeof value === "string" ? value : String(value);
};

export function MailConfigForm() {
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [configured, setConfigured] = React.useState(false);
  const [form, setForm] = React.useState<MailForm>(EMPTY_FORM);
  const [credentialsMasked, setCredentialsMasked] = React.useState<
    string | null
  >(null);
  const [verifyStatus, setVerifyStatus] =
    React.useState<ServiceVerifyStatus>("unverified");
  const [verifiedAt, setVerifiedAt] = React.useState<string | null>(null);
  const [saving, setSaving] = React.useState(false);
  const [testing, setTesting] = React.useState(false);
  const [testTo, setTestTo] = React.useState("");

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

    const row = (data ?? []).find((item) => item.service === "mail");
    if (row) {
      const config = (row.config ?? {}) as Record<string, unknown>;
      setForm({
        host: asText(config.host),
        port: asText(config.port),
        secure: config.secure === true,
        username: asText(config.username),
        password: "",
        fromAddr: asText(config.from_addr),
        fromName: asText(config.from_name),
        replyTo: asText(config.reply_to),
      });
      setCredentialsMasked(row.credentials_masked ?? null);
      setVerifyStatus(asServiceVerifyStatus(row.verify_status));
      setVerifiedAt(
        typeof row.verified_at === "string" ? row.verified_at : null,
      );
      setConfigured(true);
    } else {
      setForm(EMPTY_FORM);
      setCredentialsMasked(null);
      setVerifyStatus("unverified");
      setVerifiedAt(null);
      setConfigured(false);
    }
    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const handleSave = async () => {
    const host = form.host.trim();
    const portText = form.port.trim();
    let port: number | null = null;
    if (portText !== "") {
      const parsed = Number(portText);
      if (!Number.isInteger(parsed) || parsed < 1 || parsed > 65535) {
        toast.error("端口需为 1-65535 的整数");
        return;
      }
      port = parsed;
    }

    const fromAddr = form.fromAddr.trim();
    if (fromAddr !== "" && !EMAIL_PATTERN.test(fromAddr)) {
      toast.error("发件邮箱格式不正确");
      return;
    }
    const replyTo = form.replyTo.trim();
    if (replyTo !== "" && !EMAIL_PATTERN.test(replyTo)) {
      toast.error("回复地址格式不正确");
      return;
    }

    const nextPassword = form.password;
    const wasVerified = verifyStatus === "verified";

    setSaving(true);
    const supabase = createClient();
    // 生成物未表达 text 参数可为 NULL（NULL=不修改凭据），运行时允许传 null
    const args = {
      p_service: "mail",
      p_config: {
        host,
        port,
        secure: form.secure,
        username: form.username.trim(),
        from_addr: fromAddr,
        from_name: form.fromName.trim(),
        reply_to: replyTo,
      },
      p_credentials: nextPassword === "" ? null : nextPassword,
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
    if (nextPassword !== "") {
      // 掩码只采用 RPC 返回值（≤8 位全掩码由服务端判定），不做本地拼接
      const { data: statusRows } = await supabase.rpc("get_service_status");
      const mailStatus = (statusRows ?? []).find(
        (item) => item.service === "mail",
      );
      setCredentialsMasked(mailStatus?.credentials_masked ?? "****");
      setForm((prev) => ({ ...prev, password: "" }));
    }

    toast.success("邮件配置已保存");
    if (wasVerified && nextStatus === "unverified") {
      toast.info("配置内容已变更，验证状态已降为「待验证」，请重新测试验证");
    }
  };

  const handleTest = async () => {
    const to = testTo.trim();
    if (to === "") {
      toast.error("请输入测试收件邮箱");
      return;
    }

    setTesting(true);
    const supabase = createClient();
    const { data, error: testError } = await supabase.rpc(
      "test_mail_config",
      { p_to: to },
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
    } else {
      toast.error(result?.message ?? "配置校验未通过");
    }
  };

  if (loading) {
    return (
      <div className="flex flex-col gap-2 p-0 md:p-6">
        <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
          <CardContent className="flex flex-col gap-4 p-4 md:p-6">
            <div className="grid gap-4 lg:grid-cols-2">
              {Array.from({ length: 6 }).map((_, index) => (
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
                <FieldLabel htmlFor="mail-host">SMTP 主机</FieldLabel>
                <Input
                  id="mail-host"
                  value={form.host}
                  onChange={(event) =>
                    setForm((prev) => ({ ...prev, host: event.target.value }))
                  }
                  placeholder="smtp.example.com"
                  autoComplete="off"
                  className="h-11 lg:h-8"
                />
              </Field>
              <Field>
                <FieldLabel htmlFor="mail-port">端口</FieldLabel>
                <Input
                  id="mail-port"
                  inputMode="numeric"
                  value={form.port}
                  onChange={(event) =>
                    setForm((prev) => ({ ...prev, port: event.target.value }))
                  }
                  placeholder="587"
                  autoComplete="off"
                  className="h-11 lg:h-8"
                />
                <FieldDescription>
                  常用：587（STARTTLS）/ 465（SSL）
                </FieldDescription>
              </Field>

              <Field
                orientation="horizontal"
                className="rounded-lg border p-3 lg:col-span-2"
              >
                <FieldContent>
                  <FieldLabel htmlFor="mail-secure">
                    使用 SSL/TLS 加密连接
                  </FieldLabel>
                  <FieldDescription>
                    465 端口通常开启（隐式 SSL）；587 端口配合 STARTTLS 时也可开启
                  </FieldDescription>
                </FieldContent>
                <Switch
                  id="mail-secure"
                  checked={form.secure}
                  onCheckedChange={(checked) =>
                    setForm((prev) => ({ ...prev, secure: checked }))
                  }
                />
              </Field>

              <Field>
                <FieldLabel htmlFor="mail-username">账号</FieldLabel>
                <Input
                  id="mail-username"
                  value={form.username}
                  onChange={(event) =>
                    setForm((prev) => ({
                      ...prev,
                      username: event.target.value,
                    }))
                  }
                  placeholder="mailer@example.com"
                  autoComplete="off"
                  className="h-11 lg:h-8"
                />
              </Field>
              <Field>
                <FieldLabel htmlFor="mail-password">密码 / 授权码</FieldLabel>
                <Input
                  id="mail-password"
                  type="password"
                  value={form.password}
                  onChange={(event) =>
                    setForm((prev) => ({
                      ...prev,
                      password: event.target.value,
                    }))
                  }
                  placeholder={
                    credentialsMasked
                      ? `已保存 ${credentialsMasked}，留空不修改`
                      : "SMTP 密码或授权码"
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

              <Field>
                <FieldLabel htmlFor="mail-from-addr">发件邮箱</FieldLabel>
                <Input
                  id="mail-from-addr"
                  type="email"
                  value={form.fromAddr}
                  onChange={(event) =>
                    setForm((prev) => ({
                      ...prev,
                      fromAddr: event.target.value,
                    }))
                  }
                  placeholder="noreply@example.com"
                  autoComplete="off"
                  className="h-11 lg:h-8"
                />
              </Field>
              <Field>
                <FieldLabel htmlFor="mail-from-name">发件人名称</FieldLabel>
                <Input
                  id="mail-from-name"
                  value={form.fromName}
                  onChange={(event) =>
                    setForm((prev) => ({
                      ...prev,
                      fromName: event.target.value,
                    }))
                  }
                  placeholder="企业管理系统"
                  autoComplete="off"
                  className="h-11 lg:h-8"
                />
              </Field>
              <Field className="lg:col-span-2">
                <FieldLabel htmlFor="mail-reply-to">回复地址（可选）</FieldLabel>
                <Input
                  id="mail-reply-to"
                  type="email"
                  value={form.replyTo}
                  onChange={(event) =>
                    setForm((prev) => ({ ...prev, replyTo: event.target.value }))
                  }
                  placeholder="support@example.com"
                  autoComplete="off"
                  className="h-11 lg:h-8"
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
                {`测试验证 = 校验配置完整性（host / port / username）；真实发送验证将在 Edge Function 投递器上线后启用。`}
              </p>
              <div className="flex flex-col gap-2 sm:flex-row">
                <Input
                  type="email"
                  value={testTo}
                  onChange={(event) => setTestTo(event.target.value)}
                  placeholder="测试收件邮箱，如 you@example.com"
                  aria-label="测试收件邮箱"
                  autoComplete="off"
                  disabled={!configured}
                  className="h-11 sm:max-w-xs lg:h-8"
                />
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
                    <SendIcon data-icon="inline-start" />
                  )}
                  测试验证
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
    </div>
  );
}
