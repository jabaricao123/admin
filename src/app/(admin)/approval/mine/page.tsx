import type { Metadata } from "next";

import { ApprovalMineTable } from "@/components/approval/approval-mine-table";

export const metadata: Metadata = {
  title: "我发起的",
};

export default function ApprovalMinePage() {
  return <ApprovalMineTable />;
}
