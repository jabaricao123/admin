# 系统管理 · 公告管理

| 项 | 值 |
|---|---|
| 路由 | /system/announcements |
| 状态 | 已交付（system/013+014，admin 专用；dashboard/004 消费 published_announcements_v） |
| 模块 | [system](../README.md#9-系统管理-systemp1) |

## 目的

全站公告的编辑与存档：内容与生效时段在本页维护，投递动作委托消息中心（INDEX 职责分工）。

## 功能需求

1. 列表：标题、生效时段、范围（全员/按角色）、状态（草稿/已发布/已下线）、发布人。
2. 新增/编辑：标题、正文（富文本，受限格式）、生效起止、可见范围、置顶标记。
3. 发布：保存草稿 → 发布（写 audit 摘要）；发布即调 message `send_notification`（全员事件 announcement.published，message 侧按受众分批投递：单次批次 ≤500 收件人，pg_cron 分片；**工作台横幅为主展示位，站内信通知为可选开关**，避免全员轰炸）。
4. 下线：生效期内可下线，已读历史保留；到期的自动归档（状态机）。
5. 预览：发布前预览移动端/桌面端展示样式。

## 数据模型

`system_announcements`：id、title、content（富文本 sanitized）、starts_at、ends_at、audience（all/role:xxx）、pinned、status（draft/published/offline/archived）、published_by、时间戳。
状态机：draft → published → offline/archived（到期自动）。

## RLS

- admin 全权；普通用户仅 SELECT published 且在生效期内 + 范围内（工作台横幅消费此视图）。

## 界面规格

- 列表页模式 + Sheet 编辑（富文本用受限编辑器：标题/列表/加粗/链接）。

## 依赖与契约

- 投递走 message 发送 RPC（INDEX 规则 3）；system 只存与管状态。
- 工作台横幅展示位由 dashboard 消费 published 视图。

## 验收标准

- 状态机流转非法跳转被拒（draft 不能直接 offline）；到期公告自动不再展示；范围外角色不可见（pgTAP）。
