# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

（既有代码库已回答，不重复记录。概要：Next.js 16 App Router + shadcn/ui（Tailwind CSS 4）+ @supabase/ssr + Supabase（云端项目 mnhtuekkxiqsseoesjfn），Postgres RLS 兜底权限。详见 docs/PLAN.md 第 2 章。）

## Users

| 用户群 | 场景 | 核心 job |
|---|---|---|
| 内部员工（admin / engineer / planner / buyer / quality） | 电脑为主，手机 H5 辅助（车间、仓库、领导临时查阅） | 维护物料/BOM/工艺主数据、发起与审批变更、查文档 |
| 供应商 | 对外门户（二期规划），电脑 + 手机 | 自助维护供货信息、反馈变更，无需邮件往返 |
| 客户 | 对外门户（二期规划） | 查询已发布产品资料与文档 |
| 系统管理员（admin） | 内部后台 | 用户管理、角色分配、字典与属性配置 |

## Product Purpose

企业管理系统（admin）：通用企业内部管理平台。首期已交付组织与用户管理基线，后续模块按业务优先级接入（采购协同 U9 同步、主数据、变更审批、对外门户）。追溯与 RLS 原则全量保留：权限由数据库层强制、变更留痕、版本化。

## Positioning

- 核心机制：**行业无关的通用模型 + 字典/自定义属性配置化**——新增业务对象类型只靠配置，不改代码；这是与行业定制型系统的本质差异。
- 商业化意图：**将来对外商业化售卖**，非纯内部工具。多租户能力暂未设计（开放决策，商业化前必须解决）。
- 数据可信：权限由数据库层（RLS）强制，前端不可信；变更全流程留痕、版本化 BOM。

## Operating Context

- 现状：一期脚手架与认证已完成；二期进行中（前端已升级为 Next.js 16 + shadcn/ui，用户管理已上线，物料/BOM/变更/门户待建）。
- 使用环境：工厂/办公室内网为主；中文界面（技术术语保留英文）；暂不做多语言与原生 App，响应式 H5 覆盖移动场景。
- 关键工作流：主数据录入 → BOM 编制 → ECN 变更发起/审批/发布 → 版本留存；供应商门户协同。
- 角色权限矩阵：见 docs/PLAN.md §5（admin 全权；engineer 增改查主数据；planner/buyer/quality 只读为主；supplier/customer 仅门户关联数据）。

## Capabilities and Constraints

- 已上线：登录（Supabase 密码认证）、后台守卫、工作台（统计卡片/注册趋势/最近更新）、用户管理（列表/搜索/筛选/角色分配/启停用，仅 admin）；前端栈 Next.js 16 + shadcn/ui（官方 blocks）。
- 规划中：用户邀请流程、主数据（物料/产品/BOM）、变更审批、对外门户。
- 技术约束：单 Next.js 应用双路由组（(admin) 服务端页面 + 客户端交互 / (portal) SSR）；不纳入 ERP/MES 深度集成、报价核算、排产；v1 审批模板固定，不做自定义工作流引擎。
- 术语：ECN、BOM、RLS 等技术术语保留英文，界面文案简体中文。

## Brand Commitments

- **CJT 品牌绿为强制约束**（用户确认）：主色 `#2aaf50`、底色 `#fafcfa` 系，提取自集团既有登录页（192.168.10.211:3001），已固化为 DESIGN.md 的全局 token。所有后续界面必须沿用。
- 产品名：企业管理系统（admin）。

## Evidence on Hand

- docs/PLAN.md：v1.1 完整实施计划（数据模型、权限矩阵、里程碑、风险）。
- README.MD：进度、测试账号（admin/engineer/buyer/planner@example.com）、命令速查。
- supabase/migrations + seed.sql：数据库基线与种子数据。
- /tmp/opencode/shots/：当前界面截图 01–10（桌面/移动、亮/暗色、导航与编辑抽屉）。
- 无真实客户证言、案例、报表数据；商业化宣传材料不得虚构这些内容。

## Product Principles

1. **配置优于代码**：新业务类型/产品类型通过字典与属性配置接入，不改代码是硬指标。
2. **数据库层权限兜底**：前端只是视图；一切权限以 RLS 为准，pgTAP 全覆盖。
3. **可追溯优先于便利**：变更留痕、版本化、不物理删除，宁可录入慢也不丢历史。
4. **桌面重、移动可用**：内部工具桌面为主，移动 H5 保证查阅与轻操作（卡片+抽屉模式）。
5. **商业化就绪意识**：模型设计避免硬编码单租户假设，多租户方案进入商业化前必答题。

## Accessibility & Inclusion

工厂场景年长用户与车间强光环境存在：正文对比度 ≥4.5:1、触控目标 ≥44px 已作为移动卡片模式基线（见 DESIGN.md §5），暂无强制 WCAG 等级要求（开放决策）。
