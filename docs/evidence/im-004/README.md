# im/004 验证证据（本地 mock 企业微信端点）

本目录截图来自 **本地全链路验证**（工单 im/004）：

- 应用：本地 `next dev`（本分支代码，端口 3001）+ 本地 Supabase（真实 Auth / RLS / `audit_logins`）
- 企业微信端点：本地 HTTPS mock（`open.work.weixin.qq.com` / `open.weixin.qq.com` / `qyapi.weixin.qq.com`
  经 hosts 解析到本机，仅存在于验证机器，未入库）：
  - `wwopen/sso/qrConnect` → PC 扫码授权页
  - `connect/oauth2/authorize` → App 内免登授权页（`scope=snsapi_privateinfo`）
  - `cgi-bin/gettoken` → `access_token`（`expires_in=7200`；mock 记录调用次数以验证缓存）
  - `cgi-bin/auth/getuserinfo` → `{errcode:0,userid}`（授权码单次可用）
- 出站可达性：Postgres 容器内 `/etc/hosts` 指向宿主机 + 自签证书加入容器 CA 信任
  （**仅验证环境**；生产为公网真实端点）
- 测试账号：`engineer@example.com` 绑定 mock userid `wecom_mock_bound`；未绑定模拟码映射 `wecom_mock_unbound`
- 配置：`im_auth_configs.enabled = wecom`（凭据 `corp_id=ww_mock_corp` / `agent_id=1000002` / `secret=***`）

| 文件 | 场景 |
|---|---|
| 00-login-scan-tab-feishu.png | `enabled=feishu` 时扫码入口为「飞书扫码登录」 |
| 01-login-scan-tab-wecom.png | 切换 `enabled=wecom` 后入口自动变「企业微信扫码登录」（未改代码、未重启） |
| 02-wecom-qrconnect-mock.png | PC 扫码授权页（本地 mock；真实环境为企业微信托管二维码页） |
| 03-pc-callback-success.png | 已绑定用户 PC 扫码 → 回调签发 session → 工作台（engineer） |
| 04-im-not-bound.png | 未绑定用户 → 拒绝 + toast「未绑定企业微信账号，请联系管理员」 |
| 05-mobile-login-tab.png | 企业微信 App 内 UA（`wxwork`）打开登录页 |
| 06-wecom-oauth-mock.png | App 内免登授权页（state 以 `m.` 前缀标记；真实环境为企业微信 App 内授权页） |
| 07-mobile-callback-success.png | App 内免登 → 回调签发 session → 工作台（engineer） |
| 08-audit-logins.png | `/audit/logins`：PC 成功 / 未绑定失败 / 免登成功（`via=im_wecom`） |

## token 缓存证据

三次回调（PC 成功、未绑定、App 内免登成功）共发起 **1 次 `gettoken`、3 次 `getuserinfo`**
（同一 token 复用；mock 请求日志）：

```text
GETTOKEN count=2 corpid=ww_mock_corp           <- E2E 首次登录时获取
USERINFO token=mock-wecom-token-2 code=mock-bound-...    <- PC 扫码
USERINFO token=mock-wecom-token-2 code=mock-unbound-...  <- 未绑定拒绝
USERINFO token=mock-wecom-token-2 code=mock-bound-...    <- App 内免登
```

缓存行（`app.im_wecom_token_cache`：键含 secret sha256 指纹；token 为 `app.encrypt_secret` 密文）：

```text
cache_key = ww_mock_corp:e722a58c36accad3...c32036f
access_token::text not like '%mock-wecom-token%' = t   <- 密文落库
```

## 审计证据

```text
select via, success, im_userid, fail_reason from public.audit_logins where via='im_wecom';
 im_wecom | t | wecom_mock_bound   | -
 im_wecom | f | wecom_mock_unbound | im_not_bound
 im_wecom | t | wecom_mock_bound   | -
```

## pgTAP

`supabase/tests/im_wecom_login_test.sql`：63 断言（全量 68 文件 3971 断言通过）——
授权 URL（PC / 免登）/ secret 不出 URL / 响应解析与错误映射 / token 缓存（指纹、5 分钟余量、
过期、命中不出站）/ 预绑定匹配 / 未启用 `im_unavailable` / 两薄包装签名与授权面。

> 说明：真实企业微信测试企业的扫码与免登截图待人工复验（需在 <https://work.weixin.qq.com/>
> 创建测试企业与自建应用，并配置公网回调域名 / 可信域名）。mock 仅替代企业微信四个端点，
> 其余链路（state 校验、凭据解密、绑定匹配、Supabase 会话签发、审计写入、token 加解密缓存）
> 与生产完全一致。
