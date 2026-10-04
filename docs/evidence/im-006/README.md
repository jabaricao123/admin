# im/006 验证证据（本地全链路 + mock 飞书端点）

本目录截图来自**本地全链路验证**（工单 im/006）：

- 应用：本地 `next dev`（本分支代码，端口 3001）+ 本地 Supabase（真实 Auth / RLS / audit）
- 飞书端点：本地 HTTPS mock（`accounts.feishu.cn` / `open.feishu.cn` 经 hosts 解析到本机，
  **仅存在于验证机器，未入库**）：授权页 / code 换 token / user_info（复用 im/002 mock），
  并追加 `tenant_access_token/internal`（供配置页「测试连接」出站校验）
- 出站可达性：Postgres 容器内 hosts 指向宿主机 + mock 自签证书加入容器 CA 信任
  （仅验证环境；生产为公网真实端点）
- 测试账号：`admin@example.com`（管理员）/ `engineer@example.com`（工程师，admin 手工录入绑定）/
  `planner@example.com`（计划员，个人中心自助绑定）
- 期间共享本地库中另有并行工单（im/005 钉钉）留下的数据（钉钉卡片凭据掩码），属正常现象

| 文件 | 场景 |
|---|---|
| 00-auth-config-initial.png | 配置页：三家 IM 卡片 + 密码登录开关 + 管理员联系方式（启用前） |
| 01-feishu-credentials-saved.png | 飞书凭据保存：输入框回显掩码（secret 全掩码），toast 确认 |
| 02-test-connection.png | 「测试连接」经 Postgres 出站到 mock：`飞书凭据有效` |
| 03-switch-provider-confirm.png | 启用厂商确认弹窗：「切换将强制所有在线用户重新登录」 |
| 04-auth-config-enabled.png | 启用飞书后：当前启用徽标 + 卡片高亮 + 开关状态 |
| 05-clear-bindings-confirm-1.png | 「清空所有绑定」第一次确认 |
| 06-clear-bindings-confirm-2.png | 「清空所有绑定」二次确认（不可撤销提示） |
| 07-users-drawer-unbound.png | `/org/users` 编辑抽屉 IM 区块：当前启用厂商高亮，其余置灰可编辑 |
| 08-users-drawer-bound.png | admin 手工录入飞书 userid → 已绑定徽标 + 清空入口 + toast |
| 09-profile-unbound.png | 个人中心（普通用户）：未绑定态 + 「扫码绑定」按钮，无解绑入口 |
| 10-profile-mock-authorize.png | 扫码绑定 → mock 飞书授权页 |
| 11-profile-bound.png | 回调内调 `im_bind_self` → 已绑定成功（`feishu_mock_unbound`） |
| 12-login-tabs.png | 登录页：密码 + 扫码双 Tab（密码登录开启时） |
| 13-engineer-scan-login.png | admin 已录入 userid 的用户扫码登录成功（`feishu_mock_bound`） |
| 14-password-off-saved.png | 配置页关闭密码登录并保存应急管理员邮箱 |
| 15-login-no-password-tab.png | 关闭后匿名访问 `/login`：无密码 Tab，仅扫码入口 |
| 16-login-admin-emergency.png | `/login?admin=1`：应急密码 Tab + 仅名单可登录提示 |
| 17-emergency-denied.png | 非名单账号（engineer）经应急入口登录 → 服务端签出并提示 |
| 18-im-not-bound-contact.png | `im_not_bound`：登录页展示管理员联系方式 + 一键复制 |
| 19-clear-bindings-done.png | 清空绑定执行完成 toast（含条数 / 影响用户数） |
| 20-audit-operations.png | `/audit/operations`：`view_credentials` / `clear_bindings` 留痕 |
| 21-other-session-kicked.png | 切换厂商后**其他浏览器**的在线会话下一请求被踢回登录页 |
| 22-audit-im-auth-config.png | 按对象 `im_auth_config` 过滤：`switch_provider` + `force_logout`（sessions_revoked=7） |
| 23-audit-test-connection.png | 按动作 `test_connection` 过滤：测试连接留痕 |

## 关键结论

- **零 SQL 全流程**：配置飞书凭据 → 测试连接 → 启用（切换）→ 给用户录 userid → 该用户扫码登录，
  全部在页面上完成；期间唯一命令行为启动本地栈与 mock。
- **切换即全局签出**：`im_switch_provider` 删除 `auth.sessions`（GoTrue 对 JWT 的 `session_id`
  claim 做存在性校验，删除后下一请求返回 403 `session_not_found`，SSR 随即跳登录页）；
  截图 21 为另一浏览器会话被踢，截图 22 的 `force_logout` 记录了本次 `sessions_revoked=7`。
- **密码登录开关**：关闭后匿名 `/login` 无密码 Tab（截图 15）；应急管理员经 `/login?admin=1`
  显示密码 Tab（截图 16），非名单账号即使拿到表单也会被服务端签出（截图 17）。
- **联系方式**：`im_not_bound` 时登录页展示配置页维护的管理员联系方式并支持一键复制（截图 18）。
- **审计**：看凭据（`view_credentials`）/ 改凭据（`upsert`）/ 切换（`switch_provider`）/
  强制下线（`force_logout`）/ 清空（`clear_bindings`）/ 测试（`test_connection`）
  均可在 `/audit/operations` 查阅（截图 20/22/23）。

## pgTAP

`supabase/tests/im_config_ui_test.sql`：70 断言全绿——结构与授权面 / 掩码与响应解析纯函数 /
`im_get_config` 权限与「结果不含明文」/ `im_test_config` 不出站校验 / `im_switch_provider`
原子切换与幂等 / `im_clear_all_bindings` 计数 / `im_get_login_options` anon 可读 /
`im_password_login_allowed` 开关语义（名单内非 admin 不放行）。

> 说明：mock 仅替代飞书三个外呼端点，其余链路（凭据解密、出站、state 校验、`im_bind_self`、
> Supabase 会话签发、审计写入）与生产完全一致。真实飞书企业内的扫码截图待人工复验
> （需在飞书开放平台创建自建应用并登记两个回调地址，见配置页「回调 URL 清单」）。
