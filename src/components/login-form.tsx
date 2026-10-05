"use client";

import * as React from "react";
import { useRouter } from "next/navigation";
import {
  CopyIcon,
  Loader2Icon,
  LogInIcon,
  ShieldAlertIcon,
} from "lucide-react";
import { toast } from "sonner";

import { ImQrLogin } from "@/components/im-qr-login";
import { InfoHint } from "@/components/info-hint";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import {
  Field,
  FieldError,
  FieldGroup,
  FieldLabel,
} from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { classifyLoginFailure } from "@/lib/audit";
import { translateErrorMessage } from "@/lib/dictionaries";
import { IM_PROVIDER_LABELS } from "@/lib/im/messages";
import { createClient } from "@/lib/supabase/client";

const ERROR_MESSAGES: Record<string, string> = {
  "Invalid login credentials": "邮箱或密码错误",
  "Email not confirmed": "邮箱尚未确认，请联系管理员",
  "Too many requests": "尝试次数过多，请稍后再试",
};

function translate(message: string) {
  return ERROR_MESSAGES[message] ?? translateErrorMessage(message);
}

export function LoginForm({
  initialError,
  notice,
  enabledProvider,
  passwordLoginEnabled = true,
  adminEmergency = false,
  adminContact = "",
  notBound = false,
}: {
  initialError?: string;
  /** IM 回调错误（/login?error=im_*），toast 提示一次（工单 im/002） */
  notice?: string | null;
  /** 当前启用 IM 厂商；仅在已接入（有展示名）时出现「扫码登录」Tab */
  enabledProvider?: string | null;
  /** 密码登录全局开关（im/006）；关闭后普通访问不显示密码 Tab */
  passwordLoginEnabled?: boolean;
  /** 管理员应急登录（im/006）：/login?admin=1 时显示密码 Tab，仅应急名单放行 */
  adminEmergency?: boolean;
  /** 管理员联系方式（im/006）：im_not_bound 时展示 + 一键复制 */
  adminContact?: string;
  /** 当前错误是否为 im_not_bound（决定是否展示联系方式区块） */
  notBound?: boolean;
}) {
  const router = useRouter();
  const [email, setEmail] = React.useState("");
  const [password, setPassword] = React.useState("");
  const [error, setError] = React.useState<string | null>(initialError ?? null);
  const [loading, setLoading] = React.useState(false);

  const providerLabel = enabledProvider
    ? IM_PROVIDER_LABELS[enabledProvider]
    : undefined;
  const showScan = Boolean(providerLabel);
  const showPassword = passwordLoginEnabled || adminEmergency;

  React.useEffect(() => {
    if (notice) {
      // 固定 id：刷新 / 重试同一错误时合并，不叠加多条
      toast.error(notice, { id: "im-login-notice" });
    }
  }, [notice]);

  const copyContact = async () => {
    try {
      await navigator.clipboard.writeText(adminContact);
      toast.success("管理员联系方式已复制");
    } catch {
      toast.error("复制失败，请手动选择复制");
    }
  };

  const handleSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setLoading(true);
    setError(null);

    const supabase = createClient();
    const { error: signInError } = await supabase.auth.signInWithPassword({
      email: email.trim(),
      password,
    });

    if (signInError) {
      // 登录失败留痕（audit/005，ADR-002）：匿名通道仅记失败；失败不阻断登录交互
      await supabase.rpc("record_login_attempt", {
        p_email: email.trim(),
        p_success: false,
        p_fail_reason: classifyLoginFailure(signInError.message),
      });
      setError(translate(signInError.message));
      setLoading(false);
      return;
    }

    // im/006：密码登录关闭时仅应急管理员放行（服务端校验名单 + role/status），
    // 非放行账号立即签出，避免绕过登录页 UI 用 API 直接换到会话。
    if (!passwordLoginEnabled) {
      const { data: allowed, error: allowedError } = await supabase.rpc(
        "im_password_login_allowed",
        { p_email: email.trim() },
      );
      if (allowedError || allowed !== true) {
        await supabase.auth.signOut();
        // im/008：密码登录关闭时的被拒尝试留痕（已签出 → 匿名通道仅记失败，ADR-002）
        await supabase.rpc("record_login_attempt", {
          p_email: email.trim(),
          p_success: false,
          p_fail_reason: "password_login_disabled",
        });
        setError("密码登录已关闭，请使用扫码登录或联系管理员");
        setLoading(false);
        return;
      }
    }

    // 登录成功留痕：此时会话已建立，RPC 以本人身份写入（服务端以会话邮箱归档）
    await supabase.rpc("record_login_attempt", {
      p_email: email.trim(),
      p_success: true,
    });

    router.replace("/");
    router.refresh();
  };

  const passwordForm = (
    <form onSubmit={handleSubmit} noValidate>
      <FieldGroup>
        <Field>
          <FieldLabel htmlFor="email">邮箱</FieldLabel>
          <Input
            id="email"
            type="email"
            autoComplete="email"
            placeholder="you@example.com"
            value={email}
            onChange={(event) => setEmail(event.target.value)}
            aria-invalid={error !== null}
            required
          />
        </Field>
        <Field>
          <FieldLabel htmlFor="password">密码</FieldLabel>
          <Input
            id="password"
            type="password"
            autoComplete="current-password"
            value={password}
            onChange={(event) => setPassword(event.target.value)}
            aria-invalid={error !== null}
            required
          />
        </Field>
        {error ? <FieldError>{error}</FieldError> : null}
        {!passwordLoginEnabled && adminEmergency ? (
          <p className="flex items-start gap-1.5 text-xs text-muted-foreground">
            <ShieldAlertIcon className="mt-0.5 size-3.5 shrink-0" />
            管理员应急登录：仅配置在应急名单内的管理员邮箱可登录。
          </p>
        ) : null}
        <Field>
          <Button type="submit" disabled={loading}>
            {loading ? (
              <Loader2Icon
                className="animate-spin"
                data-icon="inline-start"
              />
            ) : (
              <LogInIcon data-icon="inline-start" />
            )}
            登录
          </Button>
        </Field>
      </FieldGroup>
    </form>
  );

  // im/007：PC 扫码 = 真二维码（ticket 轮询）+ 同浏览器直登兜底链接。
  // 移动端 H5 免登不经本 Tab（proxy.ts 按 UA 直接跳 /auth/im/<provider>/start）。
  const scanPanel =
    enabledProvider && providerLabel ? (
      <div className="flex flex-col items-center gap-1">
        <ImQrLogin
          provider={enabledProvider}
          providerLabel={providerLabel}
          adminContact={adminContact}
        />
        <a
          className="text-xs text-muted-foreground underline underline-offset-2"
          href={`/auth/im/${enabledProvider}/start`}
        >
          无法扫码？在本机浏览器直接登录
        </a>
      </div>
    ) : null;

  // im/006：im_not_bound 时展示管理员联系方式 + 一键复制（联系方式在配置页维护）
  const notBoundBanner = notBound ? (
    <div className="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-200">
      <ShieldAlertIcon className="mt-0.5 size-4 shrink-0" />
      <div className="flex flex-col gap-1.5">
        <p>
          未绑定{providerLabel ?? "IM"}账号，暂时无法扫码登录。请联系管理员为你录入绑定。
        </p>
        {adminContact ? (
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-mono text-xs break-all">
              {adminContact}
            </span>
            <Button
              type="button"
              size="sm"
              variant="outline"
              className="h-11 lg:h-8"
              onClick={() => void copyContact()}
            >
              <CopyIcon data-icon="inline-start" />
              复制联系方式
            </Button>
          </div>
        ) : (
          <p className="text-xs">管理员尚未配置联系方式，可在系统「身份认证」页设置。</p>
        )}
      </div>
    </div>
  ) : null;

  const closedPanel = (
    <div className="flex flex-col items-center gap-3 py-2 text-center">
      <div className="flex size-16 items-center justify-center rounded-2xl border bg-muted">
        <ShieldAlertIcon className="size-8 text-muted-foreground" />
      </div>
      <p className="text-sm text-muted-foreground">
        当前未启用任何登录方式，请联系管理员。
      </p>
    </div>
  );

  let body: React.ReactNode;
  if (showScan && showPassword) {
    body = (
      <Tabs defaultValue="password">
        <TabsList className="w-full">
          <TabsTrigger value="password">密码登录</TabsTrigger>
          <TabsTrigger value="im">扫码登录</TabsTrigger>
        </TabsList>
        <TabsContent value="password" className="pt-2">
          {notBoundBanner}
          {passwordForm}
        </TabsContent>
        <TabsContent value="im" className="pt-2">
          {notBoundBanner}
          {scanPanel}
        </TabsContent>
      </Tabs>
    );
  } else if (showScan) {
    body = (
      <div className="flex flex-col gap-3">
        {notBoundBanner}
        {scanPanel}
      </div>
    );
  } else if (showPassword) {
    body = (
      <div className="flex flex-col gap-3">
        {notBoundBanner}
        {passwordForm}
      </div>
    );
  } else {
    body = closedPanel;
  }

  const description = showScan
    ? showPassword
      ? "使用工作邮箱或扫码登录"
      : `使用${providerLabel}扫码登录`
    : "使用工作邮箱登录系统";

  return (
    <Card>
      <CardHeader className="text-center">
        <CardTitle className="flex items-center justify-center gap-1.5 text-xl">
          登录
          <InfoHint className="size-5">{description}</InfoHint>
        </CardTitle>
      </CardHeader>
      <CardContent>{body}</CardContent>
    </Card>
  );
}
