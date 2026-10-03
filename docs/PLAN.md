# CJTcable 企业管理系统实施计划

> 版本：v1.3 ｜ 日期：2026-10-04 ｜ 状态：待评审
> v1.1 变更：定位从"线缆行业 PLM"调整为"通用型 PLM"，行业差异通过数据字典与自定义属性适配。
> v1.2 变更：前端技术栈由 Refine + Ant Design 调整为 shadcn/ui（Tailwind CSS 4），沿用 Next.js App Router + Supabase。
> v1.3 变更：定位从"通用型 PLM"调整为"通用企业管理系统"（项目管理、采购协同、主数据、变更审批、对外门户），PLM 仅作为历史阶段术语保留。

---

## 1. 项目概述

### 1.1 背景

产品数据（物料、产品、BOM、工艺、文档、变更记录）目前分散在 Excel 和纸质文件中，且不同业务线、不同产品类型的数据结构差异大。本系统目标是建立统一、受控、可追溯的通用产品数据平台：核心模型行业无关，通过可配置字典与自定义属性适配各类产品；同时打通外部协同（供应商填报、客户查询）。

### 1.2 目标

1. 产品主数据统一：物料、产品、BOM、工艺路线、技术文档集中管理。
2. 通用可配置：字典 + 自定义属性适配不同行业与业务线，新业务类型不改代码。
3. 变更受控：ECN 变更单全流程留痕，审批通过后自动发布新版本。
4. 内外协同：供应商维护供货信息，客户查询产品资料。
5. 合规可审计：所有数据操作有审计日志，权限由数据库层强制。

### 1.3 范围（v1）

| 纳入 | 不纳入（后续版本） |
|---|---|
| 物料 / 产品 / BOM / 工艺 / 文档 / 变更审批 | ERP、MES 深度集成 |
| 字典与自定义属性配置 | 报价与成本核算、排产 |
| 内部后台 + 对外门户 | 移动端原生 App（先做响应式） |
| 用户、角色、审计日志 | 多语言（先简体中文） |
| Excel 批量导入（物料、BOM） | 工作流引擎自定义（v1 固定审批模板） |

### 1.4 成功标准

- 首批 3 种产品类型、200 条物料、10 套 BOM 完成录入并通过评审。
- 新增一个产品类型时，仅通过字典与属性配置完成，无需改代码。
- 一条变更单从发起到发布 ≤ 3 天（含审批），全程线上可查。
- 供应商可在门户自助维护供货信息，无需邮件往返。
- RLS 测试覆盖率 100%（每张表每条策略均有 pgTAP 用例）。

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
| 测试 | pgTAP（RLS/SQL）、Vitest（前端单测）、Playwright（E2E） | 见第 10 章 |
| 部署 | 前端 Vercel 或 Docker+Nginx；后端 Supabase Cloud（备选自托管） | 见第 11 章 |

环境核查（2026-10-03）：

| 项 | 状态 |
|---|---|
| Node.js | 24.21.0 已装 |
| npm | 11.19.0 已装 |
| Docker | 26.1.5 已装 |
| Supabase CLI | 未安装（Phase 0 第一步） |
| 本地 Supabase 栈 | 未运行 |

---

## 3. 系统架构

```mermaid
flowchart LR
  subgraph Client["前端 Next.js 单应用"]
    A1["(admin) 内部后台<br/>shadcn/ui + 客户端交互"]
    A2["(portal) 对外门户<br/>SSR 页面"]
  end
  subgraph Supabase["Supabase 本地 / 云端"]
    B1["Auth 认证"]
    B2["PostgREST / RPC"]
    B3["Postgres + RLS"]
    B4["Storage 文档"]
    B5["Edge Functions 邮件/定时"]
  end
  A1 --> B1 & B2 & B4
  A2 --> B1 & B2
  B2 --> B3
  B5 --> B3
  B4 --> B3
```

### 3.1 部署形态

