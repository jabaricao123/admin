"use server";

import { createClient as createServiceClient } from "@supabase/supabase-js";

import { createClient } from "@/lib/supabase/server";

/**
 * 用户停用/启用（org）：Auth Admin API ban / unban。
 *
 * 为什么需要本 action：`profiles.status` 只是档案状态，不落 Auth 层时
 * 停用用户仍可登录。ban 由 service role 在服务端调用 Auth Admin API：
 * - ban：`ban_duration: '876000h'`（约 100 年，等同永久封禁）→ 登录返回
 *   "User is banned"；配合 proxy 守卫清会话；
 * - unban：`ban_duration: 'none'` → 恢复登录。
 *
 * 安全：service role key 仅在服务端读取（无 NEXT_PUBLIC 前缀）；每个调用
 * 都以当前会话二次校验调用者为 active admin（前端守卫不可信）。
 */

export type UserBanResult = { ok: true } | { ok: false; message: string };

/** Supabase 文档推荐的“永久封禁”时长（约 100 年） */
const BAN_DURATION = "876000h";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type AdminCheck =
  | { ok: true; userId: string }
  | { ok: false; message: string };

/** 服务端校验：当前会话存在、档案 active 且角色为 admin */
async function requireAdmin(): Promise<AdminCheck> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return { ok: false, message: "登录状态已失效，请刷新页面后重试" };
  }

  const { data: profile } = await supabase
    .from("profiles")
    .select("role, status")
    .eq("id", user.id)
    .maybeSingle();

  if (!profile || profile.role !== "admin" || profile.status !== "active") {
    return { ok: false, message: "仅管理员可执行此操作" };
  }

  return { ok: true, userId: user.id };
}

/** service role 客户端：未配置时返回 null（由调用方给出可读错误） */
function createAdminClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !serviceRoleKey) {
    return null;
  }

  return createServiceClient(url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

function translateAdminApiError(error: unknown): string {
  const message =
    error instanceof Error
      ? error.message
      : typeof error === "object" && error !== null && "message" in error
        ? String((error as { message: unknown }).message)
        : "未知错误";

  if (/not found/i.test(message)) {
    return "用户不存在或已被删除";
  }
  return `操作失败：${message}`;
}

async function setBan(
  userId: string,
  banDuration: string,
): Promise<UserBanResult> {
  if (!UUID_RE.test(userId)) {
    return { ok: false, message: "用户标识不合法" };
  }

  const adminCheck = await requireAdmin();
  if (!adminCheck.ok) {
    return adminCheck;
  }

  // 自保护：与 admin_update_profile 一致，不能停用自己的账号
  if (adminCheck.userId === userId) {
    return { ok: false, message: "不能停用自己的账号" };
  }

  const admin = createAdminClient();
  if (!admin) {
    return {
      ok: false,
      message: "服务端未配置 SUPABASE_SERVICE_ROLE_KEY，无法同步登录封禁",
    };
  }

  try {
    const { error } = await admin.auth.admin.updateUserById(userId, {
      ban_duration: banDuration,
    });
    if (error) {
      return { ok: false, message: translateAdminApiError(error) };
    }
    return { ok: true };
  } catch (error) {
    return { ok: false, message: translateAdminApiError(error) };
  }
}

/** 停用用户：Auth 层封禁（登录被拒） */
export async function banUser(userId: string): Promise<UserBanResult> {
  return setBan(userId, BAN_DURATION);
}

/** 启用用户：解除 Auth 层封禁（恢复登录） */
export async function unbanUser(userId: string): Promise<UserBanResult> {
  return setBan(userId, "none");
}
