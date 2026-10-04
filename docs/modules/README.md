# 模块规划（顶级目录与子菜单）

> 来源：docs/PLAN.md §1.5（v1.4 定稿），独立成文供多 agent 并行开发引用。
> 多 agent 协作约定见 [INDEX.md](./INDEX.md)。

10 个顶级目录，按优先级逐个立项；行业深水区（ERP/MES/报价/排产）不纳入。P0 为地基（组织 + 权限），P1 为通用能力，P2 为辅助功能。

| 序号 | 顶级目录 | 标识 | 优先级 | 状态 |
|---|---|---|---|---|
| 1 | 工作台 | dashboard | - | ✅ 已上线 |
| 2 | 组织管理 | org | P0 | ✅ 已上线 |
| 3 | 权限管理 | access | P0 | ✅ 已上线 |
| 4 | 审批中心 | approval | P1 | ✅ 已上线 |
| 5 | 报表中心 | report | P1 | ✅ 已上线 |
| 6 | 审计中心 | audit | P1 | ✅ 已上线 |
| 7 | 接口/集成中心 | integration | P1 | ✅ 已上线 |
| 8 | 第三方数据同步 | sync | P1 | ✅ 已上线 |
| 9 | 系统管理 | system | P1 | ✅ 已上线 |
| 10 | 消息中心 | message | P2 | ✅ 已上线 |

## 1. 工作台 dashboard

| 子菜单 | 路由 | 功能 | 状态 |
|---|---|---|---|
| 概览 | /dashboard | 统计卡片、注册趋势、最近更新 | ✅ 已上线（统计/趋势走 dashboard_stats RPC；公告横幅） |
| 我的待办 | /dashboard/todos | 跨模块待办聚合 | ✅ 已上线（dashboard/002，消费 my_todos） |
| 我的通知 | /dashboard/notifications | 未读消息快捷入口 | ✅ 已上线（dashboard/003，消费 message RPC） |

## 2. 组织管理 org（P0）

| 子菜单 | 路由 | 功能 | 状态 |
|---|---|---|---|
| 用户管理 | /org/users | 列表/搜索/筛选/角色分配/启停用 | ✅ 已上线（org/008 迁移完成，旧路径 301） |
| 部门管理 | /org/departments | 树形部门、负责人、排序、启停用 | 待立项 |
| 岗位管理 | /org/positions | 岗位名录、编制数、所属部门 | 待立项 |
| 组织架构图 | /org/chart | 可视化树形图、按部门下钻人员 | P1 |

## 3. 权限管理 access（P0）

| 子菜单 | 路由 | 功能 |
|---|---|---|
| 角色管理 | /access/roles | 角色定义、内置/自定义 |
| 菜单权限 | /access/permissions | 角色 ↔ 菜单/按钮级授权矩阵 |
| 数据权限 | /access/data-scopes | 数据范围（本人/本部门/全部），对接 RLS |
| 权限审计 | /access/audit | 权限变更记录、越权告警（P1，联动审计中心） |

## 4. 审批中心 approval（P1）

| 子菜单 | 路由 | 功能 |
|---|---|---|
| 我的待办 | /approval/todo | 待审批列表、批量通过（不允许批量驳回，防误伤） |
| 我发起的 | /approval/mine | 我提交的申请、撤回、催办 |
| 抄送我的 | /approval/cc | 知会类审批 |
| 审批模板 | /approval/templates | 模板与表单字段配置（admin） |
| 审批流程 | /approval/flows | 流程节点、条件分支（admin） |

## 5. 报表中心 report（P1）

| 子菜单 | 路由 | 功能 |
|---|---|---|
| 预置报表 | /report/builtin | 人员统计、部门分布、操作活跃度 |
| 自定义报表 | /report/custom | 选字段、筛选、图表、保存视图 |
| 报表订阅 | /report/subscriptions | 定时推送邮件/站内信 |
| 数据导出 | /report/exports | 导出任务列表、下载历史 |

## 6. 审计中心 audit（P1）

