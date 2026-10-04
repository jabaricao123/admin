#!/usr/bin/env node
// 签发 IM 后端最小角色 JWT（im/002 修复的一次性工具）。
//
// 用法：
//   SUPABASE_JWT_SECRET=<项目 JWT secret> node scripts/mint-im-backend-jwt.mjs [有效期秒数]
//
// 输出的 JWT role=im_backend（默认有效期约 10 年）→ 配置为部署环境变量 IM_BACKEND_JWT。
// 该 token 仅能经 PostgREST 执行 public.im_start_auth / public.im_handle_callback；
// 厂商凭据解密与出站均在 Postgres 内（secret 不出库）。JWT secret 只用于本脚本，
// 绝不配置到应用运行时。Supabase Dashboard → Project Settings → API → JWT Settings。

import { createHmac } from "node:crypto";

const secret = process.env.SUPABASE_JWT_SECRET;
if (!secret) {
  console.error("缺少 SUPABASE_JWT_SECRET（Supabase Dashboard → Project Settings → API）");
  process.exit(1);
}

const ttl = Number(process.argv[2] ?? 60 * 60 * 24 * 3650);
if (!Number.isSafeInteger(ttl) || ttl <= 0) {
  console.error("有效期需为正整数秒");
  process.exit(1);
}

const b64url = (value) =>
  Buffer.from(JSON.stringify(value)).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const header = b64url({ alg: "HS256", typ: "JWT" });
const payload = b64url({
  role: "im_backend",
  iss: "supabase",
  iat: now,
  exp: now + ttl,
});
const signature = createHmac("sha256", secret)
  .update(`${header}.${payload}`)
  .digest("base64url");

console.log(`${header}.${payload}.${signature}`);
