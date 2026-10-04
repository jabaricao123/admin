# 模块开发文档（docs/modules/）

本目录承载 10 个顶级目录的开发文档，供多 agent 并行开发使用。总览见 [README.md](./README.md)（模块规划：顶级目录与子菜单）。

## 目录结构

```text
docs/modules/
├── README.md                # 模块规划总览（10 个顶级目录 + 子菜单 + 立项顺序）
├── INDEX.md                 # 本文件：协作约定 + 模块边界 + 认领流程
├── dashboard/               # 1. 工作台（已上线）
├── org/                     # 2. 组织管理（P0）
├── access/                  # 3. 权限管理（P0）
├── approval/                # 4. 审批中心（P1）
├── report/                  # 5. 报表中心（P1）
├── audit/                   # 6. 审计中心（P1）
├── integration/             # 7. 接口/集成中心（P1）
├── sync/                    # 8. 第三方数据同步（P1）
├── system/                  # 9. 系统管理（P1）
└── message/                 # 10. 消息中心（P2）
```

## 模块边界

每个模块声明：拥有什么（owns）、消费什么（consumes）、不做什么（NOT）。跨边界一律走公开契约（共享表视图 / RPC / 事件），禁止直接读改他模块的内部表。

| 模块 | owns（数据/能力） | consumes（依赖） | NOT（明确排除） |
|---|---|---|---|
| dashboard | 概览聚合视图、待办/通知入口卡片 | 各模块公开统计视图；approval 待办（P1）；message 未读（P2） | 不存业务数据；不替各模块做列表页 |
| org | `departments`、`positions`、**profiles 用户档案（含部门/岗位归属）与启停用**；用户管理页面（角色分配 UI 的宿主） | access 的角色分配 RPC | 不做角色定义与分配规则（→ access）；不做入转调离 HR 流程（另行立项） |
| access | **角色定义与分配（含 `profiles.role` 的写规则）**、角色↔菜单授权、数据范围策略、共享 RLS helper 函数（如 scope 解析函数） | org 的部门树（数据范围「本部门」） | 不拥有他模块表的 RLS 策略（各表 RLS 随建表模块走）；不做审批流（→ approval） |
| approval | 审批表单模板、流程定义、审批实例、待办 | access 的角色（审批人按角色解析）；org 的汇报关系 | 不承载具体业务表单数据（各业务模块自建表，只接审批引擎）；不发通知（→ message） |
| report | 报表定义、订阅任务、**导出任务管道（全站统一导出入口）** | 各模块公开只读视图；message（订阅推送） | 不直查业务表内部结构；不做实时大屏（v2 再议） |
| audit | 合规留痕：操作日志、登录日志、数据变更留痕（`audit_*` 表），`audit_log()` 唯一写入入口 | 全模块经统一 RPC 写入 | 不拥有技术排障日志（调用/执行明细归各模块，仅摘要进 audit）；不做告警规则引擎（audit 只供数） |
| integration | API 密钥、Webhook 订阅、调用技术日志（排障明细）、OpenAPI 文档 | access 的权限（密钥范围）；audit（调用摘要留痕） | 不做批量数据搬运（→ sync） |
| sync | 数据源连接、同步任务、执行技术日志（排障明细）、同步业务调度 | system 的 pg_cron 登记处；audit（执行摘要留痕） | 不绕过 RLS 直写业务表；不做实时 CDC（只做定时/手动批量） |
| system | 基础设施服务配置（mail/storage/sms/push/auth）、参数、**跨模块共享码表（字典）**、**pg_cron 平台登记处与只读监控**、公告存储、版本信息 | 无（基础设施模块） | 不收编模块私有枚举（各模块迁移文件自管）；不投递公告（→ message）；不做业务参数语义 |
| message | 站内信、通知文案模板、发送记录、统一发送 RPC | system 的邮件/推送配置；approval 的事件触发 | 不做外部 IM 双向会话（只做单向通知）；不存 SMTP 密码 |

### 跨模块契约规则

