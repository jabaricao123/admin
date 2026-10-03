"use client";

import * as React from "react";
import { FileTextIcon, HistoryIcon } from "lucide-react";
import { cn } from "cn";

import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import type { Database, Json } from "@/lib/database.types";
import {
  APPROVAL_TASK_STATUS_BADGE_CLASSES,
  APPROVAL_TASK_STATUS_LABELS,
  asApprovalTaskStatus,
  translateApprovalErrorMessage,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";
import { formatDateTime } from "./approval-utils";

export type InstanceDetail =
  Database["public"]["Functions"]["instance_detail"]["Returns"][number];

/** 详情 Sheet 数据源：进/换实例时自动拉取 instance_detail（参与方 RLS 校验在 DB 侧） */
export function useApprovalDetail(instanceId: string | null) {
  const [detail, setDetail] = React.useState<InstanceDetail | null>(null);
  const [loading, setLoading] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);

  React.useEffect(() => {
    if (!instanceId) {
      setDetail(null);
      setError(null);
      setLoading(false);
      return;
    }

    let cancelled = false;
    setLoading(true);
    setError(null);
    setDetail(null);

    void (async () => {
      const { data, error: detailError } = await createClient().rpc(
        "instance_detail",
        { p_instance_id: instanceId },
      );
      if (cancelled) {
        return;
      }
      if (detailError) {
        setError(detailError.message);
      } else {
        setDetail(data?.[0] ?? null);
      }
      setLoading(false);
    })();

    return () => {
      cancelled = true;
    };
  }, [instanceId]);

  return { detail, loading, error };
}

type FormField = { key: string; label: string; type?: string };

/** 通用 renderer：schema jsonb 有 fields 数组则按 label+value 渲染，否则回退 form_data 键名 */
function extractFields(schema: Json): FormField[] {
  if (!schema || typeof schema !== "object" || Array.isArray(schema)) {
    return [];
  }
  const fields = (schema as { fields?: unknown }).fields;
  if (!Array.isArray(fields)) {
    return [];
  }
  return fields.flatMap((item) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      return [];
    }
    const record = item as Record<string, unknown>;
    const key = typeof record.key === "string" ? record.key : "";
    if (!key) {
      return [];
    }
    const label =
      typeof record.label === "string" && record.label ? record.label : key;
    return [
      {
        key,
        label,
        type: typeof record.type === "string" ? record.type : undefined,
      },
    ];
  });
}

function formatFieldValue(value: Json | undefined, type?: string): string {
  if (value === null || value === undefined || value === "") {
    return "—";
  }
  if (typeof value === "boolean") {
    return value ? "是" : "否";
  }
  if (Array.isArray(value)) {
    if (value.length === 0) {
      return "—";
    }
    return value
      .map((item) =>
        typeof item === "object" && item !== null
          ? JSON.stringify(item)
          : String(item),
      )
      .join("、");
  }
  if (typeof value === "object") {
    return JSON.stringify(value);
  }
  if (type === "date" && typeof value === "string") {
    return value.slice(0, 10);
  }
  return String(value);
}

type TimelineTask = {
  task_id?: string;
  seq?: number;
  assignee_name?: string | null;
  status?: string;
  acted_at?: string | null;
  comment?: string | null;
  created_at?: string | null;
};

function parseTimeline(tasks: Json): TimelineTask[] {
  if (!Array.isArray(tasks)) {
    return [];
  }
  return tasks.flatMap((item) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      return [];
    }
    const record = item as Record<string, Json | undefined>;
    return [
      {
        task_id:
          typeof record.task_id === "string" ? record.task_id : undefined,
        seq: typeof record.seq === "number" ? record.seq : undefined,
        assignee_name:
          typeof record.assignee_name === "string"
            ? record.assignee_name
            : null,
        status: typeof record.status === "string" ? record.status : undefined,
        acted_at: typeof record.acted_at === "string" ? record.acted_at : null,
        comment: typeof record.comment === "string" ? record.comment : null,
        created_at:
          typeof record.created_at === "string" ? record.created_at : null,
      },
    ];
  });
}

