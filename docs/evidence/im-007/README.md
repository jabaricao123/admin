# im/007 验证证据（PC 扫码真二维码 · 本地 mock 三家厂商）

本目录截图来自 **本地全链路验证**（工单 im/007，修复复审 B1「手机扫 PC 二维码必然
`im_state_invalid`」）：

- 应用：本地 `next dev`（本分支代码，端口 3001）+ 本地 Supabase（真实 Auth / RLS /
  `im_qr_tickets` / `audit_logins`）；
- 三家厂商端点：本地 HTTPS mock（`login.dingtalk.com` / `api.dingtalk.com` /
  `accounts.feishu.cn` / `open.feishu.cn` / `open.work.weixin.qq.com` / `qyapi.weixin.qq.com`
  经 hosts 解析到本机，仅存在于验证机器，未入库；源码见本目录 `mock-server.mjs`）；
- 出站可达性：Postgres 容器内 `/etc/hosts` 指向宿主机 + 自签证书追加容器 CA bundle
  （**仅验证环境**；生产为公网真实端点）；
- 测试账号：`engineer@example.com` 分别绑定三家 mock userid
  （`ding_mock_union_bound` / `feishu_mock_bound` / `wecom_mock_bound`）；
  未绑定模拟码映射 `*_unbound`；
- 配置：`im_auth_configs.enabled` 随场景切换（凭据与 im/006 配置页同键）。

## 截图

| 文件 | 场景 |
|---|---|
| `10-pc-qr.png` | **PC 二维码页**：钉钉启用时 `/login` 扫码 Tab 渲染真二维码（qrcode.react，内容为授权 URL + `state=qr.<ticket>`；脚本用 jsQR 解码并与 RPC 返回的授权 URL 比对一致） |
| `10-phone-confirm.png` | **手机确认页**：手机浏览器打开二维码指向的钉钉授权页（本地 mock；真实环境为钉钉统一登录页 + App 内确认） |
| `10-phone-success.png` | **手机端「扫码成功」**：回调标记 ticket `logged_in`，手机看到「请在电脑上继续完成登录」 |
| `10-pc-after.png` | **PC 自动跳转后**：手机确认 → PC 轮询（1s）→ `/auth/qr/exchange` 一次性换 session → 工作台（实测 1317ms，无需刷新） |
| `20-pc-qr.png` / `20-phone-*.png` / `20-pc-after.png` | 飞书链路（同一 ticket 机制；PC 二维码同样经 jsQR 解码校验） |
| `30-pc-qr-wecom-iframe.png` | 企业微信链路：`wwopen/sso/qrConnect` 官方托管页以 `<iframe>` 内嵌（含「新窗口打开」兜底链接） |
| `31-wecom-qrconnect-callback.png` | 授权完成由 qrConnect 页回调本系统（iframe 内渲染「扫码成功」，主页面轮询后跳转） |
| `32-pc-after-wecom.png` | 企业微信 PC 自动跳转工作台（实测 957ms） |
| `40-phone-not-bound.png` | 未绑定用户手机端拒绝页（「未绑定钉钉账号，请联系管理员」） |
| `41-pc-not-bound.png` | **PC 端收到 `im_not_bound` 原因**：ticket 已作废（`expired` + `fail_reason`），轮询把原因透出到扫码面板 + 管理员联系方式 |
| `50-webview-cookie-path.png` | **回归**：钉钉端内 WebView 免登（同浏览器 state cookie 路径）不受影响，最终回到 `/dashboard` |
| `60-audit-logins.png` | `/audit/logins`：三家 `via=im_*` 成功 / 未绑定失败留痕 |

## 关键链路（脚本输出）

```text
[dingtalk] 二维码解码 = 授权 URL（state=qr.5ca2097f…）✓
[dingtalk] 手机确认 → PC 工作台 1317ms；PC 导航: 200 /login -> 307 /auth/qr/exchange -> 200 / -> 200 /dashboard
[feishu]   二维码解码 = 授权 URL（state=qr.320fba00…）✓
[feishu]   手机确认 → PC 工作台 1348ms；PC 导航: 200 /login -> 307 /auth/qr/exchange -> 200 / -> 200 /dashboard
[wecom]    qrConnect 回调 → PC 工作台 957ms；PC 导航: 200 /login -> 200 https://open.work.weixin.qq.com/wwopen/sso/qrConnect -> 200 /auth/callback/wecom -> 307 /auth/qr/exchange -> 200 / -> 200 /dashboard
[not_bound] 手机端拒绝 + PC 端展示未绑定原因（ticket 已作废）✓
[回归]     钉钉端内免登（state cookie 路径）最终 URL: http://localhost:3001/dashboard
```

