"use client";

// 系统管理 · 身份认证（工单 system/006 页面 + im/006 扩展）
//
// im/006 起本页上半部分为可编辑区：IM 扫码登录（三家配置 / 启用切换 / 测试连接 / 清空绑定）
// 与密码登录全局开关（含管理员联系方式），均由 im/006 数据面 RPC 支撑并写 audit；
// 下半部分保持 system/006 契约：Supabase Auth 控制台项（密码策略 / 会话时长 / OAuth 提供商 /
// 回调 URL）纯展示 + 控制台引导，标注「外部管理」。
// 回调 URL 以 window.location.origin 推导（复制按钮），本地/云端模式由 NEXT_PUBLIC_SUPABASE_URL 推导。

import * as React from "react";
import {
  CopyIcon,
  ExternalLinkIcon,
  FingerprintIcon,
  GlobeIcon,
  KeyRoundIcon,
  ShieldCheckIcon,
} from "lucide-react";
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
import { Separator } from "@/components/ui/separator";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

import { InfoHint } from "@/components/info-hint";
import { ImConfigPanel } from "@/components/system/im-config-panel";
import { PasswordLoginPanel } from "@/components/system/password-login-panel";

const EXTERNAL_BADGE_CLASS =
  "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300";

/** 静态 OAuth 提供商清单（真源在控制台，本页不读 Admin API） */
const OAUTH_PROVIDERS: { name: string; note: string }[] = [
  { name: "Google", note: "控制台填写 Client ID / Client Secret 后启用" },
  { name: "GitHub", note: "控制台填写 OAuth App 凭据后启用" },
  { name: "Apple", note: "需 Apple Developer 配置 Service ID 与密钥" },
  { name: "微信（WeChat）", note: "需微信开放平台审核应用后配置" },
];

type AuthConsoleInfo = {
  origin: string | null;
  isLocal: boolean;
  projectRef: string;
  consoleBase: string;
};

function resolveConsoleInfo(): Omit<AuthConsoleInfo, "origin"> {
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
  try {
    const url = new URL(supabaseUrl);
    const isLocal =
      url.hostname === "127.0.0.1" ||
      url.hostname === "localhost" ||
      url.protocol === "http:";
    if (isLocal) {
      return {
        isLocal: true,
        projectRef: "local",
        consoleBase: "http://127.0.0.1:54323/project/default",
      };
    }
    const projectRef = url.hostname.split(".")[0] ?? "";
    return {
      isLocal: false,
      projectRef,
      consoleBase: projectRef
        ? `https://supabase.com/dashboard/project/${projectRef}`
        : "https://supabase.com/dashboard",
    };
  } catch {
    return {
      isLocal: false,
      projectRef: "",
      consoleBase: "https://supabase.com/dashboard",
    };
  }
}

function ExternalBadge() {
  return (
    <Badge variant="outline" className={EXTERNAL_BADGE_CLASS}>
      外部管理
    </Badge>
  );
}

function ConsoleLink({ href, label }: { href: string; label: string }) {
  return (
    <Button variant="outline" size="sm" asChild className="h-11 lg:h-8">
      <a href={href} target="_blank" rel="noopener noreferrer">
        <ExternalLinkIcon data-icon="inline-start" />
        {label}
      </a>
    </Button>
  );
}

