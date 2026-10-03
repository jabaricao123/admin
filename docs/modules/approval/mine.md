# 审批中心 · 我发起的

| 项 | 值 |
|---|---|
| 路由 | /approval/mine |
| 状态 | P1，待立项 |
| 模块 | [approval](../README.md#4-审批中心-approvalp1) |

## 目的

我提交的审批申请：跟踪进度、撤回、催办。

## 功能需求

1. 列表：标题、来源模块、当前节点、当前处理人、状态（进行中/已通过/已驳回/已撤回）、提交时间。
2. 详情：表单只读 + 完整审批轨迹时间线。
3. 撤回：仅实例 running 且当前节点任务 pending（未被操作）时允许（状态机见 [engine.md](./engine.md)）；撤回后实例终态 withdrawn。
4. 催办：向当前处理人发站内信（走 message RPC），同单据 2 小时内仅一次。
5. 筛选：状态、来源模块、时间段。

## 数据模型

消费 `approval_instances`（initiator_id = auth.uid()）+ `approval_tasks`。
RPC：`withdraw_instance(instance_id)`、`urge_instance(instance_id)`（内置节流）。

## RLS

- 发起人只见自己的实例；admin 只读全部。

## 界面规格

- 列表页模式 + 详情 Sheet；状态 Badge 用 `dictionaries.ts`（进行中蓝/通过绿/驳回红/撤回灰）。

## 依赖与契约

- 催办/状态变更通知走 message RPC。
- 业务表单只读渲染由来源模块提供 registered renderer（契约：注册渲染组件 + 表单 JSON）。

## 验收标准

- 已处理节点的单据撤回被拒；催办节流生效。
