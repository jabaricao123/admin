"use client";

// 系统管理 · IM 扫码登录配置（工单 im/006）
//
// 数据面（见迁移 20261006180000_im_config_ui.sql）：
//   - im_get_config：读取某厂商配置状态 + 掩码凭据（明文不出库；每次查看写 audit view_credentials）
//   - im_upsert_config：保存凭据（pgcrypto 加密；写 audit upsert）
//   - im_test_config：测试连接（用已存或本次填写的凭据出站校验；写 audit test_connection）
//   - im_switch_provider：启用 / 停用厂商（三选一原子切换 + 全局签出；写 audit switch_provider / force_logout）
//   - im_clear_all_bindings：清空全部绑定（独立按钮，二次确认；写 audit clear_bindings）
//
// UI 约定：凭据输入框留空 = 保留已存值（掩码只放在 placeholder 展示）；
// 覆盖凭据时必须完整填写全部字段（INDEX 规则 4：修改需重输完整值）。

import * as React from "react";
import {
  BadgeCheckIcon,
  FlaskConicalIcon,
  PlugZapIcon,
  SaveIcon,
  ShieldAlertIcon,
  Trash2Icon,
} from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardAction,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Field, FieldDescription, FieldLabel } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { Switch } from "@/components/ui/switch";
import type { Database } from "@/lib/database.types";
import { createClient } from "@/lib/supabase/client";

type ProviderId = "feishu" | "wecom" | "dingtalk";

type CredentialField = {
  key: string;
  label: string;
  secret?: boolean;
  hint?: string;
};

type ProviderMeta = {
  id: ProviderId;
  label: string;
  description: string;
  fields: CredentialField[];
};

const PROVIDERS: ProviderMeta[] = [
  {
    id: "feishu",
    label: "飞书",
    description: "企业自建应用：App ID / App Secret（重定向 URL 见页面底部清单）",
    fields: [
      { key: "app_id", label: "App ID", hint: "如 cli_xxxxxxxx" },
      { key: "app_secret", label: "App Secret", secret: true },
    ],
  },
  {
    id: "wecom",
    label: "企业微信",
    description: "自建应用：企业 ID / AgentId / Secret（PC 扫码与 App 内免登共用）",
    fields: [
      { key: "corp_id", label: "企业 ID（CorpID）", hint: "ww / wx 开头" },
      { key: "agent_id", label: "应用 AgentId" },
      { key: "secret", label: "应用 Secret", secret: true },
    ],
  },
  {
    id: "dingtalk",
    label: "钉钉",
    description: "企业内部应用：AppKey / AppSecret（钉钉登录链路随 im/005 接入）",
    fields: [
      { key: "app_key", label: "AppKey" },
      { key: "app_secret", label: "AppSecret", secret: true },
    ],
  },
];

type ProviderState = {
  exists: boolean;
  enabled: boolean;
  credentials_set: boolean;
  credentials_masked: Record<string, string>;
  updated_by_name: string | null;
  updated_at: string | null;
};

type ProviderStates = Partial<Record<ProviderId, ProviderState>>;
type ProviderForms = Record<ProviderId, Record<string, string>>;

const EMPTY_FORMS: ProviderForms = {
  feishu: { app_id: "", app_secret: "" },
  wecom: { corp_id: "", agent_id: "", secret: "" },
  dingtalk: { app_key: "", app_secret: "" },
};

type ConfirmSpec = {
  title: string;
  description: string;
  confirmLabel: string;
  destructive?: boolean;
  onConfirm: () => Promise<void> | void;
};

const CONTACT_KEY = "im_admin_contact";

function asText(value: unknown): string {
  if (value === null || value === undefined) {
    return "";
  }
  return typeof value === "string" ? value : String(value);
}

function formatDateTime(value: string | null): string {
  if (!value) {
    return "—";
  }
  return new Date(value).toLocaleString("zh-CN", { hour12: false });
}

