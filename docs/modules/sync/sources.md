# 第三方数据同步 · 数据源配置

| 项 | 值 |
|---|---|
| 路由 | /sync/sources |
| 状态 | P1，待立项（admin 专用） |
| 模块 | [sync](../README.md#8-第三方数据同步-syncp1) |

## 目的

外部数据源接入管理：REST API / 外部数据库 / Excel 上传三类连接的定义与凭据保管。

## 功能需求

1. 列表：名称、类型（api/db/excel）、连接摘要（host/url 掩码）、状态、最近验证时间。
2. 新增/编辑：
   - API：base URL、鉴权（header/token/basic）、超时；
   - DB：引擎（postgres/mysql）、host、port、库名、账号密码；
   - Excel：模板文件上传至 system 对象存储（bucket: sync-templates），列映射在任务侧配置。
3. 凭据：pgcrypto 加密落库，界面掩码（`****1234`），修改需重输完整值（INDEX 规则 4）。
4. 测试连接：验证结果与时间记录；**允许保存草稿（未验证）**，标记「未验证」状态；启用任务前必须验证通过（Excel 源免测试，仅校验模板文件存在）。
5. 停用：有启用中任务的数据源不可停用。

## 数据模型

`sync_sources`：id、name、type（api/db/excel）、config jsonb（非敏感）、credentials bytea（加密）、status、last_verified_at、created_by/updated_by、时间戳。
加密钥：KMS/环境变量持有主密钥（不在库中）。

## RLS

- 仅 admin 可管理（含 SELECT：凭据已加密仍限管理员）。

## 界面规格

- 列表页模式 + 按类型分步表单（Sheet）；「测试连接」按钮异步反馈结果。

## 依赖与契约

- 被 sync/tasks 消费；测试连接的出网白名单在部署层配置（文档说明）。

## 验收标准

- 库内无明文凭据（pgTAP + 审查项）；测试失败给出可读原因；被任务引用的数据源无法停用。
