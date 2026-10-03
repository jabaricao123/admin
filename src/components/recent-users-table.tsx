import Link from "next/link";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardAction,
  CardContent,
  CardDescription,
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
import {
  PROFILE_STATUS_BADGE_CLASSES,
  PROFILE_STATUS_LABELS,
  ROLE_BADGE_CLASSES,
  ROLE_LABELS,
  type Profile,
} from "@/lib/dictionaries";

const formatDateTime = (value: string) =>
  new Date(value).toLocaleString("zh-CN", { hour12: false });

export function RecentUsersTable({ users }: { users: Profile[] }) {
  return (
    <Card className="@container/card">
      <CardHeader>
        <CardTitle>最近更新</CardTitle>
        <CardDescription>最新维护的账号档案</CardDescription>
        <CardAction>
          <Button variant="outline" size="sm" asChild>
            <Link href="/settings/users">查看全部</Link>
          </Button>
        </CardAction>
      </CardHeader>
      <CardContent>
        {users.length === 0 ? (
          <p className="py-8 text-center text-sm text-muted-foreground">
            暂无用户
          </p>
        ) : (
          <>
            <div className="hidden overflow-x-auto md:block">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="text-center">姓名</TableHead>
                    <TableHead className="text-center">角色</TableHead>
                    <TableHead className="text-center">状态</TableHead>
                    <TableHead className="text-center">更新时间</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {users.map((user) => (
                    <TableRow key={user.id}>
                      <TableCell className="text-center">
                        <div className="font-medium">
                          {user.full_name ?? user.email ?? "-"}
                        </div>
                        <div className="text-xs text-muted-foreground">
                          {user.email}
                        </div>
                      </TableCell>
                      <TableCell className="text-center">
                        <Badge
                          variant="outline"
                          className={ROLE_BADGE_CLASSES[user.role]}
                        >
                          {ROLE_LABELS[user.role]}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-center">
                        <Badge
                          variant="outline"
                          className={PROFILE_STATUS_BADGE_CLASSES[user.status]}
                        >
                          {PROFILE_STATUS_LABELS[user.status]}
                        </Badge>
                      </TableCell>
                      <TableCell className="text-center text-muted-foreground">
                        {formatDateTime(user.updated_at)}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
            <div className="flex flex-col md:hidden">
              {users.map((user) => (
                <Link
                  key={user.id}
                  href="/settings/users"
                  className="flex items-center justify-between gap-3 border-b py-3 transition-colors last:border-b-0 hover:bg-muted/40"
                >
                  <div className="min-w-0">
                    <div className="truncate text-sm font-medium">
                      {user.full_name ?? user.email ?? "-"}
                    </div>
                    <div className="truncate text-xs text-muted-foreground">
                      {user.email}
                    </div>
                  </div>
                  <div className="flex shrink-0 items-center gap-2">
                    <Badge
                      variant="outline"
                      className={ROLE_BADGE_CLASSES[user.role]}
                    >
                      {ROLE_LABELS[user.role]}
                    </Badge>
                    <Badge
                      variant="outline"
                      className={PROFILE_STATUS_BADGE_CLASSES[user.status]}
                    >
                      {PROFILE_STATUS_LABELS[user.status]}
                    </Badge>
                  </div>
                </Link>
              ))}
            </div>
          </>
        )}
      </CardContent>
    </Card>
  );
}