## mock 请求日志（节选）

```text
AUTHORIZE dingtalk mode=pc client_id=ding_mock_client state=qr.5ca2097f…
POST https://api.dingtalk.com/v1.0/oauth2/userAccessToken
TOKEN dingtalk client_id=ding_mock_client code=mock-bound-…
USERINFO dingtalk token=… → ding_mock_union_bound
AUTHORIZE dingtalk mode=pc client_id=ding_mock_client state=qr.14c5c5a8…
TOKEN dingtalk client_id=ding_mock_client code=mock-unbound-…
USERINFO dingtalk token=… → ding_mock_union_unbound
QRCONNECT wecom appid=ww_mock_corp agentid=1000002 state=qr.edf6af2a…
GETTOKEN wecom count=1 corpid=ww_mock_corp
USERINFO wecom token=… code=mock-bound-…
```

## 审计证据

```text
select via, success, im_userid, fail_reason from public.audit_logins where via like 'im_%' order by id desc limit 4;
 im_dingtalk | t | ding_mock_union_bound   |
 im_dingtalk | f | ding_mock_union_unbound | im_not_bound
 im_wecom    | t | wecom_mock_bound        |
 im_feishu   | t | feishu_mock_bound       |
```

ticket 终态（含未绑定作废与一次性消费）：

```text
select provider, status, count(*) from public.im_qr_tickets group by 1,2;
 dingtalk | consumed | 2
 dingtalk | expired  | 2   <- 未绑定拒绝即作废（fail_reason=im_not_bound）
 feishu   | consumed | 2
 wecom    | consumed | 2
```

## pgTAP

`supabase/tests/im_qr_ticket_test.sql`：69 断言 —— 表 / RLS / 零 API 角色授权；
4 个 RPC 的 SECURITY DEFINER + GRANT 面（start / poll → anon，complete / exchange →
im_backend，service_role 零路径）；两薄包装签名未变；ticket 生成（格式 / state=ticket /
secret 不出 URL / +5 分钟 / 清理旧行）；轮询只回状态与原因；`logged_in` 原子标记；
exchange 一次性（重放 / 未确认 / 过期全拒）；未绑定 / 取消作废语义；
`im_qr_complete_login` 的参数校验与「未启用 → im_unavailable（不出站）」路径。

- `supabase db reset && supabase test db`：**71 文件 4160 断言全绿**（本分支含新迁移与新测试）
- 厂商出站成功路径不在 pgTAP（本地栈无外网 mock）：由本目录 mock 全链路证据覆盖

## 本地复现步骤

1. 生成 mock 证书（SAN 见 `mock-server.mjs` 文件头），启动 mock：

   ```bash
   cd /tmp/opencode/im-007-mock && IM007_CERT_DIR=$(pwd) node <repo>/docs/evidence/im-007/mock-server.mjs
   ```

2. DB 容器注入解析与信任（验证机专属）：

   ```bash
   C=supabase_db_<ref>
   docker cp cert.pem $C:/tmp/im007-mock.crt
   docker exec $C sh -c 'cat /tmp/im007-mock.crt >> /etc/ssl/certs/ca-certificates.crt'
   docker exec $C sh -c 'printf "172.17.0.1 accounts.feishu.cn open.feishu.cn open.work.weixin.qq.com qyapi.weixin.qq.com login.dingtalk.com api.dingtalk.com\n" >> /etc/hosts'
   ```

3. 启动应用并运行验证：

   ```bash
   NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321 \
   NEXT_PUBLIC_IM_CALLBACK_BASE=http://localhost:3001 \
     npm run dev -- -p 3001

   NODE_PATH=$(npm root -g):/tmp/opencode/im-007-verify/node_modules \
     node docs/evidence/im-007/verify.mjs
   ```

   （验证脚本依赖 `playwright` / `chromium`；二维码解码依赖 `jsqr` + `pngjs`。）

> 说明：真实厂商测试企业的扫码与「App 内确认」截图待人工复验（需配置真实回调域名 /
> 可信域名）。mock 仅替代厂商端点，ticket 生成 / 轮询 / 分发 / 作废 / 一次性消费 /
> Supabase 会话签发 / 审计写入均与生产完全一致。
