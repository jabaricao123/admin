"use client";

// 数据变更页面（audit/007）：白名单表选择 + 记录检索（record_id / 最近变更点击）
// → 版本时间线（版本号/操作人/时间/变更类型）→ 任两版本双栏字段对比；
// 底部白名单管理（Table + enable 开关）。
// 数据源：get_row_versions / list_recent_versions / upsert_row_version_whitelist（均 admin）。

import * as React from "react";
import {
  ArrowRightIcon,
  CheckIcon,
  FileClockIcon,
  FileSearchIcon,
  Loader2Icon,
} from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { Switch } from "@/components/ui/switch";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { Database, Json } from "@/lib/database.types";
import {
  formatDateTime,
  formatDiffValue,
  isPlainObject,
  rowVersionChangeBadgeClass,
  rowVersionChangeLabel,
  rowVersionFieldLabel,
  rowVersionTableLabel,
  translateAuditErrorMessage,
} from "@/lib/audit";
import { createClient } from "@/lib/supabase/client";

const RECENT_LIMIT = 50;

/** 白名单表展示顺序（首期三表优先，未知表按表名字母序垫后） */
const TABLE_ORDER = ["profiles", "departments", "positions"];

function tableRank(table: string): number {
  const index = TABLE_ORDER.indexOf(table);
  return index === -1 ? TABLE_ORDER.length : index;
}

type WhitelistRow =
  Database["public"]["Tables"]["audit_row_version_whitelist"]["Row"];

/** returns table 可空列在生成类型中未标注，这里修正 */
type VersionRow = Omit<
  Database["public"]["Functions"]["get_row_versions"]["Returns"][number],
  "changed_by" | "changed_by_name"
> & {
  changed_by: string | null;
  changed_by_name: string | null;
};

type RecentRow = Omit<
  Database["public"]["Functions"]["list_recent_versions"]["Returns"][number],
  "changed_by" | "changed_by_name"
> & {
  changed_by: string | null;
  changed_by_name: string | null;
};

function ChangeTypeBadge({ changeType }: { changeType: string | null | undefined }) {
  return (
    <Badge
      variant="outline"
      className={rowVersionChangeBadgeClass(changeType ?? "")}
    >
      {rowVersionChangeLabel(changeType)}
    </Badge>
  );
}

/** 快照主字段摘要：profiles.full_name / 通用 name / code */
function versionSummary(data: Json): string {
  if (!isPlainObject(data)) {
    return "";
  }
  const candidate = data.full_name ?? data.name ?? data.code;
  return typeof candidate === "string" ? candidate : "";
}

/** 字段值展示：*_at 字段格式化为本地时间，其余走 diff 值格式化 */
function renderFieldValue(key: string, value: Json | undefined): string {
  if (value === undefined) {
    return "—";
  }
  if (key.endsWith("_at") && typeof value === "string") {
    return formatDateTime(value);
  }
  return formatDiffValue(value);
}

