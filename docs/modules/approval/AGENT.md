# approval · 代理执行卡

## 模块状态
- 状态：P1 待立项
- 认领 agent：—
- 最后更新：2026-10-04

## 快速开始
1. 读 [README.md](../README.md) 确认优先级与依赖
2. 读 [INDEX.md](../INDEX.md) 确认边界、M0 底座与共享工件冲突规则
3. 按「工单执行顺序」逐条交付

## 工单执行顺序（阻塞边，工单级）

| 序号 | 工单 | 前置依赖 | 阶段 | 预估工时 |
|---|---|---|---|---|
| 001 | 引擎核心表（approval_instances + approval_tasks，见 engine.md） | **org/001, access/001** | P0 | 2h |
| 002 | submit_instance RPC + 表单渲染注册契约（schema→Zod→renderer） | 001, **message/001** | P0 | 3h |
| 003 | act_task RPC + 状态机（端到端切片：submit→act→待办可见→pgTAP） | 002 | P0 | 2h |
| 004 | RLS + pgTAP（全套） | 003 | P0 | 2h |
| 005 | 我的待办页面（含 my_todos 公开 RPC：pending/limit 签名） | 004 | P0 | 4h |
| 006 | 我发起的页面（撤回/催办） | 005 | P0 | 3h |
| 007 | 抄送我的页面 | 005 | P0 | 2h |
| 008 | approval_form_templates 表（(code,version) 唯一）+ 版本化 | 001 | P0 | 2h |
| 009 | 审批表单模板设计器（admin） | 008 | P1 | 4h |
| 010 | approval_flows 表（(template_id,version) 唯一 + branches 预留） | 008 | P0 | 2h |
| 011 | 审批流程配置页面（admin） | 010 | P1 | 3h |
| 012 | 菜单登记 + emit_event 发射点（approval.submitted/approved/rejected） | 005, **access/005** | P0 | 1h |

## 验收 checklist（合并前必检）
- [ ] pgTAP 全部通过
- [ ] 审批动作原子（唯一约束 (instance_id, seq) 防并发双审）
- [ ] 驳回必填意见被服务端强制
- [ ] 审批人解析按 access 角色 / org 部门负责人（按 id 非名称）
- [ ] 通知走 message send_notification（前置 message/001 已合入）
- [ ] 表级仅 SELECT 本人相关；act/withdraw/已读全部经 RPC（敏感表二分）
- [ ] 审计摘要已写（前置 audit/001 已合入）
- [ ] 文档更新

## 常见陷阱
- 模板/流程版本化：唯一约束含 version，仅 draft 可编辑，实例绑具体版本
- 不承载具体业务表单数据（各业务模块自建表，register_form_renderer 注册渲染）
- 撤回仅 running 且当前任务 pending 时允许（engine.md 状态机）
- 首个切片先做端到端（001-005），多节点/条件分支后续扩展

## 契约引用
- 上游：org/001、access/001（角色解析）、message/001（通知）、audit/001
- 下游：dashboard/002（my_todos）、各业务模块（submit_instance）
- INDEX 规则：3、8、10
