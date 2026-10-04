import { redirect } from "next/navigation";

/**
 * 根路径兼容入口：概览已迁移至 /dashboard（菜单与模块文档路由），
 * 保留 / 重定向，兼容登录后跳转、侧栏品牌链接与旧书签。
 */
export default function AdminHomePage() {
  redirect("/dashboard");
}
