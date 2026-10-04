# 工作台 · 我的通知

| 项 | 值 |
|---|---|
| 路由 | /dashboard/notifications |
| 状态 | ✅ 已交付（dashboard/003，消费 message RPC） |
| 模块 | [dashboard](../README.md#1-工作台-dashboard) |

## 目的

未读消息的快捷入口，聚合显示最近站内信。

## 功能需求

1. 最近 20 条通知：标题、正文摘要、时间、已读/未读态。
2. 未读一键全部标记已读；点击进入 message 的站内信详情。

## 数据模型

只读消费：message 公开 RPC `recent_notifications(limit int default 20)`（message/inbox.md 公开面已登记）；已读状态切换调 message 的 `mark_all_read()` / 单条已读 RPC，不在本模块写库；sidebar 徽标用 `unread_count()`。

## RLS

- message 侧 RLS 保证本人只见本人通知。

## 界面规格

- 桌面 Table / 移动端卡片；未读行加左侧主色竖条或加粗标题区分。
- 空态文案「暂无通知」。

## 依赖与契约

- message 公开 RPC（唯一数据来源）。

## 验收标准

- 已读切换后 dashboard 与 message 的未读数一致（同源数据）。
