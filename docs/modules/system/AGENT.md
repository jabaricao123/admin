# system · 代理执行卡

## 模块状态
- 状态：开发中（001-003、007-009、011-014 已合入；004-006、010、015 已实现，待评审合并）
- 认领 agent：—
- 最后更新：2026-10-04

## 快速开始
1. 读 [README.md](../README.md) 确认优先级与依赖
2. 读 [INDEX.md](../INDEX.md) 确认边界、M0 底座与共享工件冲突规则
3. 按「工单执行顺序」逐条交付

## 工单执行顺序（阻塞边，工单级）

| 序号 | 工单 | 前置依赖 | 阶段 | 预估工时 |
|---|---|---|---|---|
| 001 | system_services 通用表 + pgcrypto 共享加密 helper | 无 | P0 | 3h |
| 002 | 邮件服务配置页面（草稿可存 + 验证状态机） | 001 | P0 | 2h |
| 003 | 对象存储配置页面 | 001 | P0 | 2h |
| 004 | 消息推送配置页面（预留） | 001 | P1 | 1h |
| 005 | 短信服务配置页面（预留，system_sms_templates 前缀） | 001 | P1 | 1h |
| 006 | 身份认证展示页面（只读 Admin API） | 001 | P1 | 2h |
| 007 | system_settings 表 + get_setting RPC（TTL 60s/缺 key NULL） | 001 | P0 | 2h |
| 008 | 参数配置页面 | 007 | P0 | 2h |
| 009 | system_dictionaries 表 + get_dict RPC（CI 校验兜底默认值一致） | 001 | P0 | 2h |
| 010 | 字典管理页面 + dictionaries.ts 读取层（**排最后，接口冻结后**） | 009, 全部加条目工单完成 | P0 | 3h |
| 011 | system_cron_registry 表 + register_cron_job RPC + system_cron_jobs_v | 001 | P0 | 2h |
| 012 | 定时任务监控页面（只读，健康阈值：超 2 周期警示/24h 失败率>50% 标红） | 011 | P0 | 2h |
| 013 | system_announcements 表 + 状态机 | 001 | P1 | 2h |
| 014 | 公告管理页面（发布调 message；横幅为主、通知可选） | 013, **message/001** | P1 | 3h |
| 015 | 关于/版本页面 | 001 | P1 | 1h |

## 验收 checklist（合并前必检）
- [ ] pgTAP 全部通过
- [ ] 凭据 pgcrypto 加密 + 掩码 + 修改需重输完整值
- [ ] 服务配置支持草稿保存 + 验证状态标记（改坏可回滚）
- [ ] pg_cron 登记处只读监控（无启停按钮，INDEX 规则 5）
- [ ] get_setting/get_dict 全员可读，写仅 admin
- [ ] 审计摘要已写（前置 audit/001 已合入）
- [ ] 文档更新

## 常见陷阱
- 基础设施凭据归 system，业务外部凭据归各模块（INDEX 规则 4）
- 定时任务启停回各模块调度页，本页零操作按钮
- 字典只收跨模块共享码表；dictionaries.ts 改造排最后（共享工件规则）
- get_service_config 不 GRANT authenticated（INDEX 规则 10），仅白名单后端通道

## 契约引用
- 上游：audit/001、message/001（014）
- 下游：message/009（渠道配置）、report/005+007（cron+storage）、sync/007（cron 登记）
- INDEX 规则：4（凭据分域）、5（调度登记）、10
