"use client";

// 接口文档页面（integration/009）：OpenAPI 3 快照渲染（左侧目录树 + 右侧文档）
// + Webhook 事件清单 + HMAC 验签示例（复制）+ 版本切换；发布仅 admin（Sheet）。
// 数据源 api_docs（登录可读；发布走 publish_api_doc RPC，admin 校验在服务端）。

import * as React from "react";
import {
  CopyIcon,
  Loader2Icon,
  PlusIcon,
  ShieldCheckIcon,
  WebhookIcon,
} from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Field, FieldLabel } from "@/components/ui/field";
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
import { Textarea } from "@/components/ui/textarea";
import type { Database, Json } from "@/lib/database.types";
import { translateIntegrationErrorMessage } from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

type ApiDocRow = Pick<
  Database["public"]["Tables"]["api_docs"]["Row"],
  "id" | "version" | "changelog" | "published_by" | "created_at"
>;
type ProfileRow = Pick<
  Database["public"]["Tables"]["profiles"]["Row"],
  "id" | "full_name" | "email"
>;
type Spec = Record<string, unknown>;

type NavItem = { id: string; label: string; method?: string; path?: string };
type NavGroup = { id: string; label: string; items: NavItem[] };

const HTTP_METHODS = ["get", "post", "put", "patch", "delete", "head", "options"];

const METHOD_BADGE_CLASSES: Record<string, string> = {
  get: "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300",
  post: "border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-900/60 dark:bg-blue-950/60 dark:text-blue-300",
  put: "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-900/60 dark:bg-amber-950/60 dark:text-amber-300",
  patch:
    "border-violet-200 bg-violet-50 text-violet-700 dark:border-violet-900/60 dark:bg-violet-950/60 dark:text-violet-300",
  delete:
    "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300",
};

const asRecord = (value: unknown): Spec | null =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Spec)
    : null;

const asArray = (value: unknown): unknown[] =>
  Array.isArray(value) ? value : [];

const asString = (value: unknown): string | null =>
  typeof value === "string" ? value : null;

const anchorId = (method: string, path: string) =>
  `op-${method}-${path.replace(/[^a-zA-Z0-9_-]/g, "-")}`;

function buildNav(spec: Spec): NavGroup[] {
  const tagLabels = new Map<string, string>();
  for (const tag of asArray(spec.tags)) {
    const record = asRecord(tag);
    const name = asString(record?.name);
    if (name) {
      tagLabels.set(name, asString(record?.description) ?? name);
    }
  }

  const groups: NavGroup[] = [];
  const groupMap = new Map<string, NavGroup>();
  const paths = asRecord(spec.paths) ?? {};

  for (const [path, pathItemRaw] of Object.entries(paths)) {
    const pathItem = asRecord(pathItemRaw);
    if (!pathItem) {
      continue;
    }
    for (const method of HTTP_METHODS) {
      const operation = asRecord(pathItem[method]);
      if (!operation) {
        continue;
      }
      const tags = asArray(operation.tags)
        .map(asString)
        .filter((value): value is string => Boolean(value));
      const tag = tags[0] ?? "默认";
      const label =
        asString(operation.summary) ??
        asString(operation.operationId) ??
        `${method.toUpperCase()} ${path}`;

      let group = groupMap.get(tag);
      if (!group) {
        group = {
          id: `group-${tag}`,
          label: tagLabels.get(tag) ?? tag,
          items: [],
        };
        groupMap.set(tag, group);
        groups.push(group);
      }
      group.items.push({ id: anchorId(method, path), label, method, path });
    }
  }
  return groups;
}

function requestParameters(operation: Spec) {
  const body = asRecord(operation.requestBody);
  const content = asRecord(body?.content);
  const jsonContent = asRecord(content?.["application/json"]);
  const schema = asRecord(jsonContent?.schema);
  const properties = asRecord(schema?.properties) ?? {};
  const required = new Set(
    asArray(schema?.required)
      .map(asString)
      .filter((value): value is string => Boolean(value)),
  );

  return Object.entries(properties).map(([name, raw]) => {
    const property = asRecord(raw) ?? {};
    return {
      name,
      type: asString(property.type) ?? "—",
      required: required.has(name),
      description: asString(property.description),
    };
  });
}

