"use client";

// 审批中心 · 审批流程（工单 approval/010 页面 + 011 模拟运行）
//
// 数据：approval_flows / approval_form_templates（admin SELECT）+ roles / profiles（规则取值）
//       + approval_usage_counts（引用中实例数）；写全经管理 RPC（admin 校验在 DB 侧）。
// 语义：流程绑定具体模板版本；仅 draft 可编辑，published 冻结，「新版本」复制为 v+1 draft；
//       停用需无进行中实例引用；发布新版不影响进行中旧实例。
// 交互：列表按模板分组折叠历史版本；Sheet = 节点横向序列 + 节点属性编辑 + 模拟运行 tab；
//       模拟运行先保存草稿再调 simulate_flow（与 submit_instance 同一 resolve_approver）。

import * as React from "react";
import {
  AlertTriangleIcon,
  ArrowDownIcon,
  ArrowUpIcon,
  BanIcon,
  ChevronDownIcon,
  ChevronRightIcon,
  EyeIcon,
  GitBranchIcon,
  Loader2Icon,
  PencilIcon,
  PlayIcon,
  PlusIcon,
  RocketIcon,
  Trash2Icon,
  WorkflowIcon,
} from "lucide-react";
import { toast } from "sonner";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Field, FieldDescription, FieldLabel } from "@/components/ui/field";
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
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Textarea } from "@/components/ui/textarea";
import type { Database, Json } from "@/lib/database.types";
import { translateApprovalErrorMessage } from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";
import { cn } from "cn";

import {
  APPROVER_RULE_LABELS,
  APPROVER_RULE_OPTIONS,
  CONFIG_STATUS_BADGE_CLASSES,
  CONFIG_STATUS_LABELS,
  asApproverRuleType,
  asConfigStatus,
  newFlowNode,
  nodesFromJson,
  nodesToJson,
  resolveRoleId,
  ruleSummary,
  sampleFormData,
  validateFlowNodes,
  type ApproverRuleType,
  type FlowNodeDraft,
} from "./approval-config-utils";
import { formatDateTime } from "./approval-utils";

type FlowRow = Database["public"]["Tables"]["approval_flows"]["Row"];
type TemplateRow =
  Database["public"]["Tables"]["approval_form_templates"]["Row"];
type RoleLite = {
  id: string;
  code: string;
  name: string;
  status: string;
};
type ProfileLite = {
  id: string;
  full_name: string | null;
  role: string;
  status: string;
};
type UsageRow =
  Database["public"]["Functions"]["approval_usage_counts"]["Returns"][number];

type SimStep = {
  seq?: number;
  approver_id?: string | null;
  approver_name?: string | null;
  approver_rule?: Json;
  timeout_hours?: Json;
  error?: string | null;
};

type SheetMode = "create" | "edit" | "view";

function StatusBadge({ status }: { status: string }) {
  const value = asConfigStatus(status);
  return (
    <Badge variant="outline" className={CONFIG_STATUS_BADGE_CLASSES[value]}>
      {CONFIG_STATUS_LABELS[value]}
    </Badge>
  );
}

