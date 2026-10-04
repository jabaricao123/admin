# 企业管理系统（admin）

企业内部管理系统，技术栈：Next.js 16 + shadcn/ui（Tailwind CSS 4）+ Supabase。

详细设计见 [DESIGN.md](DESIGN.md)，产品背景见 [PRODUCT.md](PRODUCT.md)。

## 快速开始

项目连接 Supabase 远端项目（project ref：`mnhtuekkxiqsseoesjfn`）。

```bash
# 1. 安装依赖
npm install

# 2. 配置环境变量（复制后填入远端项目的 anon key）
cp .env.example .env.local

# 3. 启动
npm run dev
```

打开 http://localhost:3000 ，使用测试账号登录：

| 账号 | 密码 | 角色 |
|---|---|---|
| admin@example.com | admin123 | 管理员 |
| engineer@example.com | engineer123 | 工程师 |
| buyer@example.com | buyer123 | 采购员 |
| planner@example.com | planner123 | 计划员 |

## 常用命令

| 命令 | 说明 |
|---|---|
| `npm run dev` | 启动开发服务器 |
| `npm run build` | 生产构建 |
| `npm run db:types` | 生成数据库 TS 类型 |

> 本地 Supabase（`db:start` / `db:reset` 等脚本与 `supabase/` 目录）为可选备用方案，当前默认使用远端。

## 目录结构

```text
src/
├── app/
│   ├── (admin)/          # 后台（需登录）：工作台、/org/users 用户管理
│   ├── login/            # 登录页
│   ├── layout.tsx        # 根布局：Geist 字体 / 主题 / Toaster
│   └── globals.css       # Tailwind 4 + CJT 品牌主题 token
├── components/           # 业务组件 + ui/（shadcn 组件）
├── hooks/                # 通用 hooks
├── lib/
│   ├── supabase/         # client / server / proxy（@supabase/ssr）
│   ├── im/               # IM 登录：厂商注册表（feishu/wecom/dingtalk）+ 回调编排 + state
│   ├── dictionaries.ts   # 角色 / 状态字典
│   └── database.types.ts # supabase gen types 产物
└── proxy.ts              # Next.js 16 网络边界：会话续期 + 登录拦截
supabase/
├── config.toml           # 本地 Supabase 配置
├── migrations/           # 数据库迁移
└── seed.sql              # 本地种子数据
```

## 进度

**已完成**：

- [x] 脚手架、Supabase 远端接入（@supabase/ssr 双客户端）、登录与后台守卫
- [x] 数据库基线：`profiles` 用户档案、角色枚举、RLS 与授权收紧（`supabase/migrations/`）
- [x] 工作台（统计卡片 / 注册趋势 / 最近更新）+ 用户管理（列表 / 搜索 / 筛选 / 角色分配 / 启停用，仅管理员）
- [x] 设计评审与修复：对比度、移动导航、追溯护栏（`updated_by`）、断点、错误边界
- [x] IM 扫码登录（飞书，im/002）：`/login` 扫码 Tab、OAuth 全链路、未绑定拒绝留痕、state 防代扫
- [x] 企业微信扫码 + App 内免登（im/004）：PC `qrConnect`、App 内 `oauth2/authorize`（免登）、access_token 加密缓存、两薄包装按厂商分派
- [x] 钉钉扫码 + WebView 免登（im/005）：PC 与端内同一 `oauth2/auth` 授权端点、绑定键取 `unionId`、两薄包装按厂商分派（签名不变）

## 权限模型速览

- 角色唯一来源：`public.profiles.role`（RLS 直接读取，不依赖 JWT 声明）
- 角色变更：仅管理员可调 `admin_update_profile` RPC；不能修改自己的角色、不能停用自己
- 菜单可见性：用户管理菜单仅管理员可见；页面内服务端二次校验角色
- 新建用户：后续提供邀请流程；当前可在 Supabase Dashboard 创建（或 Admin API），再到用户管理页分配角色

## IM 扫码登录（飞书 / 企业微信 / 钉钉）

登录页「扫码登录」Tab 走当前启用厂商的 OAuth（`im_auth_configs.enabled` 部署级单选，切换即生效）：已绑定用户完成授权后由后端签发标准 Supabase session（与密码登录同一会话 / RLS / 登出链路，ADR-003）。厂商凭据解密、授权 URL 构造、code 换 token、userinfo 与绑定匹配全部在 Postgres 内完成（`im_start_auth` / `im_handle_callback` 按厂商分派）：**厂商 secret 不出库，全链路不使用 service_role**（INDEX 规则 10 / ADR-001）。