/** 详情 Sheet 正文：表单数据（只读）+ 审批轨迹时间线；三页面共用 */
export function ApprovalDetailSections({
  detail,
  loading,
  error,
}: {
  detail: InstanceDetail | null;
  loading: boolean;
  error: string | null;
}) {
  if (loading) {
    return (
      <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-4">
        <Skeleton className="h-5 w-24" />
        <Skeleton className="h-24 w-full" />
        <Skeleton className="h-5 w-24" />
        <Skeleton className="h-32 w-full" />
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex min-h-0 flex-1 flex-col items-center justify-center gap-2 px-4 py-8 text-sm">
        <p className="text-destructive">
          加载失败：{translateApprovalErrorMessage(error)}
        </p>
      </div>
    );
  }

  if (!detail) {
    return null;
  }

  const formData =
    detail.form_data &&
    typeof detail.form_data === "object" &&
    !Array.isArray(detail.form_data)
      ? (detail.form_data as Record<string, Json>)
      : {};

  const fields = extractFields(detail.schema);
  const rows: FormField[] =
    fields.length > 0
      ? fields
      : Object.keys(formData).map((key) => ({ key, label: key }));

  const timeline = parseTimeline(detail.tasks);

  return (
    <div className="flex min-h-0 flex-1 flex-col gap-6 overflow-y-auto px-4">
      <section className="flex flex-col gap-2">
        <h3 className="flex items-center gap-1.5 text-sm font-medium">
          <FileTextIcon className="size-4 text-muted-foreground" />
          表单数据
        </h3>
        {rows.length === 0 ? (
          <p className="text-sm text-muted-foreground">暂无表单数据</p>
        ) : (
          <dl className="flex flex-col gap-2 rounded-lg border p-3">
            {rows.map((row) => (
              <div
                key={row.key}
                className="flex items-start justify-between gap-4 text-sm"
              >
                <dt className="shrink-0 text-muted-foreground">{row.label}</dt>
                <dd className="min-w-0 text-right break-words whitespace-pre-wrap">
                  {formatFieldValue(formData[row.key], row.type)}
                </dd>
              </div>
            ))}
          </dl>
        )}
      </section>

      <section className="flex flex-col gap-2">
        <h3 className="flex items-center gap-1.5 text-sm font-medium">
          <HistoryIcon className="size-4 text-muted-foreground" />
          审批轨迹
        </h3>
        {timeline.length === 0 ? (
          <p className="text-sm text-muted-foreground">暂无审批记录</p>
        ) : (
          <ol className="relative ml-1.5 flex flex-col gap-4 border-l border-border pl-4">
            {timeline.map((task, index) => {
              const status = asApprovalTaskStatus(task.status ?? "pending");
              const isPending = status === "pending";
              const timing = task.acted_at
                ? `处理于 ${formatDateTime(task.acted_at)}`
                : status === "skipped"
                  ? "未处理（流程结束跳过）"
                  : `待处理 · 进入于 ${formatDateTime(task.created_at)}`;
              return (
                <li key={task.task_id ?? index} className="relative">
                  <span
                    aria-hidden
                    className={cn(
                      "absolute top-1.5 -left-[21.5px] size-2.5 rounded-full border-2 border-background",
                      isPending ? "bg-primary" : "bg-muted-foreground/50",
                    )}
                  />
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="text-sm font-medium">
                      第 {task.seq ?? index + 1} 节点
                    </span>
                    <span className="text-sm text-muted-foreground">
                      {task.assignee_name ?? "未指定处理人"}
                    </span>
                    <Badge
                      variant="outline"
                      className={APPROVAL_TASK_STATUS_BADGE_CLASSES[status]}
                    >
                      {APPROVAL_TASK_STATUS_LABELS[status]}
                    </Badge>
                  </div>
                  <div className="mt-1 text-xs text-muted-foreground">
                    {timing}
                  </div>
                  {task.comment ? (
                    <p className="mt-2 rounded-md bg-muted px-2.5 py-1.5 text-sm whitespace-pre-wrap">
                      {task.comment}
                    </p>
                  ) : null}
                </li>
              );
            })}
          </ol>
        )}
      </section>
    </div>
  );
}
