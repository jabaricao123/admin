# ADR-002: 登录日志写入路径（Auth hook 调研 → 服务端打点）

- 状态：已采纳（服务端打点主路径；Auth hook 保留为未来补充通道）
- 日期：2026-10-04
- 关联工单：audit/005（audit_logins 表 + 写入路径；退出条件「调研结论写 docs/adr/，未达预期回退服务端打点」）
- 关联实现：`supabase/migrations/20261004234500_audit_logins.sql`、`src/components/login-form.tsx`、`supabase/tests/audit_logins_test.sql`

## 背景

登录日志要求「成功与失败均即时留痕」，字段包含尝试邮箱、失败原因、IP、UA，并支持 admin 全量查询与普通用户本人自查（logins.md）。工单要求先调研 Supabase Auth hook（Custom Access Token hook 覆盖成功登录、Password Verification hook 覆盖失败尝试），未达预期则回退服务端打点。

## 调研结论（Auth hook 不可行原因）

本地 CLI（2.119）与云端均支持 `config.toml` `[auth.hook.*]` 注册（`pg-functions://` 或 HTTPS），但两类 hook 都无法满足本工单的数据契约：

| 维度 | Custom Access Token hook | Password Verification hook | 服务端打点（选定） |
|---|---|---|---|
| 触发时机 | 签发/刷新 token（刷新也触发，需去重） | 密码校验后 `{user_id, valid}` | 登录提交成功/失败分支 |
| 尝试邮箱 | 有（session claims） | **无**（仅 user_id；未知邮箱不触发） | 有（表单输入 + 会话邮箱归一） |
| IP / UA | **无** | **无** | `request.headers` 采集 |
| 本地/云端注册 | config.toml + 重启 stack；云端 Dashboard/管理 API | 同左，且依赖 GoTrue 版本 | 随迁移交付，零外部配置 |
| 失败影响面 | hook 报错影响签发 | hook 失败策略影响登录流程 | 留痕失败不阻断登录（await 但不拦截） |

关键否决点：两类 hook 的 payload 均不含 IP/UA，Password Verification hook 也不含失败尝试的邮箱且对未注册邮箱根本不触发；「同账号短窗口多 IP 失败」等安全排查依赖这两项数据。注册通道还存在本地/云端分叉（云端需单独配置且不可随迁移版本化），与本仓库「迁移即契约、本地/云端行为一致」的约定冲突。

**退出条件已触发**：按工单约定将调研结论写入本 ADR，写入路径回退为服务端打点。

## 决策

### 1. 主路径：登录页服务端交互打点

- `src/components/login-form.tsx`：`signInWithPassword` 成功后（会话已建立）与失败后（仍为匿名）分别调用 `public.record_login_attempt`；失败原因按错误文案归类为 `invalid_credentials` / `user_banned` / `other`。
- 打点请求 `await` 完成后再跳转/展示错误，保证「即时留痕」；打点自身失败不阻断登录（返回错误仅忽略，不弹窗）。
- 成功调用携带已建立的会话，服务端以会话邮箱为准（防止代写他人邮箱）；失败调用为匿名。

### 2. 分层与安全边界

| 层 | 函数 | 授权 | 职责 |
|---|---|---|---|
| 唯一写入入口 | `app.audit_login(uuid, text, boolean, text, inet, text)` | 不 GRANT API 角色（INDEX 规则 10） | 收口 identity/结果/原因/IP/UA；成功清空 fail_reason |
| 公开包装 | `public.record_login_attempt(text, boolean, text)` | GRANT anon + authenticated | 身份推导、会话邮箱归一、限流、request.headers 采集 |

- 匿名仅允许记录失败（`p_success = true` 时拒绝，42501）；`user_id` 由 `p_email` 在 `auth.users` 解析，调用方无法指定身份。
- 已登录：`user_id = auth.uid()`，邮箱以会话邮箱覆盖传入值。
- 防刷：同邮箱 1 分钟 ≤10 条，超限静默丢弃（返回 NULL），不报错以免成为账号探测信号。
- RLS：admin SELECT 全量；本人 `user_id = auth.uid()` SELECT（普通用户自查）。
- 表 append-only：API 角色无 INSERT/UPDATE/DELETE，序列不暴露。

### 3. Auth hook 的未来接入方式

若后续需要覆盖刷新 token、MFA、无密码等非表单登录路径（或云端统一接管），新增 hook 迁移并授权 `supabase_auth_admin` 直接调用 `app.audit_login` 即可，表结构与查询面无须变更；届时需新 ADR 评估去重与 IP/UA 缺失的补偿方案。

## 影响

- 登录日志完整性依赖前端上报：RPC 失败（网络/限流）可能少记；限流上限 10 条/分钟/邮箱，正常人工重试不受影响。
- 普通用户本人自查依赖写入时邮箱能解析到 user_id；未注册邮箱的尝试仅 admin 可见、user_id 为 NULL。
- pgTAP `audit_logins_test.sql`（38 条）覆盖：越权直写拒绝、匿名失败留痕与身份解析、会话邮箱归一、IP/UA 采集、限流、admin 全量 + 本人隔离。
