import Link from "next/link";
import { FileClockIcon, ShieldXIcon } from "lucide-react";

import { InfoHint } from "@/components/info-hint";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardAction,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { formatDateTime, rowVersionTableLabel } from "@/lib/audit";

export type RecentChange = {
  tableName: string;
  recordId: string;
  version: number;
  changeType: string;
  changedByName: string | null;
  changedAt: string;
};

/** 最近更新（admin）：audit 公开 RPC list_recent_changes 最近 10 条数据变更 */
export function RecentChangesCard({ changes }: { changes: RecentChange[] }) {
  return (
    <Card className="@container/card gap-3! py-3!">
      <CardHeader>
        <CardTitle className="flex items-center gap-1.5">
          最近更新
          <InfoHint>最近 10 条关键表数据变更</InfoHint>
        </CardTitle>
        <CardAction>
          <Button variant="outline" size="sm" asChild className="h-11 lg:h-8">
            <Link href="/audit/changes">查看全部</Link>
          </Button>
        </CardAction>
      </CardHeader>
      <CardContent>
        {changes.length === 0 ? (
          <div className="flex flex-col items-center gap-2 py-10 text-sm text-muted-foreground">
            <FileClockIcon className="size-8 opacity-60" />
            <span>暂无变更记录</span>
          </div>
        ) : (
          <>
            <div className="hidden overflow-x-auto md:block">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="text-center">对象</TableHead>
                    <TableHead className="text-center">版本</TableHead>
                    <TableHead className="text-center">操作人</TableHead>
                    <TableHead className="text-center">时间</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {changes.map((change) => (
                    <TableRow key={`${change.tableName}:${change.recordId}:${change.version}`}>
                      <TableCell className="text-center">
                        <div className="font-medium">
                          {rowVersionTableLabel(change.tableName)}
                        </div>
                        <div className="max-w-56 truncate font-mono text-xs text-muted-foreground">
                          {change.recordId}
                        </div>
                      </TableCell>
                      <TableCell className="text-center">
                        <Badge variant="outline" className="font-mono">
                          v{change.version}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-center">
                        {change.changedByName ?? "系统/后台"}
                      </TableCell>
                      <TableCell className="text-center text-xs whitespace-nowrap text-muted-foreground">
                        {formatDateTime(change.changedAt)}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
            <div className="flex flex-col divide-y md:hidden">
              {changes.map((change) => (
                <div
                  key={`${change.tableName}:${change.recordId}:${change.version}`}
                  className="flex items-center justify-between gap-3 py-3"
                >
                  <div className="flex min-w-0 flex-col gap-1">
                    <span className="truncate text-sm font-medium">
                      {rowVersionTableLabel(change.tableName)}
                    </span>
                    <span className="truncate font-mono text-xs text-muted-foreground">
                      {change.recordId}
                    </span>
                    <span className="truncate text-xs text-muted-foreground">
                      {change.changedByName ?? "系统/后台"} ·{" "}
                      {formatDateTime(change.changedAt)}
                    </span>
                  </div>
                  <Badge variant="outline" className="shrink-0 font-mono">
                    v{change.version}
                  </Badge>
                </div>
              ))}
            </div>
          </>
        )}
      </CardContent>
    </Card>
  );
}

/** 最近更新（非 admin）：audit RPC 内部校验管理员身份，非 admin 显式占位 */
export function RecentChangesUnavailable() {
  return (
    <Card className="@container/card gap-3! py-3!">
      <CardHeader>
        <CardTitle className="flex items-center gap-1.5">
          最近更新
          <InfoHint>最近 10 条关键表数据变更</InfoHint>
        </CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col items-center gap-3 py-16 text-center">
        <ShieldXIcon className="size-10 text-muted-foreground" />
        <div className="text-lg font-medium">需要管理员权限</div>
        <p className="max-w-md text-sm text-muted-foreground">
          数据变更摘要来自审计留痕（audit_row_versions），访问经审计公开 RPC
          （内部校验管理员身份），非管理员不可读。
        </p>
      </CardContent>
    </Card>
  );
}
