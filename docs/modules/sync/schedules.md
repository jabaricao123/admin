# 第三方数据同步 · 调度管理

| 项 | 值 |
|---|---|
| 路由 | /sync/schedules |
| 状态 | P1，待立项（admin 专用） |
| 模块 | [sync](../README.md#8-第三方数据同步-syncp1) |

## 目的

同步任务的触发编排：手动 / 定时（pg_cron）/ Webhook 触发，统一启停与下次执行时间展示。

## 功能需求

1. 列表：任务、触发方式、cron 预设摘要、时区、状态、上次/下次执行时间。
2. 定时配置：预设频率（每小时/每天 HH:mm/每周几 HH:mm）+ 时区（默认 Asia/Shanghai），高级模式暴露 cron。
3. Webhook 触发：生成带 token 的触发 URL（外部系统调用即跑），token 可重置。
4. 启停用：停用即时生效（进行中的当次跑完后再注销 pg_cron job，登记处同步更新）；启动需数据源已验证。
5. 手动触发：立即执行一次（受单任务并发 1 限制，运行中再触发被拒）；webhook 触发端点限流 60 次/分钟/token。

## 数据模型

`sync_schedules`：id、task_id（唯一）、trigger_type（manual/cron/webhook）、cron_expr、timezone、webhook_token_hash、status、last_run_at、next_run_at。
执行：cron 项注册进 system pg_cron 平台登记处（INDEX 规则 5）；webhook 入口为公开 URL（token 验证）。

## RLS

- 管理仅 admin；webhook 触发端点公开但 token 验证 + 限流。

## 界面规格

- 列表页模式 + Sheet 编辑；预设频率选择器优先，cron 高级项折叠。

## 依赖与契约

- pg_cron 注册/注销经 system 登记处 RPC，本页是 sync 域操作面（`/system/jobs` 只读监控）。
- 触发执行的唯一入口是 sync 执行函数（runs 消费）。

## 验收标准

- 停用后 pg_cron 任务同步注销（登记处无孤儿 job）；token 重置后旧 URL 401；运行中重复触发被拒。
