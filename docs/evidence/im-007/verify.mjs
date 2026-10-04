// im/007 验证脚本：PC 扫码真二维码（ticket 轮询）+ 同浏览器路径回归（Playwright + Chromium + 本地厂商 mock）
//
// 前置：
//   1. 本地 Supabase 已启动且应用了本分支迁移（supabase db reset）；
//   2. mock 监听 0.0.0.0:443（docs/evidence/im-007/mock-server.mjs，见文件头与 README）；
//      DB 容器 /etc/hosts 指向宿主机、CA bundle 已追加 mock 证书；
//   3. 本分支代码 `next dev -p 3001`，环境：
//      NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321
//      NEXT_PUBLIC_IM_CALLBACK_BASE=http://localhost:3001
//   4. DB 已 seed（engineer@example.com / admin@example.com）。
//
// 运行：
//   NODE_PATH=$(npm root -g):/tmp/opencode/im-007-verify/node_modules \
//     node docs/evidence/im-007/verify.mjs
//
// 产物：本目录 *.png 截图；控制台输出二维码解码校验 / 跳转耗时 / 导航序列。
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import path from "node:path";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");
const jsQR = require("jsqr");
const { PNG } = require("pngjs");

const BASE = process.env.IM007_BASE ?? "http://localhost:3001";
const OUT = path.dirname(new URL(import.meta.url).pathname);
const DB_CONTAINER = process.env.IM007_DB_CONTAINER ?? "supabase_db_plm-cjtcable";

const MOBILE_UA =
  "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) " +
  "Chrome/114.0.0.0 Mobile Safari/537.36";
const DINGTALK_UA =
  "Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A.230805.001; wv) " +
  "AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/114.0.0.0 " +
  "Mobile Safari/537.36 AliApp(DingTalk/7.6.10)";

const CREDS = {
  feishu: '{"app_id":"cli_mock_qr","app_secret":"feishu_mock_secret"}',
  wecom: '{"corp_id":"ww_mock_corp","agent_id":"1000002","secret":"mock_wecom_secret"}',
  dingtalk: '{"app_key":"ding_mock_client","app_secret":"mock_dingtalk_secret"}',
};
const BOUND_USERID = {
  feishu: "feishu_mock_bound",
  wecom: "wecom_mock_bound",
  dingtalk: "ding_mock_union_bound",
};

function sql(text) {
  return execFileSync(
    "docker",
    ["exec", "-i", DB_CONTAINER, "psql", "-U", "postgres", "-d", "postgres", "-X", "-q", "-t", "-A", "-c", text],
    { encoding: "utf8" },
  ).trim();
}

function enableProvider(provider) {
  sql(`
    update public.im_auth_configs set enabled = false where enabled;
    insert into public.im_auth_configs (provider, enabled, credentials)
    values ('${provider}', true, app.encrypt_secret('${CREDS[provider]}'))
    on conflict (provider) do update set enabled = true, credentials = excluded.credentials;
  `);
}

function bindEngineer(provider, userid) {
  sql(`
    update public.profiles
       set wecom_userid = null, feishu_userid = null, dingtalk_userid = null
     where wecom_userid is not null or feishu_userid is not null or dingtalk_userid is not null;
    update public.profiles set ${provider}_userid = '${userid}' where email = 'engineer@example.com';
  `);
}

function setAdminContact(contact) {
  sql(`update public.system_settings set value = to_jsonb('${contact}'::text) where key = 'im_admin_contact';`);
}

const browser = await chromium.launch({
  executablePath: "/usr/bin/chromium",
  args: [
    "--no-sandbox",
    "--host-resolver-rules=" +
      [
        "login.dingtalk.com",
        "api.dingtalk.com",
        "accounts.feishu.cn",
        "open.feishu.cn",
        "open.work.weixin.qq.com",
        "qyapi.weixin.qq.com",
      ]
        .map((d) => `MAP ${d} 127.0.0.1`)
        .join(", "),
  ],
});

function trackNavigation(page) {
  const hops = [];
  page.on("response", (r) => {
    if (r.request().isNavigationRequest()) {
      const u = new URL(r.url());
      hops.push(`${r.status()} ${u.origin === BASE ? u.pathname : u.origin + u.pathname}`);
    }
  });
  return hops;
}

async function decodeQr(page) {
  const buffer = await page.getByTestId("im-qr-image").screenshot();
  const png = PNG.sync.read(buffer);
  const result = jsQR(new Uint8ClampedArray(png.data), png.width, png.height);
  return result?.data ?? null;
}

async function openScanTab(pc) {
  const startResponse = pc.waitForResponse(
    (r) => r.url().includes("/rpc/im_start_qr_login") && r.request().method() === "POST",
    { timeout: 20000 },
  );
  await pc.getByRole("tab", { name: "扫码登录" }).click();
  const response = await startResponse;
  const body = await response.json();
  if (body?.ok !== true) {
    throw new Error(`im_start_qr_login 失败: ${JSON.stringify(body)}`);
  }
  return body;
}

