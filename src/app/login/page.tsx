import type { Metadata } from "next";
import { BoxesIcon } from "lucide-react";

import { LoginForm } from "@/components/login-form";
import { BANNED_ACCOUNT_MESSAGE } from "@/lib/dictionaries";
import { imLoginErrorMessage } from "@/lib/im/messages";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "登录",
};

function pickParam(value: string | string[] | undefined): string | null {
  if (Array.isArray(value)) {
    return value[0] ?? null;
  }
  return value ?? null;
}

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{
    reason?: string | string[];
    error?: string | string[];
  }>;
}) {
  const params = await searchParams;
  const reason = pickParam(params.reason);
  const error = pickParam(params.error);
  const initialError =
    reason === "banned" ? BANNED_ACCOUNT_MESSAGE : undefined;
  const notice = imLoginErrorMessage(error);

  // 当前启用厂商（打开 IM 登录时注入登录页，Tab 仅在启用且已接入的厂商时展示）
  const supabase = await createClient();
  const { data: enabledProvider } = await supabase.rpc(
    "im_get_enabled_provider",
  );

  return (
    <div className="flex min-h-svh flex-col items-center justify-center gap-6 bg-muted p-6 md:p-10">
      <div className="flex w-full max-w-sm flex-col gap-6">
        <div className="flex flex-col items-center gap-3">
          <div className="flex size-10 items-center justify-center rounded-xl bg-primary text-primary-foreground">
            <BoxesIcon className="size-5" />
          </div>
          <div className="text-center">
            <div className="text-lg font-semibold">企业管理系统</div>
          </div>
        </div>
        <LoginForm
          initialError={initialError}
          notice={notice}
          enabledProvider={enabledProvider ?? null}
        />
      </div>
    </div>
  );
}
