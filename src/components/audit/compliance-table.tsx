"use client";

// 合规报告页面（audit/008）：参数表单（周期/范围）→ 生成 → HTML 报告预览（打印 A4）
// + 历史归档列表（点击查看、下载 HTML）；数据源 compliance_reports（RLS 仅 admin）。
// 报告内容为 SQL 端聚合快照（与审计明细页同周期口径）；PDF 经 report 导出管道留 v2。

import * as React from "react";
import {
  DownloadIcon,
  FileTextIcon,
  Loader2Icon,
  PrinterIcon,
  ShieldCheckIcon,
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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
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
  COMPLIANCE_PERIOD_OPTIONS,
  COMPLIANCE_RANGE_OPTIONS,
  compliancePeriodLabel,
  complianceRangeLabel,
  formatDateTime,
  translateAuditErrorMessage,
} from "@/lib/audit";
import { createClient } from "@/lib/supabase/client";

type ReportRow = Pick<
  Database["public"]["Tables"]["compliance_reports"]["Row"],
  "id" | "period" | "range" | "generated_by" | "created_at"
>;

type ProfileRow = Pick<
  Database["public"]["Tables"]["profiles"]["Row"],
  "id" | "full_name" | "email"
>;

type ViewingReport = {
  id: string;
  period: string;
  range: string;
  createdAt: string;
  html: string;
};

const HISTORY_LIMIT = 100;

