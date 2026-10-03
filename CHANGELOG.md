# Changelog

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循语义化版本。

## [Unreleased]

### Added
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
