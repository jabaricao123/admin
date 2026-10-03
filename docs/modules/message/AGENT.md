# message · 代理执行卡

## 模块状态
- 状态：开发中（001-002 M0 已合入 f2f6ffe）
- 认领 agent：—
- 最后更新：2026-10-04

## 快速开始
1. 读 [README.md](../README.md) 确认优先级与依赖
2. 读 [INDEX.md](../INDEX.md) 确认边界、M0 底座与共享工件冲突规则
3. 按「工单执行顺序」逐条交付

## 工单执行顺序（阻塞边，工单级）

| 序号 | 工单 | 前置依赖 | 阶段 | 预估工时 |
|---|---|---|---|---|
| 001 | messages 表 + send_notification RPC（event_key 驱动；不 GRANT authenticated） | 无 | **M0** | 2h |
| 002 | messages RLS + pgTAP | 001 | **M0** | 1h |
| 003 | 站内信收件箱页面 + 公开 RPC（recent_notifications/mark_all_read/unread_count） | 002 | **M0** | 3h |
| 004 | message_event_registry 表 + register_message_event RPC | 001 | P1 | 1h |
| 005 | message_templates 表 + 版本化（(event_key, channel, version) 唯一） | 004 | P1 | 2h |
| 006 | 通知文案模板页面（admin） | 005 | P1 | 3h |
| 007 | message_deliveries 表（按月分区 + idempotency_key） | 001 | P1 | 2h |
| 008 | 发送记录页面 | 007 | P1 | 2h |
| 009 | 渠道分发（邮件/推送/短信降级；含批量分片 ≤500/批） | 007, **system/002, system/004, system/005** | P1 | 4h |

## 验收 checklist（合并前必检）
- [ ] pgTAP 全部通过
- [ ] send_notification 不 GRANT authenticated（INDEX 规则 10）
- [ ] 渠道停用自动降级为站内信（不报错）
- [ ] 未读数全站一致（dashboard/sidebar/本页同源 unread_count）
- [ ] 重发带 idempotency_key 不产生重复
- [ ] 审计摘要已写（前置 audit/001 已合入）
- [ ] 文档更新

## 常见陷阱
- 通知文案模板命名区别于审批表单模板（INDEX 规则 8）
- 渠道分发 best-effort（推送失败不影响主渠道）；全员公告分批 ≤500/批
- messages.read_at 是未读唯一事实源（approval_ccs.read_at 仅业务标记）

## 契约引用
- 上游：audit/001、system 服务配置（009）
- 下游：dashboard/003、approval、report、system/announcements（均经 send_notification）
- INDEX 规则：2、3（通知单通道）、8、10