单体单仓、单 Supabase 项目、单 Next.js 应用，用 Next.js 路由组隔离两类用户：

| 路由组 | 用户 | 渲染策略 | 框架 |
|---|---|---|---|
| `app/(admin)/*` | 内部员工 | 服务端页面 + 客户端交互组件 | Next.js + shadcn/ui |
| `app/(portal)/*` | 供应商 / 客户 | Server Components + 客户端表单 | Next.js + shadcn/ui |
| `app/login/*` | 全员 | 客户端 | — |

### 3.2 关键决策与理由

| 决策 | 理由 | 备选方案 |
|---|---|---|
| 单应用双路由组 | 共享类型、组件、Supabase 客户端，维护成本最低 | 双应用（Vite 后台 + Next 门户），隔离更强但同步成本高 |
| RLS 兜底权限 | 前端不可信；门户用户直接连数据库 API | 仅服务端 API 鉴权（无法覆盖 PostgREST 直连） |
| 核心字段 + 自定义属性 | 通用性要求行业无关：通用字段固定，行业字段配置化 | 全 EAV（查询/表单复杂）或全固定字段（无法通用） |
| 版本化 BOM | 变更发布生成新版本，历史可追溯 | 原地覆盖（不可追溯，否决） |

---

## 4. 数据模型（后端核心）

### 4.1 设计约定

- 表名、字段 snake_case，复数表名；主键统一 `id uuid default gen_random_uuid()`。
- 所有表含 `created_at`、`updated_at`（触发器维护）；主数据含 `status`，不物理删除。
- 外键 `xxx_id`；编码类字段唯一约束；枚举用 Postgres enum。
- 行业相关字段不进固定表结构：用 `attribute_definitions` 定义、`attributes jsonb` 存储。
- 多态关联（文档、审批、审计、属性值）只存 `entity_type + entity_id`，不建 FK，用应用层 + 触发器保证。

### 4.2 枚举

| 枚举 | 取值 |
|---|---|
| user_role | admin, engineer, planner, buyer, quality, supplier, customer |
| lifecycle_status | draft, in_review, approved, released, superseded, obsolete |
| change_type | new_product, material_change, structure_change, process_change, corrective, other |
| change_status | draft, submitted, reviewing, approved, implementing, closed, rejected |
| approval_status | pending, approved, rejected, returned |
| doc_type | drawing, spec, process_card, standard, other |
| attribute_data_type | text, number, boolean, date, select, multi_select |
| org_type | supplier, customer |

### 4.3 核心表

| 表 | 用途 | 关键字段 |
|---|---|---|
| organizations | 外部组织（供应商/客户） | name, org_type, credit_code, contact_name, contact_phone |
| profiles | 用户档案（1:1 auth.users） | id(=auth.uid), full_name, department, role, organization_id, status |
| material_categories | 物料分类树 | name, parent_id, sort |
| dictionaries | 通用数据字典（工序、单位、标准等） | type, code, label, sort, status |
| attribute_definitions | 自定义属性定义（按实体类型） | entity_type, code, label, data_type, options jsonb, required, sort, status |
| materials | 物料主数据 | code, name, category_id, spec, unit, reference_price, status, attributes jsonb |
| supplier_materials | 供应商-物料供货关系 | supplier_id, material_id, price, lead_time_days, status |
| product_families | 产品系列/分类 | code, name, category_id, sort |
| products | 产品（行业无关） | code, name, family_id, model, unit, status, version, attributes jsonb |
| boms | BOM 头（版本化） | product_id, version, status, effective_date, note |
| bom_items | BOM 明细（树形） | bom_id, parent_item_id, material_id, qty_per, unit, loss_rate, seq |
| routings | 工艺路线头 | product_id, version, status |
| routing_steps | 工序 | routing_id, seq, process_id（字典）, equipment, man_hours |
| documents | 文档元数据（多态） | entity_type, entity_id, doc_type, title, file_path, version, status |
| change_requests | 变更单 ECN | code, title, change_type, reason, product_id, status, requester_id, due_date |
| change_items | 变更明细 | change_id, object_type, object_id, action（add/modify/remove）, before jsonb, after jsonb |
| approvals | 审批实例 | entity_type, entity_id, status, flow jsonb, current_step |
| approval_steps | 审批步骤 | approval_id, seq, approver_role, status, actor_id, comment, acted_at |
| audit_logs | 审计日志 | table_name, record_id, action, changes jsonb, actor_id, created_at |

