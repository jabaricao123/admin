# 报表中心 · 数据导出

| 项 | 值 |
|---|---|
| 路由 | /report/exports |
| 状态 | P1，待立项 |
| 模块 | [report](../README.md#5-报表中心-reportp1) |

## 目的

全站统一导出任务管道：任何模块的导出需求（报表、日志、名单）都经此异步生成文件并下载，不各建各的。

## 功能需求

1. 发起：各模块「导出」按钮 → 调 `request_export(source, config)`（source 来自注册表 `export_sources`：source PK、config_schema jsonb、owner_module；命名规范 `<module>.<entity>`，如 audit.operations、org.users）。
2. 任务列表：来源、条件摘要、状态（排队/生成中/完成/失败）、发起人、时间、文件大小。
3. 下载：完成后 7 天内可下载（对象存储签名 URL），过期清理。
4. 失败重试：一键重跑；保留失败原因。
5. 限额：单用户同时进行中任务 ≤3，防滥用。

## 数据模型

`export_jobs`：id、source、config jsonb、status、file_url、error、requested_by、时间戳。
worker：pg_cron 轮询排队任务（system 登记处注册）→ 生成 CSV/XLSX → 上传对象存储 → 回写 file_url。

## RLS

- requested_by = auth.uid() 或 admin；下载签名 URL 校验属主。

## 界面规格

- 列表页模式：状态 Badge、操作列（下载/重试）；进行中行显示 spinner。

## 依赖与契约

- 依赖 system 对象存储（bucket、签名 URL 有效期）与 pg_cron 登记处。
- 消费方（白名单导出源）：report 各报表、audit 各日志、org 用户名单。

## 验收标准

- 大数据量（1 万行）异步完成不阻塞页面；过期文件不可下载；限额生效。
