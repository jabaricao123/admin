# 接口/集成中心 · API 密钥

| 项 | 值 |
|---|---|
| 路由 | /integration/api-keys |
| 状态 | P1，待立项（admin 专用） |
| 模块 | [integration](../README.md#7-接口集成中心-integrationp1) |

## 目的

对外 API 凭据管理：签发、吊销、限范围、设有效期，外部系统以此访问本系统开放 API。

## 功能需求

1. 列表：名称、key 前缀（掩码）、 scopes（可访问模块）、状态、有效期、最近调用时间、创建人。
2. 签发：一次性展示完整 key（服务端生成，哈希落库），此后不可再查看。
3. 吊销：即时失效；吊销后调用 401。
4. 范围控制：sc 限到模块级只读/读写（对接 access 的角色能力模型，最小授权）。
5. 用量统计：近 30 天调用量（来自调用日志聚合）。

## 数据模型

`api_keys`：id、name、key_prefix、key_hash（唯一，sha256）、scopes jsonb、status、expires_at、last_used_at、created_by/updated_by、时间戳。
校验：中间件验哈希 + 范围 + 有效期；通过后签发短期 JWT（role=`api_client_role`，claims 带 scopes），PostgREST 按 JWT role 走 RLS（SET LOCAL 无法在中间件层生效，R5 修正）。scopes 来源：白名单视图清单（`report_allowed_views` 同源治理）映射模块级只读/读写。

## RLS

- 仅 admin 可管理；调用日志表按 RLS 分属（见 logs.md）。
- API key 校验后签发短期 JWT（role=`api_client_role`，claims 带 scopes），RLS 按该角色策略过滤（不绕过 RLS；api_client_role 仅授予白名单视图/表的最小权限）。

## 界面规格

- 列表页模式 + 签发向导（名称→范围→有效期→一次性展示 key，强调「关闭后不可再查看」）。

## 依赖与契约

- scopes 解析引用 access `roles_v` 能力；每次调用写调用日志 + audit 摘要（INDEX 规则 2）。

## 验收标准

- 吊销后请求立即 401；key 明文零落库零回显（审查项）；过期 key 拒绝。