### 4.4 关系图

```mermaid
erDiagram
  organizations ||--o{ profiles : "外部用户归属"
  organizations ||--o{ supplier_materials : "供货"
  material_categories ||--o{ materials : "分类"
  materials ||--o{ supplier_materials : "被供货"
  product_families ||--o{ products : "系列"
  products ||--o{ boms : "多版本"
  boms ||--o{ bom_items : "明细"
  materials ||--o{ bom_items : "引用"
  products ||--o{ routings : "多版本"
  routings ||--o{ routing_steps : "工序"
  products ||--o{ change_requests : "变更对象"
  change_requests ||--o{ change_items : "明细"
  change_requests ||--o{ approvals : "审批（多态）"
  approvals ||--o{ approval_steps : "步骤"
```

> documents、audit_logs、attribute_definitions 为多态/配置关联，图中省略连线。

### 4.5 状态机

产品 / BOM 生命周期：

```mermaid
stateDiagram-v2
  [*] --> draft
  draft --> in_review : 提交审批
  in_review --> approved : 审批通过
  in_review --> draft : 退回
  approved --> released : 发布（旧版转 superseded）
  released --> superseded : 新版本发布
  released --> obsolete : 停产
  superseded --> obsolete : 归档
```

变更单（ECN）：

```mermaid
stateDiagram-v2
  [*] --> draft
  draft --> submitted : 提交
  submitted --> reviewing : 受理
  reviewing --> approved : 审批通过
  reviewing --> rejected : 驳回
  approved --> implementing : 执行变更
  implementing --> closed : 验证关闭
  rejected --> draft : 修改重提
```

v1 审批流程固定 3 步（可配置留到 v2）：部门主管 → 工艺/质量 → 技术负责人。步骤以 `approval_steps` 行落地，`approvals.flow` 存 JSONB 快照，后续可平滑扩展。

### 4.6 数据库函数（RPC）

| 函数 | 作用 | 调用方 |
|---|---|---|
| fn_gen_code(prefix) | 编码生成（前缀+年份+序列） | 插入前触发器 |
| fn_bom_explode(bom_id) | 递归展开 BOM 到末级 | 前端树形视图 |
| fn_bom_rollup(bom_id) | 汇总材料用量（含损耗率） | 成本/采购参考 |
| fn_validate_attributes(entity_type, attributes) | 校验自定义属性是否符合定义 | 插入前触发器 |
| fn_submit_for_approval(entity_type, entity_id) | 创建审批实例，状态转 in_review/reviewing | 后端 |
| fn_act_on_step(step_id, decision, comment) | 审批动作，推进状态机 | 前端审批按钮 |
| fn_release_bom(bom_id) | 发布 BOM，旧版本转 superseded | 前端发布按钮 |
| fn_audit_row() | 通用审计触发器函数 | 所有业务表 |
| fn_current_role() / fn_is_internal() | RLS 辅助（读取 profiles） | 所有策略 |
| fn_set_updated_at() | 维护 updated_at | 所有表 |

### 4.7 RLS 权限设计

原则：

1. 内部角色按角色矩阵读写；外部角色只能访问与自身组织关联的数据。
2. 所有策略用 `security definer` 辅助函数判断，避免策略内联子查询导致性能问题与循环。
3. 已发布（released）数据对全内部角色只读，仅 admin 可回退。
4. 外部用户默认无任何表权限，逐一开放所需视图/表。

示例策略：

