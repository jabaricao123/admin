"use client";

// 系统管理 · 密码登录全局开关（工单 im/006）
//
// 存储：system_settings.password_login_enabled（bool）/
//       system_settings.password_login_admin_emails（json 邮箱数组，应急名单）。
// 语义：关闭后 /login 不显示密码 Tab；应急管理员经 /login?admin=1 使用密码登录，
//       且仅「名单内 + role=admin + status=active」的账号放行（im_password_login_allowed）。

import * as React from "react";
import { KeyRoundIcon, SaveIcon, ShieldAlertIcon } from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardAction,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Field, FieldDescription, FieldLabel } from "@/components/ui/field";
import { Skeleton } from "@/components/ui/skeleton";
import { Switch } from "@/components/ui/switch";
import { Textarea } from "@/components/ui/textarea";
import { InfoHint } from "@/components/info-hint";
import { createClient } from "@/lib/supabase/client";

const ENABLED_KEY = "password_login_enabled";
const EMAILS_KEY = "password_login_admin_emails";
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const ENABLED_DESCRIPTION = "密码登录全局开关：关闭后 /login 隐藏密码 Tab（应急管理员除外）";
const EMAILS_DESCRIPTION =
  "密码登录应急管理员邮箱（json 数组，小写）；关闭开关后仅名单内且 role=admin / status=active 的账号可密码登录";

function parseEmails(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value
    .filter((item): item is string => typeof item === "string")
    .map((item) => item.trim().toLowerCase())
    .filter((item) => item !== "");
}

export function PasswordLoginPanel() {
  const [loading, setLoading] = React.useState(true);
  const [enabled, setEnabled] = React.useState(true);
  const [emailsText, setEmailsText] = React.useState("");
  const [saving, setSaving] = React.useState(false);

  const load = React.useCallback(async () => {
    setLoading(true);
    const supabase = createClient();
    const { data, error } = await supabase.rpc("get_all_settings");
    if (error) {
      toast.error(`读取密码登录设置失败：${error.message}`);
      setLoading(false);
      return;
    }
    const rows = data ?? [];
    const enabledRow = rows.find((row) => row.key === ENABLED_KEY);
    const emailsRow = rows.find((row) => row.key === EMAILS_KEY);
    setEnabled(enabledRow ? enabledRow.value === true : true);
    setEmailsText(parseEmails(emailsRow?.value).join("\n"));
    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const handleSave = async () => {
    const emails = Array.from(
      new Set(
        emailsText
          .split(/[\n,，;；\s]+/)
          .map((item) => item.trim().toLowerCase())
          .filter((item) => item !== ""),
      ),
    );
    const invalid = emails.filter((email) => !EMAIL_PATTERN.test(email));
    if (invalid.length > 0) {
      toast.error(`应急管理员邮箱格式不正确：${invalid.join("、")}`);
      return;
    }
    if (!enabled && emails.length === 0) {
      toast.error("关闭密码登录前，请至少填写一名应急管理员邮箱（否则将无人能密码登录）");
      return;
    }

    setSaving(true);
    const supabase = createClient();
    const [enabledResult, emailsResult] = await Promise.all([
      supabase.rpc("upsert_setting", {
        p_key: ENABLED_KEY,
        p_value: enabled,
        p_group_name: "安全",
        p_value_type: "bool",
        p_description: ENABLED_DESCRIPTION,
      }),
      supabase.rpc("upsert_setting", {
        p_key: EMAILS_KEY,
        p_value: emails,
        p_group_name: "安全",
        p_value_type: "json",
        p_description: EMAILS_DESCRIPTION,
      }),
    ]);
    setSaving(false);

    const error = enabledResult.error ?? emailsResult.error;
    if (error) {
      toast.error(`保存失败：${error.message}`);
      return;
    }
    setEmailsText(emails.join("\n"));
    toast.success(
      enabled
        ? "密码登录已开启"
        : "密码登录已关闭：登录页仅显示扫码入口，应急管理员可用 /login?admin=1",
    );
  };

  if (loading) {
    return (
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardHeader>
          <Skeleton className="h-5 w-32" />
          <Skeleton className="h-4 w-80" />
        </CardHeader>
        <CardContent className="flex flex-col gap-3">
          <Skeleton className="h-11 w-full lg:h-8" />
          <Skeleton className="h-24 w-full" />
        </CardContent>
      </Card>
    );
  }

  return (
    <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card gap-3! py-3!">
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <KeyRoundIcon className="size-4 text-muted-foreground" />
          密码登录
          <InfoHint>
            全局开关：关闭后普通用户在 /login 看不到密码 Tab，仅保留扫码登录入口。
          </InfoHint>
        </CardTitle>
        <CardAction>
          {enabled ? (
            <Badge
              variant="outline"
              className="border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300"
            >
              已开启
            </Badge>
          ) : (
            <Badge
              variant="outline"
              className="border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300"
            >
              已关闭
            </Badge>
          )}
        </CardAction>
      </CardHeader>
      <CardContent className="flex flex-col gap-4 p-4 md:p-6">
        <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg border p-3">
          <div className="flex items-start gap-2">
            <ShieldAlertIcon className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
            <div className="flex flex-col gap-0.5">
              <span className="text-sm font-medium">允许密码登录</span>
              <span className="text-xs text-muted-foreground">
                关闭后 /login 隐藏密码 Tab；应急管理员可在 /login?admin=1 使用密码登录
              </span>
            </div>
          </div>
          <Switch
            checked={enabled}
            aria-label="允许密码登录"
            onCheckedChange={setEnabled}
          />
        </div>

        <Field>
          <FieldLabel htmlFor="password-login-emails">
            应急管理员邮箱（每行一个）
          </FieldLabel>
          <Textarea
            id="password-login-emails"
            value={emailsText}
            rows={3}
            placeholder={"admin@example.com\nops@example.com"}
            onChange={(event) => setEmailsText(event.target.value)}
          />
          <FieldDescription>
            仅当邮箱对应账号是 active 管理员时才会放行；名单内非管理员不会生效。
          </FieldDescription>
        </Field>

        <div>
          <Button
            type="button"
            size="sm"
            className="h-11 lg:h-8"
            disabled={saving}
            onClick={() => void handleSave()}
          >
            <SaveIcon data-icon="inline-start" />
            {saving ? "保存中…" : "保存密码登录设置"}
          </Button>
        </div>
      </CardContent>
    </Card>
  );
}
