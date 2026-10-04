# im/003 验证证据（飞书移动端免登 · H5 内嵌）

本目录产物由 `verify.mjs`（Playwright + Chromium，模拟飞书 WebView UA）生成：

```bash
NODE_PATH=$(npm root -g) node docs/evidence/im-003/verify.mjs
```

前置（脚本头部注释有完整版）：本地 Supabase + `npm run dev`（:3000）；另需临时写入一组「假」飞书凭据，仅为让 `/auth/im/feishu/start` 能构造授权 URL（验证完应删除）：

```sql
select public.im_upsert_config('feishu',
  '{"app_id":"cli_mock_im003","app_secret":"local-mock-secret"}'::jsonb, true);
```

| 文件 | 场景 |
|---|---|
| `01-feishu-ua-auto-login.har` | 网络轨迹：`GET /report?range=month` → 307 `/auth/im/feishu/start`（写 `im_h5_redirect_to`）→ 307 `accounts.feishu.cn/.../authorize` |
| `01-feishu-ua-auto-redirect.png` | 飞书 UA 打开受保护页：全程无登录页，直达飞书授权页 |
| `02-im-not-bound-fallback.png` | 免登失败（未绑定）→ `/login?error=im_not_bound&_im_fallback=1` toast 提示，`im_h5_fallback=1` |
| `03-loop-guard-fallback.png` | 连续两次失败（`im_h5_fallback=2`）后再开链接 → 直接 `/login?_im_fallback=1`，不再自动免登 |
| `04-chrome-ua-unaffected.png` | Chrome UA（非飞书）→ `GET /report` 307 `/login`，UA 探测不生效 |
| `05-redirect-to-target.png` | 已登录（真实 Supabase 会话）+ `im_h5_redirect_to=/dashboard` → 落地 `/dashboard`，cookie 一次性消费 |

## 关键结果（脚本 stdout）

```
[01] 导航序列: 307 /report?range=month  ->  307 /auth/im/feishu/start  ->  200 https://accounts.feishu.cn/open-apis/authen/v1/authorize
[02] 导航序列: 307 /login?error=im_not_bound  ->  200 /login?error=im_not_bound&_im_fallback=1 | im_h5_fallback = 1
[03] 导航序列: 307 /report  ->  200 /login?_im_fallback=1
[04] 导航序列: 307 /report  ->  200 /login
[05] 导航序列: 307 /  ->  200 /dashboard | redirect cookie 已消费: true
```

## 证据边界

- 01 的授权页渲染由本地 HTTPS mock 替身完成（Chromium `--host-resolver-rules` 把 `accounts.feishu.cn` 映射到本机，仅测试浏览器进程内生效）；**302 链、state cookie、IM 路由均为真实链路**。
- 「飞书 App 内静默授权 → 回调签发会话 → 直接进工作台」需要真实飞书测试应用（App 内登录态 + 应用发布），见 PR「待人工复验」小节。
- 本单不改飞书 OAuth 协议实现（复用 im/002 的 `im_start_auth` / `im_handle_callback`），授权 URL 仍为 `accounts.feishu.cn/open-apis/authen/v1/authorize`（工单中的 `open.feishu.cn` 为旧版域名，im/002 已按现行文档实现，同 PR #8 备注）。
