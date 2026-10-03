# 消息中心 · 站内信

| 项 | 值 |
|---|---|
| 路由 | /message/inbox |
| 状态 | P2，待立项 |
| 模块 | [message](../README.md#10-消息中心-messagep2) |

## 目的

站内信收件箱：系统与业务通知的统一收件视图，已读/未读、星标管理。

## 功能需求

1. 列表：发件方（模块/系统）、标题、摘要、时间、未读态；tab：全部 / 未读 / 星标。
2. 详情：完整正文（含业务跳转链接，如「去审批」）；进入即标已读。
3. 星标/取消星标；批量已读。
4. 分页 20 条；筛选按来源模块。
5. 通知渠道降级说明：短信/推送停用时仅站内信（不产生失败记录噪音）。

## 数据模型

`messages`：id、recipient_id、event_key、title、body、source_module、ref_type/ref_id（业务跳转）、read_at、starred、created_at（索引 recipient+created_at）。
写入唯一入口：`send_notification(recipient, event_key, vars jsonb)` RPC（事件驱动：按 event_key 查 `message_templates` 渲染标题/正文；不 GRANT authenticated，仅经后端 wrapper 调用，INDEX 规则 10）；无模板事件走 fallback 默认文案。内部再分发邮件/推送渠道。
公开 RPC（dashboard 消费）：`recent_notifications(limit int default 20)`、`mark_all_read()`、`unread_count()`（sidebar 徽标数据源）。

## RLS

- recipient_id = auth.uid() 可读可标已读/星标（经 RPC）；任何角色不可改他人数据；写入仅经 RPC。
- `send_notification` RPC：SECURITY DEFINER + `set search_path = ''` + 全限定名；不 GRANT authenticated（INDEX 规则 10）。

## 界面规格

- 列表页模式：未读加粗 + 主色竖条；详情用 Sheet；移动端卡片（Sheet 右侧 35vw，不分端）。

## 依赖与契约

- dashboard/notifications 消费公开 RPC（未读数同源）。
- 渠道分发读 system 服务配置（mail/push/sms）。

## 验收标准

- 未读数全站一致（dashboard、sidebar、本页同源）；已读回退（标未读）可用；业务跳转链接正确。
