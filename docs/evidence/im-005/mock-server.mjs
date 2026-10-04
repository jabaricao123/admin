// im/005 本地验证用钉钉 mock（仅验证环境；生产代码不感知本文件）
//
// 覆盖端点：
// - https://login.dingtalk.com/oauth2/auth                授权页（PC 扫码 / 端内免登同页，按 UA 渲染）
// - https://api.dingtalk.com/v1.0/oauth2/userAccessToken  code → userAccessToken（JSON）
// - https://api.dingtalk.com/v1.0/contact/users/me        用户身份（unionId / openId）
//
// 用法（本目录下）：
//   openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3 \
//     -subj "/CN=login.dingtalk.com" \
//     -addext "subjectAltName=DNS:login.dingtalk.com,DNS:api.dingtalk.com"
//   node mock-server.mjs        # 监听 0.0.0.0:443
//
// 配合：DB 容器 /etc/hosts 把两个域名指到宿主机、CA bundle 追加 cert.pem；
//       Chromium 以 --host-resolver-rules=MAP login.dingtalk.com 127.0.0.1, MAP api.dingtalk.com 127.0.0.1 启动。
import { createServer } from "node:https";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const cert = readFileSync(path.join(DIR, "cert.pem"));
const key = readFileSync(path.join(DIR, "key.pem"));
const LOG = path.join(DIR, "requests.log");
writeFileSync(LOG, "");

const log = (line) => appendFileSync(LOG, `[${new Date().toISOString()}] ${line}\n`);

const CLIENT_ID = "ding_mock_client";
const CLIENT_SECRET = "mock_dingtalk_secret";
const BOUND_UNION_ID = "ding_mock_union_bound";
const UNBOUND_UNION_ID = "ding_mock_union_unbound";

const codes = new Map(); // authCode -> unionId
const tokens = new Map(); // accessToken -> unionId
const usedCodes = new Set();
let tokenSeq = 0;

const readBody = (req) =>
  new Promise((resolve) => {
    let raw = "";
    req.on("data", (chunk) => {
      raw += chunk;
    });
    req.on("end", () => resolve(raw));
  });

const PAGE = (params, isWebView) => {
  const redirectUri = params.get("redirect_uri") ?? "";
  const state = params.get("state") ?? "";
  const nonce = Math.random().toString(36).slice(2, 10);
  const callback = (code) => {
    if (!redirectUri) return "#";
    const url = new URL(redirectUri);
    url.searchParams.set("authCode", code); // 钉钉回调参数名：authCode（与 code 同值）
    url.searchParams.set("state", state);
    return url.toString();
  };

  const boundCode = `mock-bound-${nonce}`;
  const unboundCode = `mock-unbound-${nonce}`;
  codes.set(boundCode, BOUND_UNION_ID);
  codes.set(unboundCode, UNBOUND_UNION_ID);

  return `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>钉钉授权（本地 Mock）</title>
<style>
  body{margin:0;font-family:system-ui,-apple-system,sans-serif;background:#f2f3f5;display:flex;align-items:center;justify-content:center;min-height:100vh}
  .card{background:#fff;border:1px solid #e5e6eb;border-radius:12px;width:420px;padding:32px;text-align:center;box-shadow:0 8px 24px rgba(0,0,0,.06)}
  .badge{display:inline-block;background:#e8f0ff;color:#1677ff;border-radius:999px;padding:2px 12px;font-size:12px;margin-bottom:16px}
  h1{font-size:20px;margin:0 0 4px} p{color:#646a73;font-size:14px}
  .qr{width:200px;height:200px;margin:20px auto;border:1px solid #e5e6eb;border-radius:8px;display:grid;grid-template-columns:repeat(8,1fr);padding:12px;box-sizing:border-box;gap:3px;background:#fff}
  .qr i{background:#1f2329;border-radius:2px} .qr i:nth-child(3n),.qr i:nth-child(7n+1){background:transparent}
  .btn{display:block;width:100%;box-sizing:border-box;margin:10px 0;padding:12px;border-radius:8px;border:1px solid #1677ff;background:#1677ff;color:#fff;font-size:15px;text-decoration:none}
  .btn.secondary{background:#fff;color:#1677ff}
  .btn.deny{background:#fff;color:#646a73;border-color:#dee0e3}
  .hint{font-size:12px;color:#8f959e;margin-top:16px}
</style></head><body>
<div class="card">
  <div class="badge">本地 Mock · 非真实钉钉页面</div>
  <h1>${isWebView ? "钉钉端内免登授权" : "钉钉扫码登录"}</h1>
  <p>企业管理系统 申请获取你的钉钉身份（unionId）</p>
  ${isWebView ? '<p style="font-size:40px;margin:24px 0">📲</p>' : '<div class="qr">' + Array.from({ length: 64 }, () => "<i></i>").join("") + "</div>"}
  <p>${isWebView ? "钉钉端内已登录：请确认授权（本地验证请点击下方模拟按钮）" : "请使用钉钉扫码并确认（本地验证请点击下方模拟按钮）"}</p>
  <a class="btn" href="${callback(boundCode)}">模拟：已绑定用户确认授权</a>
  <a class="btn secondary" href="${callback(unboundCode)}">模拟：未绑定用户确认授权</a>
  <a class="btn deny" href="${redirectUri}?error=access_denied&state=${encodeURIComponent(state)}">模拟：用户拒绝授权</a>
  <div class="hint">state=${state.slice(0, 18)}…（一次性，5 分钟有效）</div>
</div></body></html>`;
};

