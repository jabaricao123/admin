# org · 代理执行卡

## 模块状态
- 状态：✅ 已上线（001-010 合入；011-014 待派）
- 认领 agent：—
- 最后更新：2026-10-04

## 快速开始
1. 读 [README.md](../README.md) 确认优先级与依赖
2. 读 [INDEX.md](../INDEX.md) 确认边界、M0 底座与共享工件冲突规则
3. 按「工单执行顺序」逐条交付

## 工单执行顺序（阻塞边，工单级）

| 序号 | 工单 | 前置依赖 | 阶段 | 预估工时 |
|---|---|---|---|---|
| 001 | departments 表 migration（树形部门，status 含 deleted 终态） | 无 | P0 | 2h |
| 002 | departments RLS + pgTAP | 001 | P0 | 2h |
| 003 | 部门管理页面（树形 Table + Sheet） | 001, 002 | P0 | 4h |
| 004 | positions 表 migration | 001 | P0 | 1h |
| 005 | positions RLS + pgTAP | 004 | P0 | 1h |
| 006 | 岗位管理页面 | 004, 005 | P0 | 3h |
| 007 | profiles 加 department_id/position_id 外键（双写过渡） | 001, 004 | P0 | 2h |
| 008 | 用户管理路径迁移（/settings/users → /org/users + 301；引用面：app-sidebar、PAGE_TITLES、recent-users-table） | 007 | P0 | 2h |
| 009 | 用户管理接入部门/岗位下拉 + 角色下拉改调 assign_role | 008, **access/003** | P0 | 1h |
| 010 | 组织架构图（只读树形图） | 003, 013 | P1 | 3h |
| 011 | audit 快照触发器接入（profiles/departments/positions） | **audit/006** | P1 | 1h |
| 012 | 菜单登记（register_menu_item 注册 /org/* 路由按钮点） | **access/005** | P0 | 0.5h |
| 013 | org_stats()/signup_trend()/department_headcount() 公开 RPC（dashboard/report/chart 消费） | 007 | P0 | 1h |
| 014 | 用户变更 emit_event 发射点（org.user_changed，写路径调 integration RPC） | 009, **integration/004** | P1 | 1h |

## 验收 checklist（合并前必检）
- [ ] pgTAP 全部通过：`supabase test db`
- [ ] 类型生成无 diff：`supabase gen types`
- [ ] 非 admin 无法访问 /org/*（服务端守卫 + RLS）
- [ ] 角色分配走 access `assign_role` RPC（009 起生效）
- [ ] 旧路径 /settings/users 301 到 /org/users
- [ ] 审计摘要已写 `audit_log()`（前置 audit/001 已合入）
- [ ] 文档更新：README.md 状态与子文档

## 常见陷阱
- departments 树防环：`validate_move` RPC 服务端校验，前端只做预警
- 停用含在职人员的部门被拒（提示人数）；status 单字段（active/disabled/deleted），不单设 is_deleted
- profiles.department 文本 → department_id 双写过渡，单一写源为 department_id
- 停用用户 = status 变更 + Admin API ban 吊销会话（非仅改表）

## 契约引用
- 上游：audit/001（audit_log）、audit/006（快照表）、access/003（assign_role）、access/005（菜单注册表）
- 下游：access（departments_v）、report（部门分布）、dashboard（org_stats）
- INDEX 规则：6（RLS 随表走）、7（角色写入单通道）
