# 审批中心 · 审批表单模板

| 项 | 值 |
|---|---|
| 路由 | /approval/templates |
| 状态 | P1，待立项（admin 专用） |
| 模块 | [approval](../README.md#4-审批中心-approvalp1) |

## 目的

审批表单模板：定义某业务单据提交时要填的字段（名称明确叫「审批表单模板」，INDEX 规则 8，区别于 message 的通知文案模板）。

## 功能需求

1. 列表：模板名、code、适用来源模块、版本、状态。
2. 字段设计器：拖拽/表单式添加字段（label、字段名、类型：文本/数字/日期/单选/多选/附件、必填、默认值、选项）。
3. 版本化：发布新版本生成 version+1；进行中实例绑定旧版本不受影响（可追溯原则）。
4. 预览：按当前定义渲染表单样例。
5. 停用：无进行中实例引用时允许。

## 数据模型

`approval_form_templates`：id、name、code、module、version、schema jsonb（字段定义）、status（draft/published/disabled）、created_by/updated_by、时间戳；唯一约束 **(code, version)**；实例引用具体 template_version_id（见 engine.md）。
约束：仅 draft 可编辑；发布后 schema 不可变（新版本才可改）。

## RLS

- admin 全权；其他角色不可见（管理页）。
- pgTAP：发布版本不可变；非 admin 写拒绝。

## 界面规格

- 桌面：左侧字段列表 + 右侧属性面板 + 顶部预览 tab。
- 移动端：仅预览与基础编辑（字段增删排序），复杂设计引导去桌面端。

## 依赖与契约

- 消费方：各业务模块提交审批时按模板 schema 渲染表单并校验（Zod 由 schema 动态生成）。
- 字段类型中的附件依赖 system 对象存储（P1 前隐藏附件类型）。

## 验收标准

- 同 code 新版本发布后旧实例仍按旧 schema 展示；schema 校验拒绝非法字段名。
