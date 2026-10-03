import type { Metadata } from "next";

import { OrgChartView } from "@/components/org-chart/org-chart-view";

export const metadata: Metadata = {
  title: "组织架构",
};

export default function OrgChartPage() {
  return <OrgChartView />;
}
