# CJTcable 企业管理系统实施计划

> 版本：v1.3 ｜ 日期：2026-10-04 ｜ 状态：待评审
> v1.1 变更：定位从"线缆行业 PLM"调整为"通用型 PLM"，行业差异通过数据字典与自定义属性适配。
> v1.2 变更：前端技术栈由 Refine + Ant Design 调整为 shadcn/ui（Tailwind CSS 4），沿用 Next.js App Router + Supabase。
> v1.3 变更：定位从"通用型 PLM"调整为"通用企业管理系统"（项目管理、采购协同、主数据、变更审批、对外门户），PLM 仅作为历史阶段术语保留。

---

## 1. 项目概述

### 1.1 背景

企业内部管理数据目前分散在 Excel 和纸质文件中。本系统目标是建立统一、受控、可追溯的通用企业管理平台，模块按业务优先级逐个接入；权限由数据库层（RLS）强制，变更全流程留痕。

### 1.2 目标

1. 数据统一：组织、用户及后续业务数据集中管理。
2. 权限受控：角色矩阵 + RLS 数据库层强制，前端不可信。
3. 可追溯：操作留痕、版本化、不物理删除。
4. 合规可审计：数据操作有审计日志。

### 1.3 范围（当前）

| 纳入 | 不纳入 |
|---|---|
| 登录认证、后台守卫 | ERP、MES 深度集成 |
| 工作台（统计/趋势/最近更新） | 报价核算、排产 |
| 用户管理（列表/搜索/角色分配/启停用） | 移动端原生 App（响应式 H5 覆盖） |
| 用户、角色、审计日志 | 多语言（先简体中文） |

后续模块（主数据、变更审批、对外门户等）另行立项时更新本章。

### 1.4 成功标准

- RLS 测试覆盖率 100%（每张表每条策略均有 pgTAP 用例）。
- 非管理员无法访问用户管理页面与数据（服务端二次校验 + RLS 双保险）。

---

## 2. 技术选型

| 层 | 选型 | 说明 |
|---|---|---|
| 前端框架 | Next.js 16（App Router）+ React 19 + TypeScript | 门户需要 SSR/SEO，后台服务端渲染 + 客户端交互 |
| UI 组件 | shadcn/ui（radix-nova style，Tailwind CSS 4） | 官方 blocks 提供成品后台布局与数据表格，不引入重 UI 框架 |
| 数据通道 | @supabase/ssr + supabase-js | 官方 Next.js SSR 集成，会话刷新在 src/proxy.ts |
| 后端 | Supabase 本地栈（Postgres、PostgREST、Auth、Storage、Realtime、Edge Functions） | 本地与云端 API 完全一致 |
| 本地开发 | Supabase CLI + Docker（本机已装 Docker 26） | `supabase start` 一键起全套 |
| 类型 | supabase gen types（TypeScript） | 数据库 schema → 前端类型，单一事实来源 |
| 校验 | Zod | 表单校验 + 共享 schema |
| 测试 | pgTAP（RLS/SQL）、Playwright（E2E） | 见第 10 章 |
| 部署 | 前端 Vercel 或 Docker+Nginx；后端 Supabase Cloud（备选自托管） | 见第 11 章 |

环境核查（2026-10-03）：

| 项 | 状态 |
|---|---|
| Node.js | 24.21.0 已装 |
| npm | 11.19.0 已装 |
| Docker | 26.1.5 已装 |
| Supabase CLI | 未安装（本地栈为备用方案） |
| 本地 Supabase 栈 | 未运行 |

---

## 3. 系统架构

```mermaid
flowchart LR
  subgraph Client["前端 Next.js 单应用"]
    A1["(admin) 内部后台<br/>shadcn/ui + 客户端交互"]
  end
  subgraph Supabase["Supabase 云端"]
    B1["Auth 认证"]
    B2["PostgREST / RPC"]
    B3["Postgres + RLS"]
  end
  A1 --> B1 & B2
  B2 --> B3
```

