"use client";

import * as React from "react";
import {
  AlertTriangleIcon,
  CheckCheckIcon,
  CheckIcon,
  FilePlus2Icon,
  ListTodoIcon,
  Loader2Icon,
  SearchIcon,
  XIcon,
} from "lucide-react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { toast } from "sonner";
import { cn } from "cn";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Checkbox } from "@/components/ui/checkbox";
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
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { useIsMobile } from "@/hooks/use-mobile";
import type { Database } from "@/lib/database.types";
import {
  APPROVAL_INSTANCE_STATUS_BADGE_CLASSES,
  APPROVAL_INSTANCE_STATUS_LABELS,
  APPROVAL_OVERDUE_BADGE_CLASS,
  APPROVAL_TASK_STATUS_BADGE_CLASSES,
  APPROVAL_TASK_STATUS_LABELS,
  asApprovalInstanceStatus,
  asApprovalTaskStatus,
  translateApprovalErrorMessage,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

import { ApprovalDetailSections, useApprovalDetail } from "./approval-detail";
import {
  APPROVAL_PAGE_SIZE,
  TIME_RANGE_OPTIONS,
  formatDateTime,
  formatWaiting,
  isOverdue48h,
  sourceModuleLabel,
  withinTimeRange,
  type TimeRange,
} from "./approval-utils";

const ALL = "all";

type TodoRow = Database["public"]["Functions"]["my_todos"]["Returns"][number];
type TodoTab = "pending" | "done";

function InstanceStatusBadge({ status }: { status: string }) {
  const value = asApprovalInstanceStatus(status);
  return (
    <Badge
      variant="outline"
      className={APPROVAL_INSTANCE_STATUS_BADGE_CLASSES[value]}
    >
      {APPROVAL_INSTANCE_STATUS_LABELS[value]}
    </Badge>
  );
}

function TaskStatusBadge({ status }: { status: string }) {
  const value = asApprovalTaskStatus(status);
  return (
    <Badge
      variant="outline"
      className={APPROVAL_TASK_STATUS_BADGE_CLASSES[value]}
    >
      {APPROVAL_TASK_STATUS_LABELS[value]}
    </Badge>
  );
}

export function ApprovalTodoTable() {
  const isMobile = useIsMobile();
  const [tab, setTab] = React.useState<TodoTab>("pending");
  const [rows, setRows] = React.useState<TodoRow[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [search, setSearch] = React.useState("");
  const [moduleFilter, setModuleFilter] = React.useState(ALL);
  const [timeRange, setTimeRange] = React.useState<TimeRange>("all");
  const [page, setPage] = React.useState(1);
  const [selected, setSelected] = React.useState<Set<string>>(new Set());
  const [batching, setBatching] = React.useState(false);
  const [detailRow, setDetailRow] = React.useState<TodoRow | null>(null);
  const [comment, setComment] = React.useState("");
  const [acting, setActing] = React.useState(false);
  const [submitOpen, setSubmitOpen] = React.useState(false);
  const [demoForm, setDemoForm] = React.useState({
    title: "",
    days: "1",
    reason: "",
  });
  const [submitting, setSubmitting] = React.useState(false);
  const [highlightInstanceId, setHighlightInstanceId] = React.useState<
    string | null
  >(null);
  const requestIdRef = React.useRef(0);

  const load = React.useCallback(
    async (options?: { silent?: boolean }) => {
      const requestId = ++requestIdRef.current;
      if (!options?.silent) {
        setLoading(true);
      }
      setError(null);

      const { data, error: listError } = await createClient().rpc("my_todos", {
        p_pending: tab === "pending",
        p_limit: 200,
      });
      if (requestId !== requestIdRef.current) {
        return;
      }
      if (listError) {
        setError(listError.message);
        setRows([]);
      } else {
        setRows(data ?? []);
      }
      setLoading(false);
    },
    [tab],
  );

  React.useEffect(() => {
    void load();
  }, [load]);

  React.useEffect(() => {
    setSelected(new Set());
    setPage(1);
  }, [tab]);

  React.useEffect(() => {
    setPage(1);
  }, [search, moduleFilter, timeRange]);

  const moduleOptions = React.useMemo(() => {
    const options = Array.from(
      new Set(rows.map((row) => row.module).filter(Boolean)),
    );
    options.sort((a, b) => a.localeCompare(b, "zh-CN"));
    return options;
  }, [rows]);

  const filtered = React.useMemo(() => {
    const keyword = search.trim().toLowerCase();
    return rows.filter((row) => {
      if (moduleFilter !== ALL && row.module !== moduleFilter) {
        return false;
      }
      if (!withinTimeRange(row.created_at, timeRange)) {
        return false;
      }
      if (keyword) {
        const haystack =
          `${row.title} ${row.initiator_name ?? ""}`.toLowerCase();
        if (!haystack.includes(keyword)) {
          return false;
        }
      }
      return true;
    });
  }, [rows, search, moduleFilter, timeRange]);

  const pageCount = Math.max(1, Math.ceil(filtered.length / APPROVAL_PAGE_SIZE));
  const currentPage = Math.min(page, pageCount);
  const pagedRows = filtered.slice(
    (currentPage - 1) * APPROVAL_PAGE_SIZE,
    currentPage * APPROVAL_PAGE_SIZE,
  );
  const hasActiveFilters =
    search.trim() !== "" || moduleFilter !== ALL || timeRange !== "all";
  const allSelected =
    pagedRows.length > 0 &&
    pagedRows.every((row) => selected.has(row.task_id));

  const changeTab = (value: string) => {
    if (value === "pending" || value === "done") {
      setTab(value);
    }
  };

  const toggleSelectAll = (checked: boolean) => {
    setSelected((prev) => {
      const next = new Set(prev);
      for (const row of pagedRows) {
        if (checked) {
          next.add(row.task_id);
        } else {
          next.delete(row.task_id);
        }
      }
      return next;
    });
  };

  const toggleSelectOne = (taskId: string, checked: boolean) => {
    setSelected((prev) => {
      const next = new Set(prev);
      if (checked) {
        next.add(taskId);
      } else {
        next.delete(taskId);
      }
      return next;
    });
  };

  const openDetail = (row: TodoRow) => {
    setDetailRow(row);
    setComment("");
  };

  const closeDetail = () => {
    setDetailRow(null);
    setComment("");
  };

  const { detail, loading: detailLoading, error: detailError } =
    useApprovalDetail(detailRow?.instance_id ?? null);

  // dashboard / 站内信「去处理」携带 ?highlight=<instance_id>：命中待办则自动打开详情并高亮行；
  // 未命中（已处理 / 无权限）toast 后消费参数，避免刷新时反复提示。
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const highlight = searchParams.get("highlight");
  const consumedHighlightRef = React.useRef<string | null>(null);

  React.useEffect(() => {
    if (
      !highlight ||
      consumedHighlightRef.current === highlight ||
      loading ||
      error
    ) {
      return;
    }
    consumedHighlightRef.current = highlight;

    const row = rows.find((item) => item.instance_id === highlight);
    if (row) {
      const index = filtered.findIndex(
        (item) => item.instance_id === highlight,
      );
      if (index >= 0) {
        setPage(Math.floor(index / APPROVAL_PAGE_SIZE) + 1);
      }
      setHighlightInstanceId(highlight);
      openDetail(row);
    } else {
      toast.error("目标审批不存在或已处理");
    }

    const params = new URLSearchParams(searchParams.toString());
    params.delete("highlight");
    const query = params.toString();
    router.replace(query ? `${pathname}?${query}` : pathname, {
      scroll: false,
    });
  }, [
    highlight,
    loading,
    error,
    rows,
    filtered,
    openDetail,
    searchParams,
    router,
    pathname,
  ]);

  /** 批量通过（无批量驳回：驳回需逐条填写意见，避免误伤） */
  const handleBatchApprove = async () => {
    const taskIds = Array.from(selected);
    if (taskIds.length === 0) {
      return;
    }
    if (!window.confirm(`确认通过选中的 ${taskIds.length} 条审批？`)) {
      return;
    }

    setBatching(true);
    const supabase = createClient();
    let approved = 0;
    let failed = 0;
    let firstError = "";

    for (const taskId of taskIds) {
      const { error: actError } = await supabase.rpc("act_task", {
        p_task_id: taskId,
        p_action: "approve",
        p_comment: "",
      });
      if (actError) {
        failed += 1;
        firstError = firstError || actError.message;
      } else {
        approved += 1;
      }
    }

    setBatching(false);
    setSelected(new Set());
    if (failed > 0) {
      toast.error(
        `${approved} 条已通过，${failed} 条失败：${translateApprovalErrorMessage(firstError)}`,
      );
    } else {
      toast.success(`已通过 ${approved} 条审批`);
    }
    void load();
  };

  const handleAct = async (action: "approve" | "reject") => {
    if (!detailRow) {
      return;
    }
    const trimmed = comment.trim();
    if (action === "reject" && !trimmed) {
      toast.error("驳回必须填写意见");
      return;
    }

    setActing(true);
    const { error: actError } = await createClient().rpc("act_task", {
      p_task_id: detailRow.task_id,
      p_action: action,
      p_comment: trimmed,
    });
    setActing(false);

    if (actError) {
      toast.error(translateApprovalErrorMessage(actError.message));
      return;
    }
    toast.success(action === "approve" ? "已通过" : "已驳回");
    closeDetail();
    void load();
  };

  const handleSubmitDemo = async () => {
    const title = demoForm.title.trim();
    const reason = demoForm.reason.trim();
    const days = Number(demoForm.days);

    if (!title) {
      toast.error("请填写申请标题");
      return;
    }
    if (!Number.isFinite(days) || days <= 0) {
      toast.error("请假天数需大于 0");
      return;
    }
    if (!reason) {
      toast.error("请填写请假事由");
      return;
    }

    setSubmitting(true);
    const { error: submitError } = await createClient().rpc("submit_instance", {
      p_module: "demo",
      p_ref_type: "demo_leave",
      p_ref_id: "",
      p_template_code: "demo.leave",
      p_form_data: { title, days, reason },
    });
    setSubmitting(false);

    if (submitError) {
      toast.error(translateApprovalErrorMessage(submitError.message));
      return;
    }
    toast.success("已提交，审批人将收到待办");
    setSubmitOpen(false);
    setDemoForm({ title: "", days: "1", reason: "" });
    if (tab !== "pending") {
      setTab("pending");
    } else {
      void load();
    }
  };

  const emptyText = tab === "pending" ? "暂无待办" : "暂无已办记录";

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex flex-wrap items-center gap-2">
            <ToggleGroup
              type="single"
              value={tab}
              onValueChange={(value) => {
                if (value) {
                  changeTab(value);
                }
              }}
              variant="outline"
              className="w-full sm:w-auto"
              aria-label="待办筛选"
            >
              <ToggleGroupItem
                value="pending"
                className="h-11 flex-1 px-3 lg:h-8 lg:flex-none"
              >
                待办
              </ToggleGroupItem>
              <ToggleGroupItem
                value="done"
                className="h-11 flex-1 px-3 lg:h-8 lg:flex-none"
              >
                已办
              </ToggleGroupItem>
            </ToggleGroup>

            <div className="relative flex-1 sm:max-w-xs">
              <SearchIcon className="absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder="搜索标题 / 发起人"
                className="h-11 pl-8 text-base lg:h-8 lg:text-sm"
                aria-label="搜索标题或发起人"
              />
            </div>
            <Select value={moduleFilter} onValueChange={setModuleFilter}>
              <SelectTrigger
                className="w-full sm:w-36 min-h-11 lg:min-h-8"
                aria-label="按来源模块筛选"
              >
                <SelectValue placeholder="全部来源" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL}>全部来源</SelectItem>
                {moduleOptions.map((module) => (
                  <SelectItem key={module} value={module}>
                    {sourceModuleLabel(module)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Select
              value={timeRange}
              onValueChange={(value) => setTimeRange(value as TimeRange)}
            >
              <SelectTrigger
                className="w-full sm:w-32 min-h-11 lg:min-h-8"
                aria-label="按提交时间筛选"
              >
                <SelectValue placeholder="全部时间" />
              </SelectTrigger>
              <SelectContent>
                {TIME_RANGE_OPTIONS.map((option) => (
                  <SelectItem key={option.value} value={option.value}>
                    {option.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <div className="flex items-center gap-2 sm:ml-auto">
              <Button
                variant="outline"
                onClick={() => setSubmitOpen(true)}
                className="h-11 flex-1 lg:h-8 lg:flex-none"
              >
                <FilePlus2Icon data-icon="inline-start" />
                发起 demo 审批
              </Button>
              {tab === "pending" ? (
                <Button
                  onClick={() => void handleBatchApprove()}
                  disabled={batching || selected.size === 0}
                  className="h-11 flex-1 lg:h-8 lg:flex-none"
                >
                  {batching ? (
                    <Loader2Icon
                      className="animate-spin"
                      data-icon="inline-start"
                    />
                  ) : (
                    <CheckCheckIcon data-icon="inline-start" />
                  )}
                  批量通过{selected.size > 0 ? `（${selected.size}）` : ""}
                </Button>
              ) : null}
            </div>
          </div>

          {loading ? (
            <div className="flex flex-col gap-2">
              {Array.from({ length: 5 }).map((_, index) => (
                <Skeleton key={index} className="h-12 w-full" />
              ))}
            </div>
          ) : error ? (
            <div className="flex flex-col items-center gap-2 py-8 text-sm">
              <p className="text-destructive">
                加载失败：{translateApprovalErrorMessage(error)}
              </p>
              <Button variant="outline" onClick={() => void load()}>
                重试
              </Button>
            </div>
          ) : filtered.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <ListTodoIcon className="size-8 opacity-60" />
              {hasActiveFilters ? (
                <>
                  <span>未找到匹配的审批</span>
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => {
                      setSearch("");
                      setModuleFilter(ALL);
                      setTimeRange("all");
                    }}
                  >
                    清除筛选
                  </Button>
                </>
              ) : (
                <span>{emptyText}</span>
              )}
            </div>
          ) : isMobile ? (
            <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
              {pagedRows.map((row) =>
                tab === "pending" ? (
                  <div key={row.task_id} className="flex items-start gap-2">
                    <Checkbox
                      className="mt-4"
                      checked={selected.has(row.task_id)}
                      onCheckedChange={(checked) =>
                        toggleSelectOne(row.task_id, checked === true)
                      }
                      aria-label={`选择 ${row.title}`}
                    />
                    <TodoCard
                      row={row}
                      done={false}
                      highlighted={highlightInstanceId === row.instance_id}
                      onOpen={() => openDetail(row)}
                    />
                  </div>
                ) : (
                  <TodoCard
                    key={row.task_id}
                    row={row}
                    done={tab === "done"}
                    highlighted={highlightInstanceId === row.instance_id}
                    onOpen={() => openDetail(row)}
                  />
                ),
              )}
            </div>
          ) : (
            <div className="overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    {tab === "pending" ? (
                      <TableHead className="w-10 text-center">
                        <Checkbox
                          checked={allSelected}
                          onCheckedChange={(checked) =>
                            toggleSelectAll(checked === true)
                          }
                          aria-label="全选本页"
                        />
                      </TableHead>
                    ) : null}
                    <TableHead className="text-center">标题</TableHead>
                    <TableHead className="text-center">来源模块</TableHead>
                    <TableHead className="text-center">发起人</TableHead>
                    <TableHead className="text-center">提交时间</TableHead>
                    <TableHead className="text-center">
                      {tab === "pending" ? "等待时长" : "处理时间"}
                    </TableHead>
                    <TableHead className="text-center">状态</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {pagedRows.map((row) => (
                    <TableRow
                      key={row.task_id}
                      className={cn(
                        "cursor-pointer",
                        highlightInstanceId === row.instance_id &&
                          "border-primary bg-primary/5",
                      )}
                      tabIndex={0}
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
                      {tab === "pending" ? (
                        <TableCell
                          className="text-center"
                          onClick={(event) => event.stopPropagation()}
                        >
                          <Checkbox
                            checked={selected.has(row.task_id)}
                            onCheckedChange={(checked) =>
                              toggleSelectOne(row.task_id, checked === true)
                            }
                            aria-label={`选择 ${row.title}`}
                          />
                        </TableCell>
                      ) : null}
                      <TableCell className="text-center">
                        <span className="line-clamp-1 inline-block max-w-72 align-middle font-medium">
                          {row.title}
                        </span>
                      </TableCell>
                      <TableCell className="text-center">
                        <Badge
                          variant="outline"
                          className="text-muted-foreground"
                        >
                          {sourceModuleLabel(row.module)}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-center">
                        {row.initiator_name ?? "—"}
                      </TableCell>
                      <TableCell className="text-center text-xs whitespace-nowrap text-muted-foreground">
                        {formatDateTime(row.created_at)}
                      </TableCell>
                      <TableCell className="text-center">
                        {tab === "pending" ? (
                          <span className="inline-flex items-center gap-1.5 whitespace-nowrap">
                            {formatWaiting(row.created_at)}
                            {isOverdue48h(row.created_at) ? (
                              <Badge
                                variant="outline"
                                className={APPROVAL_OVERDUE_BADGE_CLASS}
                              >
                                <AlertTriangleIcon className="size-3" />
                                超48h
                              </Badge>
                            ) : null}
                          </span>
                        ) : (
                          <span className="text-xs whitespace-nowrap text-muted-foreground">
                            {formatDateTime(row.acted_at)}
                          </span>
                        )}
                      </TableCell>
                      <TableCell className="text-center">
                        {tab === "pending" ? (
                          <InstanceStatusBadge status={row.instance_status} />
                        ) : (
                          <TaskStatusBadge status={row.task_status} />
                        )}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}

          {!loading && !error && filtered.length > 0 ? (
            <div className="flex items-center justify-between gap-2 text-sm text-muted-foreground">
              <span>
                共 {filtered.length} 条 · 第 {currentPage} / {pageCount} 页
              </span>
              <div className="flex items-center gap-2">
                <Button
                  variant="outline"
                  disabled={currentPage <= 1 || loading}
                  onClick={() => setPage(currentPage - 1)}
                  className="h-11 px-4 lg:h-8 lg:px-3"
                >
                  上一页
                </Button>
                <Button
                  variant="outline"
                  disabled={currentPage >= pageCount || loading}
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
        open={detailRow !== null}
        onOpenChange={(open) => {
          if (!open) {
            closeDetail();
          }
        }}
      >
        <SheetContent
          side="right"
          className="w-full sm:max-w-[480px]"
        >
          {detailRow ? (
            <>
              <SheetHeader>
                <SheetTitle className="pr-8">{detailRow.title}</SheetTitle>
                <SheetDescription className="flex flex-wrap items-center gap-2 pt-1">
                  <span>{sourceModuleLabel(detailRow.module)}</span>
                  <span aria-hidden>·</span>
                  <span>{formatDateTime(detailRow.created_at)}</span>
                  <InstanceStatusBadge status={detailRow.instance_status} />
                </SheetDescription>
              </SheetHeader>
              <ApprovalDetailSections
                detail={detail}
                loading={detailLoading}
                error={detailError}
              />
              {tab === "pending" && detailRow.task_status === "pending" ? (
                <SheetFooter>
                  <Textarea
                    value={comment}
                    onChange={(event) => setComment(event.target.value)}
                    placeholder="审批意见（通过可选，驳回必填）"
                    rows={3}
                    aria-label="审批意见"
                  />
                  <div className="flex justify-end gap-2">
                    <Button
                      variant="outline"
                      onClick={() => void handleAct("reject")}
                      disabled={acting}
                    >
                      <XIcon data-icon="inline-start" />
                      驳回
                    </Button>
                    <Button
                      onClick={() => void handleAct("approve")}
                      disabled={acting}
                    >
                      {acting ? (
                        <Loader2Icon
                          className="animate-spin"
                          data-icon="inline-start"
                        />
                      ) : (
                        <CheckIcon data-icon="inline-start" />
                      )}
                      通过
                    </Button>
                  </div>
                </SheetFooter>
              ) : null}
            </>
          ) : null}
        </SheetContent>
      </Sheet>

      <Sheet open={submitOpen} onOpenChange={setSubmitOpen}>
        <SheetContent
          side="right"
          className="w-full sm:max-w-[480px]"
        >
          <SheetHeader>
            <SheetTitle>发起 demo 审批</SheetTitle>
            <SheetDescription>
              使用 demo.leave 模板提交请假申请，用于端到端演示审批流程
            </SheetDescription>
          </SheetHeader>
          <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-4">
            <Field>
              <FieldLabel htmlFor="demo-title">申请标题</FieldLabel>
              <Input
                id="demo-title"
                value={demoForm.title}
                onChange={(event) =>
                  setDemoForm((prev) => ({
                    ...prev,
                    title: event.target.value,
                  }))
                }
                placeholder="如：国庆请假申请"
              />
            </Field>
            <Field>
              <FieldLabel htmlFor="demo-days">请假天数</FieldLabel>
              <Input
                id="demo-days"
                type="number"
                min={0.5}
                step={0.5}
                value={demoForm.days}
                onChange={(event) =>
                  setDemoForm((prev) => ({ ...prev, days: event.target.value }))
                }
              />
            </Field>
            <Field>
              <FieldLabel htmlFor="demo-reason">请假事由</FieldLabel>
              <Textarea
                id="demo-reason"
                rows={4}
                value={demoForm.reason}
                onChange={(event) =>
                  setDemoForm((prev) => ({
                    ...prev,
                    reason: event.target.value,
                  }))
                }
                placeholder="简要说明请假原因"
              />
            </Field>
          </div>
          <SheetFooter className="flex-row justify-end gap-2">
            <Button variant="outline" onClick={() => setSubmitOpen(false)}>
              取消
            </Button>
            <Button onClick={() => void handleSubmitDemo()} disabled={submitting}>
              {submitting ? (
                <Loader2Icon className="animate-spin" data-icon="inline-start" />
              ) : null}
              提交审批
            </Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>
    </div>
  );
}

function TodoCard({
  row,
  done,
  highlighted,
  onOpen,
}: {
  row: TodoRow;
  done: boolean;
  highlighted: boolean;
  onOpen: () => void;
}) {
  return (
    <button
      type="button"
      data-slot="approval-todo-card"
      data-highlighted={highlighted ? "true" : undefined}
      onClick={onOpen}
      className={cn(
        "flex min-w-0 flex-1 flex-col gap-2.5 rounded-xl border bg-card p-4 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none",
        highlighted && "border-primary bg-primary/5",
      )}
    >
      <div className="flex items-start justify-between gap-3">
        <span className="min-w-0 truncate font-medium">{row.title}</span>
        {done ? (
          <TaskStatusBadge status={row.task_status} />
        ) : (
          <InstanceStatusBadge status={row.instance_status} />
        )}
      </div>
      <div className="flex flex-col gap-1.5 text-sm">
        <div className="flex items-center justify-between gap-4">
          <span className="text-muted-foreground">来源模块</span>
          <span>{sourceModuleLabel(row.module)}</span>
        </div>
        <div className="flex items-center justify-between gap-4">
          <span className="text-muted-foreground">发起人</span>
          <span>{row.initiator_name ?? "—"}</span>
        </div>
        <div className="flex items-center justify-between gap-4">
          <span className="text-muted-foreground">提交时间</span>
          <span className="tabular-nums">{formatDateTime(row.created_at)}</span>
        </div>
        <div className="flex items-center justify-between gap-4">
          <span className="text-muted-foreground">
            {done ? "处理时间" : "等待时长"}
          </span>
          {done ? (
            <span className="tabular-nums">{formatDateTime(row.acted_at)}</span>
          ) : (
            <span className="inline-flex items-center gap-1.5">
              {formatWaiting(row.created_at)}
              {isOverdue48h(row.created_at) ? (
                <Badge variant="outline" className={APPROVAL_OVERDUE_BADGE_CLASS}>
                  <AlertTriangleIcon className="size-3" />
                  超48h
                </Badge>
              ) : null}
            </span>
          )}
        </div>
      </div>
    </button>
  );
}