1. **共享数据只经公开面**：模块对外暴露的表以 `_v` 视图或 `security definer` RPC 发布；他模块禁止 join 内部表。
2. **审计写入统一入口**：所有模块调 `audit_log(module, action, object_type, object_id, diff)` 写合规摘要，不自建合规日志表；技术排障明细（调用日志、执行记录）归各模块自持，仅摘要进 audit。
3. **通知发送统一入口**：所有模块（含公告投递）调 message 的发送 RPC（`send_notification(recipient, event_key, vars)`，模板按 event_key 渲染），不直连邮件/推送配置。
4. **凭据存储统一规范、分域持有**：一律 pgcrypto 加密 + 界面掩码（可解密使用）；基础设施服务凭据归 system，业务外部凭据（sync 数据源、integration Webhook secret）归各模块。入站验签可用哈希；出站签名必须 pgcrypto 加密存明文。
5. **调度统一登记**：任何用 pg_cron 的模块必须在 system 的平台登记处注册 job，`/system/jobs` 只读监控，启停操作回到各模块自己的调度页。
6. **RLS 随表走**：各模块拥有自己表的 RLS 策略与迁移；access 只提供角色/数据范围模型及共享 helper（scope 函数），他模块 RLS 引用之，不要求改 access。
7. **角色写入单通道**：`profiles.role` 的任何写入（含 UI 上的角色分配）必须走 access 的 `assign_role` RPC；org 的用户管理页只是该 RPC 的调用方。存量 `admin_update_profile` 在 access 交付窗口内收窄（移出 role 参数或内部转调 assign_role）。
8. **模板一词二义，命名区分**：approval 的叫「审批表单模板」，message 的叫「通知文案模板」，代码/文档/界面不得混称「模板」。
9. **新增跨模块依赖**：先改本表并在模块 README 记录，禁止暗依赖。
10. **内部 RPC 调用来源校验**：定位为「全模块入口」的 RPC（如 audit_log、send_notification、emit_event、get_service_config、register_cron_job、audit_login、request_export 等，名单为例举）不得直接 GRANT 给 authenticated；仅 GRANT 给后端通道（SECURITY DEFINER wrapper 或专用数据库角色），wrapper 内部按业务规则校验（如收件人=本人相关）。函数无法可靠识别「调用模块」，禁止以「模块标记」做安全依据。

### RLS 统一声明模板（各模块开发文档引用）

```markdown
## RLS

- 表级策略（二选一，按表敏感级）：
  - 敏感表（含权限/角色/凭据/审计）：无任何角色的表级写，写仅经 SECURITY DEFINER RPC；
  - 普通表：admin 表级全权，其他角色仅 SELECT 本人相关，写经 RPC。
- 函数级：SECURITY DEFINER + `set search_path = ''` + 全限定名（沿用现有 app schema 约定）；定时/后台执行注入任务属主身份（`request.jwt.claims` 注入 owner sub），禁止 service_role（BYPASSRLS）。
- 触发器：SECURITY DEFINER + `set search_path = ''` + 全限定名（防 schema 劫持）。
- 测试：pgTAP 用例覆盖 越权读/写拒绝、角色切换后数据范围收窄、SECURITY DEFINER 函数 search_path 固定。
```

### 全局 schema 与 search_path 约定

- 沿用现有实现：业务对象在 `public`，辅助函数在 `app` schema；**不引入独立模块 schema**。
- 所有 SECURITY DEFINER 函数/触发器：`set search_path = ''` + 全限定名引用（与 `migrations/20261003145039` 现状一致）。
- 后台/定时任务执行身份统一模型：手动触发=触发人身份；定时触发=任务属主身份（claims 注入 owner sub）或专用最小角色（如 `job_runner`，仅授予必要表的最小权限）。**全局禁止 service_role**。

### 模块 RLS 边界速查

| 模块 | 表前缀 | 写入方式 | 读取范围 | 特殊说明 |
|---|---|---|---|---|
| dashboard | 无（只读视图） | 无 | 按数据范围过滤 | 消费各模块 `_v` 视图与公开 RPC |
| org | `departments`, `positions` | SECURITY DEFINER RPC | admin 全权；登录用户只读全树（选人需要） | profiles.role 写入单通道走 access RPC |
| access | `roles`, `role_menu_grants`, `role_data_scopes`, `menu_items` | SECURITY DEFINER RPC | admin 全权；其他角色只读角色名录 | 提供 scope helper 供他模块引用 |
| approval | `approval_*` | SECURITY DEFINER RPC（表级仅 SELECT 本人相关） | assignee/initiator/cc 本人；admin 只读全部 | act/withdraw/已读全部经 RPC；表单模板/流程仅 admin 可写 |
| report | `report_*` | SECURITY DEFINER RPC | owner/admin；public 报表全员可读 | 标识符仅取白名单映射，值全部参数化 |
| audit | `audit_*`（含 `audit_row_version_whitelist`） | append-only（仅 audit_log RPC，不 GRANT authenticated） | admin 全量；登录日志本人可读自己 | 触发器 search_path 固定；发布 `audit_operations_v`/`audit_denied_v` |
| integration | `api_keys`, `webhooks`, `integration_call_logs`, `api_docs` | SECURITY DEFINER RPC | 仅 admin | API key 校验后签发短期 JWT（role=api_client_role） |
| sync | `sync_*` | SECURITY DEFINER RPC | 仅 admin | 执行注入任务属主身份；profiles 字段映射排除 role/status |
| system | `system_*` | SECURITY DEFINER RPC | admin 全权；get_setting/get_dict 全员可读 | 服务配置凭据加密 + 掩码 |
| message | `messages`, `message_deliveries`, `message_templates`, `message_event_registry` | SECURITY DEFINER RPC（表级仅 SELECT 本人行） | recipient 本人；admin 全量 | send_notification 不 GRANT authenticated（规则 10） |

