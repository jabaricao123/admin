# 审批中心 · 我的待办

| 项 | 值 |
|---|---|
| 路由 | /approval/todo |
| 状态 | P1，待立项 |
| 模块 | [approval](../README.md#4-审批中心-approvalp1) |

## 目的

待我审批的单据列表：查看、通过、驳回、批量操作，审批人的主工作界面。

## 功能需求

1. 列表：单据标题、来源模块、发起人、提交时间、等待时长、当前节点；默认按等待时间倒序。
2. 详情 Sheet：表单数据（来源模块提供的只读渲染）+ 审批轨迹（时间线）。
3. 通过 / 驳回：驳回必填意见；通过可填意见。
4. 批量：勾选多条一次通过（不允许批量驳回，避免误伤）。
5. 筛选：来源模块、时间段；tab：待办 / 已办。

## 数据模型

消费 approval 引擎表：`approval_instances`（单据实例）、`approval_tasks`（待办任务：instance_id、assignee_id、status、acted_at、comment）。
RPC：`act_task(task_id, action, comment)`（原子更新 + 触发下一节点 + 写 audit 摘要 + 调 message 通知）；提交入口见 [engine.md](./engine.md) 的 `submit_instance`。
公开 RPC：`my_todos(pending boolean default true, limit int default 20)`（dashboard 聚合消费，签名以此为准）。

## RLS

- assignee_id = auth.uid() 可读可操作自己的任务；admin 只读全部。
- pgTAP：非 assignee 操作拒绝；批量操作每人仅自己的任务。

## 界面规格

- 列表页模式：工具栏 + Table（勾选列）+ 详情 Sheet（轨迹用时间线组件）。
- 移动端卡片（Sheet 右侧 35vw，不分端）；等待超 48h 行加警示 Badge。

## 依赖与契约

- 公开 RPC `my_todos()` 供 dashboard 聚合。
- 通过/驳回后事件走 message 发送 RPC（INDEX 规则 3）。

## 验收标准

- 审批动作原子（并发通过同任务仅一次生效）；驳回必填意见被服务端强制。
