# 审计中心 · 数据变更

| 项 | 值 |
|---|---|
| 路由 | /audit/changes |
| 状态 | P1，待立项 |
| 模块 | [audit](../README.md#6-审计中心-auditp1) |

## 目的

关键表字段级变更留痕与版本对比：比操作日志更结构化，支持「这条数据经历了什么版本」。

## 功能需求

1. 变更列表：表、记录标识、版本号、操作人、时间、变更类型。
2. 版本对比：任两个版本并排 diff（字段级旧值/新值）。
3. 版本时间线：单条记录全部版本按序展示。
4. 关键表白名单：`audit_row_version_whitelist` 表登记（首期：profiles、departments、positions）；新表加入 = 白名单登记 + 新迁移生成触发器。
5. 恢复（P2，延后）：以旧版本回填需走审批中心。

## 数据模型

`audit_row_versions`：id、table_name、record_id、version int、data jsonb（快照）、changed_by、changed_at。
生成：关键表 AFTER INSERT/UPDATE/DELETE 触发器自动快照（INSERT 为首版 version=1；触发器随各表迁移走，INDEX 规则 6；快照写入本表）。
白名单：`audit_row_version_whitelist` 表（table_name PK、enabled、created_by/时间戳）登记留痕表；新表加入 = 白名单登记 + 新迁移生成触发器（两步，配置无法动态生效静态 DDL）。
`audit_row_versions` 的触发器函数：`SECURITY DEFINER set search_path = ''` + 全限定名。

## RLS

- 仅 admin SELECT；无 UPDATE/DELETE（append-only）。
- 触发器显式 `SECURITY DEFINER set search_path = ''` + 全限定名（防 schema 劫持，沿用现有 app schema 约定）。

## 界面规格

- 列表页模式 + 对比视图（双栏字段对齐）；移动端逐字段纵向对比。

## 依赖与契约

- 触发器定义在各表（各模块迁移），本模块只拥有快照表与查询面。
- 与 operations 的分工：operations 记「动作+摘要」，changes 记「结构化版本」，同一事务双写。

## 验收标准

- 白名单表每次更新自动产生 +1 版本且快照完整；对比视图字段无遗漏。
