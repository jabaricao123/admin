# ADR-004: IM 登录凭据不出库与交互式出站运行时

- 状态：已采纳
- 日期：2026-10-05
- 背景：im/002 首版把「读凭据 + 构造授权 URL」放在 Next.js，靠 `im_get_provider_config`
  GRANT `service_role` 实现。该 GRANT 违反 docs/modules/INDEX.md 规则 10 与 ADR-001
  全局禁令（service_role = BYPASSRLS），验收退回。需要在「OAuth 回调必须同步拿到厂商响应」
  这一硬约束下，重新划定凭据与出站的信任边界。
- 关联：ADR-001（后台任务执行身份与出站运行时）、ADR-003（IM 登录接入形态）。

## 决策

### 1. 厂商凭据解密与 OAuth 交互全部下沉 Postgres

- 凭据读取（`app.im_provider_credentials`，内部调 `app.decrypt_secret`）、授权 URL 构造、
  code 换 token、userinfo 取 userid、预绑定匹配全部为 `SECURITY DEFINER` 函数；
- Next.js 只调两个公开薄包装：`public.im_start_auth`（返回授权 URL）、
  `public.im_handle_callback`（返回 `{ok,user_id,im_userid}` 或错误码）；
- **厂商 secret 不出 Postgres**，任何 API 角色（含 service_role）都没有读取路径。

### 2. 交互式出站用 `extensions.http`（同步）

- 登录回调必须在一次 RPC 内拿到厂商响应；ADR-001 的 pg_net + pg_cron 异步模型面向后台
  投递（webhook / 报表推送），不适用于交互式登录，二者按场景分工并存；
- pgsql-http 无默认超时，函数内收紧（连接 3s / 总 8s）；出站异常与厂商错误统一映射
  `im_failed`，detail 只含厂商 code/描述，不回显 secret。

### 3. 授权模型 = 专用最小角色 + SECURITY DEFINER 链

- 新建数据库角色 `im_backend`：nologin、非 superuser、非 BYPASSRLS、无任何表权限，
  仅 GRANT EXECUTE 两个薄包装；GRANT authenticator 以支持 PostgREST SET ROLE；
- Next.js 服务端用 role=`im_backend` 的 JWT（`IM_BACKEND_JWT`，离线签发）调用，
  apikey 走 anon；**service_role 零路径**（ADR-001）；
- `app.*` 实现函数零授权，仅由 definer 包装链式调用（调用者无需 app schema 权限）。

### 4. 会话签发仍按 ADR-003 §3

标准 Supabase session 仍由 Next.js 经 Auth Admin（generateLink + verifyOtp）签发；
service_role key 仅用于 Auth Admin（getUserById / generateLink），不再用于读取厂商凭据。
把签发下沉到数据库反而会把 service_role 写进库内，与 ADR-001 冲突，故不做。

## 考虑过的备选

| 备选 | 否决原因 |
|---|---|
| 方案 A：撤回 service_role，仅新角色执行 `im_get_provider_config`（secret 出库） | secret 仍离开 Postgres 到持有 im_backend token 的进程；token 泄露 = 凭据泄露，防御纵深弱于下沉 |
| 回调走 pg_net 异步两段式（路由轮询） | 需 flow 状态机 + 轮询 + 超时清理，交互延迟与失败面变大；同步 http 已满足且实现简单 |
| 在 DB 内经 GoTrue 直接签发 session | service_role key 需入库；ADR-003 已否决「自建 / 直签 session」 |

## 影响

- 新增迁移 `20261006153000_im_feishu_login.sql` §4/§5；im/004（企业微信）/ im/005（钉钉）
  在 SQL 内补厂商适配（URL / 表单 / userinfo 解析），注册表同步放开；
- 部署新增 `IM_BACKEND_JWT`（`npm run im:backend-token` 离线签发，轮换 = 重签 + 重启）；
- pgTAP 覆盖：角色属性（nologin / 非 bypassrls）、GRANT 面（service_role/anon/authenticated
  零路径，im_backend 仅两函数）、URL 无 secret、响应解析与错误映射；
- 真实出站成功路径由本地 mock 全链路验证（docs/evidence/im-002/README.md）。
