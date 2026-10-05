import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { UserRoundIcon } from "lucide-react";

import { Badge } from "@/components/ui/badge";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { InfoHint } from "@/components/info-hint";
import { Separator } from "@/components/ui/separator";
import {
  ROLE_BADGE_CLASSES,
  ROLE_LABELS,
  type UserRole,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/server";

import { ProfileImBinding } from "./profile-im-binding";

export const metadata: Metadata = {
  title: "个人中心",
};

function pickParam(value: string | string[] | undefined): string | null {
  if (Array.isArray(value)) {
    return value[0] ?? null;
  }
  return value ?? null;
}

export default async function SettingsProfilePage({
  searchParams,
}: {
  searchParams: Promise<{
    bound?: string | string[];
    error?: string | string[];
  }>;
}) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const [{ data: profile }, { data: options }] = await Promise.all([
    supabase
      .from("profiles")
      .select(
        "full_name, email, role, wecom_userid, feishu_userid, dingtalk_userid",
      )
      .eq("id", user.id)
      .maybeSingle(),
    supabase.rpc("im_get_login_options"),
  ]);

  const params = await searchParams;
  const boundProvider = pickParam(params.bound);
  const errorCode = pickParam(params.error);
  const optionRow = (options ?? null) as {
    enabled_provider?: string | null;
    admin_contact?: string | null;
  } | null;

  const role = (profile?.role ?? "engineer") as UserRole;

  return (
    <div className="flex flex-col gap-0.5 p-0 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card gap-3! py-3!">
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <UserRoundIcon className="size-4 text-muted-foreground" />
            账号信息
            <InfoHint>当前登录账号的基本信息（姓名在用户管理维护）</InfoHint>
          </CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-3 p-4 text-sm md:p-6">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <span className="text-muted-foreground">姓名</span>
            <span className="font-medium">
              {profile?.full_name ?? user.email ?? "—"}
            </span>
          </div>
          <Separator />
          <div className="flex flex-wrap items-center justify-between gap-2">
            <span className="text-muted-foreground">邮箱</span>
            <span className="font-mono text-xs">
              {profile?.email ?? user.email ?? "—"}
            </span>
          </div>
          <Separator />
          <div className="flex flex-wrap items-center justify-between gap-2">
            <span className="text-muted-foreground">角色</span>
            <Badge variant="outline" className={ROLE_BADGE_CLASSES[role]}>
              {ROLE_LABELS[role] ?? role}
            </Badge>
          </div>
        </CardContent>
      </Card>

      <ProfileImBinding
        bindings={{
          feishu: profile?.feishu_userid ?? null,
          wecom: profile?.wecom_userid ?? null,
          dingtalk: profile?.dingtalk_userid ?? null,
        }}
        enabledProvider={optionRow?.enabled_provider ?? null}
        adminContact={optionRow?.admin_contact ?? ""}
        boundProvider={boundProvider}
        errorCode={errorCode}
      />
    </div>
  );
}