/** 二维码图片模式（飞书 / 钉钉）：PC 出码 → 手机扫码确认 → PC 自动跳转 */
async function qrImageScenario(provider, label, prefix) {
  enableProvider(provider);
  bindEngineer(provider, BOUND_USERID[provider]);

  const pcCtx = await browser.newContext({ viewport: { width: 1280, height: 900 }, ignoreHTTPSErrors: true });
  const pc = await pcCtx.newPage();
  const hops = trackNavigation(pc);
  await pc.goto(`${BASE}/login`, { waitUntil: "networkidle" });
  const start = await openScanTab(pc);

  await pc.getByTestId("im-qr-image").waitFor({ state: "visible" });
  await pc.waitForTimeout(300);
  const decoded = await decodeQr(pc);
  if (!decoded || !decoded.includes("state=qr.")) {
    throw new Error(`二维码未解码出 ticket：${decoded}`);
  }
  // dev StrictMode 下 effect 可能触发两次 start（后一次生效）；以页面实际渲染的二维码为准
  const actualTicket = new URL(decoded).searchParams.get("state");
  if (actualTicket !== start.ticket) {
    console.log(`[${provider}] dev 双 start：RPC 先返回 ${start.ticket.slice(0, 11)}…，页面渲染 ${actualTicket.slice(0, 11)}…`);
  }
  console.log(`[${provider}] 二维码解码 = 授权 URL（state=${actualTicket.slice(0, 11)}…）✓`);
  await pc.screenshot({ path: `${OUT}/${prefix}-pc-qr.png` });

  // 手机扫码：打开授权页 → App 内确认
  const phoneCtx = await browser.newContext({
    viewport: { width: 390, height: 844 },
    userAgent: MOBILE_UA,
    ignoreHTTPSErrors: true,
  });
  const phone = await phoneCtx.newPage();
  await phone.goto(decoded, { waitUntil: "networkidle" });
  await phone.screenshot({ path: `${OUT}/${prefix}-phone-confirm.png` });

  const tClick = Date.now();
  await phone.getByRole("link", { name: "模拟：已绑定用户确认授权" }).click();
  await phone.getByRole("heading", { name: "扫码成功" }).waitFor({ timeout: 15000 });
  await phone.screenshot({ path: `${OUT}/${prefix}-phone-success.png` });

  // PC 轮询到 logged_in → /auth/qr/exchange 换 session → 工作台
  await pc.waitForURL((u) => u.origin === BASE && !/^\/(auth|login)/.test(u.pathname), { timeout: 15000 });
  const elapsed = Date.now() - tClick;
  await pc.waitForLoadState("networkidle");
  await pc.screenshot({ path: `${OUT}/${prefix}-pc-after.png` });
  console.log(`[${provider}] 手机确认 → PC 工作台 ${elapsed}ms；PC 导航: ${hops.join(" -> ")}`);
  if (elapsed > 5000) {
    throw new Error(`[${provider}] PC 自动跳转过慢: ${elapsed}ms`);
  }

  await phoneCtx.close();
  await pcCtx.close();
  return { elapsed, hops };
}

/** 企业微信：PC 内嵌官方 qrConnect 页（iframe）→ 授权成功由该页回调 → PC 自动跳转 */
async function wecomIframeScenario() {
  enableProvider("wecom");
  bindEngineer("wecom", BOUND_USERID.wecom);

  const pcCtx = await browser.newContext({ viewport: { width: 1280, height: 900 }, ignoreHTTPSErrors: true });
  const pc = await pcCtx.newPage();
  const hops = trackNavigation(pc);
  await pc.goto(`${BASE}/login`, { waitUntil: "networkidle" });
  const start = await openScanTab(pc);

  const iframe = pc.getByTestId("im-qr-iframe");
  await iframe.waitFor({ state: "visible" });
  await pc.waitForTimeout(300);
  const iframeSrc = await iframe.getAttribute("src");
  const iframeTicket = iframeSrc ? new URL(iframeSrc).searchParams.get("state") : null;
  const frame = pc.frameLocator('[data-testid="im-qr-iframe"]');
  await frame.getByRole("link", { name: "模拟：已绑定用户确认授权" }).waitFor({ timeout: 15000 });
  void start;
  console.log(`[wecom] iframe 加载官方 qrConnect 页；state=${String(iframeTicket).slice(0, 11)}…`);
  await pc.screenshot({ path: `${OUT}/30-pc-qr-wecom-iframe.png` });

  const tClick = Date.now();
  // 模拟手机确认后 qrConnect 页自行跳转回调（iframe 内导航）
  await frame.getByRole("link", { name: "模拟：已绑定用户确认授权" }).click();
  await frame.getByRole("heading", { name: "扫码成功" }).waitFor({ timeout: 15000 });
  await pc.screenshot({ path: `${OUT}/31-wecom-qrconnect-callback.png` });

  await pc.waitForURL((u) => u.origin === BASE && !/^\/(auth|login)/.test(u.pathname), { timeout: 15000 });
  const elapsed = Date.now() - tClick;
  await pc.waitForLoadState("networkidle");
  await pc.screenshot({ path: `${OUT}/32-pc-after-wecom.png` });
  console.log(`[wecom] qrConnect 回调 → PC 工作台 ${elapsed}ms；PC 导航: ${hops.join(" -> ")}`);

  await pcCtx.close();
  return elapsed;
}

