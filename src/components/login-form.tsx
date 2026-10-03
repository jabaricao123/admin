"use client";

import * as React from "react";
import { useRouter } from "next/navigation";
import { Loader2Icon, LogInIcon } from "lucide-react";

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
import { createClient } from "@/lib/supabase/client";
import { translateErrorMessage } from "@/lib/dictionaries";

const ERROR_MESSAGES: Record<string, string> = {
  "Invalid login credentials": "邮箱或密码错误",
  "Email not confirmed": "邮箱尚未确认，请联系管理员",
  "Too many requests": "尝试次数过多，请稍后再试",
};

function translate(message: string) {
  return ERROR_MESSAGES[message] ?? translateErrorMessage(message);
}

export function LoginForm() {
  const router = useRouter();
  const [email, setEmail] = React.useState("");
  const [password, setPassword] = React.useState("");
  const [error, setError] = React.useState<string | null>(null);
  const [loading, setLoading] = React.useState(false);

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
      setError(translate(signInError.message));
      setLoading(false);
      return;
    }

    router.replace("/");
    router.refresh();
  };

  return (
    <Card>
      <CardHeader className="text-center">
        <CardTitle className="text-xl">登录</CardTitle>
        <CardDescription>使用工作邮箱登录系统</CardDescription>
      </CardHeader>
      <CardContent>
        <form onSubmit={handleSubmit} noValidate>
          <FieldGroup>
            <Field>
              <FieldLabel htmlFor="email">邮箱</FieldLabel>
              <Input
                id="email"
                type="email"
                autoComplete="email"
                placeholder="you@company.com"
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
      </CardContent>
    </Card>
  );
}
