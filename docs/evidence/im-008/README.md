# im/008 验证证据（R3 钉钉绑定 authCode + R2 密码登录关闭留痕）

本目录截图来自**本地全链路验证**（工单 im/008）：

- 应用：本地 `next dev`（本分支代码，端口 3001，`NEXT_PUBLIC_IM_CALLBACK_BASE=http://localhost:3001`）
  + 本地 Supabase（真实 Auth / RLS / audit）
- 钉钉端点：本地 HTTPS mock（复用 `docs/evidence/im-005/mock-server.mjs`；`login.dingtalk.com` /
  `api.dingtalk.com` 经 hosts 解析到本机，仅存在于验证机器，未入库）
- 出站可达性：Postgres 容器内 hosts 指向宿主机 + mock 自签证书加入容器 CA
  （仅验证环境；生产为公网真实端点）
- 测试账号：`engineer@example.com`（工程师）；`admin@example.com`（管理员，应急名单）
- 配置：`im_auth_configs.enabled = dingtalk`（凭据 `app_key=ding_mock_client` /
  `app_secret=mock_dingtalk_secret`，与 im/005 同一 mock 端点）

## R3：钉钉端内扫码绑定（回调仅回传 `authCode`）

| 文件 | 场景 |
|---|---|
| 01-profile-unbound.png | 个人中心（钉钉端内 UA）：未绑定 + 「扫码绑定」按钮 |
| 02-dingtalk-mock-authorize.png | 授权页为端内形态（标题「钉钉端内免登授权」，state `m.` 前缀 = WebView 免登标记） |
| 03-profile-bound-via-authcode.png | 回调经 `authCode` 解析授权码 → `im_bind_self` → 已绑定 `ding_mock_union_unbound` |

导航序列（`bind-hops.log`，证明回调只带 `authCode`、无 `code`，且最终 307 到成功页）：

```text
200 /login
200 /settings/profile
307 /settings/profile/bind/dingtalk/start
200 https://login.dingtalk.com/oauth2/auth
307 /settings/profile/bind/dingtalk/callback?authCode=mock-unbound-8t4iq7dz&state=m.MGSKimHwUDo5aVWIs6DFKT39CJ2zO1t1KBswg6AE9TA.1791143612862
200 /settings/profile?bound=dingtalk
```

mock 请求日志（节选，`authCode` 单次换 token）：

```text
GET https://login.dingtalk.com/oauth2/auth → AUTHORIZE mode=webview client_id=ding_mock_client scope=openid prompt=consent
POST https://api.dingtalk.com/v1.0/oauth2/userAccessToken
TOKEN client_id=ding_mock_client grant_type=authorization_code code=mock-unbound-8t4iq7dz
TOKEN issued access_token=… unionId=ding_mock_union_unbound
GET https://api.dingtalk.com/v1.0/contact/users/me → USERINFO unionId=ding_mock_union_unbound
```

绑定结果（验证后已恢复基线，截图 03 为绑定成功时刻）：

```text
select email, dingtalk_userid from public.profiles where email='engineer@example.com';
     email              |     dingtalk_userid
------------------------+--------------------------
 engineer@example.com   | ding_mock_union_unbound
```

> 修复前：`code = searchParams.get("code")` 对 `authCode` 回调判空 → 直接 `?error=im_failed`；
> 修复后与登录链路（`src/lib/im/callback.ts:133`）一致，`code ?? authCode`。

## R2：密码登录关闭的被拒尝试留痕

关闭 `password_login_enabled`（应急名单仅 `admin@example.com`）后，`engineer@example.com`
经 `/login?admin=1` 输入正确密码：服务端签出 + 客户端写匿名失败留痕 + 提示「密码登录已关闭」。

| 文件 | 场景 |
|---|---|
| 04-password-disabled-denied.png | 非名单账号被拒：提示「密码登录已关闭，请使用扫码登录或联系管理员」 |
| 05-audit-logins-password-disabled.png | `/audit/logins`：该行失败原因为「密码登录已关闭」（`audit.ts` 新枚举文案） |

`audit_logins` 实查（新增行）：

```text
select id, email, success, fail_reason, via from public.audit_logins
 where fail_reason='password_login_disabled' order by id desc limit 5;
 id |        email         | success |       fail_reason       |   via
----+----------------------+---------+-------------------------+----------
 78 | engineer@example.com | f       | password_login_disabled | password
```

> 修复前：该分支只 `signOut` + `setError`，被拒尝试无任何留痕；修复后紧跟匿名
> `record_login_attempt(success=false, fail_reason='password_login_disabled')`
> （`src/components/login-form.tsx`），`src/lib/audit.ts` 同步新增展示文案。

## pgTAP

- `supabase/tests/im_config_ui_test.sql`（74 断言，含本单新增 4 条）：
  - R2：anon 可写 `password_login_disabled` 失败留痕 + 归档 `fail_reason` 断言；
  - S3：`auth.sessions` 表存在 + `id` 列存在（GoTrue 大版本升级哨兵）。
- `supabase db reset && supabase test db`：**70 文件 4095 断言全绿**（基线 4091 + 新增 4）。

## 本地复现

1. 钉钉 mock 与 DB 容器 hosts/CA：按 `docs/evidence/im-005/README.md` 步骤 1–2。
2. DB 启用钉钉 mock 凭据并保持 `engineer@example.com` 未绑定：

   ```sql
   select public.im_upsert_config('dingtalk','{"app_key":"ding_mock_client","app_secret":"mock_dingtalk_secret"}'::jsonb,false);
   select public.im_switch_provider('dingtalk');
   ```

3. `NEXT_PUBLIC_IM_CALLBACK_BASE=http://localhost:3001 npm run dev -- -p 3001`；
   运行 `NODE_PATH=$(npm root -g) node docs/evidence/im-008/verify.mjs bind`（R3）。
4. R2 前置：`password_login_enabled=false` 且应急名单含 `admin@example.com`；
   运行 `… verify.mjs r2`。

> 说明：mock 仅替代钉钉三个外呼端点，其余链路（state 校验、凭据解密、`authCode` 解析、
> `im_bind_self`、审计写入、`/audit/logins` 展示）与生产完全一致。真实钉钉企业内扫码待人工复验。