## 多 agent 协作约定

1. **模块内文档**：子文档（roles.md 等）即规格，模块 README.md 仅做索引；拆工单遵循 `/to-tickets`。
2. **跨模块依赖**：前置依赖一律精确到**工单号**（如 audit/001），「模块已上线」不作为闸门（模块上线 = 该模块 P0 工单全绿，P1 工单单独排期）；跨阶段依赖允许（P1 工单可依赖他模块 P0 工单），排期按依赖边拓扑序而非阶段标签；认领前确认前置工单已合入。
3. **状态同步**：认领以 GitHub issue 分配为唯一事实源（防并发认领）；README.md 总表只作投影，只允许改自己认领的行。
4. **全局规范**：DESIGN.md（设计）、docs/PLAN.md（架构与 RLS 约定）、docs/agents/（技能配置）对所有模块生效。
5. **文档更新**：完成工单后更新 docs/modules/README.md 状态与对应子文档，CHANGELOG 以 git 历史为准（不单独维护文件）。

### M0 底座里程碑（先于所有业务模块）

以下工单是全局隐式前置，必须先于对应消费方合入；由 Wave 0 派发：

| 工单 | 产物 | 消费方 |
|---|---|---|
| audit/001-002 | `audit_log()` + append-only 表 | 全部模块（checklist 写审计摘要） |
| audit/006 | `audit_row_versions` 表 | org/access 等带快照触发器的表 |
| message/001-003 | `messages` 表 + `send_notification` + 收件箱 | approval、report、system/announcements、dashboard |
| access/005（前半） | `menu_items` 一次性 seed 全 10 模块路由（数据源=README 路由表）+ `register_menu_item` RPC | 全部模块的菜单登记 |
| job runner ADR | 后台执行身份统一模型（见全局约定）+ 出站运行时选型（pg_net+pg_cron vs Edge Function）；产出 docs/adr/，被引用方式 = 各模块 AGENT 常见陷阱 + 派发波次约束（Wave 0 手动钉住） | sync、report、integration、message |

### 共享工件冲突规则

| 工件 | 规则 |
|---|---|
| `app-sidebar.tsx` | 结构性改造唯一写者为 access/008（菜单改造窗口）；此前 org/008 仅允许修改既有菜单项的 route 字符串与 301，不得增删菜单项；此后新菜单只经 `register_menu_item` 登记 |
| `site-header.tsx`（PAGE_TITLES） | 只追加行，键=完整路由；合并冲突双向保留 |
| `database.types.ts` | 生成物：**冲突解决=删除后重生成**，禁止手工合并 |
| `supabase/migrations/*` | 迁移只建本模块对象；跨模块引用走函数/视图晚绑定；依赖工单合入后再生成迁移；profiles 等共享表按波次串行（org 先、access 后） |
| `supabase/migrations/*`（序号） | 同模块并行工单：迁移序号按工单号 × 10000 预分配段（im/005 → 170000、im/006 → 180000、im/007 → 190000、im/008 → 200000） |
| `supabase/seed.sql` | 拆分为按模块多文件（`config.toml` 的 `sql_paths`） |
| `src/lib/dictionaries.ts` | 先冻结接口，再并行追加条目；system 字典读取层改造排最后 |
| `users-table.tsx` | 串行：access/003（assign_role）先合，org/009（角色下拉切换）后接 |

## 认领流程

1. 读 README.md 总表，确认模块状态为「待立项」且前置依赖已就绪。
2. 在对应模块目录创建 `README.md` 写明规格（范围、数据模型、页面、RLS）。
3. 更新 README.md 总表状态为「开发中（agent: <会话/工单标识>）」。
4. 用 `/to-tickets` 拆工单，逐条交付。
5. 全部工单完成后更新状态为「已上线」。
