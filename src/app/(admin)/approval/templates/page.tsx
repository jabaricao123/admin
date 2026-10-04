import type { Metadata } from "next";

import { ApprovalTemplatesTable } from "@/components/approval/approval-templates-table";

export const metadata: Metadata = {
  title: "审批模板",
};

export default function ApprovalTemplatesPage() {
  return <ApprovalTemplatesTable />;
}
