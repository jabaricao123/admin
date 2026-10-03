# 系统管理 · 对象存储

| 项 | 值 |
|---|---|
| 路由 | /system/services/storage |
| 状态 | P1，待立项（admin 专用） |
| 模块 | [system](../README.md#9-系统管理-systemp1) |

## 目的

S3/Supabase Storage 通道配置：endpoint、bucket、密钥、签名 URL 有效期、大小上限，供导出文件、附件（未来）统一存取。

## 功能需求

1. Provider 选择：supabase-storage（默认）/ s3 兼容。
2. 配置：endpoint、region、bucket、access_key、secret_key（加密+掩码）、签名 URL 有效期（分钟）、单文件大小上限、允许的 mime 白名单。
3. 测试连接：列出 bucket 可访问性验证。
4. 用量统计：bucket 占用（来自存储服务 API），趋势图（recharts）。

## 数据模型

`system_services`：service='storage'，config jsonb + credentials bytea（加密）。
读取口：`get_service_config('storage')`（白名单消费方：report 导出管道、sync Excel 导入、审批附件）。

## RLS

- 仅 admin 可管理；消费 RPC 校验来源域。

## 界面规格

- 配置表单 + 测试连接 + 用量卡片；有效期/上限用数字输入 + 单位提示。

## 依赖与契约

- bucket 不公开，所有访问经签名 URL（PLAN.md 存储约定）。
- 本页只管通道；文件生命周期（如导出 7 天过期）归各消费方声明，清理任务在 pg_cron 登记处注册。

## 验收标准

- 密钥错误时测试连接失败且不可保存；签名 URL 超时后访问 403；超限文件上传被拒。
