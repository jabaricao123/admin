// im/007 本地验证用组合 mock（仅验证环境；生产代码不感知本文件）
//
// 覆盖三家厂商的扫码链路端点（按 Host 路由，单进程 443 端口）：
// - login.dingtalk.com      /oauth2/auth                钉钉授权页（PC 扫码 / 端内 WebView 同页）
// - api.dingtalk.com        /v1.0/oauth2/userAccessToken code → userAccessToken
//                           /v1.0/contact/users/me       身份（unionId）
// - accounts.feishu.cn      /open-apis/authen/v1/authorize  飞书授权页（二维码内容）
//                           /oauth/v3/token              code → user_access_token
// - open.feishu.cn          /open-apis/authen/v1/user_info user_access_token → user_id
// - open.work.weixin.qq.com /wwopen/sso/qrConnect          企业微信 PC 扫码托管页（iframe 嵌入）
// - qyapi.weixin.qq.com     /cgi-bin/gettoken              access_token
//                           /cgi-bin/auth/getuserinfo      code → userid
//
// 用法：
//   openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3 \
//     -subj "/CN=im007-mock" -addext "subjectAltName=DNS:login.dingtalk.com,DNS:api.dingtalk.com,DNS:accounts.feishu.cn,DNS:open.feishu.cn,DNS:open.work.weixin.qq.com,DNS:qyapi.weixin.qq.com"
//   IM007_CERT_DIR=$(pwd) node mock-server.mjs      # 监听 0.0.0.0:443
//
// 配合：DB 容器 /etc/hosts 把上述域名指到宿主机（host.docker.internal）、CA bundle 追加 cert.pem；
//       Chromium 以 --host-resolver-rules=MAP <域名> 127.0.0.1 … 启动。
import { createServer } from "node:https";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const DIR = process.env.IM007_CERT_DIR ?? path.dirname(fileURLToPath(import.meta.url));
const cert = readFileSync(path.join(DIR, "cert.pem"));
const key = readFileSync(path.join(DIR, "key.pem"));
const LOG = path.join(DIR, "requests.log");
writeFileSync(LOG, "");

const log = (line) => appendFileSync(LOG, `[${new Date().toISOString()}] ${line}\n`);

// 凭据（与 DB im_auth_configs 内加密保存的一致）
const FEISHU_APP_ID = "cli_mock_qr";
const FEISHU_APP_SECRET = "feishu_mock_secret";
const WECOM_CORP_ID = "ww_mock_corp";
const WECOM_SECRET = "mock_wecom_secret";
const DING_CLIENT_ID = "ding_mock_client";
const DING_CLIENT_SECRET = "mock_dingtalk_secret";

// 绑定关系（构造账号）
const FEISHU_BOUND = "feishu_mock_bound";
const FEISHU_UNBOUND = "feishu_mock_unbound";
const WECOM_BOUND = "wecom_mock_bound";
const WECOM_UNBOUND = "wecom_mock_unbound";
const DING_BOUND = "ding_mock_union_bound";
const DING_UNBOUND = "ding_mock_union_unbound";

const usedCodes = new Set(); // code 单次可用（真实厂商行为）
const tokens = new Map(); // token → 身份
let tokenSeq = 0;
let wecomTokenSeq = 0;

const identityFromCode = (provider, code) => {
  const match = /^mock-(bound|unbound)-[a-z0-9]+$/.exec(code ?? "");
  if (!match) return null;
  const bound = match[1] === "bound";
  if (provider === "feishu") return bound ? FEISHU_BOUND : FEISHU_UNBOUND;
  if (provider === "wecom") return bound ? WECOM_BOUND : WECOM_UNBOUND;
  return bound ? DING_BOUND : DING_UNBOUND;
};

const readBody = (req) =>
  new Promise((resolve) => {
    let raw = "";
    req.on("data", (chunk) => {
      raw += chunk;
    });
    req.on("end", () => resolve(raw));
  });

