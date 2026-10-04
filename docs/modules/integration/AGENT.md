# integration · 代理执行卡

## 模块状态
- 状态：开发中（001-009 已合入；010 待排期）
- 认领 agent：—
- 最后更新：2026-10-04

## 快速开始
1. 读 [README.md](../README.md) 确认优先级与依赖
2. 读 [INDEX.md](../INDEX.md) 确认边界、M0 底座与共享工件冲突规则
3. 按「工单执行顺序」逐条交付

## 工单执行顺序（阻塞边，工单级）

| 序号 | 工单 | 前置依赖 | 阶段 | 预估工时 |
|---|---|---|---|---|
| 001 | api_keys 表 + 签发/吊销 RPC | **access/001** | P0 | 2h |
| 002 | API key 校验中间件（验哈希 → 签发短期 JWT role=api_client_role） | 001 | P0 | 3h |
| 003 | API 密钥管理页面 | 001 | P0 | 3h |
| 004 | webhooks 表 + emit_event RPC（secret pgcrypto 加密可解密；不 GRANT authenticated） | 001 | P0 | 2h |
| 005 | Webhook 投递器（异步 + 重试 + HMAC 签名；运行时按 job runner ADR） | 004 | P0 | 3h |
| 006 | Webhook 管理页面 | 004 | P0 | 3h |
| 007 | integration_call_logs 表（按月分区 + excerpt 字段）+ stats_daily 聚合表 | 002, 005 | P0 | 2h |
| 008 | 调用日志页面 | 007 | P0 | 2h |
| 009 | api_docs 表 + OpenAPI 文档页面 | 003, 006 | P1 | 2h |
| 010 | 菜单登记 + 首期发射点验收（approval/org/sync 三处 emit_event 调用确认） | 006, **access/005**, **org/014**, **approval/012**, **sync/009** | P0 | 1h |

## 验收 checklist（合并前必检）
- [ ] pgTAP 全部通过
- [ ] API key 明文零落库零回显（sha256 哈希）；吊销后立即 401
- [ ] Webhook secret pgcrypto 加密（可解密签名）+ 一次性展示 + 掩码
- [ ] 目标端可验签（HMAC 示例代码验证通过）
- [ ] emit_event 不 GRANT authenticated（INDEX 规则 10）
- [ ] 调用日志与 audit 摘要分工（INDEX 规则 2）
- [ ] 审计摘要已写（前置 audit/001 已合入）
- [ ] 文档更新

## 常见陷阱
- SET LOCAL 无法在中间件层生效：API key 校验后签发短期 JWT（非 SET LOCAL role）
- 出站签名必须可解密 secret（哈希只适用于入站验签）
- 与 sync 分工：integration 管实时接口，sync 管批量搬运
- 出站运行时选型见 job runner ADR（M0），不各造一套

## 契约引用
- 上游：access/001（角色模型）、audit/001、job runner ADR
- 下游：各模块（emit_event 发射点）、report/008（导出调用日志）
- INDEX 规则：2、4（凭据分域）、10
