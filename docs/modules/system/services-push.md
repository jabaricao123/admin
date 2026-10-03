# 系统管理 · 消息推送

| 项 | 值 |
|---|---|
| 路由 | /system/services/push |
| 状态 | P1，待立项（预留） |
| 模块 | [system](../README.md#9-系统管理-systemp1) |

## 目的

IM 机器人 Webhook 配置（企业微信/钉钉），审批提醒等场景的补充触达通道，单向推送。

## 功能需求

1. 渠道配置：企业微信机器人 webhook、钉钉机器人 webhook（各自独立开关）。
2. 加 secret 的机器人（钉钉加签）：secret 加密存储 + 掩码。
3. 测试推送：向配置的机器人发测试消息。
4. @规则（P2 延后）：按手机号 @ 对应成员，依赖 profiles 手机号字段。

## 数据模型

`system_services`：service='push'，config jsonb + credentials bytea（加密）。

## RLS

- 仅 admin 可管理；读取口同 get_service_config（白名单：message）。

## 界面规格

- 双卡片（企业微信/钉钉）各自配置与测试；未配置渠道置灰。

## 依赖与契约

- 唯一消费方 message 发送 RPC；推送失败不影响主渠道投递（best-effort）。

## 验收标准

- webhook 失效时测试按钮给出可读错误；推送失败不阻塞站内信/邮件渠道。
