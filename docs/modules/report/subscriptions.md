# 报表中心 · 报表订阅

| 项 | 值 |
|---|---|
| 路由 | /report/subscriptions |
| 状态 | P1，待立项 |
| 模块 | [report](../README.md#5-报表中心-reportp1) |

## 目的

定时推送报表：按订阅计划生成报表并发送（邮件/站内信），管理层免登录获取周期数据。

## 功能需求

1. 订阅列表：报表名、频率（每日/每周/每月）、渠道（站内信/邮件）、接收人（自己/指定角色）、状态。
2. 新增/编辑：选报表（预置或自定义）→ 频率 → 渠道 → 接收范围。
3. 执行历史：每次生成的状态、耗时、失败原因、手动重发。
4. 停用/删除：停用保留历史，删除需二次确认（不物理删，逻辑删）。

## 数据模型

`report_subscriptions`：id、report_def_id、cron_expr、channels text[]、recipients（self/role:xxx）、status、is_deleted bool（逻辑删）、created_by/updated_by、时间戳。
`report_subscription_runs`（执行历史）：id、subscription_id、status、duration_ms、error、created_at；失败可手动重发。
执行：pg_cron 任务（在 system 平台登记处注册，INDEX 规则 5），产物走 message 发送 RPC。

## RLS

- 订阅 owner 与 admin 可管理；执行历史 owner 可见自己的。
- pg_cron 任务显式注入**订阅属主身份**（`set local role = authenticated` + `request.jwt.claims` 注入 owner sub），按 owner 数据范围过滤；**禁止 service_role**（BYPASSRLS，INDEX 全局禁令）。
- pgTAP：owner 外数据不可见。

## 界面规格

- 列表页模式 + Sheet 编辑；频率选择用预设（不暴露 cron 原文给普通用户）。

## 依赖与契约

- 依赖 system 的 pg_cron 登记处与 mail 服务配置、message 发送 RPC（INDEX 规则 3、5）。
- 邮件正文内嵌表格快照 + 附件 CSV（经导出管道）。

## 验收标准

- 手动触发一次订阅全链路成功（生成→投递→站内信/邮件可查）；失败可在执行历史看到原因并可重发。
