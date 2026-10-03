# 第三方数据同步 · 同步任务

| 项 | 值 |
|---|---|
| 路由 | /sync/tasks |
| 状态 | P1，待立项（admin 专用） |
| 模块 | [sync](../README.md#8-第三方数据同步-syncp1) |

## 目的

任务定义：数据源 → 目标表（白名单）的字段映射、同步方向、冲突策略，一键试跑。

## 功能需求

1. 列表：任务名、数据源、目标表、方向（拉取/推送）、调度摘要、状态、最近执行结果。
2. 新增向导：选数据源 → 选目标表（白名单：departments/positions/profiles）→ 字段映射（源字段↔目标字段，类型检查）→ 冲突策略 → 试跑（dry-run，仅报告将变更的行数）。
3. 冲突策略：主键/唯一键冲突时 跳过 / 覆盖 / 标记人工处理（标记的行进「待处理」队列）。
4. 推送方向：白名单只读视图 → 外部（只推送，不接收回执）。
5. profiles 同步限定：按既有 id/email 匹配，**仅更新不新建**（不产生孤儿档案；用户导入含 auth 用户创建另立流程）。
6. 版本化：任务配置变更保留历史（可追溯原则），回滚到上一版配置。

## 数据模型

`sync_tasks`：id、name、source_id、target_table、direction、field_mapping jsonb、conflict_policy、status、config_version、created_by/updated_by、时间戳。
`sync_task_versions`：task_id、version、config jsonb 快照。

## RLS

- 仅 admin 可管理；执行时以 SECURITY DEFINER 函数写目标表，注入**任务属主身份**（`set local role = authenticated` + `request.jwt.claims` 注入 owner sub），`set search_path = ''` + 全限定名；禁止 service_role（INDEX 全局禁令）。
- 目标表白名单硬编码于函数体（防任意表写入）；**profiles 可映射字段设白名单，显式排除 role/status**（角色走 access 单通道、启停用走 org RPC，INDEX 规则 7）；映射越界拒执行。
- pgTAP：非白名单表写入被拒；映射 role/status 被拒；service role 不用于执行（审查项）。

## 界面规格

- 桌面向导式（步骤条）；移动端查看 + 启停，编辑引导去桌面端。
- 试跑结果用统计卡片（新增 n / 更新 n / 冲突 n / 跳过 n）。

## 依赖与契约

- 目标表白名单硬编码于 RPC（防任意表写入）；写入产生的变更同样触发 audit 版本快照。
- 执行触发调度见 schedules。

## 验收标准

- dry-run 数字与正式执行在同一数据快照下一致（同 SQL 语义；并发写产生的差异需在执行记录中可解释）；冲突标记行可在待处理队列查看并人工裁决；无白名单外表写入路径。
