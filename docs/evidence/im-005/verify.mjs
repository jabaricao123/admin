// im/005 验证脚本：钉钉扫码 + 端内 WebView 免登（Playwright + Chromium + 本地钉钉 mock）
//
// 前置：
//   1. 本地 Supabase 已启动；本分支代码 `next dev -p 3001`；
//      `.env.local` 中 NEXT_PUBLIC_IM_CALLBACK_BASE=http://localhost:3001
//   2. `/tmp/opencode/im-005-mock/server.mjs` 监听 0.0.0.0:443（login/api.dingtalk.com 替身）；
//      DB 容器 /etc/hosts 指到宿主、CA bundle 已追加 mock 证书
//   3. DB 已启用钉钉（client_id=ding_mock_client / secret=mock_dingtalk_secret）并绑定
//      engineer@example.com → ding_mock_union_bound
//
// 运行：NODE_PATH=$(npm root -g) node docs/evidence/im-005/verify.mjs
// 产物写回本目录（*.png）；mock 请求日志见 /tmp/opencode/im-005-mock/requests.log。
import { createRequire } from "node:module";
import path from "node:path";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");

const BASE = process.env.IM005_BASE ?? "http://localhost:3001";
const DINGTALK_UA =
  "Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A.230805.001; wv) " +
  "AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/114.0.0.0 " +
  "Mobile Safari/537.36 AliApp(DingTalk/7.6.10)";
const OUT = path.dirname(new URL(import.meta.url).pathname);

const browser = await chromium.launch({
  executablePath: "/usr/bin/chromium",
  args: [
    "--no-sandbox",
    "--host-resolver-rules=MAP login.dingtalk.com 127.0.0.1, MAP api.dingtalk.com 127.0.0.1",
  ],
});

function trackNavigation(page) {
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

// ===== [00] PC：登录页「钉钉扫码登录」入口 =====
const pcCtx = await browser.newContext({
  viewport: { width: 1280, height: 800 },
  ignoreHTTPSErrors: true,
});
const pc = await pcCtx.newPage();
const hopsPc = await trackNavigation(pc);
await pc.goto(`${BASE}/login`, { waitUntil: "networkidle" });
await pc.getByRole("tab", { name: "扫码登录" }).click();
await pc.screenshot({ path: `${OUT}/00-login-scan-tab-dingtalk.png` });

// ===== [01] PC 扫码：start → mock 授权页 =====
await pc.getByRole("link", { name: /钉钉扫码登录/ }).click();
await pc.waitForURL(/login\.dingtalk\.com\/oauth2\/auth/, { timeout: 20000 });
await pc.waitForTimeout(400);
await pc.screenshot({ path: `${OUT}/01-dingtalk-auth-mock-pc.png` });
console.log("[01] PC 导航序列:", hopsPc.join("  ->  "));

// ===== [02] PC 已绑定用户确认 → 回调签发 session → 工作台 =====
await pc.getByRole("link", { name: "模拟：已绑定用户确认授权" }).click();
await pc.waitForURL(
  (u) => u.origin === BASE && !/^\/(auth|login)/.test(u.pathname),
  { timeout: 20000 },
);
await pc.waitForLoadState("networkidle");
await pc.screenshot({ path: `${OUT}/02-pc-callback-success.png` });
console.log("[02] PC 最终 URL:", pc.url());
await pcCtx.close();

// ===== [03] PC 未绑定用户确认 → /login?error=im_not_bound（toast） =====
const ghostCtx = await browser.newContext({
  viewport: { width: 1280, height: 800 },
  ignoreHTTPSErrors: true,
});
const ghost = await ghostCtx.newPage();
const hopsGhost = await trackNavigation(ghost);
await ghost.goto(`${BASE}/auth/im/dingtalk/start`, { waitUntil: "networkidle" });
await ghost.getByRole("link", { name: "模拟：未绑定用户确认授权" }).click();
await ghost.waitForURL(/\/login\?error=im_not_bound/, { timeout: 20000 });
await ghost.waitForTimeout(900); // 等 sonner toast 渲染
await ghost.screenshot({ path: `${OUT}/03-im-not-bound.png` });
console.log("[03] 未绑定导航序列:", hopsGhost.join("  ->  "));
console.log("[03] 最终 URL:", ghost.url());
await ghostCtx.close();

// ===== [04] 钉钉端内 WebView：受保护页 → 自动免登（无登录页）→ mock 授权页 =====
const dtCtx = await browser.newContext({
  userAgent: DINGTALK_UA,
  viewport: { width: 390, height: 844 },
  ignoreHTTPSErrors: true,
});
const dt = await dtCtx.newPage();
const hopsDt = await trackNavigation(dt);
await dt.goto(`${BASE}/dashboard`, { waitUntil: "networkidle" });
await dt.waitForURL(/login\.dingtalk\.com\/oauth2\/auth/, { timeout: 20000 });
await dt.waitForTimeout(400);
await dt.screenshot({ path: `${OUT}/04-dingtalk-webview-auto-login.png` });
console.log("[04] WebView 导航序列:", hopsDt.join("  ->  "));

// ===== [05] 端内确认授权 → 回调签发 session → 跳回原目标 /report =====
await dt.getByRole("link", { name: "模拟：已绑定用户确认授权" }).click();
await dt.waitForURL(
  (u) => u.origin === BASE && !/^\/(auth|login)/.test(u.pathname),
  { timeout: 20000 },
);
await dt.waitForLoadState("networkidle");
await dt.screenshot({ path: `${OUT}/05-webview-callback-success.png` });
console.log("[05] WebView 最终 URL:", dt.url(), "（免登前原目标 /dashboard 已由 redirect_to 恢复）");
await dtCtx.close();

// ===== [06] 审计：/audit/logins（via=im_dingtalk 的成功 / 未绑定留痕） =====
const adminCtx = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  ignoreHTTPSErrors: true,
});
const admin = await adminCtx.newPage();
await admin.goto(`${BASE}/login`, { waitUntil: "networkidle" });
await admin.fill("#email", "admin@example.com");
await admin.fill("#password", "admin123");
await admin.click('button[type="submit"]');
await admin.waitForURL(`${BASE}/`, { timeout: 20000 });
await admin.goto(`${BASE}/audit/logins`, { waitUntil: "networkidle" });
await admin.waitForTimeout(600);
await admin.screenshot({ path: `${OUT}/06-audit-logins.png`, fullPage: true });
console.log("[06] 审计页 URL:", admin.url());
await adminCtx.close();

await browser.close();
console.log("DONE");