- 飞书（im/002）：PC 扫码；App 内 H5 免登见 im/003。
- 企业微信（im/004）：PC 扫码（`wwopen/sso/qrConnect`）与 App 内免登（`oauth2/authorize`，`scope=snsapi_privateinfo`）。
- 钉钉（im/005）：PC 扫码与端内 WebView 免登共用 `login.dingtalk.com/oauth2/auth`（`scope=openid`、`prompt=consent`）；绑定键取 `unionId`（见下）。

### 部署硬前提

| 项 | 要求 |
|---|---|
| `NEXT_PUBLIC_IM_CALLBACK_BASE` | 公网可达的 HTTPS 域名（如 `https://admin.example.com`），回调地址为 `<base>/auth/callback/<provider>`（`feishu` / `wecom` / `dingtalk`） |
| `IM_BACKEND_JWT` | role=`im_backend` 的最小角色 JWT（仅可执行两个 IM 包装 RPC），签发方式见下节 |
| 飞书开发者后台 | 该回调地址需登记在「安全设置 → 重定向 URL」白名单中（精确匹配） |
| 企业微信管理后台 | 「企业微信授权登录 → Web 网页」授权回调域 + 「网页授权及 JS-SDK」可信域名均需包含 `NEXT_PUBLIC_IM_CALLBACK_BASE` 域名（见企业微信配置步骤） |
| 钉钉开发者后台 | 「钉钉登录与分享 → 回调域名」需包含 `<NEXT_PUBLIC_IM_CALLBACK_BASE>/auth/callback/dingtalk`（见钉钉配置步骤） |
| 多实例部署 | state 落 httpOnly cookie（无 Redis）；多副本共享同一域名时需 sticky session，或后续升级为 Redis 存储 |

### IM 后端最小角色（im_backend）

两个包装 RPC 仅授权给数据库最小角色 `im_backend`（nologin、非 BYPASSRLS、无任何表权限）；部署方用项目 JWT secret **离线签发**该角色 JWT：

```bash
SUPABASE_JWT_SECRET=<Dashboard → Project Settings → API → JWT secret> \
  npm run im:backend-token        # 默认约 10 年；可传有效期秒数
```

把输出配置为部署环境变量 `IM_BACKEND_JWT`（JWT secret 只用于签发、绝不进应用运行时）。本地开发用 `supabase status` 的 JWT secret 签发后写入 `.env.local`。轮换：重新签发 → 更新环境变量 → 重启部署。


### 飞书开放平台配置步骤

1. 打开 <https://open.feishu.cn/app>，创建「企业自建应用」。
2. 「凭据与基础信息」获取 App ID / App Secret。
3. 「安全设置 → 重定向 URL」添加 `<NEXT_PUBLIC_IM_CALLBACK_BASE>/auth/callback/feishu`。
4. 「权限管理」申请 `contact:user.employee_id:readonly`（`user_info` 返回 `user_id` 的前提，绑定匹配键即 `user_id`）。
5. 创建版本并发布，确保测试账号在企业内可用该应用。
6. 系统侧写入凭据（经 `im_upsert_config` 加密存储）与用户绑定：

```sql
-- Supabase SQL Editor 以管理员身份执行（临时通道；im/006 将提供配置页）
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select id::text from public.profiles where role = 'admin' limit 1),
    'role', 'authenticated'
  )::text,
  true
);
select public.im_upsert_config(
  'feishu',
  '{"app_id":"cli_xxx","app_secret":"yyy"}'::jsonb,
  true  -- 启用飞书（全局单选取代其他厂商）
);
select public.im_admin_set_userid(
  (select id from public.profiles where email = 'user@example.com'),
  'feishu',
  '飞书 user_id'
);
```

### 飞书工作台应用（移动端免登）

飞书 App 内打开的 H5 链接（工作台 / 群聊 / 消息卡片）由 `src/proxy.ts` 按 UA（含 `Lark` / `Feishu`）识别为内嵌 WebView：未登录时自动跳 `/auth/im/feishu/start`，飞书已登录用户被静默授权后直接进入系统，不出现登录页。免登失败（未绑定 / 取消授权等）降级 `/login?error=im_*&_im_fallback=1` 并展示原因；连续两次失败后（30 分钟内）不再自动重试，成功登录后失败计数清除。Safari / Chrome 等外部浏览器 UA 不含 Lark / Feishu，不受影响，仍走密码 / 扫码登录。

把系统挂到飞书工作台，需在「企业自建应用」上补充以下配置（飞书开放平台 / 管理后台操作，非代码配置）：

