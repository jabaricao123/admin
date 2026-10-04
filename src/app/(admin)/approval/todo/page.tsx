import { Suspense } from "react";
import type { Metadata } from "next";

import { ApprovalTodoTable } from "@/components/approval/approval-todo-table";

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