| 子菜单 | 路由 | 功能 |
|---|---|---|
| 操作日志 | /audit/operations | 谁/何时/改什么（模块/动作/对象/差异） |
| 登录日志 | /audit/logins | 登录时间、IP、设备、成败 |
| 数据变更 | /audit/changes | 关键表字段级留痕、版本对比 |
| 合规报告 | /audit/compliance | 周期性权限/变更汇总，导出 PDF |

## 7. 接口/集成中心 integration（P1）

| 子菜单 | 路由 | 功能 |
|---|---|---|
| API 密钥 | /integration/api-keys | 签发、吊销、权限范围、有效期 |
| Webhook | /integration/webhooks | 事件订阅、目标 URL、重试、签名 |
| 调用日志 | /integration/logs | API/Webhook 调用记录、状态码、耗时 |
| 接口文档 | /integration/docs | 内置 OpenAPI 文档 |

> 分工：integration 管「对外接口能力」（被动 + 事件推送），sync 管「批量数据搬运」。

## 8. 第三方数据同步 sync（P1）

| 子菜单 | 路由 | 功能 |
|---|---|---|
| 数据源配置 | /sync/sources | 外部系统连接（REST API / 数据库 / Excel），凭据加密 |
| 同步任务 | /sync/tasks | 数据源 → 目标表映射、字段映射、方向、冲突策略 |
| 执行记录 | /sync/runs | 成功/失败条数、错误明细、手动重跑 |
| 调度管理 | /sync/schedules | 手动 / 定时（pg_cron）/ Webhook 触发，启停用 |

> 约束：同步写入业务表仍走 RLS/函数层，不绕过权限直写；执行历史进审计中心。

## 9. 系统管理 system（P1）

| 子菜单 | 路由 | 功能 |
|---|---|---|
| 邮件服务 | /system/services/mail | SMTP 主机/账号/密码（加密）/发件人、测试发送 |
| 对象存储 | /system/services/storage | S3/Supabase Storage：endpoint、bucket、密钥（加密）、签名 URL 有效期 |
| 短信服务 | /system/services/sms | 服务商、AccessKey（加密）、签名、模板 ID（预留） |
| 消息推送 | /system/services/push | 企业微信/钉钉机器人 Webhook（预留） |
| 身份认证 | /system/services/auth | 密码策略/会话时长/OAuth 状态展示与控制台配置指引（只读） |
| 参数配置 | /system/settings | 全局开关、业务参数（键值对+分组） |
| 字典管理 | /system/dictionaries | 枚举码表维护 |
| 定时任务 | /system/jobs | pg_cron 平台登记处只读监控（启停回各模块调度页）、执行历史 |
| 公告管理 | /system/announcements | 全站公告发布、生效时段 |
| 关于/版本 | /system/about | 版本号、更新记录 |

> 通用约束：密钥 pgcrypto 加密存储、界面掩码显示、修改需重输完整值；每个服务配置页带「测试连接」；配置变更写入审计日志。邮件服务是消息中心的前置依赖。

## 10. 消息中心 message（P2）

| 子菜单 | 路由 | 功能 |
|---|---|---|
| 站内信 | /message/inbox | 收件箱、已读/未读、星标 |
| 通知模板 | /message/templates | 模板文案、变量占位符（admin） |
| 发送记录 | /message/history | 发送流水、触达状态 |

## 立项顺序建议

**M0 底座先行**（audit/001-002+006、message/001-003、access/005 菜单 seed、job runner ADR，见 INDEX.md），随后：

1. **org**（P0）：部门/岗位数据模型 + 用户管理路径迁移。
2. **access**（P0）：角色/菜单/数据权限（001 前置 org/001；008 独占 app-sidebar）。
3. **system → approval**（P1）：基础设施 + 审批引擎（approval/002 前置 message/001）。
4. **integration → sync → report**（P1）：report/007 先于 audit/008。
5. **message 渠道层 + dashboard 聚合**（P1/P2）。
