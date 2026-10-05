# 系统管理 · 凭据加密密钥轮换预案

| 项 | 值 |
|---|---|
| 路由 | 无（后端预案；触发入口 `public.rotate_encryption_key()` RPC，admin） |
| 状态 | 已就绪（system 批次 2 修复项 1；本地已验证） |
| 模块 | [system](../README.md#9-系统管理-systemp1) |

## 目的

定义 `app.encryption_key`（凭据加密主密钥）的**容错语义**与**轮换操作手册**：密钥缺失、
轮换、密文损坏时系统如何表现，管理员如何安全地完成一次原子轮换，以及失败时如何回退。

## 现状（v1 轻量方案）

- 密钥表 `app.encryption_key` 单行 `key_id = 1`；`app.encrypt_secret` / `app.decrypt_secret`
  固定读取该行（`system/001`）。
- 本地开发密钥由迁移 `gen_random_uuid()` 随机生成，**不落版本库**；生产禁止把密钥写进迁移。
- 使用同一密钥的密文列（轮换必须全覆盖）：

| 表 | 列 |
|---|---|
| `public.system_services` | `credentials` |
| `public.webhooks` | `secret_enc`、`headers_enc` |
| `public.sync_sources` | `credentials` |
| `public.im_auth_configs` | `credentials` |
| `app.im_wecom_token_cache` | `access_token`（可再生成的临时缓存，轮换时清空） |

## 容错语义（密钥缺失 / 密文损坏时）

| 读取口 | 行为 |
|---|---|
| `app.get_service_config` | `raise` 可读错误「凭据解密失败，可能密钥已轮换（service=…）」——消费方（message 渠道分发）捕获后降级为站内信并在投递记录 `error` 留痕 |
| `app.get_service_status` | **逐行守卫**：坏行 `verify_status` 显示 `failed`、掩码位显示 `解密失败`、`config._decrypt_error` 附原因；其他行照常返回，**不锁死整页** |
| `app.get_push_status` | 凭据解密/解析失败 → 两渠道 `secret_masked = '解密失败'`（不再伪装「未配置」）；服务级状态由 `get_service_status` 显示 `failed` |

## 轮换流程（Runbook）

前置：以 `admin` 身份调用（函数内 `app.current_role()` 校验）；操作前记录首次审计基线。

1. **预检** — 确认当前密钥存在且无坏密文（坏行会阻断轮换，这是有意的原子性保护）：

   ```sql
   select count(*) from app.encryption_key where key_id = 1 and key <> '';
   ```

   坏行定位：分别对上述密文列执行 `pgp_sym_decrypt(col, 旧key)`（或调用各读取口），
   找到报错行后由业务方重新保存该凭据，再继续。

2. **执行轮换**（事务内原子完成：旧 key 解密 → 新 key 重加密 → 切换 key_id=1 → 写审计）：

   ```sql
   select public.rotate_encryption_key();
   ```

   返回各表重加密行数：`{system_services, webhooks_secret, webhooks_headers, sync_sources, im_auth_configs, im_token_cache, rotated_at}`。

3. **验证** — 抽查代表行解密内容不变：

   ```sql
   select app.decrypt_secret(credentials) from public.system_services where service = 'mail';
   select app.decrypt_secret(secret_enc) from public.webhooks limit 1;
   ```

   并确认审计已落：`audit_operations` 中 `module='system' / action='rotate' / object_type='encryption_key'`。

4. **失败处理** — RPC 任意一行解密/重加密失败即 `raise` 且**整体回滚**：旧密钥、旧密文原样保留，
   无中间态；修复坏行后重新执行即可。轮换失败不产生部分重加密数据。

## 原子性与并发

- 全流程在单条 RPC 事务内；`key_id=1` 的切换在最后一步，并发读会话在提交前经 MVCC 始终看到
  旧密钥 + 旧密文，不存在「一半新一半旧」的可读状态。
- 两个并发轮换由 `pg_advisory_xact_lock(hashtext('app.rotate_encryption_key'))` 串行化。
- 企业微信 `access_token` 缓存为可再生成数据，轮换时直接清空（下次调用自动回填），
  不构成业务中断。

## 限制与 v2 backlog

| 限制 | 说明 / v2 方向 |
|---|---|
| 无逐行密钥版本 | 轻量方案不做 `key_id` 列迁移；密文不带密钥版本，解密失败只能靠容错展示与重存修复 |
| 密钥在库内生成 | 当前用 `gen_random_bytes(32)` 生成；若生产要求外部 KMS/HSM 供钥，需扩展 RPC 入参并在应用层密闭传输 |
| 无旧密钥保留期 | 轮换后旧密钥即废弃（密文已全部重加密）；若将来支持「只加密新数据 + 旧数据懒迁移」，需引入多密钥行与密钥版本 |
| 大批量锁窗 | 单事务重加密全部行；行数很大时锁窗较长，v2 可按表分批 + 灰度（需配套逐行 key_id） |

## 依赖与契约

- 实现：`supabase/migrations/20261011010000_system_key_resilience.sql`。
- 测试：`supabase/tests/system_key_resilience_test.sql`（容错展示 / 轮换成功 / 失败回滚 / 越权）。
- 相关：`docs/modules/INDEX.md` 规则 4（凭据 pgcrypto 加密 + 界面掩码）、规则 10（内部 RPC 授权面）。
