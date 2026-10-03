# 企业管理系统设计规范（DESIGN.md）

> 版本：2.1 · 更新于 2026-10-04
> 适用范围：企业管理系统全部管理端与移动端 H5 界面
> 前端栈：Next.js 16 + shadcn/ui（radix-nova style）+ Tailwind CSS 4
> 主题来源：CJT 品牌绿 `#2aaf50`

## 1. 品牌主题（CJT 绿）

主题以 CSS 变量定义在 `src/app/globals.css`（`:root` / `.dark`），经 shadcn/ui 语义 token 驱动。禁止在业务组件里硬编码色值。

| Token | 亮色 | 暗色 | 用途 |
|---|---|---|---|
| `--primary` | `oklch(0.6636 0.1751 148.17)`（#2aaf50） | `oklch(0.8003 0.1821 151.71)` | 主按钮、选中态、链接 |
| `--ring` | 同 primary | 同 primary | focus 环 |
| `--accent` | `oklch(0.9621 0.0425 148.43)`（浅绿） | `oklch(0.2786 0.0566 148.27)`（深绿） | hover 底色、菜单选中底 |
| `--chart-1..5` | 品牌绿梯度 | 同左（明度适配） | 图表 |

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
| ≥1024px | 桌面 | 左侧 Sidebar（inset，可折叠为图标） | Table |
| <1024px | 移动 / 平板 H5 | 顶部 Header 汉堡按钮 → Sheet 侧滑 | 卡片列表（整卡可点 → 底部 Sheet） |

- 使用 Tailwind 默认断点（`sm 640 / md 768 / lg 1024`），禁止另设断点。
- 页面标题在 `src/components/site-header.tsx` 的 `PAGE_TITLES` 中注册，新增页面必须同步登记。

## 4. 列表页模式（用户管理为参考实现）

1. 顶部工具栏：搜索输入框 + 筛选 Select（角色/状态）+ 刷新按钮；移动端纵向堆叠。
2. 数据表格：shadcn `Table`，**列头与单元格内容居中**（`text-center`），分页每页 20 条，底部显示「共 N 条 · 第 X / Y 页」。
3. 编辑用 `Sheet`：桌面右侧（`side="right"`，`sm:max-w-md`）；底部 footer 放「取消 / 保存」，主操作在右。
4. 保存走 Supabase RPC / 数据操作，成功后 `toast.success` + 刷新列表；失败 `toast.error(error.message)`。
5. 枚举展示用 `Badge variant="outline"` + `src/lib/dictionaries.ts` 中的配色类名，禁止散落硬编码。
6. **移动端（<1024px）列表渲染为卡片**：整卡是 `button`（键盘可达），标题行 = 主字段 + 角色 Badge，详情行 label 左 / value 右，间距 12px；静态态细边框 + 微投影，hover/focus 边框变主色。点击卡片打开**底部 Sheet**（`side="bottom"`，`max-h-[85svh]`），字段与 footer 与桌面一致。

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