/** 未绑定：手机确认后 PC 端收到 im_not_bound 原因（ticket 作废 + fail_reason 经 poll 展示） */
async function notBoundScenario() {
  enableProvider("dingtalk");
  bindEngineer("dingtalk", BOUND_USERID.dingtalk);
  setAdminContact("admin@example.com");

  const pcCtx = await browser.newContext({ viewport: { width: 1280, height: 900 }, ignoreHTTPSErrors: true });
  const pc = await pcCtx.newPage();
  await pc.goto(`${BASE}/login`, { waitUntil: "networkidle" });
  const start = await openScanTab(pc);
  await pc.getByTestId("im-qr-image").waitFor({ state: "visible" });
  await pc.waitForTimeout(300);
  const authorizeUrl = await decodeQr(pc);
  if (!authorizeUrl || !authorizeUrl.includes("state=qr.")) {
    throw new Error(`二维码未解码出 ticket：${authorizeUrl}`);
  }
  void start;

  const phoneCtx = await browser.newContext({
    viewport: { width: 390, height: 844 },
    userAgent: MOBILE_UA,
    ignoreHTTPSErrors: true,
  });
  const phone = await phoneCtx.newPage();
  await phone.goto(authorizeUrl, { waitUntil: "networkidle" });
  await phone.getByRole("link", { name: "模拟：未绑定用户确认授权" }).click();
  await phone.getByRole("heading", { name: "扫码登录失败" }).waitFor({ timeout: 15000 });
  const phoneText = await phone.locator("body").innerText();
  if (!phoneText.includes("未绑定钉钉账号")) {
    throw new Error(`手机端未看到未绑定文案: ${phoneText}`);
  }
  await phone.screenshot({ path: `${OUT}/40-phone-not-bound.png` });

  // PC 轮询拿到 expired + reason=im_not_bound
  await pc.getByText("未绑定钉钉账号，请联系管理员").waitFor({ timeout: 8000 });
  await pc.waitForTimeout(200);
  await pc.screenshot({ path: `${OUT}/41-pc-not-bound.png` });
  console.log("[not_bound] 手机端拒绝 + PC 端展示未绑定原因（ticket 已作废）✓");

  await phoneCtx.close();
  await pcCtx.close();
}

/** 回归：移动端 H5 免登（同浏览器 state cookie 路径）不受影响 */
async function webviewCookiePathRegression() {
  enableProvider("dingtalk");
  bindEngineer("dingtalk", BOUND_USERID.dingtalk);

  const ctx = await browser.newContext({
    viewport: { width: 390, height: 844 },
    userAgent: DINGTALK_UA,
    ignoreHTTPSErrors: true,
  });
  const page = await ctx.newPage();
  const hops = trackNavigation(page);
  await page.goto(`${BASE}/dashboard`, { waitUntil: "networkidle" });
  await page.waitForURL(/login\.dingtalk\.com\/oauth2\/auth/, { timeout: 20000 });
  await page.getByRole("link", { name: "模拟：已绑定用户确认授权" }).click();
  await page.waitForURL((u) => u.origin === BASE && !/^\/(auth|login)/.test(u.pathname), { timeout: 20000 });
  await page.waitForLoadState("networkidle");
  await page.screenshot({ path: `${OUT}/50-webview-cookie-path.png` });
  console.log(`[回归] 钉钉端内免登（state cookie 路径）最终 URL: ${page.url()}；导航: ${hops.join(" -> ")}`);
  await ctx.close();
}

/** 审计页：扫码成功 / 未绑定失败留痕（via=im_*） */
async function auditScenario() {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, ignoreHTTPSErrors: true });
  const page = await ctx.newPage();
  await page.goto(`${BASE}/login`, { waitUntil: "networkidle" });
  // 密码 Tab（该页面可能默认扫码 Tab：直接填表提交）
  const emailVisible = await page.locator("#email").isVisible().catch(() => false);
  if (!emailVisible) {
    await page.getByRole("tab", { name: "密码登录" }).click();
  }
  await page.fill("#email", "admin@example.com");
  await page.fill("#password", "admin123");
  await page.click('button[type="submit"]');
  await page.waitForURL(`${BASE}/`, { timeout: 20000 });
  await page.goto(`${BASE}/audit/logins`, { waitUntil: "networkidle" });
  await page.waitForTimeout(600);
  await page.screenshot({ path: `${OUT}/60-audit-logins.png`, fullPage: true });
  console.log("[audit] /audit/logins 截图完成");
  await ctx.close();
}

// ===== 执行 =====
await qrImageScenario("dingtalk", "钉钉", "10");
await qrImageScenario("feishu", "飞书", "20");
await wecomIframeScenario();
await notBoundScenario();
await webviewCookiePathRegression();
await auditScenario();

await browser.close();
console.log("DONE");
