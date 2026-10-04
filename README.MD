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
│   ├── im/               # IM 登录：provider 抽象 + feishu 实现 + 回调编排 + state
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

## 权限模型速览

- 角色唯一来源：`public.profiles.role`（RLS 直接读取，不依赖 JWT 声明）
- 角色变更：仅管理员可调 `admin_update_profile` RPC；不能修改自己的角色、不能停用自己
- 菜单可见性：用户管理菜单仅管理员可见；页面内服务端二次校验角色
- 新建用户：后续提供邀请流程；当前可在 Supabase Dashboard 创建（或 Admin API），再到用户管理页分配角色

## IM 扫码登录（飞书）

登录页「扫码登录」Tab 走飞书 OAuth：已绑定用户扫码后由后端签发标准 Supabase session（与密码登录同一会话 / RLS / 登出链路，ADR-003）。

### 部署硬前提

| 项 | 要求 |
|---|---|
| `NEXT_PUBLIC_IM_CALLBACK_BASE` | 公网可达的 HTTPS 域名（如 `https://admin.example.com`），回调地址为 `<base>/auth/callback/feishu` |
| 飞书开发者后台 | 该回调地址需登记在「安全设置 → 重定向 URL」白名单中（精确匹配） |
| 多实例部署 | state 落 httpOnly cookie（无 Redis）；多副本共享同一域名时需 sticky session，或后续升级为 Redis 存储 |

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

### 本地联调

- 飞书要求回调公网可达：本地起 `cloudflared tunnel --url http://localhost:3000`（或 ngrok），把得到的 HTTPS 域名写入 `.env.local` 的 `NEXT_PUBLIC_IM_CALLBACK_BASE`，并在飞书后台登记回调地址。
- 登录页扫码开始前由服务端下发一次性 state（httpOnly cookie，5 分钟有效，读后作废）；登录成功 / 未绑定拒绝均落 `audit_logins`（`via='im_feishu'`，见 `/audit/logins`）。
