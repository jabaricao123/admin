import type { Metadata } from "next";

import { AnnouncementBanner } from "@/components/announcement-banner";
import {
  RecentChangesCard,
  RecentChangesUnavailable,
  type RecentChange,
} from "@/components/recent-changes-card";
import { SectionCards, type DashboardStats } from "@/components/section-cards";
import { UserGrowthChart } from "@/components/user-growth-chart";
import type { Json } from "@/lib/database.types";
import { createClient } from "@/lib/supabase/server";

// @next-codemod-ignore Cache Components：管理端路由均为服务端动态鉴权，允许阻塞式导航。
export const instant = false;

export const metadata: Metadata = {
  title: "工作台",
};

const SIGNUP_TREND_DAYS = 30;
const RECENT_CHANGES_LIMIT = 10;

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function asCount(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

/** get_dashboard_stats jsonb → 前端类型；结构异常返回 null（页面按占位处理） */
function parseDashboardStats(value: Json | null): DashboardStats | null {
  const record = asRecord(value);
  if (!record) {
    return null;
  }
  if (record.is_admin === true) {
    return {
      isAdmin: true,
      totalUsers: asCount(record.total_users),
      newThisWeek: asCount(record.new_this_week),
      activeUsers: asCount(record.active_users),
      pendingTodos: asCount(record.pending_todos),
    };
  }
  const own = asRecord(record.own);
  return { isAdmin: false, pendingTodos: asCount(own?.pending_todos) };
}

export default async function DashboardPage() {
  const supabase = await createClient();

  const [statsResult, trendResult, announcementResult] = await Promise.all([
    supabase.rpc("get_dashboard_stats"),
    supabase.rpc("signup_trend", { p_days: SIGNUP_TREND_DAYS }),
    supabase
      .from("published_announcements_v")
      .select("*")
      .order("pinned", { ascending: false })
      .order("published_at", { ascending: false, nullsFirst: false }),
  ]);

  const errors: string[] = [];
  const stats = parseDashboardStats(statsResult.data);
  const isAdmin = stats?.isAdmin ?? false;

  if (statsResult.error) {
    errors.push(statsResult.error.message);
  } else if (!stats) {
    errors.push("统计数据格式异常");
  }
  if (trendResult.error) {
    errors.push(trendResult.error.message);
  }
  if (announcementResult.error) {
    errors.push(announcementResult.error.message);
  }

  // 最近更新：audit_row_versions 仅 admin 可读（RLS），非 admin 渲染占位
  let changes: RecentChange[] = [];
  if (isAdmin) {
    const { data, error } = await supabase
      .from("audit_row_versions")
      .select("id, table_name, record_id, version, changed_by, changed_at")
      .order("changed_at", { ascending: false })
      .order("id", { ascending: false })
      .limit(RECENT_CHANGES_LIMIT);

    if (error) {
      errors.push(error.message);
    } else {
      const rows = data ?? [];
      const actorIds = Array.from(
        new Set(
          rows
            .map((row) => row.changed_by)
            .filter((value): value is string => value !== null),
        ),
      );

      const actorNames = new Map<string, string>();
      if (actorIds.length > 0) {
        const { data: profiles } = await supabase
          .from("profiles")
          .select("id, full_name, email")
          .in("id", actorIds);
        for (const profile of profiles ?? []) {
          actorNames.set(
            profile.id,
            profile.full_name?.trim() || profile.email || "—",
          );
        }
      }

      changes = rows.map((row) => ({
        id: row.id,
        tableName: row.table_name,
        recordId: row.record_id,
        version: row.version,
        changedByName: row.changed_by
          ? (actorNames.get(row.changed_by) ?? null)
          : null,
        changedAt: row.changed_at,
      }));
    }
  }

  return (
    <div className="flex flex-col gap-2 py-4">
      {errors.length > 0 ? (
        <div className="px-4 lg:px-6">
          <p className="text-sm text-destructive">
            加载工作台数据失败：{errors.join("；")}
          </p>
        </div>
      ) : null}
      <AnnouncementBanner announcements={announcementResult.data ?? []} />
      <SectionCards stats={stats ?? { isAdmin: false, pendingTodos: 0 }} />
      <div className="px-4 lg:px-6">
        <UserGrowthChart data={trendResult.data ?? []} isAdmin={isAdmin} />
      </div>
      <div className="px-4 lg:px-6">
        {isAdmin ? (
          <RecentChangesCard changes={changes} />
        ) : (
          <RecentChangesUnavailable />
        )}
      </div>
    </div>
  );
}
