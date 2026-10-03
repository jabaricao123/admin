# 审批中心 · 引擎（核心表与提交契约）

| 项 | 值 |
|---|---|
| 路由 | 无页面（引擎层） |
| 状态 | P1，待立项 |
| 模块 | [approval](../README.md#4-审批中心-approvalp1) |

## 目的

审批引擎核心：实例与任务表、提交入口 RPC、表单渲染注册契约——todo/mine/cc/flows 四份文档的共同地基。

## 核心表

`approval_instances`：id、title、module（来源模块）、ref_type/ref_id（业务对象）、template_version_id → approval_form_templates.id、flow_version_id → approval_flows.id、form_data jsonb、status（running/approved/rejected/withdrawn）、current_seq int、initiator_id、created_at/updated_at。

`approval_tasks`：id、instance_id、seq、assignee_id、status（pending/approved/rejected/skipped）、acted_at、comment、created_at，唯一约束 (instance_id, seq) 防并发双审。

## 状态机

```text
running ──act(approve, 末节点)──▶ approved
running ──act(reject)───────────▶ rejected
running ──withdraw(首节点未处理)─▶ withdrawn
```

## 提交契约

`submit_instance(module, ref_type, ref_id, template_code, form_data jsonb)` RPC：
1. 按 template_code 取当前发布版模板与绑定流程；schema→Zod 校验 form_data；
2. 事务内建实例 + 首节点任务（审批人经 resolve_approver 解析）；
3. 写 audit 摘要 + 调 message `send_notification(assignee, 'approval.pending', vars)` + `emit_event('approval.submitted', payload)`。

## 表单渲染注册契约

各业务模块注册：`register_form_renderer(module, ref_type, renderer_key)`；审批详情页按 renderer_key 渲染只读表单（渲染组件由各业务模块提供，approval 不承载业务表单数据）。

## RLS

- 表级仅 SELECT 本人相关（initiator/assignee/cc）；写全部经 RPC（INDEX 敏感表二分）。
- pgTAP：并发 act 同任务仅一次生效（唯一约束）；非 assignee act 拒绝；submit 的 Zod 校验失败拒入。

## 依赖与契约

- 上游：access 角色（审批人解析）、org 部门负责人（departments_v.leader_id）、message 发送、integration emit_event。
- 下游：todo/mine/cc 页面、dashboard 我的待办（公开 RPC `my_todos(pending boolean default true, limit int default 20)`）。

## 验收标准

- submit→首节点任务可见→act 通过→末节点后实例 approved 全链路 pgTAP。
- 撤回仅 running 且当前任务 pending 时允许；已被 act 的任务不可再 act。
