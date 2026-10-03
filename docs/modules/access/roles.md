# 权限管理 · 角色管理

| 项 | 值 |
|---|---|
| 路由 | /access/roles |
| 状态 | P0，待立项 |
| 模块 | [access](../README.md#3-权限管理-accessp0) |

## 目的

角色定义的单一事实来源：内置角色保护、自定义角色 CRUD，并为 `profiles.role` 写入提供单通道 RPC。

## 功能需求

1. 列表：角色名、标识、类型（内置/自定义）、用户数、状态、说明。
2. 新增/编辑：名称、唯一 code、说明、状态；内置角色（admin/engineer/planner/buyer/quality/supplier/customer，共 7 个，对齐 `user_role` 枚举）仅可改说明，不可删、不可改 code；外部角色（supplier/customer）本期仅读本人档案，不可分配内部权限。
3. 删除：有用户的角色不可删；删除为逻辑删除。
4. 用户数统计列；点击进入该角色用户列表（只读，链接到用户管理筛选态）。

## 数据模型

`roles`：id、name、code（唯一）、is_builtin bool、description、status、created_by/updated_by、时间戳。
RPC：`assign_role(target_user uuid, new_role text)`（唯一写 `profiles.role` 的通道，SECURITY DEFINER，内部校验当前用户为 admin，写 audit 摘要）。
存量迁移（分阶段，每阶段独立迁移 + pgTAP + 回滚点）：
1. 新增 `profiles.role_id → roles.id`（nullable）→ 回填 7 枚举值对应内置行；
2. 改造 `app.current_role()`/`app.is_internal()` 读 role_id（兼容期读枚举兜底）；
3. `admin_update_profile` 收窄：移出 p_role 参数或内部转调 assign_role 同逻辑；`handle_new_user` 改为写 role_id；
4. 前端切换（users-table 角色下拉调 assign_role）→ 删旧枚举列（最后一阶段）。
兼容读取期：role_id 与枚举列双写/双读，切换完成后删枚举。

## RLS

- admin 全权；其他角色 SELECT 角色名录（界面需要），一律禁止写。
- pgTAP：非 admin 调 assign_role 拒绝；内置角色删/改 code 拒绝（DB 约束兜底）。

## 界面规格

- 标准 列表页模式：工具栏 + Table + Sheet 编辑（右侧 35vw，不分端）；移动端卡片。
- 内置角色行加「内置」Badge（`dictionaries.ts` 配色）。

## 依赖与契约

- 消费方：org/users（角色分配 UI 调 assign_role）、approval（审批人按角色解析）、integration（密钥范围）。
- 公开发布 `roles_v`。

## 验收标准

- 任何路径写 profiles.role 只有 assign_role 一条（代码审查项 + RLS 收紧 UPDATE）。
- 旧 `admin_update_profile` 无法再写 role（参数移除或转调验证，pgTAP）。
- 内置 7 角色不可删/改 code（DB 约束兜底，pgTAP 覆盖全部 7 值）。
- 有用户的角色删除被拒且提示人数；用户数统计与实际一致。
