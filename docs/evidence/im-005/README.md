# im/005 验证证据（本地 mock 钉钉端点）

本目录截图来自 **本地全链路验证**（工单 im/005）：

- 应用：本地 `next dev`（本分支代码，端口 3001）+ 本地 Supabase（真实 Auth / RLS / `audit_logins`）
- 钉钉端点：本地 HTTPS mock（`login.dingtalk.com` / `api.dingtalk.com` 经 hosts 解析到本机，
  仅存在于验证机器，未入库；server 源码见本目录 `mock-server.mjs`）：
  - `oauth2/auth` → PC 扫码 / 端内免登授权页（同一端点，按 UA 渲染两种形态）
  - `oauth2/userAccessToken` → code 换 user accessToken（JSON body，校验 clientId/clientSecret）
  - `contact/users/me` → 返回 `unionId` / `openId`（authCode 单次、token 映射身份）
- 出站可达性：Postgres 容器内 `/etc/hosts` 指向宿主机 + 自签证书追加容器 CA bundle
  （**仅验证环境**；生产为公网真实端点）
- 测试账号：`engineer@example.com` 绑定 mock unionId `ding_mock_union_bound`；未绑定码映射
  `ding_mock_union_unbound`
- 配置：`im_auth_configs.enabled = dingtalk`（凭据 `app_key=ding_mock_client` /
  `app_secret=mock_dingtalk_secret`，与 im/006 配置页同键）

| 文件 | 场景 |
|---|---|
| 00-login-scan-tab-dingtalk.png | 切换 `enabled=dingtalk` 后登录页出现「钉钉扫码登录」Tab |
| 01-dingtalk-auth-mock-pc.png | PC 扫码授权页（本地 mock；真实环境为钉钉统一登录页 + 二维码） |
| 02-pc-callback-success.png | 已绑定用户 PC 扫码 → 回调签发 session → 工作台（engineer） |
| 03-im-not-bound.png | 未绑定用户 → 拒绝 + toast「未绑定钉钉账号，请联系管理员」 |
| 04-dingtalk-webview-auto-login.png | 钉钉端内 UA 打开受保护页 → 自动免登（无登录页）；state `m.` 前缀可见 |
| 05-webview-callback-success.png | 端内确认授权 → 回调签发 session → 跳回免登前原目标 `/dashboard` |
| 06-audit-logins.png | `/audit/logins`：PC 成功 / 未绑定失败 / 端内免登成功 |

## mock 请求日志（节选）

```text
AUTHORIZE mode=pc client_id=ding_mock_client scope=openid prompt=consent
POST https://api.dingtalk.com/v1.0/oauth2/userAccessToken
TOKEN client_id=ding_mock_client grant_type=authorization_code code=mock-bound-…
TOKEN issued access_token=… unionId=ding_mock_union_bound
GET https://api.dingtalk.com/v1.0/contact/users/me
USERINFO token=…
AUTHORIZE mode=webview client_id=ding_mock_client scope=openid prompt=consent
TOKEN client_id=ding_mock_client grant_type=authorization_code code=mock-bound-…
TOKEN issued access_token=… unionId=ding_mock_union_bound
```

PC 与端内两条链路仅授权页 UA 模式不同（`pc` / `webview`），code→token→unionId 完全一致；
回调参数为钉钉实际的 `authCode`（Next.js 侧 `code ?? authCode` 兼容，见 `src/lib/im/callback.ts`）。

## 审计证据

```text
select via, success, im_userid, fail_reason from public.audit_logins where via='im_dingtalk' order by id desc limit 3;
 im_dingtalk | t | ding_mock_union_bound   |
 im_dingtalk | f | ding_mock_union_unbound | im_not_bound
 im_dingtalk | t | ding_mock_union_bound   |
```

## 绑定键

`contact/users/me` 返回 `unionId`（本系统绑定键）与 `openId`（仅应用内唯一，不采用）；
新版接口不返回 userid —— 取 userid 需应用级 access_token + 通讯录权限，属另一条链路。
理由与取舍见迁移 `supabase/migrations/20261006170000_im_dingtalk_login.sql` 头部注释。

## pgTAP

`supabase/tests/im_dingtalk_login_test.sql`：50 断言 —— 两薄包装签名不变 / `app.im_dingtalk_*`
零 API 角色授权 / 授权 URL（PC 与 state `m.` 前缀精确匹配、secret 不出 URL、`app_key` 与
`client_id` 别名）/ 响应解析与错误映射 / 预绑定匹配（命中 / 未绑定 / 停用）/ 未启用
`im_unavailable` / `via=im_dingtalk` 留痕。

- `supabase db reset && supabase test db`：**69 文件 4021 断言全绿**（本分支迁移）
- 并发共存验证：叠加 im/006 未合入迁移 `20261006180000_im_config_ui.sql` 后
  **70 文件 4091 断言全绿**（含其 `im_config_ui_test.sql`；凭据键 `app_key`/`app_secret` 对齐）

> 说明：真实钉钉测试企业的扫码与端内免登截图待人工复验（需在 <https://open-dev.dingtalk.com/>
> 创建企业内部应用，配置回调域名与「通讯录个人信息读权限」）。mock 仅替代钉钉三个端点，
> 其余链路（state 校验、凭据解密、绑定匹配、Supabase 会话签发、审计写入）与生产完全一致。

## 本地复现步骤

1. 启动 mock：`node docs/evidence/im-005/mock-server.mjs`（host 443；自签证书随目录生成说明见脚本头注释）。
2. DB 容器注入解析与信任（验证机专属）：
   `docker cp cert.pem supabase_db_<ref>:/tmp/dingtalk-mock.crt`；
   追加到 `/etc/ssl/certs/ca-certificates.crt`；`/etc/hosts` 增加 `<宿主IP> api.dingtalk.com login.dingtalk.com`。
3. 启用钉钉并绑定（SQL Editor 以 admin 身份）：
   `select public.im_upsert_config('dingtalk','{"app_key":"ding_mock_client","app_secret":"mock_dingtalk_secret"}'::jsonb,true);`
   `select public.im_admin_set_userid((select id from public.profiles where email='engineer@example.com'),'dingtalk','ding_mock_union_bound');`
4. `NEXT_PUBLIC_IM_CALLBACK_BASE=http://localhost:3001 npm run dev -- -p 3001`；
   `NODE_PATH=$(npm root -g) node docs/evidence/im-005/verify.mjs`。
