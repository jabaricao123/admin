# 报表中心 · 自定义报表

| 项 | 值 |
|---|---|
| 路由 | /report/custom |
| 状态 | P1，待立项 |
| 模块 | [report](../README.md#5-报表中心-reportp1) |

## 目的

用户自建报表：选数据源（受限白名单视图）、选维度指标、选图表、保存与分享。

## 功能需求

1. 编辑器三步：数据源（白名单 `_v` 视图清单）→ 字段（维度/度量）→ 图表（表格/柱/折线/饼）。
2. 筛选条件：字段 + 操作符（= / in / between / like），时间字段默认范围。
3. 保存：命名、保存到「我的报表」；admin 可发布为「公共报表」；已发布可由 admin 取消发布（`publish_report_definition` / `unpublish_report_definition`，public → private 幂等）。
4. 分享：站内链接分享（接收人仍受自身 RLS 过滤，分享不越权）。

## 数据模型

`report_definitions`：id、name、source_view、config jsonb（维度/度量/筛选/图表）、visibility（private/public）、owner_id、时间戳与操作人。
`report_allowed_views`（白名单映射表）：view_name PK、allowed_columns jsonb、registered_by、created_at；新视图注册 = 本表登记 + INDEX 公开面登记（两步）。
执行层：`run_report(def jsonb)` RPC——**标识符（表/字段/分组/排序）仅取自白名单映射表 `report_allowed_views`（view_name、allowed_columns jsonb），值全部参数化**；禁止将用户输入直接拼为标识符（防注入，RLS 按策略过滤）。

## RLS

- private 仅 owner；public 全员可看；仅 owner/admin 可改；admin 可管理 public。
- 执行层 `run_report`：标识符仅取 `report_allowed_views` 白名单，值全部参数化（防注入，RLS 按策略过滤）。
- pgTAP：白名单外视图/字段注入尝试被拒。

## 界面规格

- 桌面：三栏编辑器（数据源/字段/预览）；移动端只读浏览 + 简单筛选。

## 依赖与契约

- 白名单视图由各模块在 INDEX 注册的公开面决定；新增视图需同步维护白名单表 `report_allowed_views`。

## 验收标准

- 白名单外视图/字段被 RPC 拒绝（注入尝试有 pgTAP 用例）；分享链接打开后数据仍按访问者权限过滤。
