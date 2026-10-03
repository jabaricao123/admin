# 组织管理 · 岗位管理

| 项 | 值 |
|---|---|
| 路由 | /org/positions |
| 状态 | P0，待立项 |
| 模块 | [org](../README.md#2-组织管理-orgp0) |

## 目的

岗位名录维护：名称、编码、所属部门、编制数，支撑用户档案的岗位归属。

## 功能需求

1. 列表：分页、搜索（名称/编码）、按部门筛选。
2. 新增/编辑：名称、唯一编码、所属部门（单选）、编制数（≥0）、职责描述、状态。
3. 在岗人数统计列（实时 count profiles.position_id），超编仅警示不阻断（开放决策，先警示）。
4. 停用：被用户引用的岗位停用后不出现在新编辑下拉，存量引用保留显示。

## 数据模型

`positions`：id、name、code（唯一）、department_id → departments.id、headcount int、description、status、created_by/updated_by、时间戳。

## RLS

- admin 全权写；所有登录用户 SELECT（编辑用户时需选岗位）。
- pgTAP：非 admin 写拒绝、code 唯一冲突。

## 界面规格

- 标准 列表页模式（DESIGN.md §4）：工具栏 + Table + Sheet 编辑（右侧 35vw，不分端）；移动端卡片。
- 「在岗/编制」列显示 `3/5` 形式，超编标红 Badge。

## 依赖与契约

- department 下拉来自 `departments_v`；被 org/users 编辑 Sheet 消费（岗位下拉）。

## 验收标准

- 编码唯一由 DB 约束兜底（前端校验只是体验）；在岗人数与实际引用一致。
