# 接口/集成中心 · Webhook

| 项 | 值 |
|---|---|
| 路由 | /integration/webhooks |
| 状态 | P1，待立项（admin 专用） |
| 模块 | [integration](../README.md#7-接口集成中心-integrationp1) |

## 目的

事件推送：订阅本系统事件（审批通过、用户变更、同步完成等），推送到外部 URL。

## 功能需求

1. 列表：名称、目标 URL、订阅事件（多选）、状态、最近投递结果、创建人。
2. 新增/编辑：URL（https）、事件勾选、重试策略（次数/退避）、自定义 header（脱敏显示）。
3. 签名：每 webhook 独立 secret，投递带 HMAC 签名头；secret 仅创建时展示。
4. 测试投递：发送 ping 事件验证连通。
5. 投递历史：最近 100 条/端点（详见调用日志）。

## 数据模型

`webhooks`：id、name、url、secret_enc bytea（pgcrypto 加密存明文，投递时解密计算 HMAC；出站签名必须可解密，INDEX 规则 4；一次性展示 + 界面掩码）、events text[]、retry_policy jsonb、headers jsonb（值加密）、status、时间戳与操作人。
投递：事件总线函数（各模块经 integration 公开 RPC `emit_event(name, payload)`）→ 匹配订阅 → 异步投递。

## RLS

- 仅 admin 可管理；emit_event 对全模块开放（SECURITY DEFINER，内部校验来源）。

## 界面规格

- 列表页模式 + Sheet 编辑；事件选择用 checkbox 分组（按模块分组）。

## 依赖与契约

- 各模块发事件只调 `emit_event`（不 GRANT authenticated，INDEX 规则 10），不感知具体订阅者（解耦）。
- 首期发射点契约：approval（approval.submitted/approved/rejected）、org（org.user_changed）、sync（sync.run_finished），列入各模块工单验收。
- 投递明细在调用日志；摘要进 audit（INDEX 规则 2）。

## 验收标准

- 目标端可验签（文档提供验签示例代码）；失败按策略重试后终态记录；吊销端点不再收到事件。
