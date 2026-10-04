# 权限管理 · 数据权限

| 项 | 值 |
|---|---|
| 路由 | /access/data-scopes |
| 状态 | P0，待立项 |
| 模块 | [access](../README.md#3-权限管理-accessp0) |

## 目的

数据范围策略：每个角色定义可见数据范围（本人 / 本部门 / 本部门及以下 / 全部），以共享 helper 函数对接全站 RLS。

## 功能需求

1. 列表：角色 × 范围（self / dept / dept_tree / all）单选配置；「all」仅 admin 角色可配（功能规则，非仅验收）。
2. 范围解析 helper：`scope_user_ids()` / `scope_dept_ids()`（SECURITY DEFINER + search_path 固定，按当前用户角色返回可见 id 集），供各模块 RLS 策略引用；无会话上下文（auth.uid() 为空，如定时任务）时返回空集，由调用方显式注入属主身份后调用（见 INDEX 后台执行身份模型）。所属部门解析：`department_id` 指向 deleted/disabled 部门时视同无部门，dept/dept_tree 回退「仅本人」（部门集为空）。
3. 部门树范围基于 `departments_v` 的 path 串展开「及以下」。
4. 存量影响：现状 internal 角色可读全部 profiles（通讯录/选人需要）；存量角色初始 scope 显式设为 all（engineer 等），禁止「默认 self」；切换以显式迁移 + 回归验证推进（受影响面：通讯录、审批选人、组织图、工作台统计）。
5. 变更写审计摘要；配置页提供「以某用户视角预检」工具（列出该用户可见范围）。

## 数据模型

`role_data_scopes`：role_id（唯一）、scope 枚举、updated_by、时间戳。
helper 函数（access schema）：`scope_user_ids()`、`scope_dept_ids()`。

## RLS

- admin 全权；他模块 RLS 策略 IN (select scope_user_ids()) 引用（RLS 随表走，access 只供 helper，INDEX 规则 6）。
- pgTAP：四档范围各验证一表；改范围后旧数据可见性即时收窄。

## 界面规格

- 简单配置表：角色行 + 范围 Select，行内保存。
- 移动端同构（单列卡片）。

## 依赖与契约

- 消费 departments 树（org 公开视图）。
- 消费方：所有带数据范围的业务表 RLS。
- 首个消费方：org 用户列表 RPC `list_users`（admin 全量；非 admin 按 `scope_user_ids()` 过滤，返回 total + 行数据）。
- 页面接入条件：`/org/users` 现为 admin-only（用户管理是管理功能），待「非 admin 用户目录」场景立项后，直接将列表数据源切换为 `list_users`，页面守卫再按场景调整。

## 验收标准

- engineer（self）看不到他人档案；「本部门及以下」包含子部门人员；all 仅 admin 可配。
