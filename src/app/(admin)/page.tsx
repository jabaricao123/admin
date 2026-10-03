import { RecentUsersTable } from "@/components/recent-users-table";
import { SectionCards } from "@/components/section-cards";
import { UserGrowthChart } from "@/components/user-growth-chart";
import type { Profile } from "@/lib/dictionaries";
import { createClient } from "@/lib/supabase/server";
import { buildWeeklySignupTrend } from "@/lib/trends";

export default async function DashboardPage() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("profiles")
    .select("*")
    .order("updated_at", { ascending: false });

  const rows: Profile[] = data ?? [];

  const stats = {
    total: rows.length,
    active: rows.filter((row) => row.status === "active").length,
    inactive: rows.filter((row) => row.status === "inactive").length,
    admins: rows.filter((row) => row.role === "admin").length,
  };

  return (
    <div className="flex flex-col gap-4 py-4 md:gap-6 md:py-6">
      {error ? (
        <div className="px-4 lg:px-6">
          <p className="text-sm text-destructive">
            加载用户数据失败：{error.message}
          </p>
        </div>
      ) : null}
      <SectionCards stats={stats} />
      <div className="px-4 lg:px-6">
        <UserGrowthChart data={buildWeeklySignupTrend(rows)} lowData={rows.length < 10} />
      </div>
      <div className="px-4 lg:px-6">
        <RecentUsersTable users={rows.slice(0, 5)} />
      </div>
    </div>
  );
}