export function ComplianceTable() {
  const isMobile = useIsMobile();

  const [period, setPeriod] = React.useState("month");
  const [range, setRange] = React.useState("all");
  const [generating, setGenerating] = React.useState(false);

  const [history, setHistory] = React.useState<ReportRow[]>([]);
  const [profiles, setProfiles] = React.useState<Map<string, string>>(
    new Map(),
  );
  const [loadingHistory, setLoadingHistory] = React.useState(true);
  const [historyError, setHistoryError] = React.useState<string | null>(null);
  const [viewing, setViewing] = React.useState<ViewingReport | null>(null);
  const [loadingReportId, setLoadingReportId] = React.useState<string | null>(
    null,
  );

  const iframeRef = React.useRef<HTMLIFrameElement>(null);
  const viewerRef = React.useRef<HTMLDivElement>(null);

  const loadHistory = React.useCallback(async () => {
    setLoadingHistory(true);
    setHistoryError(null);
    const supabase = createClient();
    const [reportsRes, profilesRes] = await Promise.all([
      supabase
        .from("compliance_reports")
        .select('id, period, "range", generated_by, created_at')
        .order("created_at", { ascending: false })
        .limit(HISTORY_LIMIT),
      supabase.from("profiles").select("id, full_name, email"),
    ]);

    if (reportsRes.error) {
      setHistoryError(reportsRes.error.message);
      setHistory([]);
    } else {
      setHistory((reportsRes.data ?? []) as ReportRow[]);
    }

    if (!profilesRes.error) {
      const map = new Map<string, string>();
      for (const profile of (profilesRes.data ?? []) as ProfileRow[]) {
        map.set(
          profile.id,
          profile.full_name ?? profile.email?.split("@")[0] ?? "未知用户",
        );
      }
      setProfiles(map);
    }

    setLoadingHistory(false);
  }, []);

  React.useEffect(() => {
    void loadHistory();
  }, [loadHistory]);

  const generatorName = (id: string | null) =>
    id ? (profiles.get(id) ?? "已离职用户") : "系统/后台";

  const scrollToViewer = () => {
    viewerRef.current?.scrollIntoView({ behavior: "smooth", block: "start" });
  };

  const loadReport = React.useCallback(async (row: ReportRow) => {
    setLoadingReportId(row.id);
    const { data, error } = await createClient()
      .from("compliance_reports")
      .select("file_content")
      .eq("id", row.id)
      .single();
    setLoadingReportId(null);

    if (error || !data) {
      toast.error(
        `报告加载失败：${translateAuditErrorMessage(error?.message ?? "未知错误")}`,
      );
      return;
    }

    setViewing({
      id: row.id,
      period: row.period,
      range: row.range,
      createdAt: row.created_at,
      html: data.file_content,
    });
    scrollToViewer();
  }, []);

  const handleGenerate = async () => {
    setGenerating(true);
    const { data: reportId, error } = await createClient().rpc(
      "generate_compliance_report",
      { p_period: period, p_range: range },
    );
    setGenerating(false);

    if (error) {
      toast.error(translateAuditErrorMessage(error.message));
      return;
    }

    toast.success("合规报告已生成");
    await loadHistory();
    await loadReport({
      id: reportId,
      period,
      range,
      generated_by: null,
      created_at: new Date().toISOString(),
    });
  };

  const handlePrint = () => {
    const frame = iframeRef.current;
    if (!frame?.contentWindow) {
      toast.error("报告尚未加载，无法打印");
      return;
    }
    frame.contentWindow.focus();
    frame.contentWindow.print();
  };

  const handleDownload = (report: ViewingReport) => {
    const blob = new Blob([report.html], { type: "text/html;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = `合规报告-${compliancePeriodLabel(report.period)}-${new Date(
      report.createdAt,
    )
      .toISOString()
      .slice(0, 10)}.html`;
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
    URL.revokeObjectURL(url);
  };

  const renderHistory = () => {
    if (loadingHistory) {
      return (
        <div className="flex flex-col gap-2">
          {Array.from({ length: 3 }).map((_, index) => (
            <Skeleton key={index} className="h-12 w-full" />
          ))}
        </div>
      );
    }
    if (historyError) {
      return (
        <div className="flex flex-col items-center gap-2 py-8 text-sm">
          <p className="text-destructive">
            加载失败：{translateAuditErrorMessage(historyError)}
          </p>
          <Button variant="outline" onClick={() => void loadHistory()}>
            重试
          </Button>
        </div>
      );
    }
    if (history.length === 0) {
      return (
        <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
          <FileTextIcon className="size-8 opacity-60" />
          <span>暂无历史报告，先在上方生成一份</span>
        </div>
      );
    }

    if (isMobile) {
      return (
        <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
          {history.map((row) => (
            <button
              key={row.id}
              type="button"
              onClick={() => void loadReport(row)}
              disabled={loadingReportId === row.id}
              className="flex w-full flex-col gap-2 rounded-xl border bg-card p-3 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none disabled:opacity-60"
            >
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0">
                  <div className="truncate font-medium">
                    {compliancePeriodLabel(row.period)} ·{" "}
                    {complianceRangeLabel(row.range)}
                  </div>
                  <div className="truncate text-xs leading-tight text-muted-foreground">
                    {formatDateTime(row.created_at)}
                  </div>
                </div>
                {loadingReportId === row.id ? (
                  <Loader2Icon className="size-4 animate-spin text-muted-foreground" />
                ) : (
                  <Badge variant="outline" className="text-muted-foreground">
                    查看
                  </Badge>
                )}
              </div>
              <div className="flex items-center justify-between gap-4 text-sm">
                <span className="text-muted-foreground">生成人</span>
                <span>{generatorName(row.generated_by)}</span>
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
              <TableHead className="text-center">生成时间</TableHead>
              <TableHead className="text-center">周期</TableHead>
              <TableHead className="text-center">范围</TableHead>
              <TableHead className="text-center">生成人</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {history.map((row) => (
              <TableRow
                key={row.id}
                className="cursor-pointer"
                tabIndex={0}
                onClick={() => void loadReport(row)}
                onKeyDown={(event) => {
                  if (event.target !== event.currentTarget) {
                    return;
                  }
                  if (event.key === "Enter" || event.key === " ") {
                    event.preventDefault();
                    void loadReport(row);
                  }
                }}
              >
                <TableCell className="text-center text-xs whitespace-nowrap text-muted-foreground">
                  {formatDateTime(row.created_at)}
                </TableCell>
                <TableCell className="text-center">
                  {compliancePeriodLabel(row.period)}
                </TableCell>
                <TableCell className="text-center">
                  {complianceRangeLabel(row.range)}
                </TableCell>
                <TableCell className="text-center">
                  {loadingReportId === row.id ? (
                    <Loader2Icon className="mx-auto size-4 animate-spin text-muted-foreground" />
                  ) : (
                    generatorName(row.generated_by)
                  )}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    );
  };

  return (
    <div className="flex flex-col gap-4 p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-wrap items-end gap-2">
            <label className="flex flex-col gap-1.5 text-sm">
              <span className="text-muted-foreground">周期</span>
              <Select value={period} onValueChange={setPeriod}>
                <SelectTrigger className="h-11 w-full sm:w-32 lg:h-8">
                  <SelectValue placeholder="选择周期" />
                </SelectTrigger>
                <SelectContent>
                  {COMPLIANCE_PERIOD_OPTIONS.map((option) => (
                    <SelectItem key={option.value} value={option.value}>
                      {option.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </label>
            <label className="flex flex-col gap-1.5 text-sm">
              <span className="text-muted-foreground">范围</span>
              <Select value={range} onValueChange={setRange}>
                <SelectTrigger className="h-11 w-full sm:w-40 lg:h-8">
                  <SelectValue placeholder="选择范围" />
                </SelectTrigger>
                <SelectContent>
                  {COMPLIANCE_RANGE_OPTIONS.map((option) => (
                    <SelectItem key={option.value} value={option.value}>
                      {option.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </label>
            <Button
              onClick={() => void handleGenerate()}
              disabled={generating}
              className="h-11 w-full sm:w-auto lg:h-8"
            >
              {generating ? (
                <Loader2Icon className="animate-spin" data-icon="inline-start" />
              ) : (
                <ShieldCheckIcon data-icon="inline-start" />
              )}
              生成报告
            </Button>
          </div>

          <div ref={viewerRef} className="flex flex-col gap-2">
            {viewing ? (
              <>
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <div className="text-sm">
                    <span className="font-medium">
                      {compliancePeriodLabel(viewing.period)} ·{" "}
                      {complianceRangeLabel(viewing.range)}
                    </span>
                    <span className="ml-2 text-xs text-muted-foreground">
                      生成于 {formatDateTime(viewing.createdAt)}
                    </span>
                  </div>
                  <div className="flex items-center gap-2">
                    <Button
                      variant="outline"
                      size="sm"
                      className="h-11 lg:h-8"
                      onClick={() => handlePrint()}
                    >
                      <PrinterIcon data-icon="inline-start" />
                      打印
                    </Button>
                    <Button
                      variant="outline"
                      size="sm"
                      className="h-11 lg:h-8"
                      onClick={() => handleDownload(viewing)}
                    >
                      <DownloadIcon data-icon="inline-start" />
                      下载 HTML
                    </Button>
                    <Button
                      variant="ghost"
                      size="sm"
                      className="h-11 lg:h-8"
                      onClick={() => setViewing(null)}
                    >
                      关闭预览
                    </Button>
                  </div>
                </div>
                <iframe
                  ref={iframeRef}
                  title="合规报告预览"
                  srcDoc={viewing.html}
                  className="h-[70vh] w-full rounded-lg border bg-white"
                />
              </>
            ) : (
              <div className="flex flex-col items-center gap-2 rounded-lg border border-dashed py-10 text-sm text-muted-foreground">
                <PrinterIcon className="size-8 opacity-60" />
                <span>选择周期与范围后点击「生成报告」，或从历史列表查看</span>
              </div>
            )}
          </div>
        </CardContent>
      </Card>

      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card gap-3! py-3!">
        <CardHeader>
          <CardTitle>历史报告</CardTitle>
          <CardDescription>
            归档快照（保留 1 年）：点击任意一行查看报告全文
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          {renderHistory()}
          {!loadingHistory && !historyError && history.length > 0 ? (
            <div className="text-sm text-muted-foreground">
              共 {history.length} 份（最近 {HISTORY_LIMIT} 份）
            </div>
          ) : null}
        </CardContent>
      </Card>
    </div>
  );
}
