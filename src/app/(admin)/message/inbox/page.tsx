import type { Metadata } from "next";

import { InboxTable } from "@/components/messages/inbox-table";

export const metadata: Metadata = {
  title: "站内信",
};

export default function MessageInboxPage() {
  return <InboxTable />;
}
