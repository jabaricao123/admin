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
    admin?: string | string[];
  }>;
}) {
  const params = await searchParams;
  const reason = pickParam(params.reason);
  const error = pickParam(params.error);
  const adminEmergency = pickParam(params.admin) === "1";
  const initialError =
    reason === "banned" ? BANNED_ACCOUNT_MESSAGE : undefined;

  // 登录页选项（im/006，anon 可读）：启用厂商 / 密码登录开关 / 管理员联系方式；
  // 回调错误文案据此带上厂商展示名（沿用 im/002 逻辑）
  const supabase = await createClient();
  const { data: options } = await supabase.rpc("im_get_login_options");
  const optionRow = (options ?? null) as {
    enabled_provider?: string | null;
    password_login_enabled?: boolean;
    admin_contact?: string | null;
  } | null;
  const enabledProvider = optionRow?.enabled_provider ?? null;
  const notice = imLoginErrorMessage(error, enabledProvider);

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
          enabledProvider={enabledProvider}
          passwordLoginEnabled={optionRow?.password_login_enabled !== false}
          adminEmergency={adminEmergency}
          adminContact={optionRow?.admin_contact ?? ""}
          notBound={error === "im_not_bound"}
        />
      </div>
    </div>
  );
}
