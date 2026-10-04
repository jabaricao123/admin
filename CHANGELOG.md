# Changelog

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循语义化版本。

## [Unreleased]

### Added
- IM 配置页 + 账号绑定 UI（im/006）：`/system/services/auth` 扩展为可编辑——三家 IM 卡片（appid/secret/agentid 掩码回显、凭据加密保存、测试连接、启用三选一 + 切换确认弹窗 + 全局签出）、密码登录全局开关（关闭后 `/login` 无密码 Tab，应急管理员经 `/login?admin=1` 且仅名单内 active admin 放行）、管理员联系方式（`im_not_bound` 时登录页展示 + 一键复制）、清空所有绑定（二次确认）；`/org/users` 编辑抽屉新增「IM 账号绑定」区块（当前启用厂商高亮，走 `im_admin_set_userid` / `im_unbind`）；新增个人中心 `/settings/profile` + `/settings/profile/bind/[provider]/start|callback`（普通用户扫码自助绑定 `im_bind_self`，无解绑入口）；`site-header` PAGE_TITLES 追加「个人中心」（未部署，待排期）
- 数据库（im/006）：`system_settings` 三键（`im_admin_contact` / `password_login_enabled` / `password_login_admin_emails`）；新增 6 个 RPC（`im_get_config` 仅返回掩码并写 `view_credentials` 审计、`im_test_config` 三家出站校验、`im_switch_provider` 原子切换 + 删除 `auth.sessions` 全局签出（写 `switch_provider` / `force_logout`）、`im_clear_all_bindings`、`im_get_login_options`（anon）、`im_password_login_allowed`（authenticated））；掩码与厂商响应解析 helper（零 API 授权）（未部署，待排期）
- IM 扫码登录（im/002）：`/login` 扫码登录 Tab（飞书）、`/auth/im/[provider]/start` 授权跳转 + state 防代扫（httpOnly cookie，5 分钟一次性）、`/auth/callback/feishu` 回调（调 `im_handle_callback` 在 Postgres 内完成 code 换 token → userinfo → 预绑定匹配，再由 Auth admin generateLink + verifyOtp 签发标准 session）、未绑定 / 停用拒绝 + `/audit/logins` 留痕（`via='im_feishu'`）、厂商逻辑下沉 Postgres + 最小角色 `im_backend`（修复 service_role 越权读取凭据）（未部署，待排期）
- 数据库（im/002）：`audit_logins` 新增 `via` / `im_userid`；`app.audit_login` 扩为 8 参；新增 `public.record_im_login_attempt`（anon 失败 / 已登录成功 + 绑定一致性校验）；厂商逻辑 RPC `public.im_start_auth` / `public.im_handle_callback`（仅 GRANT 最小角色 `im_backend`；凭据解密与 `extensions.http` 出站均在 Postgres 内，secret 不出库）（未部署，待排期）
- 企业微信扫码 + App 内免登（im/004）：PC `qrConnect` / App 内 `oauth2/authorize`（`snsapi_privateinfo`，UA 含 `wxwork` 自动切换）；`/auth/callback/wecom`；`app.im_wecom_*` 厂商适配（gettoken 加密缓存、code 换 userid、响应解析、回调编排）；`im_start_auth` / `im_handle_callback` 签名不变、内部按 provider 分派；登录页扫码入口与错误文案随启用厂商自动切换；pgTAP 63 断言 + 本地 mock 全链路证据（未部署，待排期）
- 钉钉扫码 + WebView 免登（im/005）：PC / 端内共用 `login.dingtalk.com/oauth2/auth`（`scope=openid`、`prompt=consent`）；`/auth/callback/dingtalk`（兼容回调参数 `authCode`）；`app.im_dingtalk_*` 厂商适配（userAccessToken JSON POST → `contact/users/me`、响应解析、回调编排、无 token 缓存）；绑定键取企业内唯一且稳定的 `unionId`（接口不返回 userid，迁移注释说明理由）；`im_start_auth` / `im_handle_callback` 签名不变、内部按 provider 分派；`src/proxy.ts` 自动免登扩展钉钉 UA；pgTAP 50 断言 + 本地 mock 全链路证据（未部署，待排期）
- IM 登录数据底座（im/001）：profiles 三列 IM userid 预绑定（UNIQUE + 格式 CHECK）、im_auth_configs 全局单选启用 + 凭据 pgcrypto 加密、5 个 RPC（im_bind_self / im_unbind / im_admin_set_userid / im_upsert_config / im_get_enabled_provider）（未部署，待排期）
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
