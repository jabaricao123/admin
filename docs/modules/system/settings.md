# 系统管理 · 参数配置

| 项 | 值 |
|---|---|
| 路由 | /system/settings |
| 状态 | 已交付（system/007+008，admin 专用） |
| 模块 | [system](../README.md#9-系统管理-systemp1) |

## 目的

全局键值参数：业务开关与阈值集中管理，消费方按 key 读取，语义归各消费模块。

## 功能需求

1. 分组列表：按 group 展示（如 通用/安全/集成）；键、当前值、类型、说明、更新时间。
2. 编辑：按类型渲染控件（bool→开关、number→数字、string→文本、json→编辑器）；保存即生效（带缓存失效）。
3. 新增：仅 admin 且需登记 group、key、类型、说明（防无主参数：说明必填）。
4. 历史回溯：参数变更历史（值 + 操作人 + 时间），支持查看旧值。
5. 内置参数预置：分页大小、会话提醒阈值等随迁移 seed。

## 数据模型

`system_settings`：key（PK）、group、value jsonb、value_type、description、updated_by、updated_at。
`system_setting_history`：key、old_value、new_value、changed_by、changed_at。
读取口：`get_setting(key)` RPC（带缓存 TTL 60s，写操作即时失效缓存；缺 key 返回 NULL 并记 debug 日志，不报错）。

## RLS

- 全员可读（消费需要）；仅 admin 可写。

## 界面规格

- 分组 Table + 行内编辑或 Sheet；json 类型用等宽字体编辑器。

## 依赖与契约

- 语义归消费方（INDEX system NOT 项）：本模块只存与校验类型，不解释业务含义。

## 验收标准

- 修改后 get_setting 即时返回新值（缓存失效正确）；历史完整；无说明的参数无法创建。
