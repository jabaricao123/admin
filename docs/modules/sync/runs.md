# 第三方数据同步 · 执行记录

| 项 | 值 |
|---|---|
| 路由 | /sync/runs |
| 状态 | P1，待立项 |
| 模块 | [sync](../README.md#8-第三方数据同步-syncp1) |

## 目的

每次同步执行的技术明细：成功/失败条数、错误明细、耗时、重跑，排障主界面。

## 功能需求

1. 列表：任务、触发方式（手动/定时/webhook）、开始/结束时间、耗时、结果（成功/部分成功/失败）、新增/更新/冲突/失败计数。
2. 详情：分批执行日志（每批 N 行）、错误行明细（行标识 + 原因）、冲突待处理队列入口。
3. 重跑：失败任务一键重跑（幂等：按冲突策略重算）。
4. 人工裁决：冲突「标记人工处理」的行在此逐条采纳（用源值）或忽略（保留目标值）。
5. 保留策略：明细 30 天（**pending 冲突记录不受清理影响**，裁决后随明细保留）；聚合长期保留（同 integration/logs 惯例）。

## 数据模型

`sync_runs`（按月分区）：id、task_id、trigger_type、status、stats jsonb、started_at、finished_at、error。
`sync_conflicts`：run_id、row_key、source_data jsonb、target_data jsonb、resolution（pending/adopted/ignored）、resolved_by。

## RLS

- 仅 admin 可见（技术明细）；摘要已进 audit。

## 界面规格

- 列表页模式：结果 Badge（成功绿/部分黄/失败红）、计数列对齐；详情 Sheet 分「日志 / 冲突队列」tab。

## 依赖与契约

- 与 audit 分工（INDEX 规则 2）：本表排障明细，audit 只有执行摘要。
- 重跑调 sync/tasks 的同一执行函数（单一实现）。

## 验收标准

- 中断任务可重跑且不产生重复写入（幂等）；冲突裁决后状态与数据一致；30 天清理生效。
