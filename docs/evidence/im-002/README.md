# im/002 验证证据（本地 mock 飞书端点）

本目录截图来自 **本地全链路验证**（工单 im/002）：

- 应用：本地 `next dev` + 本地 Supabase（真实 Auth / RLS / audit_logins）
- 飞书端点：本地 HTTPS mock（`accounts.feishu.cn` / `open.feishu.cn` 经 hosts 指向本地，
  仅存在于验证机器，未入库），mock 行为对齐官方文档：授权码单次可用、v3 token 接口、
  `user_info` 返回 `user_id`
- 测试账号：`engineer@example.com` 绑定 mock userid `feishu_mock_bound`

| 文件 | 场景 |
|---|---|
| 01-login-scan-tab.png | `/login` 新增「扫码登录」Tab（当前启用厂商为飞书时显示） |
| 02-feishu-authorize-qr.png | 飞书授权页（本地 mock；真实环境为飞书托管二维码页） |
| 03-callback-success.png | 已绑定用户扫码 → 回调签发 session → 工作台（engineer） |
| 04-im-not-bound.png | 未绑定用户扫码 → 拒绝 + toast（`/login?error=im_not_bound`） |
| 05-audit-logins.png | `/audit/logins`：IM 成功行 + 未绑定失败行（`fail_reason=im_not_bound`） |

> 说明：真实飞书测试应用的扫码截图待人工复验（需在飞书开放平台创建测试应用并提供
> 公网回调域名）；mock 仅替代飞书侧三个端点，其余链路（state 校验、凭据解密、
> 绑定匹配、Supabase 会话签发、审计写入）与生产完全一致。
