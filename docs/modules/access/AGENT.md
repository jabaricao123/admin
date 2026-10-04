# access · 代理执行卡

## 模块状态
- 状态：开发中（001-011 已合入）
- 认领 agent：—
- 最后更新：2026-10-04

## 快速开始
1. 读 [README.md](../README.md) 确认优先级与依赖
2. 读 [INDEX.md](../INDEX.md) 确认边界、M0 底座与共享工件冲突规则
3. 按「工单执行顺序」逐条交付

## 工单执行顺序（阻塞边，工单级）

| 序号 | 工单 | 前置依赖 | 阶段 | 预估工时 |
|---|---|---|---|---|
| 001 | roles 表 migration + 7 内置角色 seed（含 supplier/customer） | **org/001** | P0 | 3h |
| 002 | roles RLS + pgTAP | 001 | P0 | 1h |
| 003 | assign_role RPC + 存量改造（admin_update_profile 收窄、handle_new_user 改写、app.current_role 兼容） | 001, 002 | P0 | 3h |
| 004 | 角色管理页面 | 003 | P0 | 3h |
| 005 | menu_items 注册表 + 全 10 模块路由 seed + register_menu_item RPC（**M0 底座**） | 001 | P0 | 2h |
| 006 | visible_menus RPC（sidebar 数据源，fail-open 兜底） | 005 | P0 | 1h |
| 007 | 菜单权限矩阵页面 | 006 | P0 | 4h |
| 008 | app-sidebar.tsx 改造（消费 visible_menus；**本工单独占 sidebar 文件**） | 006, org/008 | P0 | 2h |
| 009 | role_data_scopes + scope helper（存量角色初始 scope=all，禁默认 self） | 001, org/001 | P0 | 2h |
| 010 | 数据权限配置页面 | 009 | P0 | 2h |
| 011 | 权限审计视图（消费 audit_operations_v + audit_denied_v） | **audit/003** | P1（非上线阻塞） | 2h |

## 验收 checklist（合并前必检）
- [ ] pgTAP 全部通过
- [ ] 非 admin 越权测试（角色管理/菜单权限/数据范围）
- [ ] profiles.role 仅经 assign_role 写入；旧 admin_update_profile 无法再写 role（pgTAP）
- [ ] 内置 7 角色不可删/改 code（pgTAP 全覆盖）
- [ ] 侧边栏按角色过滤；直接输 URL 被服务端拦截；RLS 拒绝（三层一致）
- [ ] 审计摘要已写（前置 audit/001 已合入）
- [ ] 文档更新

## 常见陷阱
- 存量迁移分 4 阶段（新增 role_id → 回填 → 改函数/策略 → 切前端删旧列），每阶段独立迁移 + 回滚点
- scope helper 无会话上下文（auth.uid() 为空）返回空集，调用方注入属主身份
- access/001 前置 org/001 的理由：profiles 共享表迁移波次约定（org 先、access 后），防迁移序号与共享表 DDL 冲突（INDEX 共享工件规则）
- 菜单矩阵 admin 行锁定；fail-open 期间未登记路由默认可见 + 警告
- supplier/customer 外部角色仅读本人档案，不可分配内部权限

## 契约引用
- 上游：org/001（departments）、audit/001（audit_log）、audit/003（denied 视图，P1）
- 下游：approval（角色解析）、integration（api_client_role）、全部模块（菜单登记）
- INDEX 规则：6（RLS helper）、7（角色单通道）、共享工件规则（sidebar 独占）
