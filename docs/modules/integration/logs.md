# 接口/集成中心 · 调用日志

| 项 | 值 |
|---|---|
| 路由 | /integration/logs |
| 状态 | P1，待立项 |
| 模块 | [integration](../README.md#7-接口集成中心-integrationp1) |

## 目的

技术排障明细：API 与 Webhook 每次调用/投递的请求响应详情，与 audit 合规摘要分工（INDEX 规则 2）。

## 功能需求

1. 列表：时间、类型（api/webhook）、密钥/端点、方法/事件、状态码、耗时 ms、成功/失败。
2. 详情：请求头（脱敏）、payload 摘要、响应摘要、错误信息（对应 request_excerpt/response_excerpt 字段）。
3. 筛选：类型、状态码（≥400 一键）、时间段、密钥/端点。
4. 保留策略：明细保留 30 天；聚合统计入 `integration_call_stats_daily` 长期保留；清理任务在 system pg_cron 登记处注册。
5. 导出走 report 导出管道。

## 数据模型

`integration_call_logs`（按月分区）：id、kind、key_id/webhook_id、method/event、status_code、duration_ms、request_excerpt（脱敏截断 2KB）、response_excerpt（脱敏截断 2KB）、error、created_at。
`integration_call_stats_daily`：day、kind、key_id/webhook_id、total、failed、avg_duration_ms（按天聚合，长期保留）。
写入：API 网关中间件与 webhook 投递器异步写入（不阻塞主流程）。

## RLS

- 仅 admin 可见（技术日志，不开放给普通用户）。

## 界面规格

- 列表页模式：状态码 Badge（2xx 绿 / 4xx 黄 / 5xx 红）、耗时列排序。

## 依赖与契约

- 与 audit 分工：本表是排障明细，audit 只有调用量摘要（`audit_log(module='integration', ...)`）。

## 验收标准

- 每次失败调用可在详情看到完整错误；30 天前明细不可查但聚合仍在。
