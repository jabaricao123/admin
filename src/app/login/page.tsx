import type { Metadata } from "next";
import { BoxesIcon } from "lucide-react";

import { LoginForm } from "@/components/login-form";
import { BANNED_ACCOUNT_MESSAGE } from "@/lib/dictionaries";

export const metadata: Metadata = {
  title: "登录",
};

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ reason?: string | string[] }>;
}) {
  const params = await searchParams;
  const reason = Array.isArray(params.reason)
    ? params.reason[0]
    : params.reason;
  const initialError =
    reason === "banned" ? BANNED_ACCOUNT_MESSAGE : undefined;

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
        <LoginForm initialError={initialError} />
      </div>
    </div>
  );
}
