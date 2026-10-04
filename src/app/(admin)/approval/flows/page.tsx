import type { Metadata } from "next";

import { ApprovalFlowsTable } from "@/components/approval/approval-flows-table";

export const metadata: Metadata = {
  title: "审批流程",
};

export default function ApprovalFlowsPage() {
  return <ApprovalFlowsTable />;
}
