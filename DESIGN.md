# 企业管理系统设计规范（DESIGN.md）

> 版本：2.6 · 更新于 2026-10-04
> v2.2 变更：弹窗统一为右侧 Sheet（桌面/移动同组件同视觉，35vw）；列表页去按钮化——行内不放操作按钮，行级动作全部集成弹窗内，行/卡片可点即编辑。
> v2.3 变更：新增 §7 现状差距清单并完成 7 项收口（§1 token 对齐实现、Sheet 统一右滑 35vw、桌面删操作列+整行可点、侧栏折叠为图标、移动触控 44px、错误中文化）；`tsc`/`build`/`detect` 全绿。
> v2.4 变更：手机（<640px）右侧 Sheet 改满宽，标准面板宽度统一 `w-full sm:max-w-[480px]`；基础组件移除右侧 75% 隐式默认宽（原实现优先级压过业务宽度类），移动导航抽屉恢复 288px。
> v2.5 变更：页面级标题去重——列表页/管理页主卡片移除与页头重复的标题与描述（CardHeader 仅保留于区域卡、Tab 卡与功能卡）；全站移除手动刷新按钮（数据于进入页面、筛选变化与操作完成后自动加载）；原 CardHeader 操作按钮（新建等）迁入内容区工具栏。
> v2.6 变更：保存按钮全站统一（实心主按钮 + SaveIcon，保存中 Loader2，尺寸 `h-11 lg:h-8`；与「发布」并排的「保存草稿」保持描边以维持主次）；移动卡片紧凑化（内边距 12px、标题块↔内容 8px、名称↔副标题 2px）；带标题的区域卡统一 12px 节奏（`gap-3! py-3!`）。
> 适用范围：企业管理系统全部管理端与移动端 H5 界面
> 前端栈：Next.js 16 + shadcn/ui（radix-nova style）+ Tailwind CSS 4
> 主题来源：CJT 品牌绿 `#2aaf50`

## 1. 品牌主题（CJT 绿）

主题以 CSS 变量定义在 `src/app/globals.css`（`:root` / `.dark`），经 shadcn/ui 语义 token 驱动。禁止在业务组件里硬编码色值。

| Token | 亮色 | 暗色 | 用途 |
|---|---|---|---|
| `--primary` | `oklch(0.535 0.15 148)`（#0e8335） | `oklch(0.8003 0.1821 151.71)` | 主按钮、选中态、链接（亮色为对比度修复调深，白字 4.66:1） |
| `--ring` | 同 primary | 同 primary | focus 环 |
| `--accent` | `oklch(0.9621 0.0425 148.43)`（浅绿） | `oklch(0.2786 0.0566 148.27)`（深绿） | hover 底色、菜单选中底 |
| `--chart-1` | `oklch(0.6636 0.1751 148.17)`（#2aaf50 品牌绿） | `oklch(0.8003 0.1821 151.71)` | 品牌绿仅留图表/装饰，不用于文本 |

- 暗色模式：`next-themes`（class 策略），Header 右侧按钮切换；暗色下品牌绿自动提亮，禁止为暗色单独调色。
- 字体：Geist Sans（经 `geist` 包以 `next/font/local` 本地加载，不用 Google Fonts）+ PingFang SC / Microsoft YaHei 回退链。

## 2. 组件约定

- UI 组件一律从 `@/components/ui/*` 引入（shadcn/ui，radix-ui 底层）；新增组件用 `npx shadcn@latest add <name>`，不重复造轮子。
- 官方 blocks 直接复用：后台布局与工作台源自 `dashboard-01`，登录页源自 `login-03`。
- 图标库 lucide-react（`<Icon className="size-4" />`，按钮内用 `data-icon="inline-start"`）。
- Toast 用 sonner：`toast.success("已保存")` / `toast.error(message)`。
- 空态、加载、错误必须显式呈现（骨架屏 / 空态文案 / 错误提示），不允许白屏。

## 3. 响应式断点

| 视口 | 形态 | 导航 | 列表 |
|---|---|---|---|
| ≥1024px | 桌面 | 左侧 Sidebar（inset，可折叠为图标） | Table（行可点，无操作列） |
| <1024px | 移动 / 平板 H5 | 顶部 Header 汉堡按钮 → Sheet 侧滑 | 卡片列表（整卡可点） |

- 弹窗（Sheet）统一右侧滑出、同一组件：手机（<640px）满宽；sm 起标准面板 `w-full sm:max-w-[480px]`（见 §4），宽内容与设计器面板保留各自 `sm:max-w-*` / `sm:w-[Xvw]` 规则。

- 使用 Tailwind 默认断点（`sm 640 / md 768 / lg 1024`），禁止另设断点。
- 页面标题唯一来源：`site-header.tsx` 的 `PAGE_TITLES`（页面级标题只由页头承载，新增页面必须同步登记）。列表页/管理页主卡片不重复页面级标题，也不再写描述；CardHeader 仅用于页面内区域卡、Tab 卡与功能卡。

## 4. 列表页模式（用户管理为参考实现）

