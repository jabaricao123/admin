# 消息中心 · 发送记录

| 项 | 值 |
|---|---|
| 路由 | /message/history |
| 状态 | P2，待立项 |
| 模块 | [message](../README.md#10-消息中心-messagep2) |

## 目的

发送流水：每次通知的触达状态与渠道明细，排查「为什么没收到」。

## 功能需求

1. 列表：时间、收件人、事件、渠道（站内信/邮件/推送/短信）、状态（成功/失败/降级）、错误摘要。
2. 详情：渲染后的标题/正文快照、渠道响应摘要、重发按钮（失败且渠道可用时；重发带 idempotency_key，幂等防重复）。
3. 筛选：收件人、事件、渠道、状态、时间段。
4. 降级标注：渠道停用自动降级的记录标「降级」而非「失败」。
5. 保留策略：明细 90 天（比技术日志长，涉及用户查询），聚合长期保留；清理任务在 system pg_cron 登记处注册。

## 数据模型

`message_deliveries`（按月分区）：id、message_id、recipient_id、event_key、channel、status、error、rendered_subject、rendered_body（快照）、idempotency_key、created_at；唯一约束 **(idempotency_key, created_at)**（含分区键，跨分区生效）。

## RLS

- admin 全量；普通用户 SELECT 自己的 delivery（自查收件问题）。

## 界面规格

- 列表页模式：状态 Badge（成功绿/失败红/降级黄）；详情 Sheet。

## 依赖与契约

- 与 audit 分工（INDEX 规则 2）：本表是投递明细，audit 只有发送摘要。
- 重发走 send_notification 同一实现（幂等标记避免重复通知）。

## 验收标准

- 每次业务触发可追溯完整渠道矩阵（哪些渠道成功/降级/失败）；重发不产生重复站内信；90 天清理生效。
