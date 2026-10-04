# 工作台 · 我的待办

| 项 | 值 |
|---|---|
| 路由 | /dashboard/todos |
| 状态 | ✅ 已交付（dashboard/002，消费 approval `my_todos`） |
| 模块 | [dashboard](../README.md#1-工作台-dashboard) |

## 目的

聚合跨模块待办（首个来源：审批），用户免跳转多模块处理事项。

## 功能需求

1. 待办列表：来源模块、标题、发起人、等待时长、快捷操作（去处理 → 跳转对应模块）。
2. 筛选：按来源模块；tab：待办 / 已办。
3. 空态显式呈现（「暂无待办」），不允许白屏。

## 数据模型

只读消费：approval 公开 RPC `my_todos(pending boolean default true, limit int default 20)`（签名以 approval/todo.md 为准）。dashboard 不建待办表。

## RLS

- approval 侧 RLS 保证本人只见本人待办；dashboard 无额外策略。

## 界面规格

- 列表页模式（INDEX/DESIGN.md §4）：桌面 Table，移动端卡片（Sheet 右侧 35vw，不分端）。
- 徽标标注来源模块（`Badge variant="outline"`）。

## 依赖与契约

- approval 公开 RPC（唯一数据来源）；禁止直查 approval 内部表。

## 验收标准

- 无待办时空态正确；点击「去处理」正确跳转 /approval/todo 并高亮目标项。
