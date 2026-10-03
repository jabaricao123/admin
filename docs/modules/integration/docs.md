# 接口/集成中心 · 接口文档

| 项 | 值 |
|---|---|
| 路由 | /integration/docs |
| 状态 | P1，待立项 |
| 模块 | [integration](../README.md#7-接口集成中心-integrationp1) |

## 目的

内置 OpenAPI 文档展示：外部开发者/对接方查阅开放 API 的规格、鉴权方式与事件清单。

## 功能需求

1. 文档渲染：上传/维护 OpenAPI 3 规格文件（YAML/JSON），页面内交互式浏览（折叠、搜索、锚点）。
2. 分组导航：按模块分组的 API 目录 + 事件清单（webhook payload schema）。
3. 鉴权说明：API key 获取与签名/验签示例（含 webhook HMAC 验签示例代码）。
4. 版本切换：多版本规格并存，默认最新。
5. 仅登录后可见（内部对接优先；公开门户 v2 再议）。

## 数据模型

`api_docs`：id、version、spec jsonb（OpenAPI 规格）、changelog、published_by、created_at。
规格文件纳入 git 管理（源文件），表存发布快照。

## RLS

- 登录用户 SELECT；仅 admin 发布新版本。

## 界面规格

- 桌面：左侧目录树 + 右侧文档；移动端仅目录跳转式浏览。
- 代码示例带复制按钮（sonner toast 确认）。

## 依赖与契约

- 规格内容与实际 API 实现同步维护（新端点上线必须同步规格，列入 PR 检查项）。

## 验收标准

- 文档中的路径/事件与实际开放能力一致；版本切换正常；未登录不可访问。
