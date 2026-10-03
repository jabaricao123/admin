# 审计中心 · 合规报告

| 项 | 值 |
|---|---|
| 路由 | /audit/compliance |
| 状态 | P1，待立项 |
| 模块 | [audit](../README.md#6-审计中心-auditp1) |

## 目的

周期性合规汇总：按周/月聚合操作量、权限变更、异常登录，一键生成 PDF/HTML 报告。

## 功能需求

1. 报告参数：周期（周/月/季度）、范围（全系统/指定模块）。
2. 内容模块：操作总量与 Top 活跃用户、权限与角色变更摘要、登录失败/异常摘要、数据变更量趋势。
3. 生成：PDF（或可打印 HTML，首期 HTML + 浏览器打印）经 report 导出管道产出。
4. 历史报告列表：归档下载（对象存储）。

## 数据模型

只读聚合：`audit_operations_v` / `audit_logins` / `audit_row_versions`。
`compliance_reports`（归档记录）：id、period、range、file_url、generated_by、created_at；文件保留 1 年，过期清理（pg_cron 任务在 system 登记处注册）。
报告形态：首期 HTML + 浏览器打印（@media print 适配 A4）；PDF 经 report 导出管道（v2）。

## RLS

- 仅 admin；报告内容聚合时不受个人范围过滤（admin 视角全量）。

## 界面规格

- 参数表单 + 历史列表；报告页面打印样式（@media print）适配 A4。

## 依赖与契约

- 聚合只读；文件产物走 report 导出管道与 system 对象存储。

## 验收标准

- 生成的数字与各明细页同周期统计一致；报告可重复下载直至过期清理。
