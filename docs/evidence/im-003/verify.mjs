// im/003 验证脚本：飞书移动端免登（Playwright + Chromium）
//
// 前置：
//   1. 本地 Supabase 已启动（supabase start）；`npm run dev` 监听 3000；
//      `.env.local` 中 NEXT_PUBLIC_IM_CALLBACK_BASE=http://localhost:3000
//   2. 本地栈临时写入一组「假」飞书凭据，让 /auth/im/feishu/start 能构造授权 URL：
//        select public.im_upsert_config('feishu',
//          '{"app_id":"cli_mock_im003","app_secret":"local-mock-secret"}'::jsonb, true);
//   3. 本地测试账号 engineer@example.com / engineer123（见 README「快速开始」）
//
// 运行：NODE_PATH=$(npm root -g) node docs/evidence/im-003/verify.mjs
// 产物写回本目录（*.png / *.har）；01 用本地 HTTPS mock 仅替代授权页渲染，
// host-resolver-rules 只作用于本次 Chromium 进程。
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import https from "node:https";
import os from "node:os";
import path from "node:path";
const require = createRequire(import.meta.url);
const { chromium } = require("playwright");

const BASE = process.env.IM003_BASE ?? "http://localhost:3000";
const FEISHU_UA =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Lark/7.14.1";
const OUT = path.dirname(new URL(import.meta.url).pathname);

const MOCK_AUTHORIZE_HTML = `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>飞书 · 静默授权</title>
<style>
body{font-family:system-ui,-apple-system,sans-serif;margin:0;height:100vh;display:flex;align-items:center;justify-content:center;background:#f6f7f9;color:#1f2329}
.card{width:300px;background:#fff;border-radius:12px;box-shadow:0 8px 24px rgba(31,35,41,.08);padding:32px 24px;text-align:center}
.logo{width:56px;height:56px;border-radius:14px;background:#3370ff;color:#fff;font-weight:700;font-size:20px;display:flex;align-items:center;justify-content:center;margin:0 auto 16px}
.t{font-size:15px;margin:0 0 8px;font-weight:600}
.s{font-size:12px;color:#8f959e;margin:0;line-height:1.6}
.dot{display:inline-block;width:6px;height:6px;border-radius:50%;background:#3370ff;margin-right:6px;animation:p 1s infinite alternate}
@keyframes p{from{opacity:.2}to{opacity:1}}
</style></head><body><div class="card">
<div class="logo">飞书</div>
<p class="t"><span class="dot"></span>已检测到飞书登录态</p>
<p class="s">正在静默授权并跳回企业管理系统…<br>（本地 mock 替身页：仅替代 accounts.feishu.cn 的页面渲染；真实环境为飞书官方静默授权，全程无需点击）</p>
</div></body></html>`;

// 自签证书 + 本地 HTTPS mock（仅 01 的页面渲染；host-resolver-rules 映射只在测试浏览器内生效）
const mockDir = fs.mkdtempSync(path.join(os.tmpdir(), "im-003-mock-"));
execFileSync(
  "openssl",
  [
    "req", "-x509", "-newkey", "rsa:2048", "-nodes",
    "-keyout", path.join(mockDir, "mock.key"),
    "-out", path.join(mockDir, "mock.crt"),
    "-days", "2", "-subj", "/CN=accounts.feishu.cn",
    "-addext", "subjectAltName=DNS:accounts.feishu.cn,DNS:open.feishu.cn",
  ],
  { stdio: "ignore" },
);
const mockServer = https.createServer(
  {
    key: fs.readFileSync(path.join(mockDir, "mock.key")),
    cert: fs.readFileSync(path.join(mockDir, "mock.crt")),
  },
  (_req, res) => {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(MOCK_AUTHORIZE_HTML);
  },
);
await new Promise((resolve) => mockServer.listen(443, "127.0.0.1", resolve));

const browser = await chromium.launch({
  executablePath: "/usr/bin/chromium",
  args: [
    "--no-sandbox",
    "--host-resolver-rules=MAP accounts.feishu.cn 127.0.0.1, MAP open.feishu.cn 127.0.0.1",
  ],
});

async function trackNavigation(page) {
  const hops = [];
  page.on("response", (r) => {
    if (r.request().isNavigationRequest()) {
      const u = new URL(r.url());
      hops.push(
        `${r.status()} ${u.origin === BASE ? u.pathname + u.search : u.origin + u.pathname}`,
      );
    }
  });
  return hops;
}