export function AuthInfoPanel() {
  const [origin, setOrigin] = React.useState<string | null>(null);
  const consoleInfo = React.useMemo(resolveConsoleInfo, []);

  React.useEffect(() => {
    setOrigin(window.location.origin);
  }, []);

  const copy = async (value: string, label: string) => {
    try {
      await navigator.clipboard.writeText(value);
      toast.success(`${label}已复制`);
    } catch {
      toast.error("复制失败，请手动选择复制");
    }
  };

  const callbackUrls = origin
    ? [
        { label: "站点 URL", value: origin },
        { label: "OAuth 授权回调", value: `${origin}/auth/callback` },
        { label: "IM 绑定回调（飞书）", value: `${origin}/settings/profile/bind/feishu/callback` },
        { label: "IM 绑定回调（企业微信）", value: `${origin}/settings/profile/bind/wecom/callback` },
        { label: "IM 绑定回调（钉钉）", value: `${origin}/settings/profile/bind/dingtalk/callback` },
        { label: "邮件确认 / 密码重置", value: `${origin}/auth/confirm` },
        { label: "开发期通配", value: `${origin}/**` },
      ]
    : [];

  return (
    <div className="flex flex-col gap-0.5 p-0 md:p-6">
      <InfoHint className="size-5">
        上半部分「IM 扫码登录 / 密码登录 / 管理员联系方式」在本页直接配置并即时生效
        （所有敏感操作写入审计）。下半部分为 Supabase Auth 控制台项的只读参考，
        带「外部管理」标注。
      </InfoHint>

      {/* IM 扫码登录配置（im/006） */}
      <ImConfigPanel />

      {/* 密码登录开关（im/006） */}
      <PasswordLoginPanel />

      <InfoHint className="size-5">
        以下为 Supabase Auth 控制台项只读展示：真源在控制台，本页不改这些项的运行时行为，
        避免与 Supabase 控制台双写冲突。
      </InfoHint>

      {/* 站点与会话概览 */}
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card gap-3! py-3!">
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <GlobeIcon className="size-4 text-muted-foreground" />
            站点与会话概览
            <InfoHint>
              当前部署的站点地址与 Supabase Auth 会话策略摘要
            </InfoHint>
            <ExternalBadge />
          </CardTitle>
          <CardAction>
            <ConsoleLink
              href={`${consoleInfo.consoleBase}/settings/api`}
              label="在 Supabase 控制台打开"
            />
          </CardAction>
        </CardHeader>
        <CardContent className="flex flex-col gap-3 p-4 text-sm md:p-6">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <span className="text-muted-foreground">运行模式</span>
            <Badge variant="outline">
              {consoleInfo.isLocal ? "本地 Supabase" : "云端 Supabase"}
            </Badge>
          </div>
          <Separator />
          <div className="flex flex-wrap items-center justify-between gap-2">
            <span className="text-muted-foreground">站点 URL</span>
            <span className="flex items-center gap-2">
              <span className="font-mono text-xs">
                {origin ?? "加载中…"}
              </span>
              {origin ? (
                <Button
                  type="button"
                  variant="ghost"
                  size="icon"
                  className="size-8"
                  aria-label="复制站点 URL"
                  onClick={() => void copy(origin, "站点 URL")}
                >
                  <CopyIcon className="size-3.5" />
                </Button>
              ) : null}
            </span>
          </div>
          <Separator />
          <div className="flex flex-wrap items-center justify-between gap-2">
            <span className="text-muted-foreground">Supabase 项目</span>
            <span className="font-mono text-xs">
              {consoleInfo.projectRef || "未配置"}
            </span>
          </div>
          <Separator />
          <div className="flex flex-col gap-1 text-xs text-muted-foreground">
            <p>
              JWT 有效期：默认 3600 秒（1 小时）；Refresh Token 有效期：默认 30 天。
            </p>
            <p>
              实际值以控制台「Project Settings → API → JWT Settings」为准，本页为静态说明。
            </p>
          </div>
        </CardContent>
      </Card>

      {/* 密码策略 */}
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card gap-3! py-3!">
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <KeyRoundIcon className="size-4 text-muted-foreground" />
            密码策略
            <InfoHint>
              用户密码规则由 Supabase Auth 控制台统一管理，本页只读展示默认说明
            </InfoHint>
            <ExternalBadge />
          </CardTitle>
          <CardAction>
            <ConsoleLink
              href={`${consoleInfo.consoleBase}/auth/settings`}
              label="在 Supabase 控制台打开"
            />
          </CardAction>
        </CardHeader>
        <CardContent className="flex flex-col gap-3 p-4 text-sm md:p-6">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <span className="text-muted-foreground">密码最小长度</span>
            <span>6 位（Supabase 默认）</span>
          </div>
          <Separator />
          <div className="flex flex-wrap items-center justify-between gap-2">
            <span className="text-muted-foreground">复杂度要求</span>
            <span>默认无额外强制（建议控制台开启大小写 / 数字 / 符号要求）</span>
          </div>
          <Separator />
          <div className="flex flex-wrap items-center justify-between gap-2">
            <span className="text-muted-foreground">修改指引</span>
            <span className="text-muted-foreground">
              在控制台「Authentication → Settings」修改，保存后即时生效，无需重启应用
            </span>
          </div>
        </CardContent>
      </Card>

      {/* OAuth 提供商 */}
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card gap-3! py-3!">
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <FingerprintIcon className="size-4 text-muted-foreground" />
            OAuth 提供商
            <InfoHint>
              当前未启用任何第三方登录；启用/停用均在 Supabase 控制台操作
            </InfoHint>
            <ExternalBadge />
          </CardTitle>
          <CardAction>
            <ConsoleLink
              href={`${consoleInfo.consoleBase}/auth/providers`}
              label="在 Supabase 控制台打开"
            />
          </CardAction>
        </CardHeader>
        <CardContent className="p-4 md:p-6">
          <div className="overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="text-center">提供商</TableHead>
                  <TableHead className="text-center">状态</TableHead>
                  <TableHead className="text-center">启用说明</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {OAUTH_PROVIDERS.map((provider) => (
                  <TableRow key={provider.name}>
                    <TableCell className="text-left font-medium">
                      {provider.name}
                    </TableCell>
                    <TableCell>
                      <Badge
                        variant="outline"
                        className="border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400"
                      >
                        未启用
                      </Badge>
                    </TableCell>
                    <TableCell className="text-left text-muted-foreground">
                      {provider.note}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </CardContent>
      </Card>

      {/* 回调 URL 清单 */}
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card gap-3! py-3!">
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <ShieldCheckIcon className="size-4 text-muted-foreground" />
            回调 URL 清单
            <InfoHint>
              供控制台 Redirect URLs 配置参照；以当前访问站点地址推导，支持一键复制
            </InfoHint>
            <ExternalBadge />
          </CardTitle>
          <CardAction>
            <ConsoleLink
              href={`${consoleInfo.consoleBase}/auth/url-configuration`}
              label="在 Supabase 控制台打开"
            />
          </CardAction>
        </CardHeader>
        <CardContent className="flex flex-col gap-3 p-4 md:p-6">
          {callbackUrls.length === 0 ? (
            <p className="text-sm text-muted-foreground">正在推导站点地址…</p>
          ) : (
            callbackUrls.map((item) => (
              <div
                key={item.label}
                className="flex flex-wrap items-center justify-between gap-2 rounded-lg border p-3"
              >
                <div className="flex min-w-0 flex-col gap-0.5">
                  <span className="text-xs text-muted-foreground">
                    {item.label}
                  </span>
                  <span className="break-all font-mono text-xs">
                    {item.value}
                  </span>
                </div>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  onClick={() => void copy(item.value, item.label)}
                >
                  <CopyIcon data-icon="inline-start" />
                  复制
                </Button>
              </div>
            ))
          )}
          <p className="text-xs text-muted-foreground">
            {`IM 扫码登录使用 /auth/callback/<provider>，个人中心扫码绑定使用 /settings/profile/bind/<provider>/callback —— 两者都需在厂商后台登记（飞书为重定向 URL 精确匹配）。`}
          </p>
        </CardContent>
      </Card>
    </div>
  );
}
