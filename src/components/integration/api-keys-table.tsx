"use client";

import * as React from "react";
import {
  BanIcon,
  CheckIcon,
  CopyIcon,
  KeyRoundIcon,
  Loader2Icon,
  SearchIcon,
  ShieldAlertIcon,
} from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Field,
  FieldDescription,
  FieldLabel,
} from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetFooter,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { useIsMobile } from "@/hooks/use-mobile";
import type { Database } from "@/lib/database.types";
import {
  API_KEY_EXPIRED_BADGE_CLASS,
  API_KEY_EXPIRY_OPTIONS,
  API_KEY_SCOPE_BADGE_CLASS,
  API_KEY_SCOPE_LABELS,
  API_KEY_SCOPE_OPTIONS,
  API_KEY_STATUS_BADGE_CLASSES,
  API_KEY_STATUS_LABELS,
  API_KEY_STATUS_OPTIONS,
  asApiKeyStatus,
  SECRET_WARNING_CALLOUT_CLASS,
  translateIntegrationErrorMessage,
  type ApiKeyExpiryPreset,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type ApiKeyRow = Pick<
  Database["public"]["Tables"]["api_keys"]["Row"],
  | "id"
  | "name"
  | "key_prefix"
  | "scopes"
  | "status"
  | "expires_at"
  | "last_used_at"
  | "created_by"
  | "created_at"
>;
type CreateApiKeyArgs =
  Database["public"]["Functions"]["create_api_key"]["Args"];
type ProfileRow = Pick<
  Database["public"]["Tables"]["profiles"]["Row"],
  "id" | "full_name" | "email"
>;
type UsageStatRow = Pick<
  Database["public"]["Tables"]["integration_call_stats_daily"]["Row"],
  "ref_id" | "total"
>;

type IssuedKey = {
  id: string;
  name: string;
  key: string;
  key_prefix: string;
  scopes: string[];
  expires_at: string | null;
};

type WizardStep = 1 | 2 | 3 | 4;

const PAGE_SIZE = 20;
const ALL = "all";

const WIZARD_STEPS: { step: WizardStep; label: string }[] = [
  { step: 1, label: "名称" },
  { step: 2, label: "范围" },
  { step: 3, label: "有效期" },
  { step: 4, label: "完成" },
];

const formatDateTime = (value: string | null) =>
  value
    ? new Date(value).toLocaleString("zh-CN", { hour12: false })
    : "—";

const formatDate = (value: string | null) =>
  value ? new Date(value).toLocaleDateString("zh-CN") : "永不过期";

const asScopes = (value: unknown): string[] =>
  Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];

const isExpired = (row: Pick<ApiKeyRow, "expires_at" | "status">) =>
  row.status === "active" &&
  row.expires_at !== null &&
  new Date(row.expires_at).getTime() <= Date.now();

/**
 * 近 30 天调用量：优先 get_api_key_usage RPC（明细 + 日聚合按天去重）；
 * RPC 不可用时回退 integration_call_stats_daily（admin RLS 可读）按 key_id 求和。
 */
async function loadUsageTotals(
  supabase: ReturnType<typeof createClient>,
  keys: ApiKeyRow[],
): Promise<Map<string, number>> {
  const totals = new Map<string, number>();
  if (keys.length === 0) {
    return totals;
  }

  const usageResults = await Promise.all(
    keys.map((key) => supabase.rpc("get_api_key_usage", { p_key_id: key.id })),
  );
  if (usageResults.every((result) => !result.error)) {
    usageResults.forEach((result, index) => {
      const payload = result.data as { total?: number | string } | null;
      const total = Number(payload?.total ?? 0);
      totals.set(keys[index].id, Number.isFinite(total) ? total : 0);
    });
    return totals;
  }

  // TODO(integration): get_api_key_usage 恢复后删除此降级路径
  const usageSince = new Date(Date.now() - 30 * 86_400_000)
    .toISOString()
    .slice(0, 10);
  const statsRes = await supabase
    .from("integration_call_stats_daily")
    .select("ref_id,total")
    .eq("kind", "api")
    .gte("day", usageSince)
    .limit(5000);
  if (!statsRes.error) {
    for (const stat of (statsRes.data ?? []) as UsageStatRow[]) {
      totals.set(stat.ref_id, (totals.get(stat.ref_id) ?? 0) + stat.total);
    }
  }
  return totals;
}

