# 权限管理 · 菜单权限

| 项 | 值 |
|---|---|
| 路由 | /access/permissions |
| 状态 | P0，待立项 |
| 模块 | [access](../README.md#3-权限管理-accessp0) |

## 目的

角色 ↔ 菜单/按钮级授权矩阵：控制侧边栏与页面元素的可见性（前端过滤）+ 服务端守卫（真权限）。

## 功能需求

1. 授权矩阵：行 = 角色，列 = 菜单/按钮点（来自 `menu_items` 注册表）；勾选即授权。
2. 菜单点注册表 `menu_items`：路由级一次性 seed 全 10 模块（数据源 = docs/modules/README.md 路由表，M0 底座）；按钮级 key（规范 `module.menu.button`）由各模块交付时经 `register_menu_item(key, route, module)` RPC 惰性登记；CI 校验路由与注册表一致。
3. admin 角色永远全授权且矩阵锁定（不可编辑该行）。
4. 变更即时生效并写审计摘要；提供「按角色预览菜单」预检。
5. fail-open 兜底：`menu_items` 缺某路由时，侧边栏按角色默认可见并输出警告（过渡期），矩阵只渲染已登记项，未交付模块显示「未激活」。

## 数据模型

`menu_items`（注册表）：key、parent_key、module、label、route、sort_order。
`role_menu_grants`：role_id → roles.id、menu_key → menu_items.key、granted_by、granted_at，主键 (role_id, menu_key)。
RPC：`visible_menus()` 返回当前用户可见菜单树（sidebar 数据源）。

## RLS

- admin 全权；visible_menus 按当前用户角色过滤返回。
- pgTAP：无授权角色菜单不可见；admin 全量；越权改矩阵拒绝。

## 界面规格

- 桌面：矩阵表格，行头冻结；批量勾选 + 保存。
- 移动端：按角色逐个配置（选角色 → 勾选树）。
- 保存成功 `toast.success("授权已保存")`。

## 依赖与契约

- `app-sidebar.tsx` 改造为消费 `visible_menus()`（替换按 profiles.role 硬过滤的旧逻辑）。
- 各模块页面守卫引用菜单点 key 做服务端二次校验；RLS 仍为最终防线。

## 验收标准

- 去掉某角色某菜单勾选后：侧边栏不显示 + 直接输 URL 被服务端拦截 + 数据层 RLS 拒绝（三层一致）。