### 3.1 部署形态

单体单仓、单 Supabase 项目、单 Next.js 应用：

| 路由组 | 用户 | 渲染策略 | 框架 |
|---|---|---|---|
| `app/(admin)/*` | 内部员工 | 服务端页面 + 客户端交互组件 | Next.js + shadcn/ui |
| `app/login/*` | 全员 | 客户端 | — |

> `(portal)` 门户路由组为预留设计，模块立项时启用。

### 3.2 关键决策与理由

| 决策 | 理由 | 备选方案 |
|---|---|---|
| 单应用双路由组 | 共享类型、组件、Supabase 客户端，维护成本最低 | 双应用（Vite 后台 + Next 门户），隔离更强但同步成本高 |
| RLS 兜底权限 | 前端不可信；用户直接连数据库 API | 仅服务端 API 鉴权（无法覆盖 PostgREST 直连） |
| 变更留痕、版本化 | 历史可追溯 | 原地覆盖（不可追溯，否决） |

---

## 4. 数据模型（后端核心）

### 4.1 设计约定

- 表名、字段 snake_case，复数表名；主键统一 `id uuid default gen_random_uuid()`。
- 所有表含 `created_at`、`updated_at`（触发器维护）；含 `status`，不物理删除。
- 外键 `xxx_id`；编码类字段唯一约束；枚举用 Postgres enum。

### 4.2 枚举

| 枚举 | 取值 |
|---|---|
| user_role | admin, engineer, planner, buyer, quality, supplier, customer |
| org_type | supplier, customer |

### 4.3 核心表

| 表 | 用途 | 关键字段 |
|---|---|---|
| organizations | 外部组织（供应商/客户） | name, org_type, credit_code, contact_name, contact_phone |
| profiles | 用户档案（1:1 auth.users） | id(=auth.uid), full_name, department, role, organization_id, status |
| audit_logs | 审计日志 | table_name, record_id, action, changes jsonb, actor_id, created_at |

### 4.4 关系图

```mermaid
erDiagram
  organizations ||--o{ profiles : "外部用户归属"
```

> audit_logs 为多态关联，图中省略连线。

### 4.5 状态机

用户账号状态：`active`（在职）↔ `inactive`（停用）。不物理删除。

### 4.6 数据库函数（RPC）

| 函数 | 作用 | 调用方 |
|---|---|---|
| admin_update_profile | 管理员修改用户档案（含角色），带自保护约束 | 前端用户管理 |
| fn_audit_row() | 通用审计触发器函数 | 所有业务表 |
| fn_current_role() / fn_is_internal() | RLS 辅助（读取 profiles） | 所有策略 |
| fn_set_updated_at() | 维护 updated_at | 所有表 |

### 4.7 RLS 权限设计

原则：

1. 内部角色按角色矩阵读写；外部角色只能访问与自身组织关联的数据。
2. 所有策略用 `security definer` 辅助函数判断，避免策略内联子查询导致性能问题与循环。
3. 外部用户默认无任何表权限，逐一开放所需视图/表。

示例策略：

```sql
-- 辅助函数：当前用户角色
create or replace function public.current_role() returns public.user_role
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and status = 'active'
$$;
```

角色权限矩阵（当前）：

| 资源 | admin | engineer / planner / buyer / quality | supplier / customer |
|---|---|---|---|
| 用户/组织 | 增删改查 | 仅读本人档案 | 仅读本人档案 |
| 其他业务表 | 按模块立项时定义 | 按模块立项时定义 | 按模块立项时定义 |

---

## 5. 前端设计

### 5.1 目录结构

