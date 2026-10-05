"use client";

// 个人中心 · IM 账号绑定（工单 im/006）
//
// 自助绑定：点「扫码绑定 <当前启用厂商>」→ /settings/profile/bind/<provider>/start
// （OAuth 授权 → 回调内调 public.im_bind_self 写本人绑定，见同目录 bind/）。
// 不提供解绑入口（ADR-003 §2：仅 admin 可在用户管理解绑）。

import * as React from "react";
import {
  BadgeCheckIcon,
  CopyIcon,
  QrCodeIcon,
  ShieldAlertIcon,
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
import { InfoHint } from "@/components/info-hint";
import { BANNED_ACCOUNT_MESSAGE } from "@/lib/dictionaries";

type ProviderId = "feishu" | "wecom" | "dingtalk";

type ProviderMeta = { id: ProviderId; label: string };

const PROVIDERS: ProviderMeta[] = [
  { id: "feishu", label: "飞书" },
  { id: "wecom", label: "企业微信" },
  { id: "dingtalk", label: "钉钉" },
];

const BIND_ERROR_MESSAGES: Record<string, string> = {
  im_bound_other: "该 IM 账号已绑定其他用户，请联系管理员处理（不会自动改绑）。",
  im_state_invalid: "绑定请求已失效，请重新扫码。",
  im_denied: "已取消授权。",
  im_unavailable: "当前未启用该厂商扫码，请选择已启用的厂商。",
  im_banned: BANNED_ACCOUNT_MESSAGE,
  im_failed: "绑定失败，请稍后重试或联系管理员。",
};

export function ProfileImBinding({
  bindings,
  enabledProvider,
  adminContact,
  boundProvider,
  errorCode,
}: {
  bindings: Record<ProviderId, string | null>;
  enabledProvider: string | null;
  adminContact: string;
  boundProvider: string | null;
  errorCode: string | null;
}) {
  const enabledMeta = PROVIDERS.find(
    (provider) => provider.id === enabledProvider,
  );

  const copyContact = async () => {
    try {
      await navigator.clipboard.writeText(adminContact);
      toast.success("管理员联系方式已复制");
    } catch {
      toast.error("复制失败，请手动选择复制");
    }
  };

  return (
    <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card gap-3! py-3!">
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <QrCodeIcon className="size-4 text-muted-foreground" />
          IM 账号绑定
          <InfoHint>
            绑定后可用已启用厂商扫码 / App 内免登进入系统；解绑仅管理员可操作。
          </InfoHint>
        </CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-4 p-4 md:p-6">
        {boundProvider ? (
          <div className="flex items-start gap-2 rounded-lg border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-800 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-200">
            <BadgeCheckIcon className="mt-0.5 size-4 shrink-0" />
            <p>
              已绑定
              {PROVIDERS.find((provider) => provider.id === boundProvider)
                ?.label ?? boundProvider}
              账号，下次可直接扫码 / 免登进入系统。
            </p>
          </div>
        ) : null}

        {errorCode ? (
          <div className="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-200">
            <ShieldAlertIcon className="mt-0.5 size-4 shrink-0" />
            <p>
              {BIND_ERROR_MESSAGES[errorCode] ?? BIND_ERROR_MESSAGES.im_failed}
            </p>
          </div>
        ) : null}

        {enabledMeta ? (
          <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-primary/40 bg-primary/5 p-3">
            <div className="flex flex-col gap-0.5">
              <span className="text-sm font-medium">
                当前启用：{enabledMeta.label}
              </span>
              <span className="text-xs text-muted-foreground">
                {bindings[enabledMeta.id]
                  ? "已绑定，可重新扫码换绑本人账号"
                  : `使用${enabledMeta.label} App 扫码，将你的账号绑定到当前登录用户`}
              </span>
            </div>
            <Button asChild className="h-11 lg:h-8">
              <a href={`/settings/profile/bind/${enabledMeta.id}/start`}>
                <QrCodeIcon data-icon="inline-start" />
                {bindings[enabledMeta.id] ? "重新扫码绑定" : "扫码绑定"}
              </a>
            </Button>
          </div>
        ) : (
          <div className="rounded-lg border p-3 text-sm text-muted-foreground">
            当前未启用任何扫码登录，请联系管理员在「身份认证」页启用厂商。
          </div>
        )}

        <div className="flex flex-col gap-2">
          {PROVIDERS.map((provider) => {
            const userid = bindings[provider.id];
            const active = provider.id === enabledProvider;
            return (
              <div
                key={provider.id}
                className="flex flex-wrap items-center justify-between gap-2 rounded-lg border p-3 text-sm"
              >
                <span className="flex items-center gap-2">
                  <span className={active ? "font-medium" : "text-muted-foreground"}>
                    {provider.label}
                  </span>
                  {active ? (
                    <Badge
                      variant="outline"
                      className="border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300"
                    >
                      当前启用
                    </Badge>
                  ) : null}
                </span>
                {userid ? (
                  <span className="font-mono text-xs break-all">{userid}</span>
                ) : (
                  <span className="text-xs text-muted-foreground">未绑定</span>
                )}
              </div>
            );
          })}
        </div>

        <div className="flex flex-wrap items-center justify-between gap-2 rounded-lg border bg-muted/40 p-3 text-xs text-muted-foreground">
          <span>需要解绑或录入他人绑定？联系管理员在「用户管理」处理。</span>
          {adminContact ? (
            <span className="flex items-center gap-2">
              <span className="font-mono break-all">{adminContact}</span>
              <Button
                type="button"
                variant="outline"
                size="sm"
                className="h-11 lg:h-8"
                onClick={() => void copyContact()}
              >
                <CopyIcon data-icon="inline-start" />
                复制
              </Button>
            </span>
          ) : null}
        </div>
      </CardContent>
    </Card>
  );
}
