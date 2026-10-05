# 工作台 · 概览

| 项 | 值 |
|---|---|
| 路由 | /dashboard |
| 状态 | ✅ 已上线 |
| 模块 | [dashboard](../README.md#1-工作台-dashboard) |

## 目的

登录后首页：全局统计、注册趋势、最近更新，一屏掌握系统动态。

## 功能需求

1. 统计卡片：用户总数、本周新增、活跃用户、待办数（待办数依赖审批中心，P1 前显示 `—`）。
2. 注册趋势：近 30 天注册用户折线图（recharts）。
3. 最近更新：最近 10 条数据变更摘要（audit 公开 RPC `list_recent_changes(limit int)`，服务端聚合操作人姓名与变更类型；admin only 内部校验，非 admin 显式占位「需要管理员权限」）。
4. 公告横幅：生效期内且置顶的公告展示于页面顶部（消费 system `system_announcements` published 视图；无公告时不占位）。

## 数据模型

只读消费：概览统计走 org 公开 RPC `org_stats()`（20261005160000；范围过滤与角色判定在 RPC 内完成，非 admin 仅见本人待办），注册趋势走 `signup_trend(days int)`；`get_dashboard_stats()` 已收编为委托 `org_stats` 的兼容包装（deprecated，20261012110000）。最近更新走 audit 公开 RPC `list_recent_changes(limit int)`（20261012100000），页面不再直查 `audit_row_versions` / `profiles`。批量统计性能由 `profiles(created_at)`、`profiles(status)`、`audit_row_versions(changed_at desc, id desc)` 索引与单趟聚合保障（20261012120000）。

## RLS

- 视图数据按当前用户可见范围过滤；非 admin 不见全局统计，仅见本人相关。

## 界面规格

- 卡片 `SectionCards`，`@xl/main:grid-cols-2 @5xl/main:grid-cols-4`，移动端单列。
- 图表用 `--chart-1..5` 品牌绿梯度。
- 页面标题已在 `site-header.tsx` 的 `PAGE_TITLES` 注册。

## 依赖与契约

- 无前置模块（当前态）；待办卡片依赖 approval，变更摘要依赖 audit，均走其公开 RPC。

## 验收标准

- 卡片值与聚合 RPC 结果一致（数字断言）；非 admin 数据范围正确过滤（过滤后集合断言）；新卡片接入时旧卡片数字不漂移。
