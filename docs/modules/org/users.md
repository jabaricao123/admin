# 组织管理 · 用户管理

| 项 | 值 |
|---|---|
| 路由 | /org/users（现为 /settings/users，立项时迁移并 301） |
| 状态 | ✅ 已上线，待路径迁移 |
| 模块 | [org](../README.md#2-组织管理-orgp0) |

## 目的

用户档案 CRUD、搜索筛选、启停用；角色分配的 UI 宿主（写入走 access RPC）。

## 功能需求

1. 列表：分页 20 条、搜索（姓名/邮箱）、筛选（角色/状态/部门）。
2. 编辑 Sheet：全名字、部门、岗位、状态；角色分配下拉（调 access RPC）。
3. 启停用：停用 = status 变更 + Supabase Admin API ban（吊销会话）；即时生效（登录被拒 + RLS 拦截已登录会话）。
4. 迁移：/settings/users → /org/users，旧路径 301，菜单与 PAGE_TITLES 同步。

## 数据模型

`profiles`（现状）：id、email、full_name、department（文本）、role、status、updated_by、时间戳。
立项时新增 `department_id uuid → departments.id`、`position_id uuid → positions.id` 外键；文本 department 迁移期双写，回填后转只读，最终删除（单一写源为 department_id）。

## RLS

- 现状对齐：internal 角色 SELECT 全部 profiles（通讯录/选人需要）；本人 SELECT/UPDATE 姓名与部门；role/status 无任何角色表级写，仅经 admin RPC。
- admin 经 RPC 全权（assign_role / admin_update_profile 收窄后）；启停用 = status 变更经 RPC。
- pgTAP：现有策略随迁移回归，补 department_id 更新路径用例。

## 界面规格

- 遵循 DESIGN.md §4 列表页模式：工具栏 + Table（列头居中）、Sheet 编辑（右侧 35vw，桌面/移动同组件，DESIGN v2.2）、移动端卡片。
- 角色/状态 Badge 用 `lib/dictionaries.ts` 配色。

## 依赖与契约

- 角色写入单通道：调 access 的 `assign_role(user_id, role)` RPC（INDEX 规则 7）。
- 部门下拉数据来自 departments 公开视图。

## 验收标准

- 旧路径访问 301 到新路径；非 admin 仍无法访问页面与数据（服务端二次校验 + RLS）。
- 角色分配经 access RPC 落库并写入审计摘要（audit_log）。
- 停用后该用户立即无法登录（Admin API ban 生效）且已有会话失效；启用后恢复。
