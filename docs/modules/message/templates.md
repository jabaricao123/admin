# 消息中心 · 通知文案模板

| 项 | 值 |
|---|---|
| 路由 | /message/templates |
| 状态 | P2，待立项（admin 专用） |
| 模块 | [message](../README.md#10-消息中心-messagep2) |

## 目的

通知文案模板：各业务事件的标题/正文模板与变量占位符，统一维护（命名区别于审批表单模板，INDEX 规则 8）。

## 功能需求

1. 列表：模板名、事件 key（如 approval.approved、sync.failed）、渠道（站内信/邮件/推送）、状态、更新时间。
2. 编辑：标题模板 + 正文模板，支持变量占位符 `{{initiator}}`、`{{title}}` 等（变量清单按事件注册表展示）。
3. 预览：输入样例变量值实时渲染效果（三渠道并列预览）。
4. 事件注册表：`message_event_registry` 表（见数据模型）；各模块声明事件与可用变量；未注册事件不可建模板。
5. 版本化：模板变更保留历史（可追溯），支持回滚上一版。

## 数据模型

`message_templates`：id、event_key、channel、subject_tpl、body_tpl、version、status、updated_by、时间戳；唯一约束 **(event_key, channel, version)**；当前版本指针（current_version）。
`message_template_versions`：template_id、version、快照。
`message_event_registry`（事件注册表）：event_key PK、module、description、available_vars jsonb、registered_by、created_at；各模块交付时经 `register_message_event(event_key, module, vars)` RPC 登记；未注册事件不可建模板。

## RLS

- admin 全权；其他角色不可见。

## 界面规格

- 列表页模式 + Sheet 编辑（等宽字体编辑模板）+ 预览 tab。

## 依赖与契约

- 事件注册表与各模块对接（approval/sync/report 等声明事件与变量）；send_notification 内部渲染模板。

## 验收标准

- 缺变量时渲染降级（显示占位符原文不报错）；回滚后历史保留；未注册事件无法创建模板。
