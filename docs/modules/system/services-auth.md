# 系统管理 · 身份认证

| 项 | 值 |
|---|---|
| 路由 | /system/services/auth |
| 状态 | P1，待立项（admin 专用） |
| 模块 | [system](../README.md#9-系统管理-systemp1) |

## 目的

Supabase Auth 配置的可视化治理：密码策略、会话时长、OAuth 提供商开关、回调 URL 说明。

## 功能需求

1. 只读状态区：当前 Auth 配置摘要（从 Supabase Auth Admin API 读取），标注哪些项需在 Supabase 控制台修改。
2. 密码策略：最小长度、复杂度要求展示 + 变更指引（写操作在 Supabase 控制台，本页给直达链接与说明，避免双写冲突）。
3. 会话时长：当前 JWT/会话过期策略展示。
4. OAuth 提供商：开关状态一览（Google/GitHub 等已启用项），启用/停用引导至控制台。
5. 回调 URL：站点 Redirect URL 清单展示（复制按钮），供控制台配置参照。

## 数据模型

不落库（配置真源在 Supabase Auth）；页面仅 Admin API 只读渲染。变更动作写 audit 摘要（谁查看了/导出了配置）。

## RLS

- 仅 admin 可见。

## 界面规格

- 信息卡片区 + 「在 Supabase 控制台打开」外链按钮；需控制台操作的项带「外部管理」Badge。

## 依赖与契约

- 与 audit/logins 的 Auth hook 配置互为文档引用；本页不改运行时行为（纯展示+引导）。

## 验收标准

- 展示值与 Supabase 控制台一致（同 Admin API 源）；非 admin 不可访问。
