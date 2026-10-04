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
3. 最近更新：最近 10 条数据变更摘要（`audit_row_versions`，admin；非 admin 显式占位「需要管理员权限」）。
4. 公告横幅：生效期内且置顶的公告展示于页面顶部（消费 system `system_announcements` published 视图；无公告时不占位）。

## 数据模型

只读消费：`profiles` 聚合统计走本模块公开 RPC（`get_dashboard_stats()`、`signup_trend(days int)`，范围过滤在 RPC 内完成；非 admin 不见全局统计）。原定 org/013 的 `org_stats()` 尚未合入，先以 dashboard_stats 落地，合入后可评估收敛。

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