const page = (options) => {
  const { title, accent, badge, subject, qr, buttons, state } = options;
  return `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>${title}（本地 Mock）</title>
<meta name="viewport" content="width=device-width, initial-scale=1" />
<style>
  body{margin:0;font-family:system-ui,-apple-system,sans-serif;background:#f5f6f7;display:flex;align-items:center;justify-content:center;min-height:100vh}
  .card{background:#fff;border:1px solid #e5e6eb;border-radius:12px;width:420px;max-width:calc(100vw - 32px);padding:32px;text-align:center;box-shadow:0 8px 24px rgba(0,0,0,.06);box-sizing:border-box}
  .badge{display:inline-block;background:${accent.bg};color:${accent.fg};border-radius:999px;padding:2px 12px;font-size:12px;margin-bottom:16px}
  h1{font-size:20px;margin:0 0 4px} p{color:#646a73;font-size:14px}
  .qr{width:200px;height:200px;margin:20px auto;border:1px solid #e5e6eb;border-radius:8px;display:grid;grid-template-columns:repeat(8,1fr);padding:12px;box-sizing:border-box;gap:3px;background:#fff}
  .qr i{background:#1f2329;border-radius:2px} .qr i:nth-child(3n),.qr i:nth-child(7n+1){background:transparent}
  .btn{display:block;width:100%;box-sizing:border-box;margin:10px 0;padding:12px;border-radius:8px;border:1px solid ${accent.fg};background:${accent.fg};color:#fff;font-size:15px;text-decoration:none}
  .btn.secondary{background:#fff;color:${accent.fg}}
  .btn.deny{background:#fff;color:#646a73;border-color:#dee0e3}
  .hint{font-size:12px;color:#8f959e;margin-top:16px;word-break:break-all}
</style></head><body>
<div class="card">
  <div class="badge">本地 Mock · 非真实${badge}页面</div>
  <h1>${title}</h1>
  <p>${subject}</p>
  ${qr ? '<div class="qr">' + Array.from({ length: 64 }, () => "<i></i>").join("") + "</div>" : '<p style="font-size:40px;margin:24px 0">📲</p>'}
  <p>${qr ? "请使用对应 App 扫码（本地验证请点击下方模拟按钮）" : "App 内打开（本地验证请点击下方模拟按钮）"}</p>
  ${buttons}
  <div class="hint">state=${String(state).slice(0, 18)}…（一次性，5 分钟有效）</div>
</div></body></html>`;
};

const json = (res, status, body) => {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(body));
};

const html = (res, body) => {
  res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
  res.end(body);
};

/** 授权页按钮：绑定 / 未绑定 / 拒绝（均带上 state） */
const callbackButtons = (redirectUri, state, nonce) => {
  const make = (query, text, cls) => {
    if (!redirectUri) return "";
    const url = new URL(redirectUri);
    for (const [k, v] of Object.entries(query)) {
      url.searchParams.set(k, v);
    }
    url.searchParams.set("state", state);
    return `<a class="${cls}" href="${url.toString()}">${text}</a>`;
  };
  return [
    make({ code: `mock-bound-${nonce}` }, "模拟：已绑定用户确认授权", "btn"),
    make({ code: `mock-unbound-${nonce}` }, "模拟：未绑定用户确认授权", "btn secondary"),
    make({ error: "access_denied" }, "模拟：用户拒绝授权", "btn deny"),
  ].join("\n  ");
};

const ACCENTS = {
  feishu: { bg: "#e8f3ff", fg: "#245bdb" },
  wecom: { bg: "#e8f7ee", fg: "#07c160" },
  dingtalk: { bg: "#e8f0ff", fg: "#1677ff" },
};

