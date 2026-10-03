# 系统管理 · 定时任务

| 项 | 值 |
|---|---|
| 路由 | /system/jobs |
| 状态 | P1，待立项（admin 可见） |
| 模块 | [system](../README.md#9-系统管理-systemp1) |

## 目的

pg_cron 平台登记处的只读监控：全站定时任务统一注册、状态总览、执行历史，操作回到各模块（INDEX 规则 5）。

## 功能需求

1. 登记表：job 名、来源模块、cron 表达式、时区、owner 模块路由（「去管理」链接）、状态。
2. 执行历史：全局最近执行列表（job、时间、结果、耗时），按来源模块筛选。
3. 只读边界：本页不提供启停/编辑（跳转 owner 模块操作），页面明示该约定。
4. 健康视图：超过 2 个预期周期未运行的 job 标警示；24h 内失败率 >50% 的 job 标红（阈值显式定义，可验收）。
5. 登记契约：模块经 `register_cron_job(name, module, cron, tz, owner_route)` RPC 注册/注销；联查视图 `system_cron_jobs_v`（登记表 ⨝ cron.job_run_details 聚合）。

## 数据模型

`system_cron_registry`：id、job_name（唯一）、module、cron_expr、timezone、owner_route、status、last_run_at、last_result、registered_by、时间戳。
执行状态与 pg_cron 系统表（cron.job_run_details）联查。

## RLS

- 仅 admin 可见；register_cron_job 不 GRANT authenticated（INDEX 规则 10），仅经各模块 SECURITY DEFINER wrapper 调用。

## 界面规格

- 两 tab（任务登记 / 执行历史）；警示行 Badge；「去管理」外链到 owner_route。

## 依赖与契约

- 写入方：sync/schedules、report/subscriptions、integration/logs 清理、导出清理等。
- 本页零操作按钮（纯监控），杜绝双头管理。

## 验收标准

- 任何 pg_cron job 都能在登记表找到且 owner_route 有效；孤儿 job（不在登记表）在健康视图标红提示。
