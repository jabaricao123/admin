# audit · 代理执行卡

## 模块状态
- 状态：P1 待立项（001/002/006 为 **M0 底座**，优先合入）
- 认领 agent：—
- 最后更新：2026-10-04

## 快速开始
1. 读 [README.md](../README.md) 确认优先级与依赖
2. 读 [INDEX.md](../INDEX.md) 确认边界、M0 底座与共享工件冲突规则
3. 按「工单执行顺序」逐条交付

## 工单执行顺序（阻塞边，工单级）

| 序号 | 工单 | 前置依赖 | 阶段 | 预估工时 |
|---|---|---|---|---|
| 001 | audit_operations 表 + audit_log RPC（5 参签名；不 GRANT authenticated） | 无 | **M0** | 2h |
| 002 | audit_operations RLS + pgTAP（append-only） | 001 | **M0** | 1h |
| 003 | audit_operations_v + audit_denied_v 公开视图发布 | 002 | P0 | 1h |
| 004 | 操作日志页面 | 003 | P0 | 3h |
| 005 | audit_logins 表 + 写入路径（Auth hook 调研定主路径；调研结论写入 docs/adr/，未达预期回退服务端打点） | 001 | P0 | 2h |
| 006 | audit_row_versions 表 + audit_row_version_whitelist（**M0 底座**） | 001 | **M0** | 2h |
| 007 | 数据变更页面（版本对比） | 006 | P0 | 3h |
| 008 | 合规报告（聚合 + HTML 打印导出） | 004, **report/007** | P1 | 3h |

## 验收 checklist（合并前必检）
- [ ] pgTAP 全部通过（append-only 禁止 UPDATE/DELETE）
- [ ] 触发器 SECURITY DEFINER + `set search_path = ''` + 全限定名
- [ ] admin 全量 + 登录日志本人可读自己（双向 pgTAP）
- [ ] audit_log 不 GRANT authenticated（越权调用 pgTAP）
- [ ] 文档更新

## 常见陷阱
- audit_log 是唯一写入入口（5 参签名：module/action/object_type/object_id/diff，与 INDEX 规则 2 一致）
- denied 留痕：RLS 静默拒绝不会自动写日志，需应用层捕获 42501 调 audit_log('denied')
- 触发器定义随各表迁移（org/011 等），audit 只拥有快照表与查询面
- INSERT 首版 version=1（非仅 UPDATE/DELETE）

## 契约引用
- 上游：全模块（经 wrapper 调 audit_log）
- 下游：access/011（denied 视图）、report/001（操作活跃度）、dashboard（变更摘要）
- INDEX 规则：2（审计统一入口）、10（内部 RPC 授权）
