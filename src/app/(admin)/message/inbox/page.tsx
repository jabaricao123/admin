import type { Metadata } from "next";

import { InboxTable } from "@/components/messages/inbox-table";

// @next-codemod-ignore Cache Components：管理端路由均为服务端动态鉴权，允许阻塞式导航。
export const instant = false;

export const metadata: Metadata = {
  title: "站内信",
};

export default function MessageInboxPage() {
  return <InboxTable />;
}
