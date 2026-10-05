import { Suspense } from "react";
import type { Metadata } from "next";

import { ApprovalTodoTable } from "@/components/approval/approval-todo-table";

// @next-codemod-ignore Cache Components：管理端路由均为服务端动态鉴权，允许阻塞式导航。
export const instant = false;

export const metadata: Metadata = {
  title: "我的待办",
};

export default function ApprovalTodoPage() {
  return (
    <Suspense fallback={null}>
      <ApprovalTodoTable />
    </Suspense>
  );
}
