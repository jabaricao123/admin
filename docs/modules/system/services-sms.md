# 系统管理 · 短信服务

| 项 | 值 |
|---|---|
| 路由 | /system/services/sms |
| 状态 | P1，待立项（预留，商业化启用） |
| 模块 | [system](../README.md#9-系统管理-systemp1) |

## 目的

短信通道配置（服务商、AccessKey、签名、模板），首期仅完成配置面骨架，发送能力待商业化前启用。

## 功能需求

1. 配置：provider（阿里云/腾讯云预设）、access_key_id、access_key_secret（加密+掩码）、sign_name。
2. 模板管理：模板 ID 登记表（名称、场景、模板 code、状态）——只登记，不管理服务商后台。
3. 测试发送：输入手机号发测试短信（需通道启用后；未启用时该按钮禁用并说明）。
4. 通道开关：全局启用/停用（停用时 message 的短信渠道自动降级为站内信）。

## 数据模型

`system_services`：service='sms'，config + credentials（加密）。
`system_sms_templates`：id、name、scene、provider_code、status、created_by/updated_by、时间戳（system_ 前缀，INDEX 表前缀约定）。

## RLS

- 仅 admin 可管理。

## 界面规格

- 配置表单 + 模板列表（简单 Table）；预留状态在页面顶部以 Banner 说明。

## 依赖与契约

- 消费方：message 发送 RPC（短信渠道）；启用前 message 不感知本配置。

## 验收标准

- 停用状态下 message 发送自动跳过短信渠道不报错；凭据加密与掩码符合通用约束。
