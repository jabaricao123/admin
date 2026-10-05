# dashboard · 代理执行卡

## 模块状态
- 状态：✅ 已上线（001-004 已合入：概览统计切换 RPC + 待办/通知/公告横幅）；批 1-2 收敛已完成（2026-10-05）：统计切换到 org_stats、get_dashboard_stats 委托 deprecated、最近更新切换 audit.list_recent_changes、统计/最近更新性能索引与待办数封顶修复
- 认领 agent：—
- 最后更新：2026-10-05

## 快速开始
1. 读 [README.md](../README.md) 确认优先级与依赖
2. 读 [INDEX.md](../INDEX.md) 确认边界、M0 底座与共享工件冲突规则
3. 按「工单执行顺序」逐条交付

## 工单执行顺序（阻塞边，工单级）

| 序号 | 工单 | 前置依赖 | 阶段 | 预估工时 |
|---|---|---|---|---|
| 001 | 概览页回归 + 统计切换 org_stats/signup_trend RPC | **org/013** | P0 | 1h |
| 002 | 我的待办接入 approval my_todos RPC（pending/limit 签名） | **approval/005** | P1 | 2h |
| 003 | 我的通知接入 message RPC（recent_notifications/mark_all_read/unread_count） | **message/003** | P2 | 2h |
| 004 | 公告横幅（消费 system_announcements published 视图） | **system/013** | P1 | 1h |

## 验收 checklist（合并前必检）
- [ ] 卡片值与聚合 RPC 结果一致（数字断言）
- [ ] 待办/通知卡片空态显式呈现
- [ ] 非 admin 数据范围正确过滤（过滤后集合断言）
- [ ] 页面标题已在 `site-header.tsx` 的 `PAGE_TITLES` 注册（只追加行）
- [ ] 文档更新

## 常见陷阱
- 概览页是只读视图，不建业务表；统计走 org 公开 RPC（范围过滤在 RPC 内）
- 未读数以 messages.read_at 为唯一事实源（与 approval_ccs 无双计数）

## 契约引用
- 上游：org/013、approval/005、message/003、system/013
- 下游：无（首页入口）
- INDEX 规则：1（共享数据只经公开面）