| 配置项 | 位置 | 值 |
|---|---|---|
| 网页应用（H5）能力 | 开放平台 → 应用详情 → 添加应用能力 | 开启「网页应用」 |
| 应用首页 URL | 开放平台 → 网页应用 → 移动端 / 桌面端首页 | `<NEXT_PUBLIC_IM_CALLBACK_BASE>/` |
| 重定向 URL | 安全设置 → 重定向 URL | `<NEXT_PUBLIC_IM_CALLBACK_BASE>/auth/callback/feishu`（精确匹配，与扫码共用） |
| H5 可信域名 | 安全设置 → H5 可信域名 | `<NEXT_PUBLIC_IM_CALLBACK_BASE>` 的域名（不带协议与路径） |
| IP 白名单 | 安全设置 → IP 白名单 | 如开启：加入**数据库出口 IP**（code 换 token / userinfo 出站发生在 Postgres 内，见 ADR-004） |
| 工作台入口 | 管理后台 → 工作台 → 应用管理（或发布版本时勾选工作台） | 将应用添加到目标成员的工作台 |

> 免登不改变账号匹配规则（仍按 `profiles.feishu_userid` 预绑定，ADR-003 §1），未绑定用户不会被自动建号；上述配置项截图需在真实飞书后台操作时补充。
> 本地 / 预览环境验证：Chrome DevTools → Network conditions 把 UA 改成带 `Lark/7.x` 的值，或直接用 curl `-A`，观察受保护页面 302 到 `/auth/im/feishu/start`。

### 企业微信配置步骤（im/004）

1. 打开 <https://work.weixin.qq.com/>，用管理员企业微信扫码进入管理后台。
2. 「我的企业 → 企业信息」底部获取 **企业 ID（CorpID，`ww` / `wx` 开头）**。
3. 「应用管理 → 应用 → 自建 → 创建应用」；在应用详情获取 **AgentId** 与 **Secret**（Secret 仅显示一次，可重置）。
4. 应用详情「企业微信授权登录 → 设置」→「Web 网页」→ 授权回调域填 `NEXT_PUBLIC_IM_CALLBACK_BASE` 的域名（PC 扫码用；需精确到域名，如 `admin.example.com`）。
5. 应用详情「网页授权及 JS-SDK」→ 设置可信域名（App 内免登 `oauth2/authorize` 用；需按提示完成域名归属验证）。
6. 若企业在「应用管理 → 企业可信 IP」配置了白名单，需把**服务端出站 IP**（`gettoken` / `getuserinfo` 由 Postgres 发起，即数据库主机出站 IP）加入；未配置则跳过。
7. 确保参与登录的成员在应用可见范围内（`snsapi_privateinfo` 要求成员可见；`qrConnect` 扫码时不可见的成员会提示无权限）。
8. 系统侧写入凭据与用户绑定：

```sql
-- Supabase SQL Editor 以管理员身份执行（临时通道；im/006 将提供配置页）
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select id::text from public.profiles where role = 'admin' limit 1),
    'role', 'authenticated'
  )::text,
  true
);
select public.im_upsert_config(
  'wecom',
  '{"corp_id":"ww_xxx","agent_id":"1000002","secret":"yyy"}'::jsonb,
  true  -- 启用企业微信（全局单选取代其他厂商）
);
select public.im_admin_set_userid(
  (select id from public.profiles where email = 'user@example.com'),
  'wecom',
  '企业微信 userid'
);
```

> 关于 scope：本实现按工单指定使用 `snsapi_privateinfo`（属手动授权，成员首次需在企业微信内确认）。
> 若仅需 userid、要求完全静默，可改用 `snsapi_base`（改 `app.im_wecom_build_authorize_url` 中 scope 并同步 pgTAP）。

企业微信侧的 OAuth 细节（均由 Postgres 内完成，Next.js 不接触 secret）：

| 场景 | 端点 | 说明 |
|---|---|---|
| PC 扫码 | `open.work.weixin.qq.com/wwopen/sso/qrConnect` | `appid=corpid`、`agentid`、`redirect_uri`、`state` |
| App 内免登 | `open.weixin.qq.com/connect/oauth2/authorize` | `scope=snsapi_privateinfo` + `agentid` + `#wechat_redirect`；由 start 路由按 UA（含 `wxwork`）自动选择 |
| access_token | `qyapi.weixin.qq.com/cgi-bin/gettoken` | 按 `corp_id:sha256(secret)` 加密缓存 7200s，避免每次登录都换 token |
| code → userid | `qyapi.weixin.qq.com/cgi-bin/auth/getuserinfo` | 返回 `userid`（旧版 `user/getuserinfo` 的 `UserId` 同样兼容） |