const server = createServer({ cert, key }, async (req, res) => {
  const url = new URL(req.url, "https://" + (req.headers.host ?? "unknown"));
  const host = req.headers.host ?? "unknown";
  log(`${req.method} https://${host}${url.pathname}`);

  // ----- 钉钉 -----
  if (host === "login.dingtalk.com" && url.pathname === "/oauth2/auth") {
    const redirectUri = url.searchParams.get("redirect_uri") ?? "";
    const state = url.searchParams.get("state") ?? "";
    const nonce = Math.random().toString(36).slice(2, 10);
    const isWebView = /dingtalk/i.test(req.headers["user-agent"] ?? "");
    log(`AUTHORIZE dingtalk mode=${isWebView ? "webview" : "pc"} client_id=${url.searchParams.get("client_id")} state=${state.slice(0, 12)}…`);
    html(
      res,
      page({
        title: isWebView ? "钉钉端内免登授权" : "钉钉扫码登录",
        badge: "钉钉",
        accent: ACCENTS.dingtalk,
        subject: "企业管理系统 申请获取你的钉钉身份（unionId）",
        qr: !isWebView,
        state,
        buttons: callbackButtons(redirectUri, state, nonce),
      }),
    );
    return;
  }

  if (host === "api.dingtalk.com" && url.pathname === "/v1.0/oauth2/userAccessToken") {
    const raw = await readBody(req);
    let body = {};
    try {
      body = JSON.parse(raw);
    } catch {
      json(res, 400, { code: "invalidParameter", message: "请求体不是合法 JSON" });
      return;
    }
    log(`TOKEN dingtalk client_id=${body.clientId} code=${body.code}`);
    if (body.clientId !== DING_CLIENT_ID || body.clientSecret !== DING_CLIENT_SECRET) {
      json(res, 400, { code: "invalidParameter", message: "clientId / clientSecret 不匹配" });
      return;
    }
    const identity = identityFromCode("dingtalk", body.code);
    if (!identity || usedCodes.has(body.code)) {
      log(`TOKEN dingtalk rejected${usedCodes.has(body.code) ? " (replay)" : ""} code=${body.code}`);
      json(res, 400, { code: "invalidParameter", message: "code 参数不合法" });
      return;
    }
    usedCodes.add(body.code);
    const accessToken = `mock-ding-uat-${++tokenSeq}`;
    tokens.set(accessToken, identity);
    json(res, 200, { accessToken, refreshToken: "", expireIn: 7200, corpId: "ding_mock_corp" });
    return;
  }

  if (host === "api.dingtalk.com" && url.pathname === "/v1.0/contact/users/me") {
    const token = req.headers["x-acs-dingtalk-access-token"] ?? "";
    const identity = tokens.get(token);
    log(`USERINFO dingtalk token=${token} → ${identity ?? "invalid"}`);
    if (!identity) {
      json(res, 401, { code: "invalidParameter.accessToken", message: "accessToken 无效" });
      return;
    }
    json(res, 200, {
      nick: "工程师",
      avatarUrl: "https://static.dingtalk.com/media/mock-avatar.png",
      mobile: "150****9144",
      openId: `mock_open_${identity}`,
      unionId: identity,
      email: "engineer@example.com",
      stateCode: "86",
    });
    return;
  }

  // ----- 飞书 -----
  if (host === "accounts.feishu.cn" && url.pathname === "/open-apis/authen/v1/authorize") {
    const redirectUri = url.searchParams.get("redirect_uri") ?? "";
    const state = url.searchParams.get("state") ?? "";
    const nonce = Math.random().toString(36).slice(2, 10);
    log(`AUTHORIZE feishu client_id=${url.searchParams.get("client_id")} state=${state.slice(0, 12)}…`);
    html(
      res,
      page({
        title: "飞书授权登录",
        badge: "飞书",
        accent: ACCENTS.feishu,
        subject: "企业管理系统 申请获取你的飞书账号信息",
        qr: true,
        state,
        buttons: callbackButtons(redirectUri, state, nonce),
      }),
    );
    return;
  }

  if (host === "accounts.feishu.cn" && url.pathname === "/oauth/v3/token") {
    const raw = await readBody(req);
    const form = new URLSearchParams(raw);
    const code = form.get("code") ?? "";
    log(`TOKEN feishu client_id=${form.get("client_id")} code=${code}`);
    if (form.get("client_id") !== FEISHU_APP_ID || form.get("client_secret") !== FEISHU_APP_SECRET) {
      json(res, 400, { code: 20001, error: "invalid_client", error_description: "client 不匹配" });
      return;
    }
    const identity = identityFromCode("feishu", code);
    if (!identity || usedCodes.has(code)) {
      log(`TOKEN feishu rejected${usedCodes.has(code) ? " (replay)" : ""} code=${code}`);
      json(res, 400, { code: 20065, error: "invalid_code", error_description: "code 不合法" });
      return;
    }
    usedCodes.add(code);
    const accessToken = `mock-feishu-uat-${++tokenSeq}`;
    tokens.set(accessToken, identity);
    json(res, 200, { code: 0, access_token: accessToken, token_type: "Bearer", expires_in: 7200 });
    return;
  }

  if (host === "open.feishu.cn" && url.pathname === "/open-apis/authen/v1/user_info") {
    const token = (req.headers.authorization ?? "").replace(/^Bearer\s+/i, "");
    const identity = tokens.get(token);
    log(`USERINFO feishu token=${token} → ${identity ?? "invalid"}`);
    if (!identity) {
      json(res, 200, { code: 20005, msg: "invalid token" });
      return;
    }
    json(res, 200, { code: 0, msg: "success", data: { user_id: identity, name: "Mock 工程师", open_id: `ou_${identity}` } });
    return;
  }

  // ----- 企业微信 -----
  if (host === "open.work.weixin.qq.com" && url.pathname === "/wwopen/sso/qrConnect") {
    const redirectUri = url.searchParams.get("redirect_uri") ?? "";
    const state = url.searchParams.get("state") ?? "";
    const nonce = Math.random().toString(36).slice(2, 10);
    log(`QRCONNECT wecom appid=${url.searchParams.get("appid")} agentid=${url.searchParams.get("agentid")} state=${state.slice(0, 12)}…`);
    html(
      res,
      page({
        title: "企业微信扫码登录",
        badge: "企业微信",
        accent: ACCENTS.wecom,
        subject: "企业管理系统 申请获取你的企业微信身份",
        qr: true,
        state,
        buttons: callbackButtons(redirectUri, state, nonce),
      }),
    );
    return;
  }

  if (host === "qyapi.weixin.qq.com" && url.pathname === "/cgi-bin/gettoken") {
    wecomTokenSeq += 1;
    log(`GETTOKEN wecom count=${wecomTokenSeq} corpid=${url.searchParams.get("corpid")}`);
    if (url.searchParams.get("corpid") !== WECOM_CORP_ID || url.searchParams.get("corpsecret") !== WECOM_SECRET) {
      json(res, 200, { errcode: 40013, errmsg: "invalid corpid or secret" });
      return;
    }
    json(res, 200, { errcode: 0, errmsg: "ok", access_token: `mock-wecom-token-${wecomTokenSeq}`, expires_in: 7200 });
    return;
  }

  if (host === "qyapi.weixin.qq.com" && url.pathname === "/cgi-bin/auth/getuserinfo") {
    const token = url.searchParams.get("access_token") ?? "";
    const code = url.searchParams.get("code") ?? "";
    log(`USERINFO wecom token=${token} code=${code}`);
    if (!/^mock-wecom-token-\d+$/.test(token)) {
      json(res, 200, { errcode: 40014, errmsg: "invalid access_token" });
      return;
    }
    const identity = identityFromCode("wecom", code);
    if (!identity || usedCodes.has(code)) {
      log(`USERINFO wecom rejected${usedCodes.has(code) ? " (replay)" : ""} code=${code}`);
      json(res, 200, { errcode: 40029, errmsg: "invalid code" });
      return;
    }
    usedCodes.add(code);
    json(res, 200, { errcode: 0, errmsg: "ok", userid: identity });
    return;
  }

  json(res, 404, { code: 404, msg: "not found", errcode: 404 });
});

server.listen(443, "0.0.0.0", () => {
  log("mock im/007 listening on 0.0.0.0:443");
  console.log("mock im/007 listening on https://0.0.0.0:443");
});
