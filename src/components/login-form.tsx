"use client";

import * as React from "react";
import { useRouter } from "next/navigation";
import { Loader2Icon, LogInIcon, QrCodeIcon } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
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
}: {
  initialError?: string;
  /** IM 回调错误（/login?error=im_*），toast 提示一次（工单 im/002） */
  notice?: string | null;
  /** 当前启用 IM 厂商；仅在已接入（有展示名）时出现「扫码登录」Tab */
  enabledProvider?: string | null;
}) {
  const router = useRouter();
  const [email, setEmail] = React.useState("");
  const [password, setPassword] = React.useState("");
  const [error, setError] = React.useState<string | null>(initialError ?? null);
  const [loading, setLoading] = React.useState(false);

  const providerLabel = enabledProvider
    ? IM_PROVIDER_LABELS[enabledProvider]
    : undefined;

  React.useEffect(() => {
    if (notice) {
      // 固定 id：刷新 / 重试同一错误时合并，不叠加多条
      toast.error(notice, { id: "im-login-notice" });
    }
  }, [notice]);

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

  const scanPanel = (
    <div className="flex flex-col items-center gap-4 py-2 text-center">
      <div className="flex size-16 items-center justify-center rounded-2xl border bg-muted">
        <QrCodeIcon className="size-8 text-muted-foreground" />
      </div>
      <p className="text-sm text-muted-foreground">
        使用{providerLabel} App 扫码并确认，即可登录系统
      </p>
      <Button asChild className="w-full">
        <a href={`/auth/im/${enabledProvider}/start`}>
          <QrCodeIcon data-icon="inline-start" />
          {providerLabel}扫码登录
        </a>
      </Button>
    </div>
  );

  return (
    <Card>
      <CardHeader className="text-center">
        <CardTitle className="text-xl">登录</CardTitle>
        <CardDescription>
          {providerLabel ? "使用工作邮箱或扫码登录" : "使用工作邮箱登录系统"}
        </CardDescription>
      </CardHeader>
      <CardContent>
        {providerLabel ? (
          <Tabs defaultValue="password">
            <TabsList className="w-full">
              <TabsTrigger value="password">密码登录</TabsTrigger>
              <TabsTrigger value="im">扫码登录</TabsTrigger>
            </TabsList>
            <TabsContent value="password" className="pt-2">
              {passwordForm}
            </TabsContent>
            <TabsContent value="im" className="pt-2">
              {scanPanel}
            </TabsContent>
          </Tabs>
        ) : (
          passwordForm
        )}
      </CardContent>
    </Card>
  );
}
