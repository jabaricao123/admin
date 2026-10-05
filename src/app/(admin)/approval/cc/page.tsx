import type { Metadata } from "next";

import { ApprovalCcTable } from "@/components/approval/approval-cc-table";

// @next-codemod-ignore Cache Components：管理端路由均为服务端动态鉴权，允许阻塞式导航。
export const instant = false;

export const metadata: Metadata = {
  title: "抄送我的",
};

export default function ApprovalCcPage() {
  return <ApprovalCcTable />;
}