function requestExample(operation: Spec): string | null {
  const body = asRecord(operation.requestBody);
  const content = asRecord(body?.content);
  const jsonContent = asRecord(content?.["application/json"]);
  if (!jsonContent || !("example" in jsonContent)) {
    return null;
  }
  return JSON.stringify(jsonContent.example, null, 2);
}

function CodeBlock({
  code,
  label,
}: {
  code: string;
  label?: string;
}) {
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(code);
      toast.success("代码已复制");
    } catch {
      toast.error("复制失败，请手动选择并复制");
    }
  };

  return (
    <div className="relative rounded-lg border bg-muted/40">
      <div className="flex items-center justify-between border-b px-3 py-1.5">
        <span className="font-mono text-xs text-muted-foreground">
          {label ?? "示例"}
        </span>
        <Button
          variant="ghost"
          size="icon"
          className="size-7"
          onClick={() => void copy()}
          aria-label="复制代码"
        >
          <CopyIcon className="size-3.5" />
        </Button>
      </div>
      <pre className="max-h-80 overflow-auto p-3 font-mono text-xs break-all whitespace-pre-wrap">
        {code}
      </pre>
    </div>
  );
}

export function DocsView({ isAdmin }: { isAdmin: boolean }) {
  const [versions, setVersions] = React.useState<ApiDocRow[]>([]);
  const [publishers, setPublishers] = React.useState<Map<string, string>>(
    new Map(),
  );
  const [selectedVersion, setSelectedVersion] = React.useState("");
  const [spec, setSpec] = React.useState<Spec | null>(null);
  const [loadingVersions, setLoadingVersions] = React.useState(true);
  const [loadingSpec, setLoadingSpec] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);
  const [jumpTarget, setJumpTarget] = React.useState("");

  const [publishOpen, setPublishOpen] = React.useState(false);
  const [versionInput, setVersionInput] = React.useState("");
  const [changelogInput, setChangelogInput] = React.useState("");
  const [specInput, setSpecInput] = React.useState("");
  const [publishing, setPublishing] = React.useState(false);

  const loadVersions = React.useCallback(async (): Promise<ApiDocRow[]> => {
    setLoadingVersions(true);
    setError(null);
    const supabase = createClient();
    const [docsRes, profilesRes] = await Promise.all([
      supabase
        .from("api_docs")
        .select("id, version, changelog, published_by, created_at")
        .order("created_at", { ascending: false }),
      supabase.from("profiles").select("id, full_name, email"),
    ]);

    if (docsRes.error) {
      setError(docsRes.error.message);
      setVersions([]);
      setLoadingVersions(false);
      return [];
    }

    const rows = (docsRes.data ?? []) as ApiDocRow[];
    setVersions(rows);
    setSelectedVersion((prev) =>
      prev && rows.some((row) => row.version === prev)
        ? prev
        : (rows[0]?.version ?? ""),
    );

    if (!profilesRes.error) {
      const map = new Map<string, string>();
      for (const profile of (profilesRes.data ?? []) as ProfileRow[]) {
        map.set(
          profile.id,
          profile.full_name ?? profile.email?.split("@")[0] ?? "未知用户",
        );
      }
      setPublishers(map);
    }

    setLoadingVersions(false);
    return rows;
  }, []);

  React.useEffect(() => {
    void loadVersions();
  }, [loadVersions]);

  React.useEffect(() => {
    if (!selectedVersion) {
      setSpec(null);
      return;
    }
    let cancelled = false;
    setLoadingSpec(true);
    void (async () => {
      const { data, error: specError } = await createClient()
        .from("api_docs")
        .select("spec")
        .eq("version", selectedVersion)
        .maybeSingle();
      if (cancelled) {
        return;
      }
      setLoadingSpec(false);
      if (specError || !data) {
        toast.error(
          `规格加载失败：${translateIntegrationErrorMessage(specError?.message ?? "未知错误")}`,
        );
        setSpec(null);
        return;
      }
      setSpec(asRecord(data.spec) ?? {});
    })();
    return () => {
      cancelled = true;
    };
  }, [selectedVersion]);

  const nav = React.useMemo(() => (spec ? buildNav(spec) : []), [spec]);

  const currentDoc = versions.find((row) => row.version === selectedVersion);

  const jumpItems = React.useMemo(() => {
    const items: { id: string; label: string }[] = [
      { id: "auth", label: "鉴权说明" },
    ];
    for (const group of nav) {
      for (const item of group.items) {
        items.push({ id: item.id, label: `${group.label} · ${item.label}` });
      }
    }
    items.push({ id: "events", label: "Webhook 事件清单" });
    items.push({ id: "signature", label: "签名与验签示例" });
    return items;
  }, [nav]);

  const scrollTo = (id: string) => {
    document.getElementById(id)?.scrollIntoView({
      behavior: "smooth",
      block: "start",
    });
  };

  const openPublish = () => {
    setVersionInput("");
    setChangelogInput("");
    setSpecInput(spec ? JSON.stringify(spec, null, 2) : "");
    setPublishOpen(true);
  };

  const handlePublish = async () => {
    const version = versionInput.trim();
    if (!/^v[0-9]+(\.[0-9]+)*$/.test(version)) {
      toast.error("版本号需形如 v1 或 v1.2");
      return;
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(specInput);
    } catch {
      toast.error("规格不是合法 JSON，请检查语法");
      return;
    }
    if (!asRecord(parsed)) {
      toast.error("规格必须为 JSON 对象");
      return;
    }

    setPublishing(true);
    const { error: publishError } = await createClient().rpc("publish_api_doc", {
      p_version: version,
      p_spec: parsed as Json,
      p_changelog: changelogInput.trim() || undefined,
    });
    setPublishing(false);

    if (publishError) {
      toast.error(translateIntegrationErrorMessage(publishError.message));
      return;
    }

    toast.success(`版本 ${version} 已发布`);
    setPublishOpen(false);
    setSelectedVersion(version);
    await loadVersions();
  };

  const securitySchemes = spec
    ? (asRecord(asRecord(spec.components)?.securitySchemes) ?? {})
    : {};
  const webhookEvents = spec ? asArray(spec["x-webhook-events"]) : [];
  const signature = spec ? asRecord(spec["x-webhook-signature"]) : null;

  const publisherName = currentDoc
    ? (currentDoc.published_by
        ? (publishers.get(currentDoc.published_by) ?? "已离职用户")
        : "系统内置")
    : "—";

  const renderOperation = (
    method: string,
    path: string,
    operationRaw: unknown,
  ) => {
    const operation = asRecord(operationRaw) ?? {};
    const parameters = requestParameters(operation);
    const example = requestExample(operation);
    const responses = Object.entries(asRecord(operation.responses) ?? {});

    return (
      <section
        key={anchorId(method, path)}
        id={anchorId(method, path)}
        className="scroll-mt-20 rounded-lg border p-4"
      >
        <div className="flex flex-wrap items-center gap-2">
          <Badge
            variant="outline"
            className={METHOD_BADGE_CLASSES[method] ?? ""}
          >
            {method.toUpperCase()}
          </Badge>
          <code className="font-mono text-sm">{path}</code>
          <span className="text-sm text-muted-foreground">
            {asString(operation.summary) ?? ""}
          </span>
        </div>
        {asString(operation.description) ? (
          <p className="mt-2 text-sm text-muted-foreground">
            {asString(operation.description)}
          </p>
        ) : null}

        {parameters.length > 0 ? (
          <div className="mt-3">
            <h4 className="mb-1.5 text-sm font-medium">参数</h4>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="text-center">名称</TableHead>
                  <TableHead className="text-center">类型</TableHead>
                  <TableHead className="text-center">必填</TableHead>
                  <TableHead className="text-center">说明</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {parameters.map((parameter) => (
                  <TableRow key={parameter.name}>
                    <TableCell className="text-center font-mono text-xs">
                      {parameter.name}
                    </TableCell>
                    <TableCell className="text-center text-xs">
                      {parameter.type}
                    </TableCell>
                    <TableCell className="text-center text-xs">
                      {parameter.required ? "是" : "否"}
                    </TableCell>
                    <TableCell className="text-center text-xs text-muted-foreground">
                      {parameter.description ?? "—"}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        ) : null}

        {example ? (
          <div className="mt-3">
            <h4 className="mb-1.5 text-sm font-medium">请求示例</h4>
            <CodeBlock code={example} label="application/json" />
          </div>
        ) : null}

        {responses.length > 0 ? (
          <div className="mt-3 flex flex-col gap-2">
            <h4 className="text-sm font-medium">响应</h4>
            {responses.map(([status, responseRaw]) => {
              const response = asRecord(responseRaw) ?? {};
              const content = asRecord(response.content);
              const jsonContent = asRecord(content?.["application/json"]);
              const responseExample =
                jsonContent && "example" in jsonContent
                  ? JSON.stringify(jsonContent.example, null, 2)
                  : null;
              return (
                <div key={status} className="flex flex-col gap-1.5">
                  <div className="flex items-center gap-2">
                    <Badge
                      variant="outline"
                      className={
                        Number(status) >= 400
                          ? "border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300"
                          : "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-900/60 dark:bg-emerald-950/60 dark:text-emerald-300"
                      }
                    >
                      {status}
                    </Badge>
                    <span className="text-sm text-muted-foreground">
                      {asString(response.description) ?? ""}
                    </span>
                  </div>
                  {responseExample ? (
                    <CodeBlock code={responseExample} label="响应示例" />
                  ) : null}
                </div>
              );
            })}
          </div>
        ) : null}
      </section>
    );
  };

  const renderContent = () => {
    if (loadingVersions || loadingSpec) {
      return (
        <div className="flex flex-col gap-3">
          {Array.from({ length: 4 }).map((_, index) => (
            <Skeleton key={index} className="h-24 w-full" />
          ))}
        </div>
      );
    }
    if (error || !spec) {
      return (
        <div className="flex flex-col items-center gap-2 py-12 text-sm">
          <p className="text-destructive">
            加载失败：{translateIntegrationErrorMessage(error ?? "暂无接口文档")}
          </p>
          <Button variant="outline" onClick={() => void loadVersions()}>
            重试
          </Button>
        </div>
      );
    }

    const info = asRecord(spec.info) ?? {};
    const servers = asArray(spec.servers)
      .map(asRecord)
      .filter((value): value is Spec => Boolean(value));

    return (
      <div className="flex flex-col gap-6">
        <section id="auth" className="scroll-mt-20">
          <h2 className="text-lg font-semibold">鉴权说明</h2>
          <p className="mt-1 text-sm text-muted-foreground">
            {asString(info.description) ?? ""}
          </p>
          <div className="mt-3 flex flex-col gap-2">
            {Object.entries(securitySchemes).map(([name, schemeRaw]) => {
              const scheme = asRecord(schemeRaw) ?? {};
              return (
                <div
                  key={name}
                  className="flex flex-col gap-1 rounded-lg border p-3"
                >
                  <div className="flex items-center gap-2">
                    <Badge variant="outline" className="font-mono">
                      {name}
                    </Badge>
                    <span className="text-sm font-medium">
                      {asString(scheme.type) === "http"
                        ? `HTTP ${asString(scheme.scheme) ?? ""}`
                        : `API Key（${asString(scheme.in) ?? "header"}: ${
                            asString(scheme.name) ?? ""
                          }）`}
                    </span>
                  </div>
                  <p className="text-sm text-muted-foreground">
                    {asString(scheme.description) ?? ""}
                  </p>
                </div>
              );
            })}
          </div>
          {servers.length > 0 ? (
            <div className="mt-3 text-xs text-muted-foreground">
              服务地址：
              {servers
                .map((server) => asString(server.url) ?? "")
                .filter(Boolean)
                .join("、")}
            </div>
          ) : null}
        </section>

        <section id="api" className="scroll-mt-20">
          <h2 className="text-lg font-semibold">API 目录</h2>
        </section>

        {nav.map((group) => (
          <section
            key={group.id}
            id={group.id}
            className="scroll-mt-20 flex flex-col gap-3"
          >
            <h3 className="text-base font-medium">{group.label}</h3>
            {group.items.map((item) => {
              const pathItem = asRecord(
                (asRecord(spec.paths) ?? {})[item.path ?? ""],
              );
              const operation = pathItem?.[item.method ?? ""];
              return operation
                ? renderOperation(item.method ?? "", item.path ?? "", operation)
                : null;
            })}
          </section>
        ))}

        <section id="events" className="scroll-mt-20">
          <h2 className="text-lg font-semibold">Webhook 事件清单</h2>
          <p className="mt-1 text-sm text-muted-foreground">
            订阅端点按事件名过滤；事件信封含 id / event / created_at / data。
          </p>
          {webhookEvents.length === 0 ? (
            <div className="mt-3 rounded-lg border border-dashed py-8 text-center text-sm text-muted-foreground">
              <WebhookIcon className="mx-auto mb-2 size-6 opacity-60" />
              当前版本未登记 Webhook 事件
            </div>
          ) : (
            <div className="mt-3 overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="text-center">事件名</TableHead>
                    <TableHead className="text-center">模块</TableHead>
                    <TableHead className="text-center">说明</TableHead>
                    <TableHead className="text-center">Payload 摘要</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {webhookEvents.map((eventRaw, index) => {
                    const event = asRecord(eventRaw) ?? {};
                    const schema = asRecord(event.payload_schema);
                    return (
                      <TableRow key={`${asString(event.event) ?? index}`}>
                        <TableCell className="text-center font-mono text-xs">
                          {asString(event.event) ?? "—"}
                        </TableCell>
                        <TableCell className="text-center">
                          {asString(event.module) ?? "—"}
                        </TableCell>
                        <TableCell className="text-center text-sm">
                          {asString(event.summary) ?? "—"}
                        </TableCell>
                        <TableCell className="text-center text-xs text-muted-foreground">
                          {schema
                            ? Object.entries(schema)
                                .map(
                                  ([key, value]) =>
                                    `${key}: ${String(value)}`,
                                )
                                .join("，")
                            : "—"}
                        </TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </div>
          )}
        </section>

        <section id="signature" className="scroll-mt-20">
          <h2 className="text-lg font-semibold">签名与验签示例</h2>
          <p className="mt-1 text-sm text-muted-foreground">
            算法：{asString(signature?.algorithm) ?? "HMAC-SHA256"}；请求头
            {Object.entries(asRecord(signature?.headers) ?? {}).length > 0
              ? Object.entries(asRecord(signature?.headers) ?? {})
                  .map(([key, value]) => ` ${key} = ${String(value)}`)
                  .join("；")
              : ""}
            。
          </p>
          <div className="mt-3 flex flex-col gap-3">
            {asArray(signature?.examples).map((exampleRaw, index) => {
              const example = asRecord(exampleRaw) ?? {};
              return (
                <CodeBlock
                  key={`${asString(example.language) ?? index}`}
                  code={asString(example.code) ?? ""}
                  label={asString(example.label) ?? "示例"}
                />
              );
            })}
          </div>
        </section>
      </div>
    );
  };

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-wrap items-center gap-2">
            <Select
              value={selectedVersion}
              onValueChange={setSelectedVersion}
              disabled={versions.length === 0}
            >
              <SelectTrigger
                className="h-11 w-full sm:w-40 lg:h-8"
                aria-label="切换文档版本"
              >
                <SelectValue placeholder="选择版本" />
              </SelectTrigger>
              <SelectContent>
                {versions.map((row) => (
                  <SelectItem key={row.id} value={row.version}>
                    {row.version}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            {isAdmin ? (
              <Button
                onClick={openPublish}
                disabled={versions.length === 0}
                className="h-11 w-full sm:w-auto lg:h-8"
              >
                <PlusIcon data-icon="inline-start" />
                发布新版本
              </Button>
            ) : null}
            {spec ? (
              <Select value={jumpTarget} onValueChange={(value) => {
                setJumpTarget(value);
                scrollTo(value);
              }}>
                <SelectTrigger
                  className="h-11 w-full lg:hidden"
                  aria-label="目录跳转"
                >
                  <SelectValue placeholder="目录跳转" />
                </SelectTrigger>
                <SelectContent>
                  {jumpItems.map((item) => (
                    <SelectItem key={item.id} value={item.id}>
                      {item.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            ) : null}
          </div>

          <p className="text-xs text-muted-foreground">
            {currentDoc
              ? `当前版本 ${currentDoc.version} · 发布人 ${publisherName} · ${
                  currentDoc.changelog ?? "无变更说明"
                }`
              : "OpenAPI 3 规格与 Webhook 事件清单"}
          </p>

          <div className="grid gap-6 lg:grid-cols-[240px_1fr]">
            <nav
              aria-label="文档目录"
              className="hidden lg:block lg:sticky lg:top-4 lg:self-start"
            >
              <div className="flex flex-col gap-1 text-sm">
                <button
                  type="button"
                  onClick={() => scrollTo("auth")}
                  className="rounded-md px-2 py-1 text-left text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
                >
                  鉴权说明
                </button>
                {nav.map((group) => (
                  <div key={group.id} className="flex flex-col gap-0.5">
                    <div className="px-2 pt-2 pb-1 text-xs font-medium text-muted-foreground uppercase">
                      {group.label}
                    </div>
                    {group.items.map((item) => (
                      <button
                        key={item.id}
                        type="button"
                        onClick={() => scrollTo(item.id)}
                        className="rounded-md px-2 py-1 text-left transition-colors hover:bg-accent hover:text-foreground"
                      >
                        <span className="mr-1.5 font-mono text-[10px] text-muted-foreground uppercase">
                          {item.method}
                        </span>
                        {item.label}
                      </button>
                    ))}
                  </div>
                ))}
                <button
                  type="button"
                  onClick={() => scrollTo("events")}
                  className="rounded-md px-2 py-1 text-left text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
                >
                  Webhook 事件清单
                </button>
                <button
                  type="button"
                  onClick={() => scrollTo("signature")}
                  className="rounded-md px-2 py-1 text-left text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
                >
                  签名与验签示例
                </button>
              </div>
            </nav>

            <div className="min-w-0">{renderContent()}</div>
          </div>
        </CardContent>
      </Card>

      <Sheet open={publishOpen} onOpenChange={setPublishOpen}>
        <SheetContent
          side="right"
          className="w-full sm:max-w-[480px]"
        >
          <SheetHeader>
            <SheetTitle>发布新版本</SheetTitle>
            <SheetDescription>
              发布 OpenAPI 3 快照（版本唯一，修订请发布新版本号）
            </SheetDescription>
          </SheetHeader>
          <div className="flex min-h-0 flex-col gap-4 overflow-y-auto px-4">
            <Field>
              <FieldLabel htmlFor="doc-version">版本号</FieldLabel>
              <Input
                id="doc-version"
                value={versionInput}
                onChange={(event) => setVersionInput(event.target.value)}
                placeholder="v1.1"
                className="h-11 text-base lg:h-8 lg:text-sm"
              />
            </Field>
            <Field>
              <FieldLabel htmlFor="doc-changelog">变更说明</FieldLabel>
              <Textarea
                id="doc-changelog"
                value={changelogInput}
                onChange={(event) => setChangelogInput(event.target.value)}
                placeholder="本版本新增/变更的接口与事件"
                rows={3}
              />
            </Field>
            <Field>
              <FieldLabel htmlFor="doc-spec">OpenAPI 规格（JSON）</FieldLabel>
              <Textarea
                id="doc-spec"
                value={specInput}
                onChange={(event) => setSpecInput(event.target.value)}
                rows={18}
                className="font-mono text-xs"
                placeholder='{"openapi":"3.1.0","info":{...},"paths":{...}}'
              />
            </Field>
          </div>
          <SheetFooter>
            <Button
              variant="outline"
              onClick={() => setPublishOpen(false)}
              className="h-11 lg:h-8"
            >
              取消
            </Button>
            <Button
              onClick={() => void handlePublish()}
              disabled={publishing}
              className="h-11 lg:h-8"
            >
              {publishing ? (
                <Loader2Icon className="animate-spin" data-icon="inline-start" />
              ) : (
                <ShieldCheckIcon data-icon="inline-start" />
              )}
              发布
            </Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>
    </div>
  );
}