export function ApiKeysTable() {
  const isMobile = useIsMobile();
  const [rows, setRows] = React.useState<ApiKeyRow[]>([]);
  const [creatorNames, setCreatorNames] = React.useState<Map<string, string>>(
    new Map(),
  );
  const [usageTotals, setUsageTotals] = React.useState<Map<string, number>>(
    new Map(),
  );
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [search, setSearch] = React.useState("");
  const [statusFilter, setStatusFilter] = React.useState(ALL);
  const [page, setPage] = React.useState(1);

  const [detail, setDetail] = React.useState<ApiKeyRow | null>(null);
  const [revoking, setRevoking] = React.useState(false);

  const [wizardOpen, setWizardOpen] = React.useState(false);
  const [step, setStep] = React.useState<WizardStep>(1);
  const [draftName, setDraftName] = React.useState("");
  const [draftScopes, setDraftScopes] = React.useState<string[]>([]);
  const [draftExpiry, setDraftExpiry] =
    React.useState<ApiKeyExpiryPreset>("90");
  const [issuing, setIssuing] = React.useState(false);
  const [issued, setIssued] = React.useState<IssuedKey | null>(null);

  const load = React.useCallback(async (): Promise<ApiKeyRow[]> => {
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const [keysRes, profilesRes] = await Promise.all([
      supabase
        .from("api_keys")
        .select(
          "id,name,key_prefix,scopes,status,expires_at,last_used_at,created_by,created_at",
        )
        .order("created_at", { ascending: false }),
      supabase.from("profiles").select("id, full_name, email"),
    ]);

    if (keysRes.error) {
      setError(keysRes.error.message);
      setRows([]);
      setLoading(false);
      return [];
    }

    const items = keysRes.data ?? [];
    setRows(items);

    if (!profilesRes.error) {
      const map = new Map<string, string>();
      for (const profile of (profilesRes.data ?? []) as ProfileRow[]) {
        map.set(
          profile.id,
          profile.full_name ?? profile.email?.split("@")[0] ?? "未知用户",
        );
      }
      setCreatorNames(map);
    }

    setUsageTotals(await loadUsageTotals(supabase, items));

    setLoading(false);
    return items;
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const filtered = React.useMemo(() => {
    const keyword = search.trim().toLowerCase();
    return rows.filter((row) => {
      if (statusFilter !== ALL && row.status !== statusFilter) {
        return false;
      }
      if (keyword) {
        const haystack = `${row.name} ${row.key_prefix}`.toLowerCase();
        if (!haystack.includes(keyword)) {
          return false;
        }
      }
      return true;
    });
  }, [rows, search, statusFilter]);

  React.useEffect(() => {
    setPage(1);
  }, [search, statusFilter]);

  const pageCount = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const currentPage = Math.min(page, pageCount);
  const pagedRows = filtered.slice(
    (currentPage - 1) * PAGE_SIZE,
    currentPage * PAGE_SIZE,
  );

  const resetWizard = () => {
    setStep(1);
    setDraftName("");
    setDraftScopes([]);
    setDraftExpiry("90");
    setIssued(null);
    setIssuing(false);
  };

  const openWizard = () => {
    resetWizard();
    setWizardOpen(true);
  };

  const closeWizard = () => {
    setWizardOpen(false);
    resetWizard();
  };

  const toggleScope = (scope: string, checked: boolean) => {
    setDraftScopes((prev) =>
      checked ? [...new Set([...prev, scope])] : prev.filter((s) => s !== scope),
    );
  };

  const copyText = async (text: string, label: string) => {
    try {
      await navigator.clipboard.writeText(text);
      toast.success(`${label}已复制`);
    } catch {
      toast.error("复制失败，请手动选择并复制");
    }
  };

  const goNext = () => {
    if (step === 1) {
      if (!draftName.trim()) {
        toast.error("请输入密钥名称");
        return;
      }
      setStep(2);
      return;
    }
    if (step === 2) {
      if (draftScopes.length === 0) {
        toast.error("请至少选择一个访问范围");
        return;
      }
      setStep(3);
      return;
    }
    if (step === 3) {
      void issue();
    }
  };

  const issue = async () => {
    setIssuing(true);
    const days = draftExpiry === "never" ? null : Number(draftExpiry);
    const expiresAt =
      days === null ? null : new Date(Date.now() + days * 86_400_000).toISOString();
    const supabase = createClient();
    const args = {
      p_name: draftName.trim(),
      p_scopes: draftScopes,
      p_expires_at: expiresAt,
    } as unknown as CreateApiKeyArgs;
    const { data, error: issueError } = await supabase.rpc(
      "create_api_key",
      args,
    );
    setIssuing(false);

    if (issueError) {
      toast.error(translateIntegrationErrorMessage(issueError.message));
      return;
    }

    const result = (data ?? null) as unknown as IssuedKey | null;
    if (!result?.key) {
      toast.error("签发失败：服务端未返回完整密钥，请重试");
      return;
    }

    setIssued({
      id: result.id,
      name: result.name,
      key: result.key,
      key_prefix: result.key_prefix,
      scopes: asScopes(result.scopes),
      expires_at: result.expires_at,
    });
    setStep(4);
    void load();
  };

  const openDetail = (row: ApiKeyRow) => {
    setDetail(row);
  };

  const handleRevoke = async () => {
    if (!detail) {
      return;
    }
    const confirmed = window.confirm(
      `确定吊销密钥「${detail.name}」？吊销立即生效且不可恢复，使用该密钥的调用将返回 401。`,
    );
    if (!confirmed) {
      return;
    }

    setRevoking(true);
    const supabase = createClient();
    const { error: revokeError } = await supabase.rpc("revoke_api_key", {
      p_id: detail.id,
    });
    setRevoking(false);

    if (revokeError) {
      toast.error(translateIntegrationErrorMessage(revokeError.message));
      return;
    }

    toast.success("已吊销，密钥立即失效");
    const items = await load();
    setDetail(items.find((item) => item.id === detail.id) ?? null);
  };

  const scopeBadges = (scopes: string[]) =>
    scopes.length === 0 ? (
      <span className="text-xs text-muted-foreground">未授予范围</span>
    ) : (
      <span className="flex flex-wrap items-center justify-center gap-1">
        {scopes.map((scope) => (
          <Badge
            key={scope}
            variant="outline"
            className={API_KEY_SCOPE_BADGE_CLASS}
          >
            {API_KEY_SCOPE_LABELS[scope] ?? scope}
          </Badge>
        ))}
      </span>
    );

  const creatorName = (id: string | null) =>
    id ? (creatorNames.get(id) ?? "已离职用户") : "—";

  return (
    <div className="flex flex-col gap-0.5 p-0 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
            <div className="relative flex-1 sm:max-w-xs">
              <SearchIcon className="absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder="搜索名称 / 密钥前缀"
                className="h-11 pl-8 text-base lg:h-8 lg:text-sm"
                aria-label="搜索密钥名称或前缀"
              />
            </div>
            <Select value={statusFilter} onValueChange={setStatusFilter}>
              <SelectTrigger
                className="h-11 w-full sm:w-32 lg:h-8"
                aria-label="按状态筛选"
              >
                <SelectValue placeholder="全部状态" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL}>全部状态</SelectItem>
                {API_KEY_STATUS_OPTIONS.map((option) => (
                  <SelectItem key={option.value} value={option.value}>
                    {option.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <div className="flex items-center gap-2 sm:ml-auto">
              <Button
                onClick={openWizard}
                className="h-11 flex-1 sm:flex-none lg:h-8"
              >
                <KeyRoundIcon data-icon="inline-start" />
                签发密钥
              </Button>
            </div>
          </div>

          {loading ? (
            <div className="flex flex-col gap-2">
              {Array.from({ length: 4 }).map((_, index) => (
                <Skeleton key={index} className="h-12 w-full" />
              ))}
            </div>
          ) : error ? (
            <div className="flex flex-col items-center gap-2 py-8 text-sm">
              <p className="text-destructive">
                加载失败：{translateIntegrationErrorMessage(error)}
              </p>
              <Button variant="outline" onClick={() => void load()}>
                重试
              </Button>
            </div>
          ) : filtered.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <KeyRoundIcon className="size-8 opacity-60" />
              <span>
                {rows.length === 0
                  ? "暂无 API 密钥，点击「签发密钥」创建"
                  : "没有匹配的密钥，试试调整搜索或筛选"}
              </span>
            </div>
          ) : isMobile ? (
            <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:px-0">
              {pagedRows.map((row) => {
                const status = asApiKeyStatus(row.status);
                const expired = isExpired(row);
                return (
                  <button
                    key={row.id}
                    type="button"
                    data-slot="api-key-card"
                    onClick={() => openDetail(row)}
                    className="flex w-full flex-col gap-2 rounded-xl border bg-card p-3 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                  >
                    <div className="flex items-start justify-between gap-3">
                      <div className="min-w-0">
                        <div className="truncate font-medium">{row.name}</div>
                        <div className="truncate font-mono text-xs leading-tight text-muted-foreground">
                          {row.key_prefix}…
                        </div>
                      </div>
                      <div className="flex shrink-0 flex-col items-end gap-1">
                        <Badge
                          variant="outline"
                          className={API_KEY_STATUS_BADGE_CLASSES[status]}
                        >
                          {API_KEY_STATUS_LABELS[status]}
                        </Badge>
                        {expired ? (
                          <Badge
                            variant="outline"
                            className={API_KEY_EXPIRED_BADGE_CLASS}
                          >
                            已过期
                          </Badge>
                        ) : null}
                      </div>
                    </div>
                    <div className="flex flex-wrap gap-1">
                      {scopeBadges(asScopes(row.scopes))}
                    </div>
                    <div className="flex items-center justify-between gap-4 text-sm">
                      <span className="text-muted-foreground">有效期</span>
                      <span>{formatDate(row.expires_at)}</span>
                    </div>
                    <div className="flex items-center justify-between gap-4 text-sm">
                      <span className="text-muted-foreground">最近调用</span>
                      <span>{formatDateTime(row.last_used_at)}</span>
                    </div>
                    <div className="flex items-center justify-between gap-4 text-sm">
                      <span className="text-muted-foreground">
                        近 30 天调用
                      </span>
                      <span>{usageTotals.get(row.id) ?? 0}</span>
                    </div>
                    <div className="flex items-center justify-between gap-4 text-sm">
                      <span className="text-muted-foreground">创建人</span>
                      <span>{creatorName(row.created_by)}</span>
                    </div>
                  </button>
                );
              })}
            </div>
          ) : (
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="text-center">名称</TableHead>
                    <TableHead className="text-center">密钥前缀</TableHead>
                    <TableHead className="text-center">访问范围</TableHead>
                    <TableHead className="text-center">状态</TableHead>
                    <TableHead className="text-center">有效期</TableHead>
                    <TableHead className="text-center">最近调用</TableHead>
                    <TableHead className="text-center">近 30 天调用</TableHead>
                    <TableHead className="text-center">创建人</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {pagedRows.map((row) => {
                    const status = asApiKeyStatus(row.status);
                    return (
                      <TableRow
                        key={row.id}
                        role="button"
                        tabIndex={0}
                        className="cursor-pointer"
                        onClick={() => openDetail(row)}
                        onKeyDown={(event) => {
                          if (event.target !== event.currentTarget) {
                            return;
                          }
                          if (event.key === "Enter" || event.key === " ") {
                            event.preventDefault();
                            openDetail(row);
                          }
                        }}
                      >
                        <TableCell className="text-center font-medium">
                          {row.name}
                        </TableCell>
                        <TableCell className="text-center font-mono text-xs text-muted-foreground">
                          {row.key_prefix}…
                        </TableCell>
                        <TableCell className="text-center">
                          {scopeBadges(asScopes(row.scopes))}
                        </TableCell>
                        <TableCell className="text-center">
                          <span className="inline-flex items-center gap-1">
                            <Badge
                              variant="outline"
                              className={API_KEY_STATUS_BADGE_CLASSES[status]}
                            >
                              {API_KEY_STATUS_LABELS[status]}
                            </Badge>
                            {isExpired(row) ? (
                              <Badge
                                variant="outline"
                                className={API_KEY_EXPIRED_BADGE_CLASS}
                              >
                                已过期
                              </Badge>
                            ) : null}
                          </span>
                        </TableCell>
                        <TableCell className="text-center text-xs text-muted-foreground">
                          {formatDate(row.expires_at)}
                        </TableCell>
                        <TableCell className="text-center text-xs text-muted-foreground">
                          {formatDateTime(row.last_used_at)}
                        </TableCell>
                        <TableCell className="text-center text-xs text-muted-foreground">
                          {usageTotals.get(row.id) ?? 0}
                        </TableCell>
                        <TableCell className="text-center text-xs text-muted-foreground">
                          {creatorName(row.created_by)}
                        </TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </div>
          )}

          {!loading && !error && filtered.length > 0 ? (
            <div className="flex items-center justify-between gap-2 text-sm text-muted-foreground">
              <span>
                {filtered.length === rows.length
                  ? `共 ${filtered.length} 条 · 第 ${currentPage} / ${pageCount} 页`
                  : `匹配 ${filtered.length} 条（共 ${rows.length} 条）· 第 ${currentPage} / ${pageCount} 页`}
              </span>
              <div className="flex items-center gap-2">
                <Button
                  variant="outline"
                  disabled={currentPage <= 1}
                  onClick={() => setPage(currentPage - 1)}
                  className="h-11 px-4 lg:h-8 lg:px-3"
                >
                  上一页
                </Button>
                <Button
                  variant="outline"
                  disabled={currentPage >= pageCount}
                  onClick={() => setPage(currentPage + 1)}
                  className="h-11 px-4 lg:h-8 lg:px-3"
                >
                  下一页
                </Button>
              </div>
            </div>
          ) : null}
        </CardContent>
      </Card>

      {/* 详情 Sheet：整行可点进入；吊销动作集成在弹窗内（列表无操作列） */}
      <Sheet
        open={detail !== null}
        onOpenChange={(open) => {
          if (!open) {
            setDetail(null);
          }
        }}
      >
        <SheetContent
          side="right"
          className="w-full sm:max-w-[480px]"
        >
          <SheetHeader>
            <SheetTitle>密钥详情</SheetTitle>
            <SheetDescription>
              完整密钥仅在签发时展示一次，此处只能查看前缀与授权信息
            </SheetDescription>
          </SheetHeader>

          {detail ? (
            <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-4">
              <div className="flex flex-col gap-1">
                <div className="text-lg font-medium">{detail.name}</div>
                <div className="font-mono text-xs text-muted-foreground">
                  {detail.key_prefix}…
                </div>
              </div>

              <div className="flex flex-col gap-3 rounded-xl border p-4">
                <div className="flex items-center justify-between gap-4 text-sm">
                  <span className="text-muted-foreground">状态</span>
                  <span className="inline-flex items-center gap-1">
                    <Badge
                      variant="outline"
                      className={
                        API_KEY_STATUS_BADGE_CLASSES[
                          asApiKeyStatus(detail.status)
                        ]
                      }
                    >
                      {API_KEY_STATUS_LABELS[asApiKeyStatus(detail.status)]}
                    </Badge>
                    {isExpired(detail) ? (
                      <Badge
                        variant="outline"
                        className={API_KEY_EXPIRED_BADGE_CLASS}
                      >
                        已过期
                      </Badge>
                    ) : null}
                  </span>
                </div>
                <div className="flex items-center justify-between gap-4 text-sm">
                  <span className="text-muted-foreground">访问范围</span>
                  <span className="flex flex-wrap justify-end gap-1">
                    {asScopes(detail.scopes).map((scope) => (
                      <Badge
                        key={scope}
                        variant="outline"
                        className={API_KEY_SCOPE_BADGE_CLASS}
                      >
                        {API_KEY_SCOPE_LABELS[scope] ?? scope}
                      </Badge>
                    ))}
                  </span>
                </div>
                <div className="flex items-center justify-between gap-4 text-sm">
                  <span className="text-muted-foreground">有效期</span>
                  <span>
                    {detail.expires_at
                      ? `${new Date(detail.expires_at).toLocaleString("zh-CN", { hour12: false })} 到期`
                      : "永不过期"}
                  </span>
                </div>
                <div className="flex items-center justify-between gap-4 text-sm">
                  <span className="text-muted-foreground">最近调用</span>
                  <span>{formatDateTime(detail.last_used_at)}</span>
                </div>
                <div className="flex items-center justify-between gap-4 text-sm">
                  <span className="text-muted-foreground">创建人</span>
                  <span>{creatorName(detail.created_by)}</span>
                </div>
                <div className="flex items-center justify-between gap-4 text-sm">
                  <span className="text-muted-foreground">创建时间</span>
                  <span>{formatDateTime(detail.created_at)}</span>
                </div>
              </div>

              {detail.status === "active" ? (
                <Button
                  variant="outline"
                  onClick={() => void handleRevoke()}
                  disabled={revoking}
                  className="h-11 border-destructive/40 text-destructive hover:bg-destructive/10 lg:h-8"
                >
                  {revoking ? (
                    <Loader2Icon
                      className="animate-spin"
                      data-icon="inline-start"
                    />
                  ) : (
                    <BanIcon data-icon="inline-start" />
                  )}
                  吊销密钥
                </Button>
              ) : (
                <p className="text-xs text-muted-foreground">
                  该密钥已吊销，使用它的调用返回 401，此操作不可恢复。
                </p>
              )}
            </div>
          ) : null}
        </SheetContent>
      </Sheet>

      {/* 签发向导 Sheet：名称 → 范围 → 有效期 → 一次性展示完整密钥 */}
      <Sheet
        open={wizardOpen}
        onOpenChange={(open) => {
          if (!open) {
            closeWizard();
          }
        }}
      >
        <SheetContent
          side="right"
          className="w-full sm:max-w-[480px]"
        >
          <SheetHeader>
            <SheetTitle>签发 API 密钥</SheetTitle>
            <SheetDescription>
              三步完成：填写名称、勾选访问范围、选择有效期
            </SheetDescription>
          </SheetHeader>

          <div className="flex min-h-0 flex-1 flex-col gap-5 overflow-y-auto px-4">
            <ol className="flex items-center gap-1" aria-label="签发步骤">
              {WIZARD_STEPS.map((item, index) => {
                const active = step === item.step;
                const done = step > item.step;
                return (
                  <li
                    key={item.step}
                    className="flex flex-1 items-center gap-1"
                    aria-current={active ? "step" : undefined}
                  >
                    <span
                      className={`flex size-6 shrink-0 items-center justify-center rounded-full border text-xs ${
                        done || active
                          ? "border-primary bg-primary text-primary-foreground"
                          : "text-muted-foreground"
                      }`}
                    >
                      {done ? <CheckIcon className="size-3.5" /> : item.step}
                    </span>
                    <span
                      className={`text-xs ${
                        active ? "font-medium" : "text-muted-foreground"
                      }`}
                    >
                      {item.label}
                    </span>
                    {index < WIZARD_STEPS.length - 1 ? (
                      <span className="mx-1 h-px flex-1 bg-border" />
                    ) : null}
                  </li>
                );
              })}
            </ol>

            {step === 1 ? (
              <Field>
                <FieldLabel htmlFor="api-key-name">密钥名称</FieldLabel>
                <Input
                  id="api-key-name"
                  value={draftName}
                  onChange={(event) => setDraftName(event.target.value)}
                  placeholder="如：ERP 对接（财务）"
                  autoComplete="off"
                  className="h-11 text-base lg:h-8 lg:text-sm"
                />
                <FieldDescription>
                  名称用于识别调用方与排障，不参与鉴权。
                </FieldDescription>
              </Field>
            ) : null}

            {step === 2 ? (
              <Field>
                <FieldLabel>访问范围（scopes）</FieldLabel>
                <div className="flex flex-col gap-3">
                  {API_KEY_SCOPE_OPTIONS.map((option) => (
                    <label
                      key={option.value}
                      htmlFor={`api-key-scope-${option.value}`}
                      className="flex cursor-pointer items-center gap-3 rounded-lg border p-3 has-data-checked:border-primary/40 has-data-checked:bg-primary/5"
                    >
                      <Checkbox
                        id={`api-key-scope-${option.value}`}
                        checked={draftScopes.includes(option.value)}
                        onCheckedChange={(checked) =>
                          toggleScope(option.value, checked === true)
                        }
                      />
                      <span className="flex flex-col">
                        <span className="text-sm font-medium">
                          {option.label}
                        </span>
                        <span className="font-mono text-xs text-muted-foreground">
                          {option.value}
                        </span>
                      </span>
                    </label>
                  ))}
                </div>
                <FieldDescription>
                  按最小授权勾选；未勾选的范围调用一律拒绝。
                </FieldDescription>
              </Field>
            ) : null}

            {step === 3 ? (
              <Field>
                <FieldLabel>有效期</FieldLabel>
                <div className="flex flex-col gap-3">
                  {API_KEY_EXPIRY_OPTIONS.map((option) => (
                    <label
                      key={option.value}
                      htmlFor={`api-key-expiry-${option.value}`}
                      className="flex cursor-pointer items-center gap-3 rounded-lg border p-3 has-data-checked:border-primary/40 has-data-checked:bg-primary/5"
                    >
                      <input
                        type="radio"
                        name="api-key-expiry"
                        id={`api-key-expiry-${option.value}`}
                        value={option.value}
                        checked={draftExpiry === option.value}
                        onChange={() =>
                          setDraftExpiry(option.value as ApiKeyExpiryPreset)
                        }
                        className="size-4 accent-primary"
                      />
                      <span className="text-sm font-medium">
                        {option.label}
                      </span>
                    </label>
                  ))}
                </div>
                <FieldDescription>
                  {draftExpiry === "never"
                    ? "永不过期密钥风险较高，请在不再使用时及时吊销。"
                    : `到期时间：${new Date(
                        Date.now() + Number(draftExpiry) * 86_400_000,
                      ).toLocaleString("zh-CN", {
                        hour12: false,
                      })}（到期后调用自动返回 401）`}
                </FieldDescription>
              </Field>
            ) : null}

            {step === 4 && issued ? (
              <div className="flex flex-col gap-4">
                <div
                  className={`flex items-start gap-2 rounded-xl border p-3 text-sm ${SECRET_WARNING_CALLOUT_CLASS}`}
                >
                  <ShieldAlertIcon className="mt-0.5 size-4 shrink-0" />
                  <p>
                    完整密钥仅此一次展示，关闭后不可再查看。请立即复制并通过安全渠道交付使用方。
                  </p>
                </div>

                <div className="flex flex-col gap-2 rounded-xl border p-4">
                  <div className="text-sm text-muted-foreground">
                    {issued.name}
                  </div>
                  <div className="font-mono text-lg break-all">
                    {issued.key}
                  </div>
                  <Button
                    variant="outline"
                    onClick={() => void copyText(issued.key, "密钥")}
                    className="h-11 lg:h-8"
                  >
                    <CopyIcon data-icon="inline-start" />
                    复制密钥
                  </Button>
                </div>

                <div className="flex flex-col gap-3 rounded-xl border p-4 text-sm">
                  <div className="flex items-center justify-between gap-4">
                    <span className="text-muted-foreground">密钥前缀</span>
                    <span className="font-mono text-xs">
                      {issued.key_prefix}…
                    </span>
                  </div>
                  <div className="flex items-center justify-between gap-4">
                    <span className="text-muted-foreground">访问范围</span>
                    <span className="flex flex-wrap justify-end gap-1">
                      {issued.scopes.map((scope) => (
                        <Badge
                          key={scope}
                          variant="outline"
                          className={API_KEY_SCOPE_BADGE_CLASS}
                        >
                          {API_KEY_SCOPE_LABELS[scope] ?? scope}
                        </Badge>
                      ))}
                    </span>
                  </div>
                  <div className="flex items-center justify-between gap-4">
                    <span className="text-muted-foreground">有效期</span>
                    <span>{formatDate(issued.expires_at)}</span>
                  </div>
                </div>
              </div>
            ) : null}

            {step === 4 && !issued ? (
              <p className="text-sm text-muted-foreground">
                密钥已签发，但服务端未返回完整密钥。请关闭后到列表中确认，如未创建成功可重新签发。
              </p>
            ) : null}
          </div>

          <SheetFooter>
            {step < 4 ? (
              <>
                <Button
                  variant="outline"
                  onClick={closeWizard}
                  className="h-11 lg:h-8"
                >
                  取消
                </Button>
                <div className="flex gap-2">
                  {step > 1 ? (
                    <Button
                      variant="outline"
                      onClick={() => setStep((step - 1) as WizardStep)}
                      className="h-11 lg:h-8"
                    >
                      上一步
                    </Button>
                  ) : null}
                  <Button
                    onClick={goNext}
                    disabled={issuing}
                    className="h-11 lg:h-8"
                  >
                    {issuing ? (
                      <Loader2Icon
                        className="animate-spin"
                        data-icon="inline-start"
                      />
                    ) : null}
                    {step === 3 ? "确认签发" : "下一步"}
                  </Button>
                </div>
              </>
            ) : (
              <>
                {issued ? (
                  <Button
                    variant="outline"
                    onClick={() => void copyText(issued.key, "密钥")}
                    className="h-11 lg:h-8"
                  >
                    <CopyIcon data-icon="inline-start" />
                    复制密钥
                  </Button>
                ) : null}
                <Button onClick={closeWizard} className="h-11 lg:h-8">
                  完成
                </Button>
              </>
            )}
          </SheetFooter>
        </SheetContent>
      </Sheet>
    </div>
  );
}
