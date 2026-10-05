"use client";

// 系统管理 · 消息推送配置（工单 system/004 页面）
//
// 数据：get_push_status（admin，双渠道脱敏读取）、upsert_push_channel（单渠道保存）、
//       test_push_config（配置完整性校验，真实推送待通道接入）。
// 契约（docs/modules/system/services-push.md）：双卡片各自配置与测试；未配置渠道置灰；
//       页面顶部预留 Banner；secret 加密存储、界面仅掩码（留空不修改）。

import * as React from "react";
import {
  BellRingIcon,
  InfoIcon,
  Loader2Icon,
  SaveIcon,
  SendIcon,
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
import {
  Field,
  FieldContent,
  FieldDescription,
  FieldLabel,
} from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { Switch } from "@/components/ui/switch";
import { InfoHint } from "@/components/info-hint";
import type { Database } from "@/lib/database.types";
import {
  asServiceVerifyStatus,
  PUSH_CHANNEL_DESCRIPTIONS,
  PUSH_CHANNEL_LABELS,
  SERVICE_VERIFY_STATUS_BADGE_CLASSES,
  SERVICE_VERIFY_STATUS_LABELS,
  translateSystemErrorMessage,
  type PushChannel,
  type ServiceVerifyStatus,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type PushStatusRow =
  Database["public"]["Functions"]["get_push_status"]["Returns"][number];
type UpsertPushArgs =
  Database["public"]["Functions"]["upsert_push_channel"]["Args"];

type ChannelForm = {
  webhookUrl: string;
  secret: string;
  enabled: boolean;
  configured: boolean;
  secretMasked: string | null;
};

type UpsertResult = {
  channel?: string;
  config?: Record<string, unknown> | null;
  verify_status?: string;
  verified_at?: string | null;
};

type TestResult = {
  ok?: boolean;
  message?: string;
  channel?: string;
  verify_status?: string;
  verified_at?: string | null;
};

const CHANNELS: PushChannel[] = ["wecom", "dingtalk"];

const EMPTY_FORMS: Record<PushChannel, ChannelForm> = {
  wecom: {
    webhookUrl: "",
    secret: "",
    enabled: false,
    configured: false,
    secretMasked: null,
  },
  dingtalk: {
    webhookUrl: "",
    secret: "",
    enabled: false,
    configured: false,
    secretMasked: null,
  },
};

const asText = (value: unknown): string => {
  if (value === null || value === undefined) {
    return "";
  }
  return typeof value === "string" ? value : String(value);
};

const formatDateTime = (value: string) =>
  new Date(value).toLocaleString("zh-CN", { hour12: false });

/** 与服务端掩码规则一致：**** + 明文尾 4 位 */
const maskSecret = (secret: string): string => `****${secret.slice(-4)}`;

export function PushConfigPanel() {
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [forms, setForms] =
    React.useState<Record<PushChannel, ChannelForm>>(EMPTY_FORMS);
  const [verifyStatus, setVerifyStatus] =
    React.useState<ServiceVerifyStatus>("unverified");
  const [verifiedAt, setVerifiedAt] = React.useState<string | null>(null);
  const [savingChannel, setSavingChannel] = React.useState<PushChannel | null>(
    null,
  );
  const [testingChannel, setTestingChannel] = React.useState<PushChannel | null>(
    null,
  );

  const load = React.useCallback(async () => {
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const { data, error: loadError } = await supabase.rpc("get_push_status");

    if (loadError) {
      setError(loadError.message);
      setLoading(false);
      return;
    }

    const rows = (data ?? []) as PushStatusRow[];
    const next = { ...EMPTY_FORMS };
    for (const channel of CHANNELS) {
      const row = rows.find((item) => item.channel === channel);
      const webhookUrl = asText(row?.webhook_url);
      next[channel] = {
        webhookUrl,
        secret: "",
        enabled: row?.enabled === true,
        configured: webhookUrl !== "",
        secretMasked: row?.secret_masked ?? null,
      };
    }
    setForms(next);

    const { data: statusData } = await supabase.rpc("get_service_status");
    const pushRow = (statusData ?? []).find((item) => item.service === "push");
    setVerifyStatus(asServiceVerifyStatus(pushRow?.verify_status ?? ""));
    setVerifiedAt(
      typeof pushRow?.verified_at === "string" ? pushRow.verified_at : null,
    );

    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const patchForm = (channel: PushChannel, patch: Partial<ChannelForm>) => {
    setForms((prev) => ({ ...prev, [channel]: { ...prev[channel], ...patch } }));
  };

  const handleSave = async (channel: PushChannel) => {
    const form = forms[channel];
    const webhookUrl = form.webhookUrl.trim();
    if (form.enabled && webhookUrl === "") {
      toast.error("启用该渠道前请先填写 Webhook URL");
      return;
    }

    setSavingChannel(channel);
    const supabase = createClient();
    // 生成物未表达 text 参数可为 NULL（NULL=不修改 secret），运行时允许传 null
    const args = {
      p_channel: channel,
      p_webhook_url: webhookUrl,
      p_secret: form.secret === "" ? null : form.secret,
      p_enabled: form.enabled,
    };
    const { data, error: saveError } = await supabase.rpc(
      "upsert_push_channel",
      args as UpsertPushArgs,
    );
    setSavingChannel(null);

    if (saveError) {
      toast.error(translateSystemErrorMessage(saveError.message));
      return;
    }

    const result = (data ?? null) as UpsertResult | null;
    const channelConfig = (result?.config?.[channel] ?? null) as {
      webhook_url?: unknown;
      enabled?: unknown;
    } | null;
    patchForm(channel, {
      webhookUrl: asText(channelConfig?.webhook_url ?? webhookUrl),
      enabled: channelConfig?.enabled === true,
      configured: asText(channelConfig?.webhook_url ?? webhookUrl) !== "",
      secret: "",
      secretMasked:
        form.secret === "" ? form.secretMasked : maskSecret(form.secret),
    });
    setVerifyStatus(asServiceVerifyStatus(result?.verify_status ?? ""));
    setVerifiedAt(
      typeof result?.verified_at === "string" ? result.verified_at : null,
    );

    toast.success(`${PUSH_CHANNEL_LABELS[channel]}配置已保存`);
    if (result?.verify_status === "unverified") {
      toast.info("配置内容已变更，验证状态已降为「待验证」，请重新测试");
    }
  };

  const handleTest = async (channel: PushChannel) => {
    setTestingChannel(channel);
    const supabase = createClient();
    const { data, error: testError } = await supabase.rpc("test_push_config", {
      p_channel: channel,
    });
    setTestingChannel(null);

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
      <div className="flex flex-col gap-0.5 p-0 md:p-6">
        <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
          <CardHeader>
            <Skeleton className="h-5 w-24" />
            <Skeleton className="h-4 w-72 max-w-full" />
          </CardHeader>
          <CardContent className="grid gap-4 p-4 md:p-6 lg:grid-cols-2">
            {Array.from({ length: 2 }).map((_, index) => (
              <Skeleton key={index} className="h-64 w-full" />
            ))}
          </CardContent>
        </Card>
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex flex-col gap-0.5 p-0 md:p-6">
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
    <div className="flex flex-col gap-0.5 p-0 md:p-6">
      {/* 预留状态 Banner（services-push.md：推送通道为预留能力） */}
      <div className="flex items-start gap-2 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-200">
        <InfoIcon className="mt-0.5 size-4 shrink-0" />
        <p>
          推送通道为预留能力，接入后自动启用。当前「测试推送」仅校验配置完整性，
          不会真实发送消息；真实推送待 Webhook 通道接入后生效，推送失败不影响站内信与邮件主渠道。
        </p>
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        {CHANNELS.map((channel) => {
          const form = forms[channel];
          const saving = savingChannel === channel;
          const testing = testingChannel === channel;
          return (
            <Card
              key={channel}
              className="rounded-none border-0 md:rounded-xl md:border md:@container/card gap-3! py-3!"
            >
              <CardHeader>
                <CardTitle className="flex items-center gap-2">
                  <BellRingIcon className="size-4 text-muted-foreground" />
                  {PUSH_CHANNEL_LABELS[channel]}
                  <InfoHint>{PUSH_CHANNEL_DESCRIPTIONS[channel]}</InfoHint>
                </CardTitle>
              </CardHeader>
              <CardContent className="flex flex-col gap-4 p-4 md:p-6">
                <Field>
                  <FieldLabel htmlFor={`push-${channel}-url`}>
                    Webhook URL
                  </FieldLabel>
                  <Input
                    id={`push-${channel}-url`}
                    value={form.webhookUrl}
                    onChange={(event) =>
                      patchForm(channel, { webhookUrl: event.target.value })
                    }
                    placeholder={
                      channel === "wecom"
                        ? "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=..."
                        : "https://oapi.dingtalk.com/robot/send?access_token=..."
                    }
                    autoComplete="off"
                    className="h-11 lg:h-8"
                  />
                </Field>

                <Field>
                  <FieldLabel htmlFor={`push-${channel}-secret`}>
                    Secret（可选）
                  </FieldLabel>
                  <Input
                    id={`push-${channel}-secret`}
                    type="password"
                    value={form.secret}
                    onChange={(event) =>
                      patchForm(channel, { secret: event.target.value })
                    }
                    placeholder={
                      form.secretMasked
                        ? `已保存 ${form.secretMasked}，留空不修改`
                        : "加签 Secret（钉钉加签机器人需填写）"
                    }
                    autoComplete="new-password"
                    className="h-11 lg:h-8"
                  />
                  <FieldDescription>
                    {form.secretMasked
                      ? `已保存凭据 ${form.secretMasked}；留空表示不修改，输入新值将整体替换`
                      : "当前未配置 Secret；保存后加密存储，不回显明文"}
                  </FieldDescription>
                </Field>

                <Field
                  orientation="horizontal"
                  className="rounded-lg border p-3"
                >
                  <FieldContent>
                    <FieldLabel htmlFor={`push-${channel}-enabled`}>
                      启用该渠道
                    </FieldLabel>
                    <FieldDescription>
                      启用前需填写 Webhook URL；停用渠道不参与消息推送
                    </FieldDescription>
                  </FieldContent>
                  <Switch
                    id={`push-${channel}-enabled`}
                    checked={form.enabled}
                    onCheckedChange={(checked) =>
                      patchForm(channel, { enabled: checked })
                    }
                  />
                </Field>

                <div className="flex flex-col gap-2 sm:flex-row sm:justify-end">
                  <Button
                    type="button"
                    variant="outline"
                    onClick={() => void handleTest(channel)}
                    disabled={testing || saving || !form.configured}
                    className="h-8"
                  >
                    {testing ? (
                      <Loader2Icon
                        className="animate-spin"
                        data-icon="inline-start"
                      />
                    ) : (
                      <SendIcon data-icon="inline-start" />
                    )}
                    测试推送
                  </Button>
                  <Button
                    type="button"
                    onClick={() => void handleSave(channel)}
                    disabled={saving || testing}
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
                    保存
                  </Button>
                </div>

                {!form.configured ? (
                  <p className="text-xs text-muted-foreground">
                    该渠道尚未配置 Webhook URL，「测试推送」暂不可用。
                  </p>
                ) : null}
              </CardContent>
            </Card>
          );
        })}
      </div>

      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-wrap items-center gap-2 p-4 md:p-6">
          <span className="text-sm font-medium">推送通道验证状态</span>
          <Badge
            variant="outline"
            className={SERVICE_VERIFY_STATUS_BADGE_CLASSES[verifyStatus]}
          >
            {SERVICE_VERIFY_STATUS_LABELS[verifyStatus]}
          </Badge>
          <span className="text-xs text-muted-foreground">
            {verifiedAt
              ? `最近验证：${formatDateTime(verifiedAt)}`
              : "尚未测试验证（测试结果为整个推送服务的状态）"}
          </span>
        </CardContent>
      </Card>
    </div>
  );
}
