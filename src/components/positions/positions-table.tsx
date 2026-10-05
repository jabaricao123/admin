"use client";

import * as React from "react";
import {
  BriefcaseIcon,
  Loader2Icon,
  SaveIcon,
  SearchIcon,
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
import { Textarea } from "@/components/ui/textarea";
import { useIsMobile } from "@/hooks/use-mobile";
import type { Database } from "@/lib/database.types";
import {
  POSITION_STATUS_BADGE_CLASSES,
  POSITION_STATUS_LABELS,
  POSITION_STATUS_OPTIONS,
  translatePositionErrorMessage,
  type PositionStatus,
} from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/client";

const PAGE_SIZE = 20;
const ALL = "all";
const NO_DEPARTMENT = "none";

type PositionRow = Database["public"]["Views"]["positions_v"]["Row"];
type DepartmentRow = Database["public"]["Views"]["departments_v"]["Row"];

type Position = {
  id: string;
  name: string;
  code: string;
  departmentId: string | null;
  departmentName: string | null;
  headcount: number;
  description: string;
  status: PositionStatus;
  staffCount: number;
};

type DepartmentOption = {
  id: string;
  name: string;
  path: string;
};

type PositionForm = {
  name: string;
  code: string;
  departmentId: string;
  headcount: string;
  description: string;
  status: PositionStatus;
};

const EMPTY_FORM: PositionForm = {
  name: "",
  code: "",
  departmentId: NO_DEPARTMENT,
  headcount: "0",
  description: "",
  status: "active",
};

const toPosition = (row: PositionRow): Position => ({
  id: row.id ?? "",
  name: row.name ?? "",
  code: row.code ?? "",
  departmentId: row.department_id,
  departmentName: row.department_name,
  headcount: row.headcount ?? 0,
  description: row.description ?? "",
  status: row.status === "disabled" ? "disabled" : "active",
  staffCount: row.staff_count ?? 0,
});

const toDepartment = (row: DepartmentRow): DepartmentOption => ({
  id: row.id ?? "",
  name: row.name ?? "",
  path: row.path ?? row.name ?? "",
});

export function PositionsTable() {
  const isMobile = useIsMobile();
  const [rows, setRows] = React.useState<Position[]>([]);
  const [departments, setDepartments] = React.useState<DepartmentOption[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [error, setError] = React.useState<string | null>(null);
  const [search, setSearch] = React.useState("");
  const [departmentFilter, setDepartmentFilter] = React.useState(ALL);
  const [page, setPage] = React.useState(1);
  const [sheetOpen, setSheetOpen] = React.useState(false);
  const [editing, setEditing] = React.useState<Position | null>(null);
  const [form, setForm] = React.useState<PositionForm>(EMPTY_FORM);
  const [saving, setSaving] = React.useState(false);

  const load = React.useCallback(async () => {
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const [positionRes, departmentRes] = await Promise.all([
      supabase
        .from("positions_v")
        .select("*")
        .order("created_at", { ascending: false }),
      supabase.from("departments_v").select("*").order("path"),
    ]);

    if (positionRes.error) {
      setError(positionRes.error.message);
      setRows([]);
    } else {
      setRows((positionRes.data ?? []).map(toPosition));
    }

    if (!departmentRes.error) {
      setDepartments((departmentRes.data ?? []).map(toDepartment));
    }

    setLoading(false);
  }, []);

  React.useEffect(() => {
    void load();
  }, [load]);

  const filtered = React.useMemo(() => {
    const keyword = search.trim().toLowerCase();
    return rows.filter((row) => {
      if (departmentFilter !== ALL && row.departmentId !== departmentFilter) {
        return false;
      }
      if (keyword) {
        const haystack = `${row.name} ${row.code}`.toLowerCase();
        if (!haystack.includes(keyword)) {
          return false;
        }
      }
      return true;
    });
  }, [rows, search, departmentFilter]);

  React.useEffect(() => {
    setPage(1);
  }, [search, departmentFilter]);

  const pageCount = Math.max(1, Math.ceil(filtered.length / PAGE_SIZE));
  const currentPage = Math.min(page, pageCount);
  const hasActiveFilters = search.trim() !== "" || departmentFilter !== ALL;
  const pagedRows = filtered.slice(
    (currentPage - 1) * PAGE_SIZE,
    currentPage * PAGE_SIZE,
  );

  /** 编辑中岗位若挂在已删除部门（departments_v 已过滤），补一个临时选项避免下拉空白 */
  const departmentOptions = React.useMemo(() => {
    if (
      editing?.departmentId &&
      !departments.some((item) => item.id === editing.departmentId)
    ) {
      const label = editing.departmentName ?? "已删除部门";
      return [
        ...departments,
        { id: editing.departmentId, name: label, path: `${label}（已删除）` },
      ];
    }
    return departments;
  }, [departments, editing]);

  const openCreate = () => {
    setEditing(null);
    setForm(EMPTY_FORM);
    setSheetOpen(true);
  };

  const openEdit = (row: Position) => {
    setEditing(row);
    setForm({
      name: row.name,
      code: row.code,
      departmentId: row.departmentId ?? NO_DEPARTMENT,
      headcount: String(row.headcount),
      description: row.description,
      status: row.status,
    });
    setSheetOpen(true);
  };

  const closeSheet = () => {
    setSheetOpen(false);
    setEditing(null);
    setForm(EMPTY_FORM);
  };

  const handleSave = async () => {
    const name = form.name.trim();
    const code = form.code.trim();

    if (!name) {
      toast.error("岗位名称不能为空");
      return;
    }
    if (!code) {
      toast.error("岗位编码不能为空");
      return;
    }

    const headcount = Number(form.headcount);
    if (!Number.isInteger(headcount) || headcount < 0) {
      toast.error("编制数必须为不小于 0 的整数");
      return;
    }

    setSaving(true);
    const supabase = createClient();
    const { error: saveError } = await supabase.rpc("upsert_position", {
      p_id: editing?.id,
      p_name: name,
      p_code: code,
      p_department_id:
        form.departmentId === NO_DEPARTMENT ? undefined : form.departmentId,
      p_headcount: headcount,
      p_description: form.description.trim() || undefined,
      p_status: form.status,
    });
    setSaving(false);

    if (saveError) {
      toast.error(translatePositionErrorMessage(saveError.message));
      return;
    }

    toast.success(editing ? "已保存" : "已新增");
    closeSheet();
    void load();
  };

  const handleDelete = async () => {
    if (!editing) {
      return;
    }

    const confirmed = window.confirm(
      `确定删除岗位「${editing.name}」？删除后不可恢复。`,
    );
    if (!confirmed) {
      return;
    }

    setSaving(true);
    const supabase = createClient();
    const { error: deleteError } = await supabase.rpc("delete_position", {
      p_id: editing.id,
    });
    setSaving(false);

    if (deleteError) {
      toast.error(translatePositionErrorMessage(deleteError.message));
      return;
    }

    toast.success("已删除");
    closeSheet();
    void load();
  };

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
                placeholder="搜索名称 / 编码"
                className="h-11 pl-8 text-base lg:h-8 lg:text-sm"
                aria-label="搜索岗位名称或编码"
              />
            </div>
            <Select value={departmentFilter} onValueChange={setDepartmentFilter}>
              <SelectTrigger
                className="h-11 w-full sm:w-44 lg:h-8"
                aria-label="按部门筛选"
              >
                <SelectValue placeholder="全部部门" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={ALL}>全部部门</SelectItem>
                {departments.map((option) => (
                  <SelectItem key={option.id} value={option.id}>
                    {option.path}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <div className="flex items-center gap-2 sm:ml-auto">
              <Button
                onClick={openCreate}
                className="h-11 flex-1 lg:h-8 lg:flex-none"
              >
                <BriefcaseIcon data-icon="inline-start" />
                新增岗位
              </Button>
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
                加载失败：{translatePositionErrorMessage(error)}
              </p>
              <Button variant="outline" onClick={() => void load()}>
                重试
              </Button>
            </div>
          ) : pagedRows.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-12 text-sm text-muted-foreground">
              <BriefcaseIcon className="size-8 opacity-60" />
              {hasActiveFilters ? (
                <>
                  <span>未找到匹配的岗位</span>
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => {
                      setSearch("");
                      setDepartmentFilter(ALL);
                    }}
                  >
                    清除筛选
                  </Button>
                </>
              ) : (
                <span>暂无岗位，点击「新增岗位」创建</span>
              )}
            </div>
          ) : isMobile ? (
            <div className="-mx-4 flex flex-col gap-2 px-4 md:mx-0 md:gap-3 md:px-0">
              {pagedRows.map((row) => {
                const overCapacity = row.staffCount > row.headcount;
                return (
                  <button
                    key={row.id}
                    type="button"
                    data-slot="position-card"
                    onClick={() => openEdit(row)}
                    className="flex w-full flex-col gap-2 rounded-xl border bg-card p-3 text-left shadow-xs transition-colors hover:border-primary/50 focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:outline-none"
                  >
                    <div className="flex items-start justify-between gap-3">
                      <div className="min-w-0">
                        <div className="truncate font-medium">{row.name}</div>
                        <div className="truncate font-mono text-xs leading-tight text-muted-foreground">
                          {row.code}
                        </div>
                      </div>
                      <Badge
                        variant="outline"
                        className={POSITION_STATUS_BADGE_CLASSES[row.status]}
                      >
                        {POSITION_STATUS_LABELS[row.status]}
                      </Badge>
                    </div>
                    <div className="flex flex-col gap-1.5 text-sm">
                      <div className="flex items-center justify-between gap-4">
                        <span className="text-muted-foreground">所属部门</span>
                        <span>{row.departmentName ?? "—"}</span>
                      </div>
                      <div className="flex items-center justify-between gap-4">
                        <span className="text-muted-foreground">
                          在岗 / 编制
                        </span>
                        <Badge variant={overCapacity ? "destructive" : "outline"}>
                          {row.staffCount}/{row.headcount}
                        </Badge>
                      </div>
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
                    <TableHead className="text-center">编码</TableHead>
                    <TableHead className="text-center">所属部门</TableHead>
                    <TableHead className="text-center">在岗 / 编制</TableHead>
                    <TableHead className="text-center">状态</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {pagedRows.map((row) => {
                    const overCapacity = row.staffCount > row.headcount;
                    return (
                      <TableRow
                        key={row.id}
                        className="cursor-pointer"
                        role="button"
                        tabIndex={0}
                        aria-label={`编辑岗位 ${row.name}`}
                        onClick={() => openEdit(row)}
                        onKeyDown={(event) => {
                          if (event.key === "Enter" || event.key === " ") {
                            event.preventDefault();
                            openEdit(row);
                          }
                        }}
                      >
                        <TableCell className="text-center font-medium">
                          {row.name}
                        </TableCell>
                        <TableCell className="text-center font-mono text-xs text-muted-foreground">
                          {row.code}
                        </TableCell>
                        <TableCell className="text-center">
                          {row.departmentName ?? "—"}
                        </TableCell>
                        <TableCell className="text-center">
                          <Badge
                            variant={overCapacity ? "destructive" : "outline"}
                            className={
                              overCapacity ? undefined : "text-muted-foreground"
                            }
                          >
                            {row.staffCount}/{row.headcount}
                          </Badge>
                        </TableCell>
                        <TableCell className="text-center">
                          <Badge
                            variant="outline"
                            className={POSITION_STATUS_BADGE_CLASSES[row.status]}
                          >
                            {POSITION_STATUS_LABELS[row.status]}
                          </Badge>
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
                {hasActiveFilters
                  ? `匹配 ${filtered.length} 条（共 ${rows.length} 条）· 第 ${currentPage} / ${pageCount} 页`
                  : `共 ${filtered.length} 条 · 第 ${currentPage} / ${pageCount} 页`}
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
        open={sheetOpen}
        onOpenChange={(open) => {
          if (!open) {
            closeSheet();
          }
        }}
      >
        <SheetContent
          side="right"
          className="w-full sm:max-w-[480px]"
        >
          <SheetHeader>
            <SheetTitle>{editing ? "编辑岗位" : "新增岗位"}</SheetTitle>
            <SheetDescription className="flex flex-col gap-1">
              {editing ? (
                <>
                  <span className="font-medium text-foreground">
                    {editing.name}
                  </span>
                  <span className="font-mono text-xs">{editing.code}</span>
                  <span className="text-xs">
                    在岗 {editing.staffCount} 人 · 编制 {editing.headcount} 人
                    {editing.staffCount > editing.headcount ? "（超编）" : ""}
                  </span>
                </>
              ) : (
                <span>录入岗位名称、唯一编码与所属部门</span>
              )}
            </SheetDescription>
          </SheetHeader>
          <div className="flex min-h-0 flex-col gap-4 overflow-y-auto px-4">
            <Field>
              <FieldLabel htmlFor="position-name">名称</FieldLabel>
              <Input
                id="position-name"
                value={form.name}
                onChange={(event) =>
                  setForm((prev) => ({ ...prev, name: event.target.value }))
                }
                placeholder="如：前端开发工程师"
              />
            </Field>
            <Field>
              <FieldLabel htmlFor="position-code">编码</FieldLabel>
              <Input
                id="position-code"
                value={form.code}
                onChange={(event) =>
                  setForm((prev) => ({ ...prev, code: event.target.value }))
                }
                placeholder="如：DEV-FE"
              />
              <FieldDescription>全系统唯一，冲突时保存会被拒绝</FieldDescription>
            </Field>
            <Field>
              <FieldLabel htmlFor="position-department">所属部门</FieldLabel>
              <Select
                value={form.departmentId}
                onValueChange={(value) =>
                  setForm((prev) => ({ ...prev, departmentId: value }))
                }
              >
                <SelectTrigger id="position-department" className="w-full">
                  <SelectValue placeholder="未指定" />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value={NO_DEPARTMENT}>未指定</SelectItem>
                  {departmentOptions.map((option) => (
                    <SelectItem key={option.id} value={option.id}>
                      {option.path}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
            <Field>
              <FieldLabel htmlFor="position-headcount">编制数</FieldLabel>
              <Input
                id="position-headcount"
                type="number"
                min={0}
                step={1}
                value={form.headcount}
                onChange={(event) =>
                  setForm((prev) => ({ ...prev, headcount: event.target.value }))
                }
              />
              <FieldDescription>
                在岗人数超过编制时仅标红警示，不阻断保存
              </FieldDescription>
            </Field>
            <Field>
              <FieldLabel htmlFor="position-description">职责描述</FieldLabel>
              <Textarea
                id="position-description"
                rows={3}
                value={form.description}
                onChange={(event) =>
                  setForm((prev) => ({
                    ...prev,
                    description: event.target.value,
                  }))
                }
                placeholder="岗位职责简述（可选）"
              />
            </Field>
            <Field>
              <FieldLabel htmlFor="position-status">状态</FieldLabel>
              <Select
                value={form.status}
                onValueChange={(value) =>
                  setForm((prev) => ({
                    ...prev,
                    status: value as PositionStatus,
                  }))
                }
              >
                <SelectTrigger id="position-status" className="w-full">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {POSITION_STATUS_OPTIONS.map((option) => (
                    <SelectItem key={option.value} value={option.value}>
                      {option.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <FieldDescription>
                停用后不再出现在新编辑的用户岗位下拉中，存量引用保留展示
              </FieldDescription>
            </Field>
          </div>
          <SheetFooter className="flex-row justify-end gap-2">
            {editing ? (
              <Button
                variant="outline"
                className="mr-auto text-destructive hover:text-destructive"
                onClick={() => void handleDelete()}
                disabled={saving}
              >
                删除
              </Button>
            ) : null}
            <Button
              variant="outline"
              onClick={closeSheet}
              className="h-8"
            >
              取消
            </Button>
            <Button
              onClick={() => void handleSave()}
              disabled={saving}
              className="h-8"
            >
              {saving ? (
                <Loader2Icon
                  className="size-3.5 animate-spin"
                  data-icon="inline-start"
                />
              ) : (
                <SaveIcon className="size-3.5" data-icon="inline-start" />
              )}
              保存
            </Button>
          </SheetFooter>
        </SheetContent>
      </Sheet>
    </div>
  );
}
