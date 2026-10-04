"use client";

// 报表中心 · 自定义报表列表与详情（report/004）
// 列表：我的报表 / 公共报表两个 tab（名称/数据源/图表/可见性/更新时间，行可点，无操作列）。
// 详情：配置摘要 + run_report 结果（recharts/表格，移动端降级表格）+ 操作（分享/编辑/发布/删除）。
// 编辑器：CustomReportEditor 三步 Sheet；分享链接 /report/custom?id=<def_id>（数据仍按访问者 RLS 过滤）。

import * as React from "react";
import {
  BarChart3Icon,
  CopyIcon,
  LineChartIcon,
  Loader2Icon,
  PencilIcon,
  PieChartIcon,
  PlusIcon,
  RefreshCwIcon,
  RocketIcon,
  SearchIcon,
  Table2Icon,
  Trash2Icon,
  Undo2Icon,
} from "lucide-react";
import { toast } from "sonner";

import { CustomReportEditor } from "@/components/report/custom-report-editor";
import { ReportResultView } from "@/components/report/report-result";
import {
  ReportEmptyState,
  ReportErrorState,
  ReportLoadingSkeleton,
} from "@/components/report/report-shared";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetFooter,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useIsMobile } from "@/hooks/use-mobile";
import {
  formatDateTime,
  parseReportDefinition,
  parseRunResult,
  REPORT_CHART_LABELS,
  REPORT_VISIBILITY_BADGE_CLASSES,
  REPORT_VISIBILITY_LABELS,
  reportConfigSummary,
  translateReportErrorMessage,
  type AllowedView,
  type ReportChartType,
  type ReportDefinition,
  type ReportRunResult,
} from "@/lib/report";
import { createClient } from "@/lib/supabase/client";

const PAGE_SIZE = 20;

type PanelState =
  | { mode: "view"; defId: string }
  | { mode: "edit"; defId: string }
  | { mode: "create" }
  | null;

type RunState = {
  loading: boolean;
  error: string | null;
  result: ReportRunResult | null;
};

const IDLE_RUN: RunState = { loading: false, error: null, result: null };

const CHART_ICONS: Record<ReportChartType, typeof Table2Icon> = {
  table: Table2Icon,
  bar: BarChart3Icon,
  line: LineChartIcon,
  pie: PieChartIcon,
};

function ChartBadge({ chart }: { chart: ReportChartType }) {
  const Icon = CHART_ICONS[chart];
  return (
    <span className="inline-flex items-center gap-1 text-muted-foreground">
      <Icon className="size-3.5" />
      {REPORT_CHART_LABELS[chart]}
    </span>
  );
}