```text
admin/
├── src/
│   ├── app/
│   │   ├── layout.tsx                 # 根布局（Geist 字体、主题、Toaster）
│   │   ├── globals.css                # Tailwind 4 + CJT 品牌 token
│   │   ├── login/page.tsx             # 登录（内部+门户共用）
│   │   ├── (admin)/
│   │   │   ├── layout.tsx             # Sidebar + Header + 会话/角色校验
│   │   │   ├── page.tsx               # 工作台
│   │   │   └── settings/users/        # 用户管理（已完成）
│   ├── components/
│   │   ├── ui/                        # shadcn/ui 组件（npx shadcn add 维护）
│   │   ├── app-sidebar.tsx            # 侧边导航（按角色过滤）
│   │   └── users/users-table.tsx      # 用户管理表格 + 编辑抽屉
│   ├── hooks/
│   ├── lib/
│   │   ├── supabase/client.ts         # 浏览器客户端
│   │   ├── supabase/server.ts         # 服务端客户端（@supabase/ssr）
│   │   ├── supabase/proxy.ts          # 会话刷新（供 proxy.ts 调用）
│   │   ├── dictionaries.ts            # 枚举、字典（中文标签/配色）
│   │   └── database.types.ts          # supabase gen types 产物
│   └── proxy.ts                       # Next.js 16 网络边界：会话续期 + 登录拦截
├── supabase/
│   ├── config.toml
│   ├── migrations/
│   └── seed.sql
├── docs/
└── .env.local
```

### 5.2 导航与路由结构

菜单集中在 `src/components/app-sidebar.tsx`，按 `profiles.role` 过滤（如「用户管理」仅管理员可见）；页面级权限在各自 Server Component 中二次校验。未来模块按同一约定扩展。

### 5.3 页面清单

| 路由 | 页面 | 状态 |
|---|---|---|
| /dashboard | 概览（统计卡片、注册趋势、最近更新） | 已完成 |
| /settings/users | 用户管理（列表/搜索/筛选/角色分配/启停用） | 已完成 |

### 5.4 关键组件

| 组件 | 说明 |
|---|---|
| AppSidebar | 侧边导航，按 `profiles.role` 过滤菜单 |
| UsersTable | 用户管理表格 + 编辑抽屉 |
| 工作台卡片/图表 | 统计卡片、注册趋势（recharts）、最近更新 |

### 5.5 前端约定

- 页面默认 Server Component（`(admin)` 布局在服务端校验会话与角色）；交互组件按需 `"use client"`。
- 数据访问统一走 `@/lib/supabase/*` 客户端（浏览器 `client.ts` / 服务端 `server.ts`），不裸写 fetch。
- UI 组件从 `@/components/ui` 引入，新增组件用 `npx shadcn@latest add <name>`；表单校验用 Zod schema，与后端导入校验共用。
- 金额、数量、长度统一用 decimal 字符串传输，避免浮点误差；展示层处理精度。
- 时间统一 UTC 存储，dayjs 本地化展示（Asia/Shanghai）。
- i18n 先硬编码简体中文，文案集中到 `lib/constants.ts`，为 v2 做准备。

---

## 6. 后端设计

### 6.1 迁移工作流

1. 每个功能一批迁移：`supabase migration new <name>`。
2. 迁移只增不改：已合并的迁移禁止编辑，修正用新迁移。
3. 每批迁移附带 pgTAP 测试：`supabase/tests/<name>_test.sql`。
4. 本地验证：`supabase db reset` → 全量迁移 + seed 重放。
5. 云端发布：`supabase db push`（staging 先行，prod 需二次确认）。

迁移命名与顺序（首批）：

| 序号 | 迁移 | 内容 |
|---|---|---|
| 001 | init_enums_profiles | 枚举、profiles、organizations、辅助函数、RLS 策略 |

### 6.2 Edge Functions

暂无。后续模块需要时（邀请邮件、定时提醒、Excel 解析）再立项。

### 6.3 Storage

暂无 bucket。后续文档/附件模块需要时再立项，届时所有访问经 RLS/签名 URL，bucket 不公开。

### 6.4 Seed 数据（本地）

- 每角色 1 个测试账号（密码统一，本地关闭邮箱确认）。
- `supabase/seed.sql` 幂等可重放，不依赖生产数据。

---

## 7. 本地开发环境搭建