export function ApprovalFlowsTable() {
  const [flows, setFlows] = React.useState<FlowRow[]>([]);
  const [templates, setTemplates] = React.useState<TemplateRow[]>([]);
  const [roles, setRoles] = React.useState<RoleLite[]>([]);
  const [profiles, setProfiles] = React.useState<ProfileLite[]>([]);
  const [usage, setUsage] = React.useState<UsageRow[]>([]);
  const [currentUserId, setCurrentUserId] = React.useState<string | null>(null);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [expanded, setExpanded] = React.useState<Set<string>>(new Set());
  const [busyId, setBusyId] = React.useState<string | null>(null);

  // Sheet 状态
  const [sheetOpen, setSheetOpen] = React.useState(false);
  const [sheetMode, setSheetMode] = React.useState<SheetMode>("create");
  const [editingId, setEditingId] = React.useState<string | null>(null);
  const [editingVersion, setEditingVersion] = React.useState<number | null>(
    null,
  );
  const [activeTab, setActiveTab] = React.useState("design");
  const [formName, setFormName] = React.useState("");
  const [formTemplateId, setFormTemplateId] = React.useState("");
  const [nodes, setNodes] = React.useState<FlowNodeDraft[]>([]);
  const [selectedNodeId, setSelectedNodeId] = React.useState<string | null>(
    null,
  );
  const [saving, setSaving] = React.useState(false);
  const [publishing, setPublishing] = React.useState(false);

  // 模拟运行状态
  const [simInitiator, setSimInitiator] = React.useState("");
  const [simFormData, setSimFormData] = React.useState("{}");
  const [simResult, setSimResult] = React.useState<SimStep[] | null>(null);
  const [simError, setSimError] = React.useState<string | null>(null);
  const [simulating, setSimulating] = React.useState(false);

  const readOnly = sheetMode === "view";

  const load = React.useCallback(async (options?: { silent?: boolean }) => {
    if (!options?.silent) {
      setLoading(true);
    }
    setError(null);
    const supabase = createClient();
    const [
      flowResult,
      templateResult,
      roleResult,
      profileResult,
      usageResult,
      userResult,
    ] = await Promise.all([
      supabase
        .from("approval_flows")
        .select("*")
        .order("version", { ascending: false }),
      supabase
        .from("approval_form_templates")
        .select("*")
        .order("code")
        .order("version", { ascending: false }),
      supabase
        .from("roles")
        .select("id, code, name, status")
        .order("created_at"),
      supabase
        .from("profiles")
        .select("id, full_name, role, status")
        .eq("status", "active")
        .order("full_name"),
      supabase.rpc("approval_usage_counts"),
      supabase.auth.getUser(),
    ]);

    const firstError =
      flowResult.error ??
      templateResult.error ??
      roleResult.error ??
      profileResult.error ??
      usageResult.error;
    if (firstError) {
      setError(firstError.message);
      setLoading(false);
      return;
    }

    setFlows(flowResult.data ?? []);
    setTemplates(templateResult.data ?? []);
    setRoles(roleResult.data ?? []);
    setProfiles(profileResult.data ?? []);
    setUsage(usageResult.data ?? []);
    setCurrentUserId(userResult.data.user?.id ?? null);
    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const usageByFlow = React.useMemo(() => {
    const map = new Map<string, { total: number; running: number }>();
    for (const row of usage) {
      map.set(row.flow_version_id, {
        total: Number(row.total_count),
        running: Number(row.running_count),
      });
    }
    return map;
  }, [usage]);

  const groups = React.useMemo(() => {
    const map = new Map<string, FlowRow[]>();
    for (const row of flows) {
      const list = map.get(row.template_id) ?? [];
      list.push(row);
      map.set(row.template_id, list);
    }
    return Array.from(map.entries()).map(([templateId, rows]) => ({
      templateId,
      template: templates.find((item) => item.id === templateId) ?? null,
      rows: [...rows].sort((a, b) => b.version - a.version),
    }));
  }, [flows, templates]);

  const activeRoles = React.useMemo(
    () => roles.filter((role) => role.status === "active"),
    [roles],
  );
  const roleIds = React.useMemo(
    () => activeRoles.map((role) => role.id),
    [activeRoles],
  );
  const userIds = React.useMemo(
    () => profiles.map((profile) => profile.id),
    [profiles],
  );

  const defaultRoleId = React.useMemo(
    () =>
      activeRoles.find((role) => role.code === "admin")?.id ??
      activeRoles[0]?.id ??
      "",
    [activeRoles],
  );

  const selectedNode = React.useMemo(
    () => nodes.find((node) => node.id === selectedNodeId) ?? null,
    [nodes, selectedNodeId],
  );

  const bindableTemplates = React.useMemo(
    () => templates.filter((template) => template.status !== "disabled"),
    [templates],
  );

  /** template_id → 该模板已存在流程的 id 集合（同模板可有多版本行） */
  const flowIdsByTemplate = React.useMemo(() => {
    const map = new Map<string, Set<string>>();
    for (const row of flows) {
      const ids = map.get(row.template_id) ?? new Set<string>();
      ids.add(row.id);
      map.set(row.template_id, ids);
    }
    return map;
  }, [flows]);

  /** 新建可用模板：排除已有流程的模板，消除「该模板下已存在流程」必败路径 */
  const createTemplates = React.useMemo(
    () =>
      bindableTemplates.filter(
        (template) => !flowIdsByTemplate.has(template.id),
      ),
    [bindableTemplates, flowIdsByTemplate],
  );

  /** 编辑草稿当前绑定的模板 id（该模板保持可选，回切不受限） */
  const editingFlowTemplateId = React.useMemo(() => {
    if (!editingId) {
      return null;
    }
    return flows.find((row) => row.id === editingId)?.template_id ?? null;
  }, [flows, editingId]);

  /** 编辑态：当前流程绑定的模板保持可选；其余已有流程的模板禁用 */
  const isTemplateTaken = (templateId: string) => {
    if (editingId !== null && templateId === editingFlowTemplateId) {
      return false;
    }
    return flowIdsByTemplate.has(templateId);
  };

  const boundTemplate = React.useMemo(
    () => templates.find((template) => template.id === formTemplateId) ?? null,
    [templates, formTemplateId],
  );

  const resetSimulation = (template: TemplateRow | null) => {
    setSimResult(null);
    setSimError(null);
    setSimFormData(
      JSON.stringify(sampleFormData(template?.schema ?? ({} as Json)), null, 2),
    );
    setSimInitiator((prev) => prev || currentUserId || "");
  };

  // -------------------------------------------------------------------------
  // 打开 / 关闭设计器
  // -------------------------------------------------------------------------
  const openCreate = () => {
    const template =
      createTemplates.find((item) => item.status === "published") ??
      createTemplates[0] ??
      null;
    if (!template) {
      toast.error("所有可用模板均已绑定流程，请先新建模板版本");
      return;
    }
    const first = newFlowNode({ roleId: defaultRoleId });
    setSheetMode("create");
    setEditingId(null);
    setEditingVersion(null);
    setFormName("");
    setFormTemplateId(template.id);
    setNodes([first]);
    setSelectedNodeId(first.id);
    setActiveTab("design");
    setSimInitiator(currentUserId ?? profiles[0]?.id ?? "");
    resetSimulation(template);
    setSheetOpen(true);
  };

  const openRow = (
    row: FlowRow,
    mode: SheetMode,
    tab: "design" | "simulate" = "design",
  ) => {
    const parsed = nodesFromJson(row.nodes);
    const initialRaw =
      parsed.length > 0 ? parsed : [newFlowNode({ roleId: defaultRoleId })];
    // 存量节点 role value 可能是 code：归一化为 role.id 后再进入设计器
    const initial = initialRaw.map((node) =>
      node.ruleType === "role"
        ? { ...node, roleId: resolveRoleId(node.roleId, roles) }
        : node,
    );
    const template = templates.find((item) => item.id === row.template_id) ?? null;
    setSheetMode(mode);
    setEditingId(row.id);
    setEditingVersion(row.version);
    setFormName(row.name);
    setFormTemplateId(row.template_id);
    setNodes(initial);
    setSelectedNodeId(initial[0]?.id ?? null);
    setActiveTab(tab);
    setSimInitiator(currentUserId ?? profiles[0]?.id ?? "");
    resetSimulation(template);
    setSheetOpen(true);
  };

  const closeSheet = () => {
    setSheetOpen(false);
    setEditingId(null);
    setEditingVersion(null);
    setNodes([]);
    setSelectedNodeId(null);
    setSimResult(null);
    setSimError(null);
  };

  // -------------------------------------------------------------------------
  // 节点编辑
  // -------------------------------------------------------------------------
  const updateNode = (id: string, patch: Partial<FlowNodeDraft>) => {
    setNodes((prev) =>
      prev.map((node) => (node.id === id ? { ...node, ...patch } : node)),
    );
  };

  const moveNode = (index: number, delta: -1 | 1) => {
    setNodes((prev) => {
      const target = index + delta;
      if (target < 0 || target >= prev.length) {
        return prev;
      }
      const next = [...prev];
      [next[index], next[target]] = [next[target], next[index]];
      return next;
    });
  };

  const addNode = () => {
    const node = newFlowNode({ roleId: defaultRoleId });
    setNodes((prev) => [...prev, node]);
    setSelectedNodeId(node.id);
  };

  const removeNode = (id: string) => {
    setNodes((prev) => {
      const next = prev.filter((node) => node.id !== id);
      setSelectedNodeId((current) =>
        current === id ? (next[0]?.id ?? null) : current,
      );
      return next;
    });
  };

  const handleTemplateChange = (templateId: string) => {
    setFormTemplateId(templateId);
    const template = templates.find((item) => item.id === templateId) ?? null;
    resetSimulation(template);
  };

  // -------------------------------------------------------------------------
  // 保存 / 发布 / 停用 / 新版本
  // -------------------------------------------------------------------------
  const saveDraft = React.useCallback(async (): Promise<FlowRow | null> => {
    if (!formName.trim()) {
      toast.error("流程名称不能为空");
      return null;
    }
    if (!formTemplateId) {
      toast.error("请选择绑定模板");
      return null;
    }
    if (boundTemplate?.status === "disabled") {
      toast.error("绑定模板已停用，请改绑其他版本");
      return null;
    }
    const nodeError = validateFlowNodes(nodes, roleIds, userIds);
    if (nodeError) {
      toast.error(nodeError);
      return null;
    }

    setSaving(true);
    const { data, error: saveError } = await createClient().rpc("upsert_flow", {
      p_name: formName.trim(),
      p_template_id: formTemplateId,
      p_nodes: nodesToJson(nodes),
      p_id: editingId ?? undefined,
    });
    setSaving(false);

    if (saveError) {
      toast.error(translateApprovalErrorMessage(saveError.message));
      return null;
    }
    setEditingId(data.id);
    setEditingVersion(data.version);
    return data;
  }, [boundTemplate, editingId, formName, formTemplateId, nodes, roleIds, userIds]);

  const handleSaveDraft = async () => {
    const saved = await saveDraft();
    if (!saved) {
      return;
    }
    toast.success(`草稿已保存（v${saved.version}）`);
    void load({ silent: true });
  };

  const handlePublish = async () => {
    const saved = await saveDraft();
    if (!saved) {
      return;
    }
    setPublishing(true);
    const { error: publishError } = await createClient().rpc("publish_flow", {
      p_id: saved.id,
    });
    setPublishing(false);
    if (publishError) {
      toast.error(translateApprovalErrorMessage(publishError.message));
      return;
    }
    toast.success(`已发布 v${saved.version}`);
    void load({ silent: true });
  };

  const handlePublishRow = async (row: FlowRow) => {
    setBusyId(row.id);
    const { error: publishError } = await createClient().rpc("publish_flow", {
      p_id: row.id,
    });
    setBusyId(null);
    if (publishError) {
      toast.error(translateApprovalErrorMessage(publishError.message));
      return;
    }
    toast.success(`已发布 ${row.name} v${row.version}`);
    void load({ silent: true });
  };

  const handleNewVersion = async (row: FlowRow) => {
    if (
      !window.confirm(
        `基于 ${row.name} v${row.version} 创建 v${row.version + 1} 草稿？旧版本保持不变。`,
      )
    ) {
      return;
    }
    setBusyId(row.id);
    const { data, error: versionError } = await createClient().rpc(
      "new_flow_version",
      { p_id: row.id },
    );
    setBusyId(null);
    if (versionError) {
      toast.error(translateApprovalErrorMessage(versionError.message));
      return;
    }
    toast.success(`已创建 v${data.version} 草稿`);
    await load({ silent: true });
    openRow(data, "edit");
  };

  const handleDisable = async (row: FlowRow) => {
    if (
      !window.confirm(
        `停用 ${row.name} v${row.version}？停用后不可恢复；仍有进行中实例引用时会被拒绝。`,
      )
    ) {
      return;
    }
    setBusyId(row.id);
    const { error: disableError } = await createClient().rpc("disable_flow", {
      p_id: row.id,
    });
    setBusyId(null);
    if (disableError) {
      toast.error(translateApprovalErrorMessage(disableError.message));
      return;
    }
    toast.success("流程已停用");
    void load({ silent: true });
  };

  // -------------------------------------------------------------------------
  // 模拟运行
  // -------------------------------------------------------------------------
  const runSimulation = async () => {
    const nodeError = validateFlowNodes(nodes, roleIds, userIds);
    if (nodeError) {
      toast.error(nodeError);
      return;
    }
    if (!simInitiator) {
      toast.error("请选择模拟发起人");
      return;
    }

    // 编辑/新建时先保存，确保模拟的是持久化后的 nodes（与真实提交路径一致）
    let flowId = editingId;
    if (sheetMode !== "view") {
      const saved = await saveDraft();
      if (!saved) {
        return;
      }
      flowId = saved.id;
    }
    if (!flowId) {
      toast.error("请先保存流程草稿再模拟");
      return;
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(simFormData || "{}");
    } catch {
      setSimError("样例 form_data 不是合法 JSON");
      setSimResult(null);
      return;
    }
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      setSimError("form_data 必须是 JSON 对象");
      setSimResult(null);
      return;
    }

    setSimulating(true);
    setSimError(null);
    const { data, error: simErrorResult } = await createClient().rpc(
      "simulate_flow",
      {
        p_flow_id: flowId,
        p_form_data: parsed as Json,
        p_initiator: simInitiator,
      },
    );
    setSimulating(false);
    if (simErrorResult) {
      setSimError(translateApprovalErrorMessage(simErrorResult.message));
      setSimResult(null);
      return;
    }
    setSimResult(Array.isArray(data) ? (data as unknown as SimStep[]) : []);
  };

  // -------------------------------------------------------------------------
  // 行渲染
  // -------------------------------------------------------------------------
  const renderActions = (row: FlowRow) => {
    const status = asConfigStatus(row.status);
    const busy = busyId === row.id;
    return (
      <div className="flex flex-wrap items-center justify-end gap-1">
        {status === "draft" ? (
          <>
            <Button
              size="sm"
              variant="outline"
              className="h-9 lg:h-8"
              onClick={() => openRow(row, "edit")}
            >
              <PencilIcon data-icon="inline-start" />
              编辑
            </Button>
            <Button
              size="sm"
              variant="outline"
              className="h-9 lg:h-8"
              disabled={busy}
              onClick={() => void handlePublishRow(row)}
            >
              {busy ? (
                <Loader2Icon
                  className="animate-spin"
                  data-icon="inline-start"
                />
              ) : (
                <RocketIcon data-icon="inline-start" />
              )}
              发布
            </Button>
          </>
        ) : (
          <>
            <Button
              size="sm"
              variant="outline"
              className="h-9 lg:h-8"
              onClick={() => openRow(row, "view")}
            >
              <EyeIcon data-icon="inline-start" />
              查看
            </Button>
            <Button
              size="sm"
              variant="outline"
              className="h-9 lg:h-8"
              onClick={() => openRow(row, "view", "simulate")}
            >
              <PlayIcon data-icon="inline-start" />
              模拟
            </Button>
            <Button
              size="sm"
              variant="outline"
              className="h-9 lg:h-8"
              disabled={busy}
              onClick={() => void handleNewVersion(row)}
            >
              {busy ? (
                <Loader2Icon
                  className="animate-spin"
                  data-icon="inline-start"
                />
              ) : (
                <GitBranchIcon data-icon="inline-start" />
              )}
              新版本
            </Button>
            {status === "published" ? (
              <Button
                size="sm"
                variant="outline"
                className="h-9 lg:h-8"
                disabled={busy}
                onClick={() => void handleDisable(row)}
              >
                <BanIcon data-icon="inline-start" />
                停用
              </Button>
            ) : null}
          </>
        )}
      </div>
    );
  };

  const renderHistoryRow = (row: FlowRow, template: TemplateRow | null) => {
    const counts = usageByFlow.get(row.id);
    return (
      <TableRow key={row.id} className="bg-muted/40">
        <TableCell className="max-w-[200px]">
          <span className="pl-5 text-xs text-muted-foreground">
            v{row.version} · {row.name}
          </span>
        </TableCell>
        <TableCell className="text-sm">
          {template ? (
            <span>
              {template.name}
              <span className="font-mono text-xs text-muted-foreground">
                {" "}
                v{template.version}
              </span>
            </span>
          ) : (
            "—"
          )}
        </TableCell>
        <TableCell className="font-mono text-sm">v{row.version}</TableCell>
        <TableCell>
          <StatusBadge status={row.status} />
        </TableCell>
        <TableCell className="text-sm">
          {counts ? (
            <span>
              {counts.total}
              <span className="text-xs text-muted-foreground">
                （进行中 {counts.running}）
              </span>
            </span>
          ) : (
            "0"
          )}
        </TableCell>
        <TableCell className="text-xs text-muted-foreground">
          {formatDateTime(row.updated_at)}
        </TableCell>
        <TableCell>{renderActions(row)}</TableCell>
      </TableRow>
    );
  };

  const toggleExpanded = (templateId: string) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(templateId)) {
        next.delete(templateId);
      } else {
        next.add(templateId);
      }
      return next;
    });
  };

  return (
    <div className="flex flex-col p-0 md:gap-6 md:p-6">
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardContent className="flex flex-col gap-4 p-4 md:p-6">
          <div className="flex items-center justify-between gap-2">
            <span className="text-sm text-muted-foreground">
              共 {groups.length} 个模板流程（{flows.length} 个版本）
            </span>
            <div className="flex items-center gap-2">
              <Button onClick={openCreate} className="h-11 lg:h-8">
                <PlusIcon data-icon="inline-start" />
                新增流程
              </Button>
            </div>
          </div>

          {loading ? (
            <div className="flex flex-col gap-3">
              {Array.from({ length: 3 }).map((_, index) => (
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
          ) : groups.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <WorkflowIcon className="size-8 opacity-60" />
              <span>暂无审批流程</span>
            </div>
          ) : (
            <div className="overflow-x-auto rounded-lg border">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>流程名</TableHead>
                    <TableHead>绑定模板</TableHead>
                    <TableHead>版本</TableHead>
                    <TableHead>状态</TableHead>
                    <TableHead>实例引用</TableHead>
                    <TableHead>更新时间</TableHead>
                    <TableHead className="text-right">操作</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {groups.map((group) => {
                    const latest = group.rows[0];
                    const isExpanded = expanded.has(group.templateId);
                    const counts = usageByFlow.get(latest.id);
                    return (
                      <React.Fragment key={group.templateId}>
                        <TableRow>
                          <TableCell className="max-w-[220px]">
                            <button
                              type="button"
                              onClick={() => toggleExpanded(group.templateId)}
                              className="flex items-center gap-1.5 text-left"
                            >
                              {group.rows.length > 1 ? (
                                isExpanded ? (
                                  <ChevronDownIcon className="size-4 shrink-0" />
                                ) : (
                                  <ChevronRightIcon className="size-4 shrink-0" />
                                )
                              ) : (
                                <WorkflowIcon className="size-4 shrink-0 text-muted-foreground" />
                              )}
                              <span className="truncate font-medium">
                                {latest.name}
                              </span>
                              {group.rows.length > 1 ? (
                                <Badge
                                  variant="ghost"
                                  className="text-[11px] text-muted-foreground"
                                >
                                  {group.rows.length} 个版本
                                </Badge>
                              ) : null}
                            </button>
                          </TableCell>
                          <TableCell className="text-sm">
                            {group.template ? (
                              <span>
                                {group.template.name}
                                <span className="font-mono text-xs text-muted-foreground">
                                  {" "}
                                  v{group.template.version}
                                </span>
                              </span>
                            ) : (
                              "—"
                            )}
                          </TableCell>
                          <TableCell className="font-mono text-sm">
                            v{latest.version}
                          </TableCell>
                          <TableCell>
                            <StatusBadge status={latest.status} />
                          </TableCell>
                          <TableCell className="text-sm">
                            {counts ? (
                              <span>
                                {counts.total}
                                <span className="text-xs text-muted-foreground">
                                  （进行中 {counts.running}）
                                </span>
                              </span>
                            ) : (
                              "0"
                            )}
                          </TableCell>
                          <TableCell className="text-xs text-muted-foreground">
                            {formatDateTime(latest.updated_at)}
                          </TableCell>
                          <TableCell>{renderActions(latest)}</TableCell>
                        </TableRow>
                        {isExpanded
                          ? group.rows
                              .slice(1)
                              .map((row) => renderHistoryRow(row, group.template))
                          : null}
                      </React.Fragment>
                    );
                  })}
                </TableBody>
              </Table>
            </div>
          )}
        </CardContent>
      </Card>

      <Sheet
        open={sheetOpen}
        onOpenChange={(open) => {
          if (!open) {
            closeSheet();
          }
        }}
      >
        <SheetContent
          side="right"
          className="w-full gap-0 sm:w-[72vw] sm:min-w-[520px] sm:max-w-[1080px]"
        >
          <SheetHeader className="border-b">
            <SheetTitle>
              {sheetMode === "create"
                ? "新增审批流程"
                : sheetMode === "edit"
                  ? `编辑流程 v${editingVersion ?? "?"}`
                  : `查看流程 v${editingVersion ?? "?"}`}
            </SheetTitle>
            <SheetDescription className="flex flex-col gap-1">
              <span className="font-mono text-xs">
                {boundTemplate
                  ? `${boundTemplate.name} v${boundTemplate.version}（${boundTemplate.code}）`
                  : "（未绑定模板）"}
              </span>
              <span className="text-xs">
                {sheetMode === "view"
                  ? "已发布内容冻结：如需修改请使用「新版本」复制为草稿；可随时模拟运行"
                  : "仅草稿可编辑；节点按 seq 顺序审批，发布后进行中实例按旧版本执行"}
              </span>
            </SheetDescription>
          </SheetHeader>

          <Tabs
            value={activeTab}
            onValueChange={setActiveTab}
            className="min-h-0 flex-1 gap-0 px-4"
          >
            <TabsList className="mt-3 w-full">
              <TabsTrigger value="design">节点设计</TabsTrigger>
              <TabsTrigger value="simulate">模拟运行</TabsTrigger>
            </TabsList>

            {/* 节点设计 */}
            <TabsContent
              value="design"
              className="flex min-h-0 flex-col gap-4 overflow-y-auto pt-4 pb-2"
            >
              <div className="grid gap-3 sm:grid-cols-2">
                <Field>
                  <FieldLabel htmlFor="flow-name">流程名称</FieldLabel>
                  <Input
                    id="flow-name"
                    value={formName}
                    onChange={(event) => setFormName(event.target.value)}
                    placeholder="如：请假单节点审批"
                    disabled={readOnly}
                  />
                </Field>
                <Field>
                  <FieldLabel htmlFor="flow-template">绑定模板</FieldLabel>
                  <Select
                    value={formTemplateId}
                    onValueChange={handleTemplateChange}
                    disabled={readOnly}
                  >
                    <SelectTrigger id="flow-template" className="w-full">
                      <SelectValue placeholder="选择模板版本" />
                    </SelectTrigger>
                    <SelectContent>
                      {bindableTemplates.map((template) => {
                        const taken = isTemplateTaken(template.id);
                        return (
                          <SelectItem
                            key={template.id}
                            value={template.id}
                            disabled={taken}
                          >
                            {template.name} v{template.version}（{template.code}）
                            {taken ? " · 已有流程" : ""}
                          </SelectItem>
                        );
                      })}
                    </SelectContent>
                  </Select>
                  <FieldDescription>
                    绑定的是具体模板版本；同模板仅维护一条版本链，已有流程的模板请用「新版本」
                  </FieldDescription>
                </Field>
              </div>

              {/* 节点横向序列 */}
              <div className="flex flex-wrap items-center gap-1 rounded-lg border bg-muted/30 p-3">
                {nodes.length === 0 ? (
                  <span className="text-sm text-muted-foreground">
                    暂无节点
                  </span>
                ) : (
                  nodes.map((node, index) => (
                    <React.Fragment key={node.id}>
                      {index > 0 ? (
                        <span className="text-muted-foreground">→</span>
                      ) : null}
                      <button
                        type="button"
                        onClick={() => setSelectedNodeId(node.id)}
                        className={cn(
                          "flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs transition-colors",
                          node.id === selectedNodeId
                            ? "border-primary bg-primary/10 text-primary"
                            : "bg-background hover:bg-muted",
                        )}
                      >
                        <span className="flex size-4 items-center justify-center rounded-full bg-muted text-[10px] font-medium">
                          {index + 1}
                        </span>
                        {ruleSummary(node, activeRoles, profiles)}
                      </button>
                    </React.Fragment>
                  ))
                )}
              </div>

              <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_20rem]">
                <div className="flex flex-col gap-2">
                  <p className="text-xs text-muted-foreground lg:hidden">
                    移动端建议以查看与模拟为主，节点编辑请在桌面端进行。
                  </p>
                  {nodes.length === 0 ? (
                    <p className="rounded-lg border border-dashed p-6 text-center text-sm text-muted-foreground">
                      暂无节点，点击下方「添加节点」
                    </p>
                  ) : (
                    nodes.map((node, index) => {
                      const selected = node.id === selectedNodeId;
                      return (
                        <div
                          key={node.id}
                          role="button"
                          tabIndex={0}
                          onClick={() => setSelectedNodeId(node.id)}
                          onKeyDown={(event) => {
                            if (event.key === "Enter" || event.key === " ") {
                              event.preventDefault();
                              setSelectedNodeId(node.id);
                            }
                          }}
                          className={cn(
                            "flex cursor-pointer items-center gap-2 rounded-lg border p-3 transition-colors",
                            selected
                              ? "border-primary bg-primary/5"
                              : "hover:bg-muted/50",
                          )}
                        >
                          <span className="w-6 shrink-0 text-center text-xs text-muted-foreground">
                            {index + 1}
                          </span>
                          <div className="min-w-0 flex-1">
                            <div className="truncate text-sm font-medium">
                              {ruleSummary(node, activeRoles, profiles)}
                            </div>
                            <div className="truncate font-mono text-xs text-muted-foreground">
                              seq {index + 1} ·{" "}
                              {APPROVER_RULE_LABELS[node.ruleType]}
                              {node.timeoutHours.trim()
                                ? ` · 超时 ${node.timeoutHours} 小时`
                                : ""}
                            </div>
                          </div>
                          <div
                            className="flex shrink-0 items-center"
                            onClick={(event) => event.stopPropagation()}
                          >
                            <Button
                              type="button"
                              size="icon"
                              variant="ghost"
                              className="size-8"
                              aria-label="上移节点"
                              disabled={readOnly || index === 0}
                              onClick={() => moveNode(index, -1)}
                            >
                              <ArrowUpIcon className="size-4" />
                            </Button>
                            <Button
                              type="button"
                              size="icon"
                              variant="ghost"
                              className="size-8"
                              aria-label="下移节点"
                              disabled={readOnly || index === nodes.length - 1}
                              onClick={() => moveNode(index, 1)}
                            >
                              <ArrowDownIcon className="size-4" />
                            </Button>
                            <Button
                              type="button"
                              size="icon"
                              variant="ghost"
                              className="size-8 text-destructive"
                              aria-label="删除节点"
                              disabled={readOnly || nodes.length <= 1}
                              onClick={() => removeNode(node.id)}
                            >
                              <Trash2Icon className="size-4" />
                            </Button>
                          </div>
                        </div>
                      );
                    })
                  )}
                  {!readOnly ? (
                    <Button
                      type="button"
                      variant="outline"
                      onClick={addNode}
                      className="h-11 lg:h-9"
                    >
                      <PlusIcon data-icon="inline-start" />
                      添加节点
                    </Button>
                  ) : null}
                </div>

                {/* 节点属性面板 */}
                <div className="rounded-lg border p-4">
                  {selectedNode ? (
                    <div className="flex flex-col gap-4">
                      <Field>
                        <FieldLabel htmlFor="node-rule-type">
                          审批人规则
                        </FieldLabel>
                        <Select
                          value={selectedNode.ruleType}
                          onValueChange={(value) => {
                            const ruleType = asApproverRuleType(value);
                            updateNode(selectedNode.id, {
                              ruleType,
                              roleId:
                                ruleType === "role"
                                  ? selectedNode.roleId || defaultRoleId
                                  : "",
                              userId:
                                ruleType === "user" ? selectedNode.userId : "",
                            });
                          }}
                          disabled={readOnly}
                        >
                          <SelectTrigger
                            id="node-rule-type"
                            className="w-full"
                          >
                            <SelectValue />
                          </SelectTrigger>
                          <SelectContent>
                            {APPROVER_RULE_OPTIONS.map((option) => (
                              <SelectItem
                                key={option.value}
                                value={option.value}
                              >
                                {option.label}
                              </SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                      </Field>

                      {selectedNode.ruleType === "role" ? (
                        <Field>
                          <FieldLabel htmlFor="node-role">角色</FieldLabel>
                          <Select
                            value={selectedNode.roleId}
                            onValueChange={(value) =>
                              updateNode(selectedNode.id, { roleId: value })
                            }
                            disabled={readOnly}
                          >
                            <SelectTrigger id="node-role" className="w-full">
                              <SelectValue placeholder="选择角色" />
                            </SelectTrigger>
                            <SelectContent>
                              {activeRoles.map((role) => (
                                <SelectItem key={role.id} value={role.id}>
                                  {role.name}
                                </SelectItem>
                              ))}
                            </SelectContent>
                          </Select>
                          <FieldDescription>
                            运行时取该角色下建档最早的启用用户
                          </FieldDescription>
                        </Field>
                      ) : null}

                      {selectedNode.ruleType === "user" ? (
                        <Field>
                          <FieldLabel htmlFor="node-user">指定审批人</FieldLabel>
                          <Select
                            value={selectedNode.userId}
                            onValueChange={(value) =>
                              updateNode(selectedNode.id, { userId: value })
                            }
                            disabled={readOnly}
                          >
                            <SelectTrigger id="node-user" className="w-full">
                              <SelectValue placeholder="选择用户" />
                            </SelectTrigger>
                            <SelectContent>
                              {profiles.map((profile) => (
                                <SelectItem key={profile.id} value={profile.id}>
                                  {profile.full_name ?? profile.id.slice(0, 8)}
                                </SelectItem>
                              ))}
                            </SelectContent>
                          </Select>
                        </Field>
                      ) : null}

                      {selectedNode.ruleType === "dept_leader" ? (
                        <p className="rounded-md bg-muted px-3 py-2 text-xs text-muted-foreground">
                          按发起人所属部门的负责人解析（departments.leader_id），
                          无需额外配置
                        </p>
                      ) : null}

                      <Field>
                        <FieldLabel htmlFor="node-timeout">
                          超时时长（小时，可选）
                        </FieldLabel>
                        <Input
                          id="node-timeout"
                          type="number"
                          min={0}
                          value={selectedNode.timeoutHours}
                          onChange={(event) =>
                            updateNode(selectedNode.id, {
                              timeoutHours: event.target.value,
                            })
                          }
                          placeholder="如：24"
                          disabled={readOnly}
                        />
                        <FieldDescription>
                          超时提醒投递为 P2（本期仅存配置）
                        </FieldDescription>
                      </Field>
                    </div>
                  ) : (
                    <p className="py-8 text-center text-sm text-muted-foreground">
                      点击左侧节点编辑属性
                    </p>
                  )}
                </div>
              </div>
            </TabsContent>

            {/* 模拟运行 */}
            <TabsContent
              value="simulate"
              className="flex min-h-0 flex-col gap-4 overflow-y-auto pt-4 pb-2"
            >
              <p className="text-sm text-muted-foreground">
                模拟使用与真实提交相同的审批人解析逻辑（resolve_approver）；
                {sheetMode === "view"
                  ? "以已保存版本为准。"
                  : "运行前会先保存当前草稿。"}
              </p>

              <div className="grid gap-3 sm:grid-cols-2">
                <Field>
                  <FieldLabel htmlFor="sim-initiator">发起人</FieldLabel>
                  <Select
                    value={simInitiator}
                    onValueChange={setSimInitiator}
                  >
                    <SelectTrigger id="sim-initiator" className="w-full">
                      <SelectValue placeholder="选择发起人" />
                    </SelectTrigger>
                    <SelectContent>
                      {profiles.map((profile) => (
                        <SelectItem key={profile.id} value={profile.id}>
                          {profile.full_name ?? profile.id.slice(0, 8)}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </Field>
                <Field>
                  <FieldLabel htmlFor="sim-flow">模拟流程</FieldLabel>
                  <Input
                    id="sim-flow"
                    value={
                      boundTemplate
                        ? `${boundTemplate.name} v${boundTemplate.version}`
                        : "（未绑定模板）"
                    }
                    disabled
                  />
                </Field>
              </div>

              <Field>
                <FieldLabel htmlFor="sim-form-data">样例 form_data（JSON）</FieldLabel>
                <Textarea
                  id="sim-form-data"
                  rows={7}
                  value={simFormData}
                  onChange={(event) => setSimFormData(event.target.value)}
                  className="font-mono"
                  spellCheck={false}
                />
                <FieldDescription>
                  按绑定模板 schema 生成；条件分支（P2）启用后参与路由判定
                </FieldDescription>
              </Field>

              <Button
                className="h-11 self-start lg:h-9"
                onClick={() => void runSimulation()}
                disabled={simulating}
              >
                {simulating ? (
                  <Loader2Icon
                    className="animate-spin"
                    data-icon="inline-start"
                  />
                ) : (
                  <PlayIcon data-icon="inline-start" />
                )}
                运行模拟
              </Button>

              {simError ? (
                <p className="rounded-lg border border-destructive/40 bg-destructive/5 px-3 py-2 text-sm text-destructive">
                  {simError}
                </p>
              ) : null}

              {simResult ? (
                simResult.length === 0 ? (
                  <p className="text-sm text-muted-foreground">
                    流程无节点，未产生模拟结果
                  </p>
                ) : (
                  <ol className="flex flex-col gap-2">
                    {simResult.map((step, index) => (
                      <li
                        key={`${step.seq ?? index}`}
                        className={cn(
                          "flex flex-wrap items-center gap-x-3 gap-y-1 rounded-lg border p-3 text-sm",
                          step.error
                            ? "border-destructive/40 bg-destructive/5"
                            : undefined,
                        )}
                      >
                        <span className="flex size-6 items-center justify-center rounded-full bg-muted text-xs font-medium">
                          {step.seq ?? index + 1}
                        </span>
                        {step.error ? (
                          <>
                            <Badge
                              variant="outline"
                              className="border-red-200 bg-red-50 text-red-700 dark:border-red-900/60 dark:bg-red-950/60 dark:text-red-300"
                            >
                              <AlertTriangleIcon data-icon="inline-start" />
                              解析失败
                            </Badge>
                            <span className="text-destructive">
                              {step.error}
                            </span>
                          </>
                        ) : (
                          <>
                            <span className="font-medium">
                              {step.approver_name ?? "未命名用户"}
                            </span>
                            <span className="font-mono text-xs text-muted-foreground">
                              {step.approver_id?.slice(0, 8)}
                            </span>
                          </>
                        )}
                      </li>
                    ))}
                  </ol>
                )
              ) : null}
            </TabsContent>
          </Tabs>

          {sheetMode !== "view" ? (
            <SheetFooter className="flex-row items-center justify-end gap-2 border-t">
              <span className="mr-auto text-xs text-muted-foreground">
                {editingId
                  ? `正在编辑草稿 v${editingVersion ?? "?"}`
                  : "保存后将创建 v1 草稿"}
              </span>
              <Button
                variant="outline"
                className="h-11 lg:h-8"
                onClick={() => void handleSaveDraft()}
                disabled={saving || publishing}
              >
                {saving ? (
                  <Loader2Icon
                    className="animate-spin"
                    data-icon="inline-start"
                  />
                ) : null}
                保存草稿
              </Button>
              <Button
                className="h-11 lg:h-8"
                onClick={() => void handlePublish()}
                disabled={saving || publishing}
              >
                {publishing ? (
                  <Loader2Icon
                    className="animate-spin"
                    data-icon="inline-start"
                  />
                ) : null}
                发布
              </Button>
            </SheetFooter>
          ) : null}
        </SheetContent>
      </Sheet>
    </div>
  );
}
