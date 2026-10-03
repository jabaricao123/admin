# report · 代理执行卡

## 模块状态
- 状态：P1 待立项
- 认领 agent：—
- 最后更新：2026-10-04

## 快速开始
1. 读 [README.md](../README.md) 确认优先级与依赖
2. 读 [INDEX.md](../INDEX.md) 确认边界、M0 底座与共享工件冲突规则
3. 按「工单执行顺序」逐条交付

## 工单执行顺序（阻塞边，工单级）

| 序号 | 工单 | 前置依赖 | 阶段 | 预估工时 |
|---|---|---|---|---|
| 001 | 预置报表（人员统计/部门分布/操作活跃度；消费 org_stats + audit_operations_v） | **org/013, audit/003** | P0 | 3h |
| 002 | report_definitions + report_allowed_views 白名单映射表 | 001 | P0 | 2h |
| 003 | run_report RPC（标识符仅取白名单，值全参数化） | 002 | P0 | 2h |
| 004 | 自定义报表编辑器 | 003 | P1 | 4h |
| 005 | report_subscriptions + report_subscription_runs 表 | 002, **message/001, system/011** | P1 | 2h |
| 006 | 报表订阅页面（执行注入订阅属主身份，禁 service_role） | 005 | P1 | 3h |
| 007 | export_jobs 表 + export_sources 注册表 + worker（**先于 audit/008**） | **system/003, system/011** | P0 | 4h |
| 008 | 数据导出页面 | 007 | P0 | 2h |
| 009 | 菜单登记 | 001, **access/005** | P0 | 0.5h |

## 验收 checklist（合并前必检）
- [ ] pgTAP 全部通过
- [ ] run_report 标识符仅取 report_allowed_views，用户输入不拼标识符（注入 pgTAP）
- [ ] 数据按当前用户数据范围过滤（scope helper）
- [ ] 订阅执行注入订阅属主身份；service role 零使用（审查项）
- [ ] 导出任务异步不阻塞页面；单用户并发 ≤3
- [ ] pg_cron 在 system 登记处注册（INDEX 规则 5）
- [ ] 审计摘要已写（前置 audit/001 已合入）
- [ ] 文档更新

## 常见陷阱
- 只允许引用各模块 `_v` 视图与公开 RPC（INDEX 规则 1）
- 分享链接打开后数据仍按访问者权限过滤（RLS 兜底）
- 007 是 audit/008 的前置（导出管道生产者），排期不可颠倒
- worker 出站运行时见 job runner ADR（M0）

## 契约引用
- 上游：org/013、audit/003、system/003+011、message/001、audit/001
- 下游：audit/008（合规报告导出）
- INDEX 规则：1、5