```sql
-- 辅助函数：当前用户角色
create or replace function public.current_role() returns public.user_role
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and status = 'active'
$$;

-- 内部员工可读物料主数据
create policy materials_select_internal on public.materials for select
using (public.current_role() in ('admin','engineer','planner','buyer','quality'));

-- 供应商只能看到自己被邀请供货的物料
create policy supplier_materials_select on public.supplier_materials for select
using (
  public.current_role() = 'supplier'
  and supplier_id = (select organization_id from public.profiles where id = auth.uid())
);

-- 已发布 BOM 内部只读，草稿仅创建人/管理员可改
create policy boms_update on public.boms for update
using (
  public.current_role() = 'admin'
  or (public.current_role() = 'engineer' and status = 'draft' and created_by = auth.uid())
);
```

角色权限矩阵（v1）：

| 资源 | admin | engineer | planner | buyer | quality | supplier | customer |
|---|---|---|---|---|---|---|---|
| 物料主数据 | 增删改查 | 增改查 | 读 | 读 | 读 | 仅关联 | — |
| 产品 | 增删改查 | 增改查 | 读 | 读 | 读 | — | 仅发布 |
| BOM | 增删改查 | 增改查 | 读 | 读 | 读 | — | — |
| 变更单 | 全流程 | 发起/执行 | 参与 | 参与 | 审批 | 反馈 | — |
| 工艺路线 | 增删改查 | 增改查 | 读 | — | 读 | — | — |
| 文档 | 增删改查 | 增改查 | 读 | 读 | 读 | 关联下载 | 发布下载 |
| 字典/属性定义 | 增删改查 | 读 | 读 | 读 | 读 | — | — |
| 用户/组织 | 增删改查 | — | — | — | — | — | — |

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
│   │   │   ├── settings/users/        # 用户管理（已完成）
│   │   │   ├── materials/             # 规划：list / create / edit / show
│   │   │   ├── products/              # 规划：自定义属性表单、BOM 页签
│   │   │   ├── boms/[id]/             # 规划：BOM 树
│   │   │   └── changes/ documents/ partners/
│   │   └── (portal)/                  # 规划：供应商 / 客户门户
│   ├── components/
│   │   ├── ui/                        # shadcn/ui 组件（npx shadcn add 维护）
│   │   ├── app-sidebar.tsx            # 侧边导航（按角色过滤）
│   │   ├── users/users-table.tsx      # 用户管理表格 + 编辑抽屉
│   │   └── ...                        # 工作台卡片 / 图表 / 登录表单
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
│   ├── seed.sql
│   └── functions/                     # Edge Functions（规划）
├── tests/                             # 规划：e2e（Playwright）+ unit（Vitest）
├── docs/
└── .env.local
```

### 5.2 导航与路由结构

菜单集中在 `src/components/app-sidebar.tsx`，按 `profiles.role` 过滤（如「用户管理」仅管理员可见）；页面级权限在各自 Server Component 中二次校验。未来模块按同一约定扩展：

| 资源 | 路由前缀 | 状态 |
|---|---|---|
| users | /settings/users | 已完成 |
| materials | /materials | 规划 |
| products | /products | 规划（自定义属性表单、BOM 页签） |
| boms | /boms | 规划（树形编辑） |
| changes | /changes | 规划（审批时间线、diff） |
| documents | /documents | 规划 |
| partners | /partners | 规划 |

### 5.3 页面清单

| 路由 | 页面 | 优先级 | 要点 |
|---|---|---|---|
| /dashboard | 概览 | P0 | 待办审批、最近变更、统计卡片 |
| /materials | 物料 CRUD | P0 | 分类筛选、编码自动生成、批量导入 |
| /products | 产品 CRUD | P0 | 通用字段 + 自定义属性动态表单 |
| /products/show/:id | 产品详情 | P0 | 属性、版本、关联 BOM/工艺/文档页签 |
| /boms/show/:id | BOM 树 | P0 | 树形编辑、用量汇总、版本对比 |
| /changes | 变更列表 | P0 | 状态筛选、我的待办 |
| /changes/create | 新建变更 | P0 | 选择对象、填写前后值、附件 |
| /changes/show/:id | 变更详情 | P0 | 审批时间线、diff 视图、审批操作 |
| /documents | 文档库 | P1 | 上传/下载、关联实体、版本 |
| /partners | 供应商/客户 | P1 | 组织 CRUD、关联账号 |
| /settings/users | 用户管理 | P1 | 邀请、角色分配、停用 |
| /settings/dictionaries | 字典与属性定义 | P1 | 物料分类、工序、单位、自定义属性维护 |
| /portal | 门户首页 | P0 | 按角色渲染入口 |
| /portal/supplier | 供货维护 | P0 | 价格、交期、状态 |
| /portal/customer | 产品目录 | P1 | 只读查询已发布产品 |
| /portal/profile | 账号信息 | P1 | 改密、联系方式 |

### 5.4 关键组件

| 组件 | 说明 |
|---|---|
| BomTree | 树形结构 + 可编辑表格，支持拖拽排序、层级增删 |
| DynamicAttrForm | 按 attribute_definitions 渲染动态表单，Zod 动态校验 |
| ApprovalTimeline | 审批步骤时间线，含状态、意见、时间 |
| ChangeDiff | before/after JSONB 对比渲染，字段级高亮 |
| ExcelImport | 上传 → 模板校验 → 预览 → 入库，含错误报告 |
| FileUpload | 对接 Supabase Storage，多态实体关联 |

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
| 001 | init_enums_profiles | 枚举、profiles、organizations、辅助函数 |
| 002 | master_data | material_categories、dictionaries、attribute_definitions、materials、供应商关系 |
| 003 | products | product_families、products、routings、routing_steps、属性校验函数 |
| 004 | boms | boms、bom_items、BOM 函数 |
| 005 | changes | change_requests、change_items、approvals、approval_steps |
| 006 | documents_audit | documents、audit_logs、审计触发器 |
| 007 | rls_policies | 全表 RLS 与策略 |
| 008 | seed_helpers | 编码生成、导入辅助函数 |

### 6.2 Edge Functions

| 函数 | 触发 | 作用 |
|---|---|---|
| invite-user | 前端调用（admin） | 创建 auth 用户 + profiles + 发送邀请邮件 |
| notify-approval | 数据库 webhook | 审批提交/通过/驳回邮件通知 |
| scheduled-reminders | Cron（每日 8:00） | 变更单超期、文档到期提醒 |
| import-excel | 前端调用 | 服务端解析大文件（备选，小文件前端直解） |
| erp-sync | v2 预留 | 与 ERP 同步物料/产品 |

### 6.3 Storage

| Bucket | 内容 | 访问策略 |
|---|---|---|
| drawings | 图纸、规格书 | 内部读；门户仅 released 关联文档 |
| attachments | 变更单附件 | 变更参与人读写 |
| imports | Excel 导入临时文件 | 上传者 24h 后清理 |

文件命名：`{entity_type}/{entity_id}/{uuid}-{原文件名}`。所有访问经 RLS/签名 URL，bucket 不公开。

### 6.4 Seed 数据（本地）

- 字典与分类：工序字典（示例值）、单位、材料分类树、自定义属性示例。
- 每角色 1 个测试账号（密码统一，本地关闭邮箱确认）。
- 示例物料 20 条、产品 3 个（跨 2 种产品类型）、BOM 2 套、变更单 2 条（不同状态）。
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

> 估算基于 1 名全栈开发；若前后端各 1 人并行，总周期约缩短 40%。

| 阶段 | 内容 | 交付物 | 预估 |
|---|---|---|---|
| Phase 0 环境与骨架 | CLI、脚手架、shadcn 布局与登录、双路由组、CI 雏形 | 可登录的空系统 | 3 人日 |
| Phase 1 主数据 | 物料、分类、字典、自定义属性、供应商/客户、用户与角色 | 主数据 CRUD 可用 + RLS 策略 + pgTAP | 5 人日 |
| Phase 2 产品与 BOM | 产品、自定义属性、BOM 树、工艺路线、文档、导入 | 主数据与 BOM 可用，BOM 汇总正确 | 8 人日 |
| Phase 3 变更与审批 | ECN、审批流、状态机、通知、审计日志 | 变更全流程线上闭环 | 8 人日 |
| Phase 4 对外门户 | 门户布局、供应商维护、客户查询、账号 | 门户上线，外部用户可自助 | 5 人日 |
| Phase 5 测试与上线 | E2E、性能、staging、数据迁移演练、上线 | 生产可用 | 5 人日 |

合计约 34 人日，含缓冲按 8 周排期。

### 各阶段验收标准

| 阶段 | 验收 |
|---|---|
| Phase 0 | 本地 `supabase start` + 前端登录成功；类型生成流程跑通 |
| Phase 1 | 200 条物料导入成功；新建自定义属性并在表单生效；越权访问被 RLS 拒绝（pgTAP 证明） |
| Phase 2 | BOM 展开/汇总与人工核算一致；图纸可上传关联下载 |
| Phase 3 | 一条 ECN 走完 3 级审批并发布新 BOM 版本；旧版本转 superseded |
| Phase 4 | 供应商账号只能看到自己的供货数据；客户只能看已发布产品 |
| Phase 5 | 5 条 E2E 全绿；staging 演练一次数据迁移与回滚 |

---

## 10. 测试策略

| 层 | 工具 | 覆盖 |
|---|---|---|
| 数据库 | pgTAP | 每张表每条 RLS 策略至少 1 允许 + 1 拒绝用例；状态机函数用例 |
| 单元 | Vitest | 编码生成、BOM 汇总计算、diff 渲染、Zod schema |
| E2E | Playwright | 登录跳转、物料 CRUD、发起变更、审批、门户权限隔离 |
| 数据 | seed + 工厂函数 | 各角色测试账号、典型产品/BOM 数据集 |

CI（GitHub Actions）流水线：lint → typecheck → vitest → `supabase db reset && supabase test db` →（可选）Playwright。

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
| 过度配置化：属性/字典太灵活导致录入体验差 | 用户弃用、数据质量低 | 控制 v1 配置范围（仅属性与字典），核心字段固定；提供必填校验与录入模板 |
| 历史 Excel 数据质量差 | 导入失败、脏数据 | 先模板化 + 校验脚本 + 预览入库，分批迁移 |
| RLS 策略疏漏导致数据泄露 | 严重（门户用户互见数据） | pgTAP 全覆盖 + 上线前多角色审计 + 双人审查 |
| 重 UI 框架的兼容与升级维护成本 | 升级阻塞、生态锁定 | shadcn/ui 为源码级组件（`components/ui` 入库），无第三方重 UI 框架锁定 |
| 审批流程需求变化 | 状态机重构 | flow 存 JSONB 快照，v1 固定流程，v2 引入流程模板表 |
| 通用型定位导致需求蔓延 | 范围失控 | 以"首批 3 种产品类型"为边界，超出进 v2 列表 |
| 单人开发进度风险 | 延期 | 按阶段验收，Phase 2 后可先内部试用主数据模块 |

---

## 13. 附录

### 13.1 依赖清单

```text
# 运行时
next react react-dom typescript
shadcn radix-ui lucide-react cn tailwindcss @tailwindcss/postcss
next-themes sonner recharts
@supabase/supabase-js @supabase/ssr
zod react-hook-form @hookform/resolvers
dayjs
# 开发
vitest @testing-library/react @playwright/test
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
| ADR-004 | BOM 版本化，发布即冻结 | 已定 |
| ADR-005 | 部署后端优先 Supabase Cloud，合规受限时自托管 | 待评审 |
| ADR-006 | 通用模型：核心字段固定 + 字典/自定义属性扩展 | 已定 |
