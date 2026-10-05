import type { Metadata } from "next";

import { ApprovalMineTable } from "@/components/approval/approval-mine-table";

// @next-codemod-ignore Cache Components：管理端路由均为服务端动态鉴权，允许阻塞式导航。
export const instant = false;

export const metadata: Metadata = {
  title: "我发起的",
};

export default function ApprovalMinePage() {
  return <ApprovalMineTable />;
}
