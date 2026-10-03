# 审计中心 · 操作日志

| 项 | 值 |
|---|---|
| 路由 | /audit/operations |
| 状态 | P1，待立项 |
| 模块 | [audit](../README.md#6-审计中心-auditp1) |

## 目的

合规留痕主视图：谁、何时、在哪个模块、对什么对象、做了什么、改了什么（前后差异）。

## 功能需求

1. 列表：时间、操作人、模块、动作（create/update/delete/assign…）、对象（类型+标识）、差异摘要。
2. 详情：字段级前后值对比（旧值删除线、新值主色）、上下文（IP、UA）。
3. 筛选：模块、操作人、对象类型、动作、时间段；组合查询。
4. 精确检索：按对象标识查看其完整变更史（时间线视图）。
5. 导出走 report 导出管道。

## 数据模型

`audit_operations`：id、actor_id、module、action、object_type、object_id、diff jsonb、ip、ua、created_at（append-only，禁止 UPDATE/DELETE）。
唯一写入入口：`audit_log(module, action, object_type, object_id, diff)` RPC（INDEX 规则 2；不 GRANT authenticated，仅经后端 SECURITY DEFINER wrapper 调用，INDEX 规则 10）。
公开面：发布 `audit_operations_v`（actor 名、module、action、object_type、object_id、diff、ip、ua、created_at），供 access 权限审计、report 操作活跃度、audit 合规报告消费（INDEX 登记）。
`audit_denied_v`：越权尝试视图（user、module、route、reason、time），写入路径为应用层捕获 42501/守卫拒绝后调 `audit_log(module, 'denied', ...)`；access/audit 消费。
分区：按月分区表（量增长后维护）。

## RLS

- 仅 admin SELECT；无任何角色可写（只经 SECURITY DEFINER 的 audit_log 写入）。
- pgTAP：直接 UPDATE/DELETE 拒绝；audit_log 可写且自动带 actor；非 authenticated 直调 audit_log 拒绝（GRANT 检查）。

## 界面规格

- 列表页模式：工具栏（多筛选）+ Table + 详情 Sheet；移动端卡片。
- diff 渲染组件通用化（access/audit、audit/changes 复用）。

## 依赖与契约

- 全模块作为写入方消费 audit_log；access/audit 页是本表的模块过滤视图。

## 验收标准

- 各模块每次关键写操作均有记录且 diff 完整；表无法被 UPDATE/DELETE（pgTAP 验证）。
