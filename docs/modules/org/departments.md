# 组织管理 · 部门管理

| 项 | 值 |
|---|---|
| 路由 | /org/departments |
| 状态 | P0，待立项 |
| 模块 | [org](../README.md#2-组织管理-orgp0) |

## 目的

树形部门维护：创建、改名、调父级、排序、设负责人、启停用，为权限「本部门」数据范围提供骨架。

## 功能需求

1. 树形展示：层级缩进 + 展开折叠；搜索即时过滤。
2. 新增/编辑：名称、父部门、负责人（选人）、排序号、状态。
3. 调整层级：拖拽或「移动到」对话框（禁止把节点移到自己的子孙下，需循环检测）。
4. 停用：有在职人员的部门不可停用；停用部门不出现在选人下拉。
5. 删除策略：不物理删除（可追溯原则），只允许删空部门且置 status='deleted'（逻辑删除）。

## 数据模型

`departments`：id、name、parent_id（自关联，NULL=根）、leader_id → profiles.id、sort_order int、status（active/disabled/deleted，deleted 为逻辑删除终态，不单设 is_deleted）、created_by/updated_by、created_at/updated_at。
`departments_v`：含 path 路径串；过滤 status='deleted' 行；停用（disabled）部门保留在树中但选人下拉过滤。
辅助 RPC：`department_tree()` 返回闭包表或递归 CTE 结果；`validate_move(node, new_parent)` 防环。

## RLS

- admin 全权；其他角色 SELECT 全树（选人下拉需要）；非 admin 一律禁止写。
- pgTAP：防环约束、越权写拒绝、停用部门下人员约束各至少 1 例。

## 界面规格

- 桌面：树形 Table（缩进列）+ 顶部「新增部门」按钮 + 行内操作菜单。
- 移动端：卡片树（缩进缩放），操作收进右侧 Sheet（35vw，不分端）。
- 编辑用右侧 Sheet（35vw，不分端），保存成功 `toast.success("已保存")` + 刷新。

## 依赖与契约

- 被消费方：access（数据范围「本部门」读 departments 视图）、org/users（部门下拉）、org/chart。
- 对外发布 `departments_v`（含 path 路径串），禁止他模块 join 内部表。

## 验收标准

- 循环引用被服务端拒绝（RPC 校验为准，前端只做预警）。
- 停用含在职人员的部门被拒绝并提示人数。
- 树渲染：默认折叠至 3 级，点击展开；500 节点内首屏渲染 < 2s（桌面）；移动端可完整浏览与下钻。