const json = (res, status, body) => {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(body));
};

const server = createServer({ cert, key }, async (req, res) => {
  const url = new URL(req.url, "https://" + (req.headers.host ?? "unknown"));
  log(`${req.method} https://${req.headers.host}${url.pathname}`);

  if (url.pathname === "/oauth2/auth") {
    const isWebView = /dingtalk/i.test(req.headers["user-agent"] ?? "");
    log(`AUTHORIZE mode=${isWebView ? "webview" : "pc"} client_id=${url.searchParams.get("client_id")} scope=${url.searchParams.get("scope")} prompt=${url.searchParams.get("prompt")}`);
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(PAGE(url.searchParams, isWebView));
    return;
  }

  if (url.pathname === "/v1.0/oauth2/userAccessToken") {
    const raw = await readBody(req);
    let body = {};
    try {
      body = JSON.parse(raw);
    } catch {
      log("TOKEN invalid json body");
      json(res, 400, { code: "invalidParameter", message: "请求体不是合法 JSON", requestId: "mock-r1" });
      return;
    }
    log(`TOKEN client_id=${body.clientId} grant_type=${body.grantType} code=${body.code}`);
    if (body.clientId !== CLIENT_ID || body.clientSecret !== CLIENT_SECRET) {
      json(res, 400, { code: "invalidParameter", message: "clientId / clientSecret 不匹配", requestId: "mock-r2" });
      return;
    }
    if (body.grantType !== "authorization_code") {
      json(res, 400, { code: "invalidParameter", message: "grantType 非法", requestId: "mock-r3" });
      return;
    }
    const unionId = codes.get(body.code);
    if (!unionId || usedCodes.has(body.code)) {
      log(`TOKEN rejected code=${body.code}${usedCodes.has(body.code) ? " (replay)" : ""}`);
      json(res, 400, { code: "invalidParameter", message: "code参数不合法", requestId: "mock-r4" });
      return;
    }
    usedCodes.add(body.code);
    const accessToken = `mock-ding-uat-${++tokenSeq}`;
    tokens.set(accessToken, unionId);
    log(`TOKEN issued access_token=${accessToken} unionId=${unionId}`);
    json(res, 200, { accessToken, refreshToken: "", expireIn: 7200, corpId: "ding_mock_corp" });
    return;
  }

  if (url.pathname === "/v1.0/contact/users/me") {
    const token = req.headers["x-acs-dingtalk-access-token"] ?? "";
    log(`USERINFO token=${token}`);
    const unionId = tokens.get(token);
    if (!unionId) {
      json(res, 401, { code: "invalidParameter.accessToken", message: "accessToken 无效", requestId: "mock-r5" });
      return;
    }
    json(res, 200, {
      nick: "工程师",
      avatarUrl: "https://static.dingtalk.com/media/mock-avatar.png",
      mobile: "150****9144",
      openId: `mock_open_${unionId.split("_").pop()}`,
      unionId,
      email: "engineer@example.com",
      stateCode: "86",
    });
    return;
  }

  json(res, 404, { code: "notFound", message: "not found", requestId: "mock-r404" });
});

server.listen(443, "0.0.0.0", () => {
  log("mock dingtalk listening on 0.0.0.0:443");
  console.log("mock dingtalk listening on https://0.0.0.0:443");
});