export function CustomReports({
  currentUserId,
  isAdmin,
  initialId,
}: {
  currentUserId: string;
  isAdmin: boolean;
  initialId: string | null;
}) {
  const isMobile = useIsMobile();
  const [definitions, setDefinitions] = React.useState<ReportDefinition[]>([]);
  const [allowedViews, setAllowedViews] = React.useState<AllowedView[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [tab, setTab] = React.useState<"mine" | "public">("mine");
  const [search, setSearch] = React.useState("");
  const [page, setPage] = React.useState(1);
  const [panel, setPanel] = React.useState<PanelState>(null);
  const [runState, setRunState] = React.useState<RunState>(IDLE_RUN);
  const [confirmDeleteDef, setConfirmDeleteDef] =
    React.useState<ReportDefinition | null>(null);
  const [deleting, setDeleting] = React.useState(false);

  const load = React.useCallback(async () => {
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const [defRes, viewRes] = await Promise.all([
      supabase
        .from("report_definitions")
        .select(
          "id, name, source_view, config, visibility, owner_id, updated_at",
        )
        .order("updated_at", { ascending: false }),
      supabase
        .from("report_allowed_views")
        .select("view_name, allowed_columns")
        .order("view_name"),
    ]);

    if (defRes.error) {
      setError(defRes.error.message);
      setDefinitions([]);
    } else {
      setDefinitions((defRes.data ?? []).map(parseReportDefinition));
    }

    if (!viewRes.error) {
      setAllowedViews(
        (viewRes.data ?? []).map((row) => ({
          view_name: row.view_name,
          allowed_columns: (row.allowed_columns ?? {}) as Record<string, string>,
        })),
      );
    }

    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  // 分享链接直达：/report/custom?id=<def_id>
  React.useEffect(() => {
    if (initialId) {
      setPanel({ mode: "view", defId: initialId });
    }
  }, [initialId]);

  /** 同步 ?id= 到地址栏（分享语义；replaceState 避免触发 RSC 往返与状态重置） */
  const syncUrl = (defId: string | null) => {
    const url = defId ? `/report/custom?id=${defId}` : "/report/custom";
    window.history.replaceState(null, "", url);
  };

  const openView = (defId: string) => {
    setPanel({ mode: "view", defId });
    syncUrl(defId);
  };

  const closePanel = () => {
    setPanel(null);
    syncUrl(null);
  };

  const viewDefId = panel?.mode === "view" ? panel.defId : null;
  const activeDef =
    panel?.mode === "view" || panel?.mode === "edit"
      ? (definitions.find((item) => item.id === panel.defId) ?? null)
      : null;

  const loadRun = React.useCallback(async (defId: string) => {
    setRunState({ loading: true, error: null, result: null });
    const { data, error: runError } = await createClient().rpc("run_report", {
      p_def_id: defId,
    });
    if (runError) {
      setRunState({
        loading: false,
        error: translateReportErrorMessage(runError.message),
        result: null,
      });
      return;
    }
    setRunState({ loading: false, error: null, result: parseRunResult(data) });
  }, []);

  React.useEffect(() => {
    if (!viewDefId) {
      setRunState(IDLE_RUN);
      return;
    }
    void loadRun(viewDefId);
  }, [viewDefId, loadRun]);

  const mineCount = definitions.filter(
    (item) => item.owner_id === currentUserId,
  ).length;
  const publicCount = definitions.filter(
    (item) => item.visibility === "public",
  ).length;

  const filtered = React.useMemo(() => {
    const keyword = search.trim().toLowerCase();
    return definitions.filter((item) => {
      const inTab =
        tab === "mine"
          ? item.owner_id === currentUserId
          : item.visibility === "public";
      if (!inTab) {
        return false;
      }
      if (keyword && !item.name.toLowerCase().includes(keyword)) {
        return false;
      }
      return true;
    });
  }, [definitions, tab, search, currentUserId]);

  React.useEffect(() => {
    setPage(1);
  }, [tab, search]);

  const pageCount = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const currentPage = Math.min(page, pageCount);
  const pagedRows = filtered.slice(
    (currentPage - 1) * PAGE_SIZE,
    currentPage * PAGE_SIZE,
  );

  const handleCopyLink = async (def: ReportDefinition) => {
    const url = `${window.location.origin}/report/custom?id=${def.id}`;
    try {
      await navigator.clipboard.writeText(url);
      toast.success("分享链接已复制");
    } catch {
      toast.error(`复制失败，请手动复制：${url}`);
    }
  };

  const handleDelete = async (def: ReportDefinition) => {
    setDeleting(true);
    const { error: deleteError } = await createClient().rpc(
      "delete_report_definition",
      { p_def_id: def.id },
    );
    setDeleting(false);
    if (deleteError) {
      toast.error(translateReportErrorMessage(deleteError.message));
      return;
    }
    toast.success("已删除");
    setConfirmDeleteDef(null);
    closePanel();
    void load();
  };

  const handleVisibility = async (def: ReportDefinition, publish: boolean) => {
    const { error: rpcError } = await createClient().rpc(
      publish ? "publish_report_definition" : "unpublish_report_definition",
      { p_def_id: def.id },
    );
    if (rpcError) {
      toast.error(translateReportErrorMessage(rpcError.message));
      return;
    }
    toast.success(publish ? "已发布为公共报表" : "已取消发布");
    void load();
  };

  const renderList = () => {
    if (loading) {
      return <ReportLoadingSkeleton />;
    }
    if (error) {
      return (
        <ReportErrorState
          message={translateReportErrorMessage(error)}
          onRetry={() => void load()}
        />
      );
    }
    if (pagedRows.length === 0) {
      return search.trim() ? (
        <ReportEmptyState
          title="未找到匹配的报表"
          description={`没有名称包含「${search.trim()}」的报表。`}
        />
      ) : (
        <ReportEmptyState
          title={tab === "mine" ? "暂无自定义报表" : "暂无公共报表"}
          description={
            tab === "mine"
              ? "点击右上角「新建报表」，三步配置数据源、字段与图表。"
              : "管理员可将私有报表发布为公共报表，供全员查看。"
          }
        />
      );
    }

    if (isMobile) {
      return (
        <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
          {pagedRows.map((def) => (
            <button
              key={def.id}
              type="button"
              onClick={() => openView(def.id)}
              className="flex w-full flex-col gap-2 rounded-xl border bg-card p-3 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
            >
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0 truncate font-medium">{def.name}</div>
                <Badge
                  variant="outline"
                  className={REPORT_VISIBILITY_BADGE_CLASSES[def.visibility]}
                >
                  {REPORT_VISIBILITY_LABELS[def.visibility]}
                </Badge>
              </div>
              <div className="flex flex-col gap-1.5 text-sm">
                <div className="flex items-center justify-between gap-4">
                  <span className="text-muted-foreground">数据源</span>
                  <span className="truncate font-mono text-xs">
                    {def.source_view}
                  </span>
                </div>
                <div className="flex items-center justify-between gap-4">
                  <span className="text-muted-foreground">图表类型</span>
                  <ChartBadge chart={def.config.chart} />
                </div>
                <div className="flex items-center justify-between gap-4">
                  <span className="text-muted-foreground">更新时间</span>
                  <span className="tabular-nums">
                    {formatDateTime(def.updated_at)}
                  </span>
                </div>
              </div>
            </button>
          ))}
        </div>
      );
    }

    return (
      <div className="overflow-x-auto">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="text-center">名称</TableHead>
              <TableHead className="text-center">数据源</TableHead>
              <TableHead className="text-center">图表类型</TableHead>
              <TableHead className="text-center">可见性</TableHead>
              <TableHead className="text-center">更新时间</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {pagedRows.map((def) => (
              <TableRow
                key={def.id}
                className="cursor-pointer"
                role="button"
                tabIndex={0}
                aria-label={`查看报表 ${def.name}`}
                onClick={() => openView(def.id)}
                onKeyDown={(event) => {
                  if (event.key === "Enter" || event.key === " ") {
                    event.preventDefault();
                    openView(def.id);
                  }
                }}
              >
                <TableCell className="text-center font-medium">
                  {def.name}
                </TableCell>
                <TableCell className="text-center font-mono text-xs text-muted-foreground">
                  {def.source_view}
                </TableCell>
                <TableCell className="text-center">
                  <ChartBadge chart={def.config.chart} />
                </TableCell>
                <TableCell className="text-center">
                  <Badge
                    variant="outline"
                    className={REPORT_VISIBILITY_BADGE_CLASSES[def.visibility]}
                  >
                    {REPORT_VISIBILITY_LABELS[def.visibility]}
                  </Badge>
                </TableCell>
                <TableCell className="text-center text-muted-foreground">
                  {formatDateTime(def.updated_at)}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    );
  };

  const renderRun = () => {
    if (!activeDef) {
      return null;
    }
    if (runState.loading) {
      return <ReportLoadingSkeleton rows={4} />;
    }
    if (runState.error) {
      return (
        <ReportErrorState
          message={runState.error}
          onRetry={() => void loadRun(activeDef.id)}
        />
      );
    }
    if (!runState.result) {
      return null;
    }
    return (
      <ReportResultView config={activeDef.config} result={runState.result} />
    );
  };

  const isOwner = activeDef?.owner_id === currentUserId;

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
            <Tabs
              value={tab}
              onValueChange={(value) => setTab(value as "mine" | "public")}
            >
              <TabsList>
                <TabsTrigger value="mine">我的报表（{mineCount}）</TabsTrigger>
                <TabsTrigger value="public">
                  公共报表（{publicCount}）
                </TabsTrigger>
              </TabsList>
            </Tabs>
            <div className="relative flex-1 sm:max-w-xs">
              <SearchIcon className="absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder="搜索报表名称"
                className="h-11 pl-8 text-base lg:h-8 lg:text-sm"
                aria-label="搜索报表名称"
              />
            </div>
            <div className="flex items-center gap-2 sm:ml-auto">
              <Button
                onClick={() => setPanel({ mode: "create" })}
                className="h-11 flex-1 lg:h-8 lg:flex-none"
              >
                <PlusIcon data-icon="inline-start" />
                新建报表
              </Button>
            </div>
          </div>

          {renderList()}

          {!loading && !error && filtered.length > 0 ? (
            <div className="flex items-center justify-between gap-2 text-sm text-muted-foreground">
              <span>
                共 {filtered.length} 条 · 第 {currentPage} / {pageCount} 页
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

      <Sheet
        open={panel?.mode === "view"}
        onOpenChange={(open) => {
          if (!open) {
            closePanel();
          }
        }}
      >
        <SheetContent
          side="right"
          className="w-full sm:max-w-[480px]"
        >
          <SheetHeader>
            <SheetTitle>
              {activeDef?.name ?? (loading ? "加载中…" : "报表详情")}
            </SheetTitle>
            <SheetDescription className="flex flex-col gap-1.5">
              {activeDef ? (
                <>
                  <span className="flex flex-wrap items-center gap-1.5">
                    <Badge
                      variant="outline"
                      className={
                        REPORT_VISIBILITY_BADGE_CLASSES[activeDef.visibility]
                      }
                    >
                      {REPORT_VISIBILITY_LABELS[activeDef.visibility]}
                    </Badge>
                    <Badge variant="outline" className="font-normal">
                      <ChartBadge chart={activeDef.config.chart} />
                    </Badge>
                    <span className="font-mono text-xs">
                      {activeDef.source_view}
                    </span>
                  </span>
                  <span>
                    更新时间：{formatDateTime(activeDef.updated_at)}
                  </span>
                </>
              ) : (
                <span>正在读取报表定义…</span>
              )}
            </SheetDescription>
          </SheetHeader>

          <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-4">
            {loading ? (
              <ReportLoadingSkeleton rows={3} />
            ) : !activeDef ? (
              <ReportEmptyState
                title="报表不存在或无权查看"
                description="分享链接仅能打开你可见的报表（私有报表仅属主与管理员可见）。"
              />
            ) : (
              <>
                <div className="rounded-lg border p-3 text-xs text-muted-foreground">
                  配置摘要：{reportConfigSummary(activeDef.config)}
                </div>
                <div className="flex flex-col gap-2">
                  <div className="flex items-center justify-between">
                    <div className="text-sm font-medium">运行结果</div>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => void loadRun(activeDef.id)}
                      disabled={runState.loading}
                    >
                      <RefreshCwIcon
                        className={runState.loading ? "animate-spin" : undefined}
                        data-icon="inline-start"
                      />
                      重跑
                    </Button>
                  </div>
                  <p className="text-xs text-muted-foreground">
                    执行 run_report：标识符仅取白名单，数据按你的权限（RLS）过滤。
                  </p>
                  {renderRun()}
                </div>
              </>
            )}
          </div>

          {activeDef ? (
            <SheetFooter className="flex-row flex-wrap justify-end gap-2">
              <Button
                variant="outline"
                onClick={() => void handleCopyLink(activeDef)}
              >
                <CopyIcon data-icon="inline-start" />
                复制分享链接
              </Button>
              {isOwner || isAdmin ? (
                <Button
                  variant="outline"
                  onClick={() =>
                    setPanel({ mode: "edit", defId: activeDef.id })
                  }
                >
                  <PencilIcon data-icon="inline-start" />
                  编辑
                </Button>
              ) : null}
              {isAdmin ? (
                <Button
                  variant="outline"
                  onClick={() =>
                    void handleVisibility(
                      activeDef,
                      activeDef.visibility !== "public",
                    )
                  }
                >
                  {activeDef.visibility === "public" ? (
                    <Undo2Icon data-icon="inline-start" />
                  ) : (
                    <RocketIcon data-icon="inline-start" />
                  )}
                  {activeDef.visibility === "public" ? "取消发布" : "发布"}
                </Button>
              ) : null}
              {isOwner || isAdmin ? (
                <Button
                  variant="destructive"
                  onClick={() => setConfirmDeleteDef(activeDef)}
                >
                  <Trash2Icon data-icon="inline-start" />
                  删除
                </Button>
              ) : null}
            </SheetFooter>
          ) : null}
        </SheetContent>
      </Sheet>

      {/* 删除确认 Sheet（替代 window.confirm） */}
      <Sheet
        open={confirmDeleteDef !== null}
        onOpenChange={(open) => {
          if (!open) {
            setConfirmDeleteDef(null);
          }
        }}
      >
        <SheetContent side="right" className="w-full sm:max-w-[480px]">
          <SheetHeader>
            <SheetTitle>删除报表</SheetTitle>
            <SheetDescription>
              {confirmDeleteDef
                ? `确定删除报表「${confirmDeleteDef.name}」？删除后不可恢复。`
                : ""}
            </SheetDescription>
          </SheetHeader>
          <SheetFooter className="flex-row justify-end gap-2">
            <Button
              variant="outline"
              className="h-11 lg:h-8"
              onClick={() => setConfirmDeleteDef(null)}
            >
              取消
            </Button>
            <Button
              variant="destructive"
              className="h-11 lg:h-8"
              disabled={deleting}
              onClick={() =>
                confirmDeleteDef && void handleDelete(confirmDeleteDef)
              }
            >
              {deleting ? (
                <Loader2Icon
                  className="animate-spin"
                  data-icon="inline-start"
                />
              ) : (
                <Trash2Icon data-icon="inline-start" />
              )}
              删除
            </Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>

      <CustomReportEditor
        open={panel?.mode === "create" || panel?.mode === "edit"}
        onOpenChange={(open) => {
          if (open) {
            return;
          }
          if (panel?.mode === "edit") {
            setPanel({ mode: "view", defId: panel.defId });
          } else {
            setPanel(null);
          }
        }}
        definition={panel?.mode === "edit" ? activeDef : null}
        allowedViews={allowedViews}
        onSaved={() => {
          closePanel();
          void load();
        }}
      />
    </div>
  );
}
