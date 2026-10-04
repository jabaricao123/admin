// diff 渲染组件（audit/004，operations.md：字段级前后值对比，旧值删除线 + 新值主色）。
// 通用化设计：access/audit、audit/changes 均可复用；数据形态兼容三类写入约定：
//   1. { before: {...}, after: {...} }  字段级对比（access 角色编辑等）
//   2. { before: scalar, after: scalar, ...extras }  单值对比 + 上下文（assign/data_scope 等）
//   3. { key: value, ... }  平铺新建/越权原因（create/denied 等）
import { ArrowRightIcon } from "lucide-react";

import type { Json } from "@/lib/database.types";
import {
  formatDiffValue,
  isPlainObject,
  ROW_VERSION_FIELD_LABELS,
} from "@/lib/audit";

/**
 * 已知字段的中文展示名；未知字段回退原始 key。
 * 复用数据变更页（audit_row_versions）的字段映射（org 白名单表的 full_name、
 * department_id 等），再补操作日志/权限审计常见键（reason、module 等）。
 */
const FIELD_LABELS: Record<string, string> = {
  ...ROW_VERSION_FIELD_LABELS,
  reason: "原因",
  code: "标识",
  role_id: "角色 ID",
  module: "模块",
  config: "配置",
  source: "来源",
  before: "变更前",
  after: "变更后",
};

function fieldLabel(key: string): string {
  return FIELD_LABELS[key] ?? key;
}

type DiffEntry = { label: string; before?: Json; after?: Json };

function ChangeRow({ label, before, after }: DiffEntry) {
  const isNew = before === undefined;
  const isRemoved = after === undefined;

  return (
    <div className="flex flex-col gap-1.5 rounded-lg border p-3">
      <div className="text-xs text-muted-foreground">{label}</div>
      <div className="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm">
        {isNew ? (
          <span className="text-xs text-muted-foreground">（新增）</span>
        ) : (
          <span className="text-muted-foreground line-through">
            {formatDiffValue(before)}
          </span>
        )}
        {isRemoved ? (
          <span className="text-xs text-muted-foreground">（已删除）</span>
        ) : (
          <>
            <ArrowRightIcon className="size-3.5 shrink-0 text-muted-foreground" />
            <span className="font-medium text-primary">
              {formatDiffValue(after)}
            </span>
          </>
        )}
      </div>
    </div>
  );
}

function ContextRow({ label, value }: { label: string; value: Json }) {
  return (
    <div className="flex items-center justify-between gap-4 py-1.5 text-sm">
      <span className="text-muted-foreground">{label}</span>
      <span className="text-right break-all">{formatDiffValue(value)}</span>
    </div>
  );
}

type DiffModel = {
  changes: DiffEntry[];
  contexts: { label: string; value: Json }[];
};

function buildDiffModel(diff: Json | null | undefined): DiffModel | null {
  if (!isPlainObject(diff) || Object.keys(diff).length === 0) {
    return null;
  }

  const changes: DiffEntry[] = [];
  const contexts: { label: string; value: Json }[] = [];

  if ("before" in diff || "after" in diff) {
    const { before, after, ...extras } = diff;
    if (isPlainObject(before) || isPlainObject(after)) {
      const beforeObj = isPlainObject(before) ? before : {};
      const afterObj = isPlainObject(after) ? after : {};
      const keys = Array.from(
        new Set([...Object.keys(beforeObj), ...Object.keys(afterObj)]),
      );
      for (const key of keys) {
        changes.push({
          label: fieldLabel(key),
          before: key in beforeObj ? beforeObj[key] : undefined,
          after: key in afterObj ? afterObj[key] : undefined,
        });
      }
    } else {
      changes.push({ label: "变更", before, after });
    }
    for (const [key, value] of Object.entries(extras)) {
      contexts.push({ label: fieldLabel(key), value: value as Json });
    }
    return { changes, contexts };
  }

  // 平铺字段：按「新值」呈现（create/denied 等）
  for (const [key, value] of Object.entries(diff)) {
    changes.push({ label: fieldLabel(key), after: value as Json });
  }
  return { changes, contexts };
}

export function DiffView({ diff }: { diff: Json | null | undefined }) {
  const model = buildDiffModel(diff);

  if (model === null) {
    return <p className="py-2 text-sm text-muted-foreground">无差异数据</p>;
  }

  return (
    <div className="flex flex-col gap-2">
      {model.changes.map((entry, index) => (
        <ChangeRow
          key={`${entry.label}-${index}`}
          label={entry.label}
          before={entry.before}
          after={entry.after}
        />
      ))}
      {model.contexts.length > 0 ? (
        <div className="mt-1 flex flex-col divide-y rounded-lg border px-3 py-1">
          {model.contexts.map((entry) => (
            <ContextRow
              key={entry.label}
              label={entry.label}
              value={entry.value}
            />
          ))}
        </div>
      ) : null}
    </div>
  );
}