1. 主卡片不设页面级标题：内容首行即工具栏（搜索输入框 + 筛选 Select + 新建等操作按钮；移动端纵向堆叠）；全站不设手动刷新按钮，数据在进入页面、筛选变化与操作完成后自动加载；原 CardHeader 中的操作按钮迁入此工具栏。
2. 数据表格：shadcn `Table`，**列头与单元格内容居中**（`text-center`），分页每页 20 条，底部显示「共 N 条 · 第 X / Y 页」。
3. **行内不放按钮**：表格只有数据列，无「操作/编辑」列；新建等一切行级动作集成到弹窗内。表格行本身可点（`cursor-pointer` + hover 高亮 + 键盘可达），点击整行打开弹窗——这是列表页进入编辑的唯一路径。移动端卡片沿用既有模式（整卡可点）。
4. 弹窗统一用 `Sheet`，**桌面与移动同为右侧滑出**（`side="right"`，同一组件、同一视觉，不按端分叉 bottom 模式）；宽度 **手机（<640px）满宽，sm 起标准面板 `w-full sm:max-w-[480px]`**；宽内容面板用 `sm:max-w-2xl/3xl/lg`，设计器面板用 `sm:w-[52/68/72vw]` + min/max。**每个 `SheetContent` 必须显式声明宽度**（基础组件不提供默认宽度）；footer「取消 / 保存」，主操作在右。
5. 保存走 Supabase RPC / 数据操作，成功后 `toast.success` + 刷新列表；失败 `toast.error(error.message)`。
6. 枚举展示用 `Badge variant="outline"` + `src/lib/dictionaries.ts` 中的配色类名，禁止散落硬编码。
7. **移动端（<1024px）列表渲染为卡片**：整卡是 `button`（键盘可达），标题行 = 主字段 + 角色 Badge，详情行 label 左 / value 右；**卡片内边距 12px（`p-3`），标题块↔首行内容 8px（`gap-2`），名称↔副标题 2px**；静态态细边框 + 微投影，hover/focus 边框变主色。点击卡片打开右侧 Sheet（同第 4 条，与桌面一致）。
8. **保存按钮统一**：实心主按钮 + `SaveIcon`（保存中换 `Loader2Icon`），尺寸 `h-11 lg:h-8`；Sheet footer 的「取消/关闭」与保存同高；与「发布」并排的「保存草稿」保持描边（主次）。
9. **带标题的区域卡（含 Tab 卡与功能卡）统一 12px 节奏**：Card 加 `gap-3! py-3!`（标题/描述↔内容与上下外缘 12px），标题字号不变。

## 5. 布局细则

| 场景 | 规格 |
|---|---|
| 页面内容 | `px-4 lg:px-6`，纵向间距 `gap-4 md:gap-6` |
| Header | 高度 `--header-height`，白底/暗底 + 底边框 |
| 工作台卡片 | `@xl/main:grid-cols-2 @5xl/main:grid-cols-4`，移动端单列（`SectionCards`） |
| 侧边栏 | 宽 288px（`--sidebar-width`），inset 变体，折叠为图标 |

## 6. 代码约定

- 页面默认 Server Component；仅交互组件加 `"use client"`。
- 数据访问：`@/lib/supabase/client`（浏览器）/ `@/lib/supabase/server`（服务端，`await createClient()`）；会话续期在 `src/proxy.ts`，禁止在组件里重复实现。
- 认证守卫：`(admin)/layout.tsx` 服务端 `getUser()`；`proxy.ts` 负责未登录重定向与已登录访问 `/login` 的反弹。
- 角色集中判读：`src/lib/dictionaries.ts`（标签与配色）；菜单过滤在 `app-sidebar.tsx`，页面级角色校验在对应 Server Component。
- 文案：全中文，技术术语保留英文；按钮名其动作、错误名其问题与恢复路径。
- 可达性：可点元素必须有键盘路径；图标按钮必须有 `aria-label`。

## 7. 现状差距（v2.2 登记，v2.3 已全部对齐）

7 项差距已在 2026-10-04 逐项收口，本表保留为完成记录：

| # | 位置 | 完成内容 |
|---|---|---|
| 1 | `src/app/globals.css` + §1 token 表 | §1 token 表已改记实现值（#0e8335），品牌绿注明「仅图表/装饰」 |
| 2 | `users-table.tsx` 编辑 Sheet | 删 isMobile 分叉，统一 `side="right"` |
| 3 | `users-table.tsx` 编辑 Sheet | 宽度改 `w-[35vw] min-w-[320px] max-w-[480px]` |
| 4 | `users-table.tsx` 桌面表格 | 删「操作」列，`TableRow` 加 onClick + cursor-pointer，整行可点 |
| 5 | `app-sidebar.tsx` | `collapsible="offcanvas"` 改 `collapsible="icon"`（折叠为图标，tooltip 生效） |
| 6 | `users-table.tsx` 工具栏/分页/输入 | `<1024px` 统一 `h-11`，搜索输入 `text-base`（防 iOS 缩放），桌面维持原密度 |
| 7 | `users-table.tsx` 错误态 | 错误接入 `translateErrorMessage` + 重试按钮 |

验证：`tsc --noEmit` 通过、`npm run build` 通过、`impeccable detect --json src` 0 findings。
