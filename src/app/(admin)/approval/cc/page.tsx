import type { Metadata } from "next";

import { ApprovalCcTable } from "@/components/approval/approval-cc-table";

export const metadata: Metadata = {
  title: "抄送我的",
};

export default function ApprovalCcPage() {
  return <ApprovalCcTable />;
}