export function ImConfigPanel() {
  const [loading, setLoading] = React.useState(true);
  const [states, setStates] = React.useState<ProviderStates>({});
  const [forms, setForms] = React.useState<ProviderForms>(EMPTY_FORMS);
  const [busy, setBusy] = React.useState<string | null>(null);
  const [contact, setContact] = React.useState("");
  const [contactSaving, setContactSaving] = React.useState(false);
  const [confirm, setConfirm] = React.useState<ConfirmSpec | null>(null);

  const load = React.useCallback(async () => {
    setLoading(true);
    const supabase = createClient();
    const [configs, settings] = await Promise.all([
      Promise.all(
        PROVIDERS.map((provider) =>
          supabase.rpc("im_get_config", { p_provider: provider.id }),
        ),
      ),
      supabase.rpc("get_all_settings"),
    ]);

    const next: ProviderStates = {};
    configs.forEach((response, index) => {
      const provider = PROVIDERS[index];
      const data = (response.data ?? null) as
        | (ProviderState & { credentials_masked?: Record<string, string> })
        | null;
      if (response.error || !data) {
        toast.error(
          `读取「${provider.label}」配置失败：${
            response.error?.message ?? "响应为空"
          }`,
        );
        return;
      }
      next[provider.id] = {
        exists: data.exists === true,
        enabled: data.enabled === true,
        credentials_set: data.credentials_set === true,
        credentials_masked: data.credentials_masked ?? {},
        updated_by_name: data.updated_by_name ?? null,
        updated_at: data.updated_at ?? null,
      };
    });

    if (!settings.error) {
      const row = (settings.data ?? []).find(
        (item) => item.key === CONTACT_KEY,
      );
      setContact(asText(row?.value));
    }

    setStates(next);
    setForms(EMPTY_FORMS);
    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const enabledProvider = React.useMemo(
    () => PROVIDERS.find((provider) => states[provider.id]?.enabled) ?? null,
    [states],
  );

  const reloadProvider = async (provider: ProviderMeta) => {
    const supabase = createClient();
    const { data, error } = await supabase.rpc("im_get_config", {
      p_provider: provider.id,
    });
    if (error || !data) {
      return;
    }
    const row = data as ProviderState & {
      credentials_masked?: Record<string, string>;
    };
    setStates((prev) => ({
      ...prev,
      [provider.id]: {
        exists: row.exists === true,
        enabled: row.enabled === true,
        credentials_set: row.credentials_set === true,
        credentials_masked: row.credentials_masked ?? {},
        updated_by_name: row.updated_by_name ?? null,
        updated_at: row.updated_at ?? null,
      },
    }));
  };

  const filledCredentials = (provider: ProviderMeta) => {
    const form = forms[provider.id];
    const result: Record<string, string> = {};
    for (const field of provider.fields) {
      const value = (form[field.key] ?? "").trim();
      if (value !== "") {
        result[field.key] = value;
      }
    }
    return result;
  };

  const allFieldsFilled = (provider: ProviderMeta) => {
    const filled = filledCredentials(provider);
    return Object.keys(filled).length === provider.fields.length;
  };

  const handleSaveCredentials = async (provider: ProviderMeta) => {
    const filled = filledCredentials(provider);
    const state = states[provider.id];
    if (Object.keys(filled).length === 0) {
      toast.error("请填写完整凭据后再保存（掩码只用于展示，不会当作新值提交）");
      return;
    }
    if (!allFieldsFilled(provider)) {
      toast.error(
        `修改凭据需填写完整字段：${provider.fields
          .map((field) => field.label)
          .join(" / ")}`,
      );
      return;
    }

    const save = async () => {
      setBusy(`save-${provider.id}`);
      const supabase = createClient();
      const args = {
        p_provider: provider.id,
        p_credentials: filled as Database["public"]["Functions"]["im_upsert_config"]["Args"]["p_credentials"],
        p_enabled: null,
      } as unknown as Database["public"]["Functions"]["im_upsert_config"]["Args"];
      const { error } = await supabase.rpc("im_upsert_config", args);
      setBusy(null);
      if (error) {
        toast.error(`保存失败：${error.message}`);
        return;
      }
      toast.success(`「${provider.label}」凭据已加密保存`);
      await reloadProvider(provider);
    };

    if (state?.credentials_set) {
      setConfirm({
        title: `覆盖「${provider.label}」凭据？`,
        description:
          "已保存的凭据将被本次填写的值整体替换（pgcrypto 加密存储，旧值不可恢复）。",
        confirmLabel: "覆盖保存",
        destructive: true,
        onConfirm: save,
      });
      return;
    }

    await save();
  };

  const handleTest = async (provider: ProviderMeta) => {
    const state = states[provider.id];
    const filled = filledCredentials(provider);
    const useTyped = Object.keys(filled).length > 0;

    if (!useTyped && !state?.credentials_set) {
      toast.error("请先填写完整凭据或保存后再测试连接");
      return;
    }
    if (useTyped && !allFieldsFilled(provider)) {
      toast.error("测试前请填写完整凭据（或清空输入以测试已保存的凭据）");
      return;
    }

    setBusy(`test-${provider.id}`);
    const supabase = createClient();
    const { data, error } = await supabase.rpc("im_test_config", {
      p_provider: provider.id,
      p_credentials: useTyped
        ? (filled as Database["public"]["Functions"]["im_test_config"]["Args"]["p_credentials"])
        : undefined,
    });
    setBusy(null);

    if (error) {
      toast.error(`测试失败：${error.message}`);
      return;
    }
    const result = (data ?? null) as { ok?: boolean; message?: string } | null;
    if (result?.ok) {
      toast.success(result.message ?? `「${provider.label}」连接正常`);
    } else {
      toast.error(result?.message ?? `「${provider.label}」连接失败`);
    }
  };

  const handleToggle = (provider: ProviderMeta, next: boolean) => {
    const state = states[provider.id];
    if (next === state?.enabled) {
      return;
    }

    if (next) {
      setConfirm({
        title: `启用「${provider.label}」扫码登录？`,
        description:
          "切换将强制所有在线用户重新登录（包括你当前会话），并自动停用其他厂商。不会清空任何用户绑定。",
        confirmLabel: `启用${provider.label}`,
        onConfirm: async () => {
          setBusy(`switch-${provider.id}`);
          const supabase = createClient();
          const { data, error } = await supabase.rpc("im_switch_provider", {
            p_provider: provider.id,
          });
          setBusy(null);
          if (error) {
            toast.error(`启用失败：${error.message}`);
            return;
          }
          const result = (data ?? null) as {
            sessions_revoked?: number;
          } | null;
          toast.success(
            `已启用「${provider.label}」，${result?.sessions_revoked ?? 0} 个在线会话已下线`,
          );
          // 当前会话已被全局签出：下一请求即跳登录页
          window.location.assign("/login");
        },
      });
      return;
    }

    setConfirm({
      title: `停用「${provider.label}」扫码登录？`,
      description: enabledProvider
        ? `停用后系统不再提供扫码入口，且所有在线用户（含你当前会话）将重新登录。已保存的凭据与用户绑定都保留，可随时重新启用。`
        : "停用后系统不再提供扫码入口。",
      confirmLabel: "停用",
      destructive: true,
      onConfirm: async () => {
        setBusy(`switch-${provider.id}`);
        const supabase = createClient();
        const { data, error } = await supabase.rpc("im_switch_provider", {
          p_provider: null as unknown as string,
        });
        setBusy(null);
        if (error) {
          toast.error(`停用失败：${error.message}`);
          return;
        }
        const result = (data ?? null) as { sessions_revoked?: number } | null;
        toast.success(
          `已停用「${provider.label}」，${result?.sessions_revoked ?? 0} 个在线会话已下线`,
        );
        window.location.assign("/login");
      },
    });
  };

  const handleClearBindings = () => {
    setConfirm({
      title: "清空所有用户的 IM 绑定？",
      description:
        "三家厂商（飞书 / 企业微信 / 钉钉）的全部 userid 绑定将被置空，所有用户都无法再扫码登录，直到重新绑定。此操作不可撤销，不会影响账号密码与角色。",
      confirmLabel: "继续",
      destructive: true,
      onConfirm: () => {
        setConfirm({
          title: "再次确认：清空所有绑定",
          description:
            "这是最后一步确认。清空后需要管理员逐个重新录入，或在个人中心重新扫码绑定。",
          confirmLabel: "确认清空",
          destructive: true,
          onConfirm: async () => {
            setBusy("clear-bindings");
            const supabase = createClient();
            const { data, error } = await supabase.rpc(
              "im_clear_all_bindings",
            );
            setBusy(null);
            if (error) {
              toast.error(`清空失败：${error.message}`);
              return;
            }
            const result = (data ?? null) as {
              total_cleared?: number;
              profiles_affected?: number;
            } | null;
            toast.success(
              `已清空 ${result?.total_cleared ?? 0} 条绑定（涉及 ${
                result?.profiles_affected ?? 0
              } 个用户）`,
            );
          },
        });
      },
    });
  };

  const handleSaveContact = async () => {
    setContactSaving(true);
    const supabase = createClient();
    const { error } = await supabase.rpc("upsert_setting", {
      p_key: CONTACT_KEY,
      p_value: contact.trim(),
      p_group_name: "通用",
      p_value_type: "string",
      p_description:
        "IM 未绑定（im_not_bound）时登录页展示的管理员联系方式，可填邮箱 / 电话 / 其他",
    });
    setContactSaving(false);
    if (error) {
      toast.error(`保存失败：${error.message}`);
      return;
    }
    toast.success("管理员联系方式已保存");
  };

  if (loading) {
    return (
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardHeader>
          <Skeleton className="h-5 w-40" />
          <Skeleton className="h-4 w-72" />
        </CardHeader>
        <CardContent className="grid gap-4 lg:grid-cols-3">
          {PROVIDERS.map((provider) => (
            <div key={provider.id} className="flex flex-col gap-3">
              <Skeleton className="h-5 w-24" />
              <Skeleton className="h-11 w-full lg:h-8" />
              <Skeleton className="h-11 w-full lg:h-8" />
            </div>
          ))}
        </CardContent>
      </Card>
    );
  }

  return (
    <div className="flex flex-col gap-4 md:gap-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card gap-3! py-3!">
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <PlugZapIcon className="size-4 text-muted-foreground" />
            IM 扫码登录
          </CardTitle>
          <CardDescription>
            三家厂商任一时刻仅启用一家；启用切换会强制所有在线用户重新登录（不清空绑定）。
          </CardDescription>
          <CardAction className="flex items-center gap-2">
            {enabledProvider ? (
              <Badge
                variant="outline"
                className="border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300"
              >
                当前启用：{enabledProvider.label}
              </Badge>
            ) : (
              <Badge
                variant="outline"
                className="border-zinc-200 bg-zinc-50 text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400"
              >
                未启用
              </Badge>
            )}
            <Button
              type="button"
              variant="outline"
              size="sm"
              className="h-11 lg:h-8"
              disabled={busy !== null}
              onClick={handleClearBindings}
            >
              <Trash2Icon data-icon="inline-start" />
              清空所有绑定
            </Button>
          </CardAction>
        </CardHeader>
        <CardContent className="grid gap-4 p-4 md:p-6 lg:grid-cols-3">
          {PROVIDERS.map((provider) => {
            const state = states[provider.id];
            const form = forms[provider.id];
            const isEnabled = state?.enabled === true;
            const isBusy =
              busy === `save-${provider.id}` ||
              busy === `test-${provider.id}` ||
              busy === `switch-${provider.id}`;

            return (
              <div
                key={provider.id}
                data-slot="im-provider-card"
                className={
                  isEnabled
                    ? "flex flex-col gap-3 rounded-xl border border-primary/40 bg-primary/5 p-4"
                    : "flex flex-col gap-3 rounded-xl border p-4"
                }
              >
                <div className="flex items-center justify-between gap-2">
                  <div className="flex flex-col gap-0.5">
                    <span className="flex items-center gap-1.5 font-medium">
                      {provider.label}
                      {state?.credentials_set ? (
                        <BadgeCheckIcon
                          className="size-4 text-emerald-600"
                          aria-label="凭据已保存"
                        />
                      ) : null}
                    </span>
                    <span className="text-xs text-muted-foreground">
                      {provider.description}
                    </span>
                  </div>
                  <Switch
                    checked={isEnabled}
                    disabled={busy !== null}
                    aria-label={`启用${provider.label}`}
                    onCheckedChange={(next) => handleToggle(provider, next)}
                  />
                </div>

                {provider.fields.map((field) => (
                  <Field key={field.key}>
                    <FieldLabel htmlFor={`im-${provider.id}-${field.key}`}>
                      {field.label}
                    </FieldLabel>
                    <Input
                      id={`im-${provider.id}-${field.key}`}
                      type={field.secret ? "password" : "text"}
                      autoComplete="off"
                      value={form[field.key] ?? ""}
                      placeholder={
                        state?.credentials_masked?.[field.key]
                          ? `已保存：${state.credentials_masked[field.key]}`
                          : "未配置"
                      }
                      onChange={(event) =>
                        setForms((prev) => ({
                          ...prev,
                          [provider.id]: {
                            ...prev[provider.id],
                            [field.key]: event.target.value,
                          },
                        }))
                      }
                    />
                    {field.hint ? (
                      <FieldDescription>{field.hint}</FieldDescription>
                    ) : null}
                  </Field>
                ))}

                <div className="flex flex-wrap items-center gap-2">
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    className="h-11 lg:h-8"
                    disabled={busy !== null}
                    onClick={() => void handleSaveCredentials(provider)}
                  >
                    <SaveIcon data-icon="inline-start" />
                    {busy === `save-${provider.id}` ? "保存中…" : "保存凭据"}
                  </Button>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    className="h-11 lg:h-8"
                    disabled={busy !== null}
                    onClick={() => void handleTest(provider)}
                  >
                    <FlaskConicalIcon data-icon="inline-start" />
                    {busy === `test-${provider.id}` ? "测试中…" : "测试连接"}
                  </Button>
                </div>

                <p className="text-xs text-muted-foreground">
                  {state?.credentials_set
                    ? `已保存 · 最近修改：${
                        state.updated_by_name ?? "—"
                      } · ${formatDateTime(state.updated_at)}`
                    : "尚未保存凭据"}
                  <br />
                  修改凭据需填写完整字段；留空表示保留已存值。
                </p>
              </div>
            );
          })}
        </CardContent>
      </Card>

      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card gap-3! py-3!">
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <ShieldAlertIcon className="size-4 text-muted-foreground" />
            管理员联系方式
          </CardTitle>
          <CardDescription>
            用户扫码后提示「未绑定」时，登录页展示该联系方式并提供一键复制（引导用户找管理员录入绑定）。
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-3 p-4 md:p-6">
          <Field>
            <FieldLabel htmlFor="im-admin-contact">
              联系方式（邮箱 / 电话 / 其他）
            </FieldLabel>
            <Input
              id="im-admin-contact"
              value={contact}
              placeholder="如 it-support@example.com 或 分机 8000"
              onChange={(event) => setContact(event.target.value)}
            />
            <FieldDescription>
              留空时登录页显示「请联系管理员」但不展示具体联系方式。
            </FieldDescription>
          </Field>
          <div>
            <Button
              type="button"
              size="sm"
              className="h-11 lg:h-8"
              disabled={contactSaving}
              onClick={() => void handleSaveContact()}
            >
              <SaveIcon data-icon="inline-start" />
              {contactSaving ? "保存中…" : "保存联系方式"}
            </Button>
          </div>
        </CardContent>
      </Card>

      <Dialog
        open={confirm !== null}
        onOpenChange={(open) => {
          if (!open) {
            setConfirm(null);
          }
        }}
      >
        <DialogContent data-slot="im-confirm-dialog">
          <DialogHeader>
            <DialogTitle>{confirm?.title}</DialogTitle>
            <DialogDescription>{confirm?.description}</DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => setConfirm(null)}
            >
              取消
            </Button>
            <Button
              type="button"
              variant={confirm?.destructive ? "destructive" : "default"}
              disabled={busy !== null}
              onClick={() => {
                const action = confirm?.onConfirm;
                setConfirm(null);
                if (action) {
                  void action();
                }
              }}
            >
              {confirm?.confirmLabel ?? "确认"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
