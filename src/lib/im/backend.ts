// IM 后端专用最小角色客户端（im/002 修复）：JWT role=im_backend。
//
// 权限边界（见迁移 20261006153000 §4/§5）：im_backend 为 nologin、非 BYPASSRLS、
// 无表权限的角色，仅 EXECUTE public.im_start_auth / public.im_handle_callback；
// 厂商凭据解密与出站（extensions.http）均在 SECURITY DEFINER 内完成，secret 不出 Postgres。
//
// 凭证来源：部署方用项目 JWT secret 离线签发（README「IM 后端最小角色」），
// 只把签发结果 IM_BACKEND_JWT 配置到服务端环境；运行时绝不读取 JWT secret。
// 未配置时返回 null，调用方按 im_unavailable 失败（fail closed）。

import { createClient, type SupabaseClient } from "@supabase/supabase-js";

export function createImBackendClient(): SupabaseClient | null {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  const backendJwt = process.env.IM_BACKEND_JWT;
  if (!url || !anonKey || !backendJwt) {
    return null;
  }

  // apikey 用 anon（网关放行），Authorization 用 im_backend JWT（PostgREST SET ROLE）；
  // 不用 service_role（ADR-001 全局禁令）。
  return createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${backendJwt}` } },
  });
}