> 现状说明：项目已切换为 Supabase 远端项目（ref：`mnhtuekkxiqsseoesjfn`），开发环境变量指向远端；本章本地栈方案保留为备用（离线开发或收费考量时启用）。

### 7.1 前置条件

Node 24、npm 11、Docker 26（均已具备）；Supabase CLI 需安装。

### 7.2 初始化步骤

```bash
# 1. 安装 Supabase CLI（Linux，无 brew）
npm i -g supabase
supabase --version

# 2. 若空目录已有 docs/，推荐脚手架生成到临时目录后合并：
cd /tmp/opencode
npm create refine-app@latest admin-tmp
# 交互选择：Refine(Next.js) → Supabase → Ant Design → 无示例页 → i18n 否（v1.2 已调整为 shadcn/ui + @supabase/ssr）
# 然后合并到 /root/admin（保留 docs/）

# 3. 初始化 Supabase（仓库根目录）
cd /root/admin
supabase init

# 4. 启动本地栈（首次拉镜像约 3-5 分钟）
supabase start
supabase status        # 查看 URL / anon key / service_role key

# 5. 生成数据库类型
supabase gen types typescript --local > lib/types/database.types.ts

# 6. 配置前端环境变量（.env.local）
# NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321
# NEXT_PUBLIC_SUPABASE_ANON_KEY=<supabase status 输出>

# 7. 启动前端
npm run dev
```

### 7.3 本地端口

| 服务 | 地址 |
|---|---|
| API（REST/Auth/Storage） | http://127.0.0.1:54321 |
| Postgres | postgresql://postgres:postgres@127.0.0.1:54322/postgres |
| Studio | http://127.0.0.1:54323 |
| Inbucket（测试邮件） | http://127.0.0.1:54324 |
| 前端 | http://localhost:3000 |

### 7.4 日常命令

| 命令 | 用途 |
|---|---|
| supabase start / stop | 启停本地栈（stop 默认保留数据） |
| supabase db reset | 重放全部迁移 + seed（改 schema 后必跑） |
| supabase migration new <name> | 新建迁移 |
| supabase test db | 运行 pgTAP 测试 |
| supabase gen types typescript --local | 重新生成类型 |
| supabase functions serve | 本地调试 Edge Functions |
| npm run dev / build / lint / test | 前端常规命令 |

### 7.5 注意事项

- `supabase stop --no-backup` 会清空数据；日常用默认 `stop`。
- 本地 Auth 关闭邮箱确认（config.toml：`enable_confirmations = false`），测试邮件仍可在 Inbucket 查看。
- 前端连接本地栈时 key 为本地固定值；上线前用环境变量区分，不入库敏感 key。

---

## 8. 开发规范

| 项 | 约定 |
|---|---|
| 分支 | main 保护；feat/<模块>-<简述>；fix/<简述>；通过 PR 合并 |
| 提交 | Conventional Commits：feat / fix / docs / refactor / test / chore |
| 数据库 | 表/字段 snake_case；迁移不可回改；策略命名 `<表>_<动作>_<人群>` |
| 前端 | 组件 PascalCase；hooks useXxx；文件与导出同名 |
| 类型 | 数据库类型只由生成器产出，不手改；业务类型放 lib/types |
| 校验 | 所有表单、导入均 Zod 校验；后端触发器兜底约束 |
| 代码审查 | 涉及 RLS/迁移/审批状态机的 PR 必须双人审查 |
| 环境 | .env.local 不入库；.env.example 维护变量清单 |

---

## 9. 里程碑计划

| 阶段 | 内容 | 交付物 | 状态 |
|---|---|---|---|
| Phase 0 环境与骨架 | CLI、脚手架、shadcn 布局与登录、双路由组 | 可登录的系统 | 已完成 |
| Phase 1 用户与组织管理 | profiles、角色、RLS、工作台、用户管理 | 用户管理可用 + RLS 策略 | 已完成 |

