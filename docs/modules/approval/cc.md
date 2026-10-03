# 审批中心 · 抄送我的

| 项 | 值 |
|---|---|
| 路由 | /approval/cc |
| 状态 | P1，待立项 |
| 模块 | [approval](../README.md#4-审批中心-approvalp1) |

## 目的

知会类审批：抄送给我的单据只读跟踪，无需操作。

## 功能需求

1. 列表：标题、来源模块、发起人、当前节点、抄送时间、实例状态。
2. 详情：表单只读 + 审批轨迹。
3. 已读标记：进入详情自动标记该抄送已读。
4. 筛选：未读 / 全部；来源模块。

## 数据模型

`approval_ccs`：instance_id、cc_user_id、read_at，主键 (instance_id, cc_user_id)。

## RLS

- cc_user_id = auth.uid() 可读可标已读；admin 只读全部。

## 界面规格

- 列表页模式；未读行加粗 + 主色竖条；移动端卡片。

## 依赖与契约

- 抄送目标解析（按角色/部门）用 access/org 公开数据。
- 新抄送通知走 message RPC。

## 验收标准

- 未读列表与 message 未读数来源一致（messages.read_at 为未读唯一事实源；approval_ccs.read_at 仅业务标记，避免双计数）。