export function ChangesTable() {
  const [whitelist, setWhitelist] = React.useState<WhitelistRow[]>([]);
  const [whitelistLoading, setWhitelistLoading] = React.useState(true);
  const [whitelistError, setWhitelistError] = React.useState<string | null>(null);
  const [selectedTable, setSelectedTable] = React.useState("");
  const [recordInput, setRecordInput] = React.useState("");

  const [activeRecord, setActiveRecord] = React.useState<{
    table: string;
    recordId: string;
  } | null>(null);
  const [timeline, setTimeline] = React.useState<VersionRow[]>([]);
  const [timelineLoading, setTimelineLoading] = React.useState(false);
  const [timelineError, setTimelineError] = React.useState<string | null>(null);
  const [selectedIds, setSelectedIds] = React.useState<number[]>([]);

  const [recent, setRecent] = React.useState<RecentRow[]>([]);
  const [recentLoading, setRecentLoading] = React.useState(false);
  const [recentError, setRecentError] = React.useState<string | null>(null);

  const [savingTable, setSavingTable] = React.useState<string | null>(null);

  const sortedWhitelist = React.useMemo(
    () =>
      [...whitelist].sort(
        (a, b) =>
          tableRank(a.table_name) - tableRank(b.table_name) ||
          a.table_name.localeCompare(b.table_name),
      ),
    [whitelist],
  );

  const loadWhitelist = React.useCallback(async () => {
    setWhitelistLoading(true);
    const { data, error } = await createClient()
      .from("audit_row_version_whitelist")
      .select("*");

    setWhitelistLoading(false);
    if (error) {
      setWhitelistError(error.message);
      return;
    }
    setWhitelistError(null);
    setWhitelist(data ?? []);
  }, []);

  React.useEffect(() => {
    void loadWhitelist();
  }, [loadWhitelist]);

  React.useEffect(() => {
    if (!selectedTable && sortedWhitelist.length > 0) {
      setSelectedTable(sortedWhitelist[0].table_name);
    }
  }, [sortedWhitelist, selectedTable]);

  const loadRecent = React.useCallback(async (table: string) => {
    setRecentLoading(true);
    setRecentError(null);
    const { data, error } = await createClient().rpc("list_recent_versions", {
      p_table: table,
      p_limit: RECENT_LIMIT,
    });

    setRecentLoading(false);
    if (error) {
      setRecentError(error.message);
      setRecent([]);
      return;
    }
    setRecent(data ?? []);
  }, []);

  React.useEffect(() => {
    if (selectedTable) {
      void loadRecent(selectedTable);
    }
  }, [selectedTable, loadRecent]);

  const loadVersions = React.useCallback(async (table: string, recordId: string) => {
    setTimelineLoading(true);
    setTimelineError(null);
    setActiveRecord({ table, recordId });

    const { data, error } = await createClient().rpc("get_row_versions", {
      p_table: table,
      p_record_id: recordId,
    });

    setTimelineLoading(false);
    if (error) {
      setTimelineError(error.message);
      setTimeline([]);
      setSelectedIds([]);
      return;
    }

    const rows = data ?? [];
    setTimeline(rows);
    // 默认选中最后两个版本（没有两个则选中全部），便于直接对比
    const lastTwo = [...rows]
      .sort((a, b) => a.version - b.version)
      .slice(-2)
      .map((row) => row.id);
    setSelectedIds(lastTwo);
  }, []);

  const resetDetail = () => {
    setTimeline([]);
    setActiveRecord(null);
    setSelectedIds([]);
    setTimelineError(null);
  };

  const handleTableChange = (table: string) => {
    setSelectedTable(table);
    setRecordInput("");
    resetDetail();
  };

  const handleSearch = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const recordId = recordInput.trim();
    if (!selectedTable) {
      toast.error("请先选择留痕表");
      return;
    }
    if (!recordId) {
      toast.error("请输入记录标识（record_id）");
      return;
    }
    void loadVersions(selectedTable, recordId);
  };

  const handleRecentClick = (row: RecentRow) => {
    if (!selectedTable) {
      return;
    }
    setRecordInput(row.record_id);
    void loadVersions(selectedTable, row.record_id);
  };

  const toggleVersion = (id: number) => {
    setSelectedIds((prev) => {
      if (prev.includes(id)) {
        return prev.filter((value) => value !== id);
      }
      if (prev.length >= 2) {
        // 已选两个：替换较早选中的那个（保持最近点选优先）
        return [prev[1], id];
      }
      return [...prev, id];
    });
  };

  const handleToggleWhitelist = async (row: WhitelistRow, enabled: boolean) => {
    setSavingTable(row.table_name);
    const { data, error } = await createClient().rpc(
      "upsert_row_version_whitelist",
      { p_table: row.table_name, p_enabled: enabled },
    );
    setSavingTable(null);

    if (error) {
      toast.error(translateAuditErrorMessage(error.message));
      return;
    }

    const result = (data ?? null) as { notice?: string | null } | null;
    if (result?.notice) {
      toast.info(result.notice);
    } else {
      toast.success(
        enabled
          ? `已启用「${rowVersionTableLabel(row.table_name)}」留痕`
          : `已停用「${rowVersionTableLabel(row.table_name)}」留痕`,
      );
    }
    void loadWhitelist();
  };

  /** 版本对比：选中的两个版本按 version 升序（旧 → 新） */
  const comparePair = React.useMemo(() => {
    if (selectedIds.length !== 2 || timeline.length === 0) {
      return null;
    }
    const rows = timeline.filter((row) => selectedIds.includes(row.id));
    if (rows.length !== 2) {
      return null;
    }
    const sorted = [...rows].sort((a, b) => a.version - b.version);
    return { before: sorted[0], after: sorted[1] };
  }, [selectedIds, timeline]);

  type DiffField = {
    key: string;
    label: string;
    before?: Json;
    after?: Json;
    changed: boolean;
  };

  const diffFields = React.useMemo<DiffField[]>(() => {
    if (!comparePair) {
      return [];
    }
    const beforeData = isPlainObject(comparePair.before.data)
      ? comparePair.before.data
      : {};
    const afterData = isPlainObject(comparePair.after.data)
      ? comparePair.after.data
      : {};
    const keys = Array.from(
      new Set([...Object.keys(beforeData), ...Object.keys(afterData)]),
    );

    const fields: DiffField[] = keys.map((key) => ({
      key,
      label: rowVersionFieldLabel(key),
      before: beforeData[key],
      after: afterData[key],
      changed:
        JSON.stringify(beforeData[key] ?? null) !==
        JSON.stringify(afterData[key] ?? null),
    }));
    // 变更字段置顶（字段无遗漏：未变字段仍展示）
    return fields.sort((a, b) => Number(b.changed) - Number(a.changed));
  }, [comparePair]);

  const changedCount = diffFields.filter((field) => field.changed).length;

  const renderRecent = () => {
    if (recentLoading) {
      return (
        <div className="flex flex-col gap-2">
          {Array.from({ length: 4 }).map((_, index) => (
            <Skeleton key={index} className="h-11 w-full" />
          ))}
        </div>
      );
    }
    if (recentError) {
      return (
        <p className="py-6 text-center text-sm text-destructive">
          加载失败：{translateAuditErrorMessage(recentError)}
        </p>
      );
    }
    if (recent.length === 0) {
      return (
        <div className="flex flex-col items-center gap-2 py-10 text-sm text-muted-foreground">
          <FileClockIcon className="size-8 opacity-60" />
          <span>该表暂无变更记录</span>
        </div>
      );
    }

    return (
      <>
        <div className="hidden overflow-x-auto md:block">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>记录</TableHead>
                <TableHead className="text-center">版本</TableHead>
                <TableHead className="text-center">操作人</TableHead>
                <TableHead className="text-center">时间</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {recent.map((row) => (
                <TableRow
                  key={row.id}
                  className="cursor-pointer"
                  tabIndex={0}
                  onClick={() => handleRecentClick(row)}
                  onKeyDown={(event) => {
                    if (event.target !== event.currentTarget) {
                      return;
                    }
                    if (event.key === "Enter" || event.key === " ") {
                      event.preventDefault();
                      handleRecentClick(row);
                    }
                  }}
                >
                  <TableCell className="max-w-56 truncate font-mono text-xs">
                    {row.record_id}
                  </TableCell>
                  <TableCell className="text-center font-mono text-xs">
                    v{row.version}
                  </TableCell>
                  <TableCell className="text-center">
                    {row.changed_by_name ?? "系统/后台"}
                  </TableCell>
                  <TableCell className="text-center text-xs whitespace-nowrap text-muted-foreground">
                    {formatDateTime(row.changed_at)}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
        <div className="flex flex-col gap-2 md:hidden">
          {recent.map((row) => (
            <button
              key={row.id}
              type="button"
              onClick={() => handleRecentClick(row)}
              className="flex w-full items-center justify-between gap-3 rounded-xl border bg-card p-3 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
            >
              <div className="flex min-w-0 flex-col gap-1">
                <span className="truncate font-mono text-xs">{row.record_id}</span>
                <span className="truncate text-xs text-muted-foreground">
                  {row.changed_by_name ?? "系统/后台"} ·{" "}
                  {formatDateTime(row.changed_at)}
                </span>
              </div>
              <Badge variant="outline" className="shrink-0 font-mono">
                v{row.version}
              </Badge>
            </button>
          ))}
        </div>
      </>
    );
  };

  const renderTimeline = () => {
    if (timelineLoading) {
      return (
        <div className="flex flex-col gap-2">
          {Array.from({ length: 4 }).map((_, index) => (
            <Skeleton key={index} className="h-16 w-full" />
          ))}
        </div>
      );
    }
    if (timelineError) {
      return (
        <p className="py-6 text-center text-sm text-destructive">
          加载失败：{translateAuditErrorMessage(timelineError)}
        </p>
      );
    }
    if (!activeRecord) {
      return (
        <div className="flex flex-col items-center gap-2 py-10 text-sm text-muted-foreground">
          <FileSearchIcon className="size-8 opacity-60" />
          <span>输入记录标识，或点击左侧最近变更，查看版本时间线</span>
        </div>
      );
    }
    if (timeline.length === 0) {
      return (
        <div className="flex flex-col items-center gap-2 py-10 text-sm text-muted-foreground">
          <FileSearchIcon className="size-8 opacity-60" />
          <span>未找到该记录的版本记录</span>
        </div>
      );
    }

    return (
      <ol className="relative ml-1.5 flex list-none flex-col gap-3 border-l pl-5">
        {timeline.map((row) => {
          const selected = selectedIds.includes(row.id);
          const summary = versionSummary(row.data);

          return (
            <li key={row.id} className="relative">
              <span
                className={`absolute top-4 -left-[25px] size-2.5 rounded-full border-2 border-background ${
                  selected ? "bg-primary" : "bg-muted-foreground/40"
                }`}
              />
              <button
                type="button"
                onClick={() => toggleVersion(row.id)}
                aria-pressed={selected}
                className={`flex w-full flex-col gap-2 rounded-xl border bg-card p-3 text-left shadow-xs transition-colors focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none ${
                  selected
                    ? "border-primary ring-2 ring-primary/20"
                    : "hover:border-primary/50"
                }`}
              >
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <div className="flex items-center gap-2">
                    <Badge variant="outline" className="font-mono">
                      v{row.version}
                    </Badge>
                    <ChangeTypeBadge changeType={row.change_type} />
                  </div>
                  <span
                    className={`flex size-4 shrink-0 items-center justify-center rounded-full border ${
                      selected
                        ? "border-primary bg-primary text-primary-foreground"
                        : "border-muted-foreground/40"
                    }`}
                  >
                    {selected ? <CheckIcon className="size-3" /> : null}
                  </span>
                </div>
                <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted-foreground">
                  <span>{row.changed_by_name ?? "系统/后台"}</span>
                  <span>{formatDateTime(row.changed_at)}</span>
                  {summary ? (
                    <span className="max-w-48 truncate">{summary}</span>
                  ) : null}
                </div>
              </button>
            </li>
          );
        })}
      </ol>
    );
  };

  const renderCompare = () => {
    if (!comparePair) {
      return null;
    }
    const { before, after } = comparePair;

    return (
      <section className="flex flex-col gap-3 rounded-xl border p-4">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h3 className="text-sm font-medium">版本对比</h3>
          <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
            <span className="font-mono">v{before.version}</span>
            <ArrowRightIcon className="size-3.5" />
            <span className="font-mono">v{after.version}</span>
            <span>
              · 变更 {changedCount} 项 / 共 {diffFields.length} 项
            </span>
          </div>
        </div>

        {diffFields.length === 0 ? (
          <p className="py-4 text-center text-sm text-muted-foreground">
            两个版本快照均为空
          </p>
        ) : (
          <>
            <div className="hidden overflow-x-auto md:block">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="w-40">字段</TableHead>
                    <TableHead>旧值（v{before.version}）</TableHead>
                    <TableHead>新值（v{after.version}）</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {diffFields.map((field) => (
                    <TableRow
                      key={field.key}
                      className={field.changed ? "bg-primary/10" : undefined}
                    >
                      <TableCell className="align-top font-medium">
                        {field.label}
                      </TableCell>
                      <TableCell className="align-top text-xs break-all text-muted-foreground">
                        {renderFieldValue(field.key, field.before)}
                      </TableCell>
                      <TableCell
                        className={`align-top text-xs break-all ${
                          field.changed
                            ? "font-medium text-primary"
                            : "text-muted-foreground"
                        }`}
                      >
                        {renderFieldValue(field.key, field.after)}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>

            <div className="flex flex-col gap-2 md:hidden">
              {diffFields.map((field) => (
                <div
                  key={field.key}
                  className={`flex flex-col gap-1.5 rounded-lg border p-3 ${
                    field.changed ? "border-primary/40 bg-primary/5" : ""
                  }`}
                >
                  <div className="text-xs text-muted-foreground">
                    {field.label}
                    {field.changed ? " · 已变更" : ""}
                  </div>
                  <div className="flex flex-col gap-1 text-sm">
                    <span className="break-all text-muted-foreground line-through">
                      {renderFieldValue(field.key, field.before)}
                    </span>
                    <span
                      className={`break-all ${
                        field.changed ? "font-medium text-primary" : ""
                      }`}
                    >
                      {renderFieldValue(field.key, field.after)}
                    </span>
                  </div>
                </div>
              ))}
            </div>
          </>
        )}
      </section>
    );
  };

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <form
            onSubmit={handleSearch}
            className="flex flex-wrap items-center gap-2"
          >
            <Select value={selectedTable} onValueChange={handleTableChange}>
              <SelectTrigger
                className="h-11 w-full sm:w-44 lg:h-8"
                aria-label="选择留痕表"
              >
                <SelectValue placeholder="选择表" />
              </SelectTrigger>
              <SelectContent>
                {sortedWhitelist.map((row) => (
                  <SelectItem key={row.table_name} value={row.table_name}>
                    {rowVersionTableLabel(row.table_name)}
                    {row.enabled ? "" : "（已停用）"}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Input
              value={recordInput}
              onChange={(event) => setRecordInput(event.target.value)}
              placeholder="记录标识（record_id），如用户 UUID"
              className="h-11 w-full text-base sm:min-w-52 sm:flex-1 lg:h-8 lg:text-sm"
              aria-label="记录标识"
            />
            <Button type="submit" className="h-11 w-full sm:w-auto lg:h-8">
              <FileSearchIcon data-icon="inline-start" />
              查看版本
            </Button>
          </form>

          {whitelistError ? (
            <p className="py-6 text-center text-sm text-destructive">
              白名单加载失败：{translateAuditErrorMessage(whitelistError)}
            </p>
          ) : null}

          <div className="grid gap-4 lg:grid-cols-[minmax(0,2fr)_minmax(0,3fr)]">
            <section className="flex min-w-0 flex-col gap-3">
              <h3 className="text-sm font-medium">
                最近变更
                <span className="ml-2 text-xs font-normal text-muted-foreground">
                  {rowVersionTableLabel(selectedTable)} · 最近 {RECENT_LIMIT} 条
                </span>
              </h3>
              {renderRecent()}
            </section>

            <section className="flex min-w-0 flex-col gap-3">
              <h3 className="flex flex-wrap items-center gap-2 text-sm font-medium">
                版本时间线
                {activeRecord ? (
                  <span className="font-mono text-xs font-normal text-muted-foreground">
                    {rowVersionTableLabel(activeRecord.table)} ·{" "}
                    {activeRecord.recordId}
                  </span>
                ) : null}
                {timeline.length > 0 ? (
                  <span className="text-xs font-normal text-muted-foreground">
                    已选 {selectedIds.length} / 2
                  </span>
                ) : null}
              </h3>
              {renderTimeline()}
            </section>
          </div>

          {renderCompare()}
        </CardContent>
      </Card>

      <Card className="rounded-none border-0 md:rounded-xl md:border">
        <CardHeader>
          <CardTitle>留痕表白名单</CardTitle>
          <CardDescription>
            开关只控制快照是否写入；新表加入 = 白名单登记 + 新迁移挂触发器（两步，配置无法动态生效）
          </CardDescription>
        </CardHeader>
        <CardContent className="p-4 md:p-6">
          {whitelistLoading ? (
            <div className="flex flex-col gap-2">
              {Array.from({ length: 3 }).map((_, index) => (
                <Skeleton key={index} className="h-11 w-full" />
              ))}
            </div>
          ) : whitelistError ? (
            <p className="py-6 text-center text-sm text-destructive">
              白名单加载失败：{translateAuditErrorMessage(whitelistError)}
            </p>
          ) : (
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>表</TableHead>
                    <TableHead className="hidden sm:table-cell">表名</TableHead>
                    <TableHead>留痕</TableHead>
                    <TableHead className="text-center">更新时间</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {sortedWhitelist.map((row) => (
                    <TableRow key={row.table_name}>
                      <TableCell className="font-medium">
                        {rowVersionTableLabel(row.table_name)}
                      </TableCell>
                      <TableCell className="hidden font-mono text-xs text-muted-foreground sm:table-cell">
                        {row.table_name}
                      </TableCell>
                      <TableCell>
                        <div className="flex items-center gap-2">
                          <Switch
                            checked={row.enabled}
                            disabled={savingTable === row.table_name}
                            onCheckedChange={(checked) =>
                              void handleToggleWhitelist(row, checked)
                            }
                            aria-label={`${rowVersionTableLabel(row.table_name)} 留痕开关`}
                          />
                          <span className="text-sm">
                            {row.enabled ? "启用" : "停用"}
                          </span>
                          {savingTable === row.table_name ? (
                            <Loader2Icon className="size-3.5 animate-spin text-muted-foreground" />
                          ) : null}
                        </div>
                      </TableCell>
                      <TableCell className="text-center text-xs whitespace-nowrap text-muted-foreground">
                        {formatDateTime(row.updated_at)}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
