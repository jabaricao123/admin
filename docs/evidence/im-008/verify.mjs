// im/008 验证脚本：钉钉绑定回调兼容 authCode（R3）+ 密码登录关闭失败审计（R2）
//
// 前置：
//   1. 本地 Supabase 已启动；本分支代码 `next dev -p 3001`，且
//      NEXT_PUBLIC_IM_CALLBACK_BASE=http://localhost:3001
//   2. 钉钉 mock 在 443 监听（复用 docs/evidence/im-005/mock-server.mjs；
//      DB 容器 /etc/hosts 把 login/api.dingtalk.com 指向宿主、cert.pem 加入容器 CA）
//   3. R3 前置：DB 启用钉钉（app_key=ding_mock_client / app_secret=mock_dingtalk_secret），
//      engineer@example.com 未绑定钉钉
//      R2 前置：password_login_enabled=false 且 password_login_admin_emails 含 admin@example.com
//
// 运行：NODE_PATH=$(npm root -g) node docs/evidence/im-008/verify.mjs bind
//       NODE_PATH=$(npm root -g) node docs/evidence/im-008/verify.mjs r2
// 产物写回本目录（*.png / bind-hops.log）
import { writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");

const BASE = process.env.IM008_BASE ?? "http://localhost:3001";
const OUT = path.dirname(new URL(import.meta.url).pathname);
const PHASE = process.argv[2] ?? "bind";
// 默认钉钉端内 WebView UA（R3 验收场景：端内扫码绑定）；IM008_UA=pc 可切回普通浏览器
const DINGTALK_UA =
  "Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A.230805.001; wv) " +
  "AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/114.0.0.0 " +
  "Mobile Safari/537.36 AliApp(DingTalk/7.6.10)";
const UA = process.env.IM008_UA === "pc" ? undefined : DINGTALK_UA;

const browser = await chromium.launch({
  executablePath: process.env.CHROMIUM_PATH ?? "/usr/bin/chromium",
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
        `${r.status()} ${
          u.origin === BASE ? u.pathname + u.search : u.origin + u.pathname
        }`,
      );
    }
  });
  return hops;
}

async function passwordLogin(page, email, password, admin = false) {
  await page.goto(`${BASE}/login${admin ? "?admin=1" : ""}`, {
    waitUntil: "networkidle",
  });
  await page.fill("#email", email);
  await page.fill("#password", password);
  await page.getByRole("button", { name: "登录", exact: true }).click();
}

if (PHASE === "bind") {
  // ===== R3：钉钉绑定回调兼容 authCode（mock 只回传 authCode，不回传 code） =====
  const context = await browser.newContext({
    ignoreHTTPSErrors: true,
    viewport: { width: 1440, height: 1000 },
    ...(UA ? { userAgent: UA } : {}),
  });
  const page = await context.newPage();
  const hops = trackNavigation(page);

  await passwordLogin(page, "engineer@example.com", "engineer123");
  await page.waitForURL(`${BASE}/`, { timeout: 30000 });
  await page.goto(`${BASE}/settings/profile`, { waitUntil: "networkidle" });
  await page.waitForTimeout(500);
  await page.screenshot({ path: `${OUT}/01-profile-unbound.png`, fullPage: true });

  await page.getByRole("link", { name: "扫码绑定" }).click();
  await page.waitForURL(/login\.dingtalk\.com\/oauth2\/auth/, { timeout: 20000 });
  await page.waitForTimeout(300);
  await page.screenshot({
    path: `${OUT}/02-dingtalk-mock-authorize.png`,
    fullPage: true,
  });

  const href = await page
    .getByRole("link", { name: /未绑定用户确认授权/ })
    .getAttribute("href");
  if (!href || !/[?&]authCode=/.test(href)) {
    throw new Error(`R3 前置失败：mock 回调链接未使用 authCode：${href}`);
  }
  console.log("[R3] mock 回调链接使用 authCode=…（无 code 参数）");

  await page.getByRole("link", { name: /未绑定用户确认授权/ }).click();
  await page.waitForURL(/settings\/profile\?bound=dingtalk/, { timeout: 30000 });
  await page.waitForTimeout(800);
  await page.screenshot({
    path: `${OUT}/03-profile-bound-via-authcode.png`,
    fullPage: true,
  });

  const body = await page.locator("body").innerText();
  if (!body.includes("已绑定钉钉账号")) {
    throw new Error("R3 失败：绑定成功提示缺失");
  }
  writeFileSync(`${OUT}/bind-hops.log`, hops.join("\n") + "\n");
  console.log("[R3] 绑定成功；导航序列：\n" + hops.join("\n"));
  await context.close();
} else if (PHASE === "r2") {
  // ===== R2：密码登录关闭后，非名单账号经应急入口被拒并留痕 =====
  const context = await browser.newContext({
    ignoreHTTPSErrors: true,
    viewport: { width: 1440, height: 1000 },
  });
  const page = await context.newPage();

  await passwordLogin(page, "engineer@example.com", "engineer123", true);
  await page.waitForTimeout(2500);
  const body = await page.locator("body").innerText();
  if (!body.includes("密码登录已关闭")) {
    throw new Error("R2 失败：未出现「密码登录已关闭」提示");
  }
  await page.screenshot({
    path: `${OUT}/04-password-disabled-denied.png`,
    fullPage: true,
  });
  console.log("[R2] 被拒提示出现，客户端已写匿名失败留痕");
  await context.close();

  // admin（应急名单内）登录查看登录日志：新留痕的 fail_reason 展示
  const adminContext = await browser.newContext({
    ignoreHTTPSErrors: true,
    viewport: { width: 1440, height: 1000 },
  });
  const admin = await adminContext.newPage();
  await passwordLogin(admin, "admin@example.com", "admin123", true);
  await admin.waitForURL(`${BASE}/`, { timeout: 30000 });
  await admin.goto(`${BASE}/audit/logins`, { waitUntil: "networkidle" });
  await admin.waitForTimeout(800);
  await admin.screenshot({
    path: `${OUT}/05-audit-logins-password-disabled.png`,
    fullPage: true,
  });
  await adminContext.close();
  console.log("[R2] /audit/logins 截图完成");
} else {
  throw new Error(`未知阶段：${PHASE}`);
}

await browser.close();