### 钉钉配置步骤（im/005）

1. 打开 <https://open-dev.dingtalk.com/>，创建「企业内部应用」（H5 微应用 / 网页应用均可）。
2. 「凭证与基础信息」获取 **Client ID（旧称 AppKey）** 与 **Client Secret（旧称 AppSecret）**。
3. 「权限管理 → 个人权限」申请 **通讯录个人信息读权限（`Contact.User.Read`）**；权限范围选全部员工或目标成员。
4. 「钉钉登录与分享 → 回调域名」登记 `<NEXT_PUBLIC_IM_CALLBACK_BASE>/auth/callback/dingtalk`（`redirect_uri` 必须与登记地址一致）。
5. 发布 / 发布版本，确保参与登录的成员在应用可见范围内。
6. 若「开发管理」配置了**服务器出口 IP** 白名单，需加入数据库主机出站 IP（code 换 token / 取用户信息发生在 Postgres 内，ADR-004）。
7. 系统侧写入凭据与用户绑定：

```sql
-- Supabase SQL Editor 以管理员身份执行（临时通道；im/006 将提供配置页）
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select id::text from public.profiles where role = 'admin' limit 1),
    'role', 'authenticated'
  )::text,
  true
);
select public.im_upsert_config(
  'dingtalk',
  '{"app_key":"ding_xxx","app_secret":"yyy"}'::jsonb,
  true  -- 启用钉钉（全局单选取代其他厂商）
);
select public.im_admin_set_userid(
  (select id from public.profiles where email = 'user@example.com'),
  'dingtalk',
  '钉钉 unionId'
);
```

> **绑定键为 `unionId`**：新版钉钉 `contact/users/me`（userAccessToken 身份）不返回 userid；取 userid 需额外应用级凭据与通讯录权限。`unionId` 企业内唯一且稳定，`openId` 仅应用内唯一、不采用。详见迁移 `20261006170000_im_dingtalk_login.sql` 头部注释。
> **免登形态**：端内 WebView 打开系统时 `src/proxy.ts` 按 UA（含 `DingTalk`）自动跳授权链路；钉钉端内已登录，用户在授权页仅需确认（无需账号密码）。完全静默需接入钉钉授权组件 SDK（JSAPI `openAuth`），不在本系统「凭据不出库」的 HTTPS 出站模型内。

钉钉侧的 OAuth 细节（均由 Postgres 内完成，Next.js 不接触 secret）：

| 场景 | 端点 | 说明 |
|---|---|---|
| PC 扫码 / 端内免登 | `login.dingtalk.com/oauth2/auth` | `client_id`（= 配置的 `app_key`）+ `scope=openid` + `prompt=consent`；端内 / 端外同一端点，由 start 路由按 UA（含 `DingTalk`）标记 state `m.` |
| code → 用户 token | `api.dingtalk.com/v1.0/oauth2/userAccessToken` | JSON body `{clientId: app_key, clientSecret: app_secret, code, grantType}`；`expireIn` 7200s；**无缓存**（code 单次直换，无 client_credential 中间层） |
| 用户身份 | `api.dingtalk.com/v1.0/contact/users/me` | Header `x-acs-dingtalk-access-token`；取 `unionId` 作为 `profiles.dingtalk_userid`（`openId` 应用内唯一，不采用） |

> 凭据键与 im/006 配置页一致：`app_key` / `app_secret`（兼容别名 `client_id` / `client_secret` / `app_id` / `secret`）。

### 本地联调

- 飞书 / 企业微信 / 钉钉均要求回调公网可达：本地起 `cloudflared tunnel --url http://localhost:3000`（或 ngrok），把得到的 HTTPS 域名写入 `.env.local` 的 `NEXT_PUBLIC_IM_CALLBACK_BASE`，并在对应厂商后台登记回调域 / 可信域名。
- 本地栈还需 `IM_BACKEND_JWT`：用本地默认 JWT secret 签发后写入 `.env.local`：

```bash
# JWT secret 取 `supabase status` 显示的 JWT_SECRET（本地栈固定默认值）
SUPABASE_JWT_SECRET=<JWT_SECRET> \
  npm run im:backend-token   # 输出写入 .env.local 的 IM_BACKEND_JWT
```

- 登录页扫码开始前由服务端下发一次性 state（httpOnly cookie，5 分钟有效，读后作废）；登录成功 / 未绑定拒绝均落 `audit_logins`（`via='im_feishu'`，见 `/audit/logins`）。
