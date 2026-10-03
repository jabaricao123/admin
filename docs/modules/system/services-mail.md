# 系统管理 · 邮件服务

| 项 | 值 |
|---|---|
| 路由 | /system/services/mail |
| 状态 | P1，待立项（admin 专用） |
| 模块 | [system](../README.md#9-系统管理-systemp1) |

## 目的

SMTP 邮件通道配置：主机/账号/密码/发件人，测试发送，为消息中心提供唯一邮件出口。

## 功能需求

1. 配置表单：host、port、secure（SSL/TLS）、username、password、from_addr、from_name、回复地址（可选）。
2. 密码 pgcrypto 加密落库、掩码显示、修改需重输完整值（INDEX 规则 4）。
3. 测试发送：输入收件邮箱发送测试信；**允许保存草稿（未验证）**并标记验证状态，已验证配置被修改后降级为「待复验」（防止改坏无法回滚）。
4. 连接状态：最近一次测试结果与时间常驻展示。
5. 环境变量模式：允许「仅用环境变量、库中不存」的部署形态（表单只读展示 env 引用名）。

## 数据模型

`system_services`（通用表，service 域分区）：service='mail'，config jsonb（非敏感）+ credentials bytea（加密）。
读取口：`get_service_config(service)` RPC（SECURITY DEFINER，仅白名单消费方：message 发送器）。

## RLS

- 仅 admin 可管理；get_service_config 不 GRANT authenticated（INDEX 规则 10），仅经专用数据库角色（如 message_sender）调用的 SECURITY DEFINER wrapper 放行。

## 界面规格

- 单页配置表单 + 「测试发送」按钮；保存成功 `toast.success("邮件配置已保存")`。

## 依赖与契约

- 唯一消费方是 message 发送 RPC（INDEX 规则 3）；本页不做发送历史（→ message/history）。

## 验收标准

- 错误凭据无法通过测试并给出可读错误；配置变更写 audit 摘要；message 侧能取到最新配置即时生效。
