# ADR-001: 后台任务执行身份与出站运行时

- 状态：已采纳
- 日期：2026-10-04
- 背景：sync 同步执行、report 订阅/导出 worker、integration Webhook 投递、message 渠道分发都需要后台/出站执行能力；INDEX 全局禁止 service_role（BYPASSRLS），需统一执行身份模型与运行时选型。

## 决策

### 1. 执行身份模型

| 触发方式 | 执行身份 | 实现 |
|---|---|---|
| 手动触发 | 触发人身份 | 前端会话自然携带 JWT，RLS 按触发人过滤 |
| 定时触发（pg_cron） | 任务属主身份 | 任务表存 owner_id；执行函数 SECURITY DEFINER，内部 `set local role = authenticated` + `select set_config('request.jwt.claims', json_build_object('sub', owner_id, 'role', 'authenticated')::text, true)` 注入属主身份，RLS 按属主过滤 |
| 系统级任务（清理/聚合） | 专用最小角色 `job_runner` | 新建数据库角色，仅授予目标表必要权限（如 DELETE 过期日志），不授予业务表 |

全局禁令：**任何路径不得使用 service_role 执行后台任务**（BYPASSRLS 破坏「数据库层权限兜底」原则）。

### 2. 出站运行时选型

选择 **pg_net + pg_cron**（数据库内出站 HTTP + 调度），不引入 Edge Function 常驻投递器：

| 方案 | 评价 |
|---|---|
| pg_net + pg_cron（选） | 与现有迁移/测试体系一致；任务定义、执行记录、重试全部落库可审计；本地/云端行为一致 |
| Edge Function 投递器 | 引入第二种运行时与部署通道，本地开发需额外起 functions serve；出站秘钥管理分叉；延后到确有低延迟需求再立项 |

约定：Webhook 投递、邮件发送（经 SMTP 中继 API 或 Edge Function 单点封装）、报表订阅推送统一走「pg_cron 轮询队列表 → pg_net 异步 POST → 写执行记录」模式；队列表与执行记录归各模块（integration/message/report 各自的表），调度统一在 system pg_cron 登记处注册。

### 3. 失败与重试

- 重试策略存任务配置（次数 + 指数退避），执行记录表记 attempts/next_retry_at。
- 终态失败写 audit 摘要 + 调 send_notification 通知任务属主。

## 影响

- sync/005、report/005/007、integration/005、message/009 按本 ADR 实现执行身份与出站。
- pgTAP 必须覆盖：属主注入后 RLS 过滤正确（owner 外数据不可见）、service_role 零使用（审查项）。
- 若未来引入 Edge Function 投递器，需新 ADR 替代本节运行时部分。

## 状态：已落地（写入 docs/adr/001-job-runner.md）
