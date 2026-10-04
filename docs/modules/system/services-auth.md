# 系统管理 · 身份认证

| 项 | 值 |
|---|---|
| 路由 | /system/services/auth |
| 状态 | P1，已上线（system/006 只读区 + im/006 IM 配置区） |
| 模块 | [system](../README.md#9-系统管理-systemp1) |

## 目的

身份认证治理页，分两层：

1. **IM 登录配置区（im/006，可编辑）**：飞书 / 企业微信 / 钉钉三家凭据与启用切换、
   测试连接、清空绑定、密码登录全局开关、管理员联系方式 —— 全部经 system 模块 RPC
   落库并写审计。
2. **Supabase Auth 控制台参考区（system/006，只读）**：密码策略 / 会话时长 /
   OAuth 提供商 / 回调 URL 说明，标注「外部管理」并外链控制台。

## 功能需求

1. IM 配置：三家卡片（凭据掩码回显、留空保持、覆盖需完整重输）；启用三选一，
   切换弹确认并强制所有在线会话重新登录（不自动清空绑定）；「清空所有绑定」独立按钮
   二次确认；「测试连接」用已存或本次填写的凭据出站校验。
2. 密码登录开关：关闭后 `/login` 隐藏密码 Tab；应急管理员经 `/login?admin=1`
   且仅名单内 `role=admin` / `status=active` 账号放行（服务端二次校验）。
3. 管理员联系方式：`im_not_bound` 时登录页展示 + 一键复制。
4. 只读参考区：当前 Auth 配置摘要（含回调 URL 清单与复制），变更引导至 Supabase 控制台。

## 数据模型

- `im_auth_configs`（im/001）：厂商配置与启用状态；凭据 pgcrypto 加密，界面只显示掩码。
- `system_settings`（im/006 新增键）：`im_admin_contact`（string）/
  `password_login_enabled`（bool）/ `password_login_admin_emails`（json 数组）。
- RPC（im/006）：`im_get_config`（掩码读取，写 `view_credentials` 审计）/
  `im_test_config`（出站校验，写 `test_connection`）/ `im_switch_provider`
  （三选一原子切换 + 删除 `auth.sessions` 全局签出，写 `switch_provider` + `force_logout`）/
  `im_clear_all_bindings`（写 `clear_bindings`）/ `im_get_login_options`（anon）/
  `im_password_login_allowed`（authenticated）。

## RLS

- 表与 RPC 边界归 system / im/001 迁移：`im_auth_configs` 无表级写、admin 列级只读；
  新 RPC 仅 GRANT authenticated（anon 只放 `im_get_login_options`），函数内 admin 校验。
- 仅 admin 可见本页；个人中心 `/settings/profile` 走 `im_bind_self` 自助通道（只写本人）。

## 界面规格

- 可编辑卡片区（厂商卡片 / 密码登录 / 联系方式）+ 只读参考卡片区；敏感操作确认弹窗
  （切换 / 覆盖凭据 / 清空绑定二次确认）；所有敏感操作可审计。

## 依赖与契约

- 上游：im/001（表 + 5 RPC）、im/002/004（厂商链路）、system/001（凭据加密）、audit/001（审计）。
- 绑定回调：登录扫码 `/auth/callback/<provider>`，个人中心绑定 `/settings/profile/bind/<provider>/callback`
  两者都需在厂商后台登记（飞书精确匹配）。

## 验收标准

- admin 零 SQL 完成「配置凭据 → 启用 → 录 userid → 用户扫码登录」全流程。
- 切换厂商后所有在线会话下一请求跳登录页；清空绑定为独立操作且不影响会话。
- 看凭据 / 改凭据 / 切换 / 清空 / 强制下线均可在 `/audit/operations` 查到。
- 非 admin 不可访问本页；普通用户在个人中心可自绑、无解绑入口。
