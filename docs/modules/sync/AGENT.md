# sync · 代理执行卡

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
| 001 | sync_sources 表 + 凭据 pgcrypto 加密（复用 system 加密 helper） | **system/001** | P0 | 2h |
| 002 | 数据源配置页面（API/DB/Excel；草稿可存 + 验证状态） | 001 | P0 | 3h |
| 003 | sync_tasks 表 + 版本化（profiles 映射排除 role/status） | **org/001, org/004, org/007** | P0 | 2h |
| 004 | 同步任务向导（字段映射 + 冲突策略 + dry-run） | 003 | P0 | 4h |
| 005 | sync_runs 表（按月分区）+ 执行函数（注入任务属主身份，禁 service_role） | 003 | P0 | 3h |
| 006 | 执行记录页面（重跑幂等 + 冲突裁决；pending 冲突不受 30 天清理影响） | 005 | P0 | 3h |
| 007 | sync_schedules 表 + pg_cron 注册（经 system 登记处） | 005, **system/011** | P0 | 2h |
| 008 | 调度管理页面（停用后当次跑完再注销；webhook 限流 60/min） | 007 | P0 | 2h |
| 009 | 菜单登记 + emit_event 发射点（sync.run_finished） | 008, **access/005** | P0 | 0.5h |

## 验收 checklist（合并前必检）
- [ ] pgTAP 全部通过
- [ ] 执行注入任务属主身份（auth claims 注入 owner sub）；service role 零使用（审查项）
- [ ] 目标表白名单硬编码；profiles 映射 role/status 被拒（pgTAP）
- [ ] profiles 按 id/email 仅更新不新建（无孤儿档案）
- [ ] dry-run 与正式执行同快照一致（差异可解释）
- [ ] pg_cron 在 system 登记处注册（INDEX 规则 5）
- [ ] 审计摘要已写（前置 audit/001 已合入）
- [ ] 文档更新

## 常见陷阱
- 无会话上下文时 scope helper 返回空集：执行函数显式注入属主身份（INDEX 后台执行身份模型）
- 中断重跑幂等（按冲突策略重算，不产生重复写入）
- 与 integration 分工：sync 管批量搬运，integration 管实时接口
- 出站运行时选型见 job runner ADR（M0）

## 契约引用
- 上游：org（目标表）、system/001+011、audit/001、job runner ADR
- 下游：audit 执行摘要、message 失败通知、integration emit_event
- INDEX 规则：2、4、5、7（profiles 排除 role/status）