后续模块（主数据、变更审批、对外门户等）按业务优先级另行立项，不再预排计划。

---

## 10. 测试策略

| 层 | 工具 | 覆盖 |
|---|---|---|
| 数据库 | pgTAP | 每张表每条 RLS 策略至少 1 允许 + 1 拒绝用例 |
| E2E | Playwright | 登录跳转、用户管理、权限隔离 |
| 数据 | seed | 各角色测试账号 |

CI（GitHub Actions）流水线：lint → typecheck → `supabase db reset && supabase test db` →（可选）Playwright。

---

## 11. 部署与运维

### 11.1 环境划分

| 环境 | 前端 | 后端 | 数据 |
|---|---|---|---|
| local | localhost:3000 | 本地 Supabase | 种子数据 |
| staging | Vercel Preview / 内网 | Supabase 独立项目 | 脱敏样本 |
| prod | Vercel / 公司服务器 | Supabase 独立项目 | 正式数据 |

### 11.2 后端方案对比

| 方案 | 优点 | 缺点 | 建议 |
|---|---|---|---|
| Supabase Cloud | 免运维、备份/PITR、升级自动 | 数据出境合规需评估、按月费用 | 起步首选；如有合规要求选自托管 |
| 自托管 Docker | 数据自主、内网部署 | 需 DBA/运维、升级备份自理 | 有内网合规要求时采用 |

### 11.3 上线检查清单

1. RLS 审计：以每个角色真实 JWT 调用 PostgREST 逐表验证。
2. 关闭本地测试用户；生产开启邮箱确认与强密码策略。
3. 备份策略确认（每日备份 + 恢复演练一次）。
4. Storage bucket 全部私有 + 签名 URL。
5. 环境变量、密钥轮换；service_role key 仅后端使用。
6. 监控：Supabase Dashboard 报表 + 前端 Vercel Analytics（或自建 uptime 监控）。

---

## 12. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| RLS 策略疏漏导致数据泄露 | 严重 | pgTAP 全覆盖 + 上线前多角色审计 + 双人审查 |
| 重 UI 框架的兼容与升级维护成本 | 升级阻塞、生态锁定 | shadcn/ui 为源码级组件（`components/ui` 入库），无第三方重 UI 框架锁定 |
| 通用型定位导致需求蔓延 | 范围失控 | 模块按业务优先级逐个立项，不预排大计划 |

---

## 13. 附录

### 13.1 依赖清单

```text
# 运行时
next react react-dom typescript
shadcn radix-ui lucide-react cn tailwindcss @tailwindcss/postcss
next-themes sonner recharts
@supabase/supabase-js @supabase/ssr
# 开发
@playwright/test
supabase（全局 CLI）
```

### 13.2 参考资料

| 主题 | 链接 |
|---|---|
| shadcn/ui 文档 | https://ui.shadcn.com/docs |
| shadcn/ui Blocks（成品页面） | https://ui.shadcn.com/blocks |
| Supabase Next.js SSR 集成 | https://supabase.com/docs/guides/auth/server-side/nextjs |
| Supabase 本地开发 | https://supabase.com/docs/guides/local-development |
| Supabase RLS | https://supabase.com/docs/guides/auth/row-level-security |
| Supabase CLI | https://supabase.com/docs/reference/cli |

### 13.3 决策记录（ADR 索引）

| 编号 | 决策 | 状态 |
|---|---|---|
| ADR-001 | 采用 Supabase 作为后端与本地一致性方案 | 已定 |
| ADR-002 | 前端单应用双路由组（Next.js + shadcn/ui） | 已定 |
| ADR-003 | 权限以 RLS 为最终边界，前端仅做菜单隐藏 | 已定 |
| ADR-004 | 变更留痕、版本化、不物理删除 | 已定 |
| ADR-005 | 部署后端优先 Supabase Cloud，合规受限时自托管 | 待评审 |
| ADR-006 | 通用模型：核心字段固定 + 字典/自定义属性扩展 | 已定 |
