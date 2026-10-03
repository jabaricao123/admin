# 审计中心 · 登录日志

| 项 | 值 |
|---|---|
| 路由 | /audit/logins |
| 状态 | P1，待立项 |
| 模块 | [audit](../README.md#6-审计中心-auditp1) |

## 目的

登录行为留痕：成功/失败、时间、IP、设备，支撑安全排查与非管理员自查。

## 功能需求

1. 列表：时间、用户、结果（成功/失败）、失败原因、IP、设备（UA 解析）、归属地（P2，可延后）。
2. 筛选：用户、结果、时间段。
3. 本人自查视图：普通用户可看自己的登录记录（安全自查），不见他人。
4. 异常提示：同账号短窗口多 IP 失败在详情中标警示。
5. 导出走 report 导出管道。

## 数据模型

`audit_logins`：id、user_id、success bool、fail_reason、ip、ua、created_at（append-only）。
写入路径（二选一调研后定主路径）：Supabase Auth hook（Custom Access Token hook 覆盖成功登录；Password Verification Attempt 类 hook 覆盖失败尝试）或服务端打点；统一走 audit 域 RPC `audit_login(...)`（不 GRANT authenticated）。

## RLS

- admin SELECT 全量；普通用户 SELECT user_id = auth.uid()（本人自查）。
- 写入仅经 `audit_login(...)` RPC（不 GRANT authenticated，INDEX 规则 10）。

## 界面规格

- 列表页模式：结果 Badge（成功绿/失败红）；移动端卡片。

## 依赖与契约

- 不依赖他模块；Auth hook 配置变更在 system 身份认证页同步说明（文档互链）。

## 验收标准

- 登录成功与失败均即时有记录；普通用户无法看到他人记录（pgTAP）。
