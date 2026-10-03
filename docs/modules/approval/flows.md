# 审批中心 · 审批流程

| 项 | 值 |
|---|---|
| 路由 | /approval/flows |
| 状态 | P1，待立项（admin 专用） |
| 模块 | [approval](../README.md#4-审批中心-approvalp1) |

## 目的

流程定义：节点序列、审批人规则（按角色/按部门负责人/指定人）、条件分支，绑定表单模板构成完整审批配置。

## 功能需求

1. 列表：流程名、绑定模板、版本、状态、引用中的实例数。
2. 节点编辑：线性添加节点（顺序审批）；每节点设置审批人规则（角色 / 部门负责人 / 指定人）与超时时长（可选）。
3. 条件分支（P1 二期）：按表单字段值路由（等于/大于），先做单线性，字段留扩展。
4. 版本化：同模板逻辑，进行中实例绑旧版本。
5. 模拟运行：输入样例表单数据，展示将经过的节点与每步审批人。

## 数据模型

`approval_flows`：id、name、template_id、version、nodes jsonb（[{seq, approver_rule, timeout_hours}]；branches 数组为条件分支预留，P1 二期启用）、status（draft/published/disabled）、时间戳与操作人；唯一约束 (template_id, version)。
解析函数：`resolve_approver(node, initiator)`（按规则→access 角色 / org 部门负责人 departments_v.leader_id）。

## RLS

- admin 全权；运行时 RPC（提交、act）对所有登录用户开放但只操作自己的实例/任务。

## 界面规格

- 桌面：节点横向流程条（添加/删除/排序）+ 节点属性面板。
- 移动端：列表 + 只读查看流程结构。

## 依赖与契约

- 审批人按角色解析走 access `roles_v`；部门负责人走 org `departments_v.leader_id`。
- 节点超时提醒（P2）走 message。

## 验收标准

- 模拟运行结果与真实提交路径一致（同一解析函数）；按角色解析在角色改名后仍生效（按 id 非按名称）。