// ===== [01] 飞书 UA：受保护页 → 自动免登跳转（无登录页）→ 飞书授权页 =====
const ctx1 = await browser.newContext({
  userAgent: FEISHU_UA,
  viewport: { width: 390, height: 844 },
  ignoreHTTPSErrors: true,
  recordHar: { path: `${OUT}/01-feishu-ua-auto-login.har`, content: "omit" },
});
const p1 = await ctx1.newPage();
const hops1 = await trackNavigation(p1);
await p1.goto(`${BASE}/report?range=month`, { waitUntil: "networkidle" });
await p1.screenshot({ path: `${OUT}/01-feishu-ua-auto-redirect.png` });
console.log("[01] 导航序列:", hops1.join("  ->  "));
console.log("[01] 最终 URL:", p1.url());
await ctx1.close();

// ===== [02] 未绑定失败：/login?error=im_not_bound → 带一次性标记 + 计数 1 + toast =====
const ctx2 = await browser.newContext({
  userAgent: FEISHU_UA,
  viewport: { width: 390, height: 844 },
});
const p2 = await ctx2.newPage();
const hops2 = await trackNavigation(p2);
await p2.goto(`${BASE}/login?error=im_not_bound`, { waitUntil: "networkidle" });
await p2.waitForTimeout(900); // 等 sonner toast 渲染
await p2.screenshot({ path: `${OUT}/02-im-not-bound-fallback.png` });
const cookies2 = await ctx2.cookies();
console.log("[02] 导航序列:", hops2.join("  ->  "));
console.log(
  "[02] 最终 URL:",
  p2.url(),
  "| im_h5_fallback =",
  cookies2.find((c) => c.name === "im_h5_fallback")?.value,
);
await ctx2.close();

// ===== [03] 防环：连续两次失败后（计数 2）再开链接 → 直接降级 /login，不再自动免登 =====
const ctx3 = await browser.newContext({
  userAgent: FEISHU_UA,
  viewport: { width: 390, height: 844 },
});
await ctx3.addCookies([
  { name: "im_h5_fallback", value: "2", domain: "localhost", path: "/" },
]);
const p3 = await ctx3.newPage();
const hops3 = await trackNavigation(p3);
await p3.goto(`${BASE}/report`, { waitUntil: "domcontentloaded" });
await p3.waitForTimeout(400);
await p3.screenshot({ path: `${OUT}/03-loop-guard-fallback.png` });
console.log("[03] 导航序列:", hops3.join("  ->  "));
console.log("[03] 最终 URL:", p3.url());
await ctx3.close();

// ===== [04] Chrome（非飞书）UA：不受影响，正常到登录页 =====
const ctx4 = await browser.newContext({ viewport: { width: 390, height: 844 } });
const p4 = await ctx4.newPage();
const hops4 = await trackNavigation(p4);
await p4.goto(`${BASE}/report`, { waitUntil: "networkidle" });
await p4.screenshot({ path: `${OUT}/04-chrome-ua-unaffected.png` });
console.log("[04] 导航序列:", hops4.join("  ->  "));
console.log("[04] 最终 URL:", p4.url());
await ctx4.close();

// ===== [05] 已登录（真实 Supabase 会话）+ 免登 redirect cookie → 跳回原目标 =====
const loginCtx = await browser.newContext();
const lp = await loginCtx.newPage();
await lp.goto(`${BASE}/login`);
await lp.fill("#email", "engineer@example.com");
await lp.fill("#password", "engineer123");
await lp.click('button[type="submit"]');
await lp.waitForURL(`${BASE}/`, { timeout: 20000 });
const session = await loginCtx.storageState();
await loginCtx.close();

const ctx5 = await browser.newContext({
  userAgent: FEISHU_UA,
  viewport: { width: 390, height: 844 },
  storageState: session,
});
await ctx5.addCookies([
  { name: "im_h5_redirect_to", value: "/dashboard", domain: "localhost", path: "/" },
]);
const p5 = await ctx5.newPage();
const hops5 = await trackNavigation(p5);
await p5.goto(`${BASE}/`, { waitUntil: "networkidle" });
await p5.screenshot({ path: `${OUT}/05-redirect-to-target.png` });
const cookies5 = await ctx5.cookies();
console.log("[05] 导航序列:", hops5.join("  ->  "));
console.log(
  "[05] 最终 URL:",
  p5.url(),
  "| redirect cookie 已消费:",
  !cookies5.some((c) => c.name === "im_h5_redirect_to"),
);
await ctx5.close();

await browser.close();
mockServer.close();
console.log("DONE");
