# Changelog

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循语义化版本。

## [Unreleased]

### Added
- IM 登录数据底座（im/001）：profiles 三列 IM userid 预绑定（UNIQUE + 格式 CHECK）、im_auth_configs 全局单选启用 + 凭据 pgcrypto 加密、5 个 RPC（im_bind_self / im_unbind / im_admin_set_userid / im_upsert_config / im_get_enabled_provider）
- docs/modules/ 模块开发文档体系 v1.4.3：10 模块 46 份规格 + 10 份 AGENT.md 执行卡 + INDEX 边界/契约/M0 底座/共享工件规则
- approval/engine.md：审批引擎核心表与 submit_instance 契约
- supabase/seeds/ 按模块多文件 seed（admin + 4 个内部角色测试账号）
- supabase/tests/ pgTAP 冒烟测试

### Changed
- seed.sql 拆分为 supabase/seeds/*.sql（config.toml sql_paths 通配）
- 模块标识 organization 简写为 org（路由 /org/*）

### Fixed（文档评审修正，v1.4.1-v1.4.3）
- service_role 全局禁令（BYPASSRLS），后台任务注入属主身份
- Webhook secret 改 pgcrypto 可解密加密（HMAC 出站签名）
- API key 校验后签发短期 JWT（替代中间件 SET LOCAL）
- 审批模板/流程版本化唯一约束含 version
- audit_log 签名统一 5 参；audit 公开面（operations_v/denied_v）定义
- 角色迁移：7 内置角色（含 supplier/customer）+ admin_update_profile 分阶段收敛
- org↔access、audit↔report 死锁解除（工单级依赖）
- Sheet 规范统一右侧 35vw 不分端（DESIGN v2.2）

## [0.2.0] - 2026-10-04

### Added — 10 模块全量交付（Wave 0-3，3416 pgTAP 全绿）
- org：departments/positions 树形与岗位管理、profiles 外键双写、组织架构图、用户管理迁移 /org/users（301）、org_stats/department_headcount 公开 RPC、org.user_changed 事件
- access：roles 7 内置角色、assign_role 单通道（admin_update_profile 收窄）、menu_items 54 条 seed + visible_menus、数据驱动 sidebar、role_data_scopes 四档 scope helper、权限审计页
- approval：引擎（instances/tasks/状态机/submit/act/withdraw）、模板设计器与流程配置（版本化、simulate_flow）、待办/发起/抄送三页面
- report：预置报表、自定义报表（run_report 白名单参数化）、订阅（cron+属主注入）、统一导出管道
- audit：operations/logins/row_versions 三 append-only、版本对比页、合规报告、登录打点（ADR-002）
- integration：api_keys（sha256+短期 JWT）、webhooks（pgcrypto secret+HMAC 签名+pg_net 投递器）、调用日志分区、OpenAPI 文档
- sync：sources/tasks/runs/schedules 全链路（映射白名单拒 role/status、冲突三策略、webhook 触发限流）
- system：服务配置五件套（mail/storage/sms/push/auth）、参数、字典、cron 登记处、公告、关于页
- message：站内信、事件注册表、通知模板版本化、渠道分发降级、发送记录
- dashboard：统计 RPC 化、我的待办/通知、公告横幅
- ADR-001 后台执行身份（禁 service_role、属主注入、pg_net+pg_cron）；ADR-002 登录打点路径
