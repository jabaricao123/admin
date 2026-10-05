/** @type {import('next').NextConfig} */
const nextConfig = {
  // 多标签页保活（cacheComponents）：客户端导航用 React Activity 隐藏页面而非卸载，
  // 表单/滚动/筛选等状态切回标签时保留（Next.js 保活最近 3 个路由）。
  // 管理端全路由服务端动态鉴权，各 page/layout 以 instant=false 选择退出静态预渲染。
  cacheComponents: true,
  output: "standalone",
  allowedDevOrigins: ["192.168.10.213"],
  async redirects() {
    return [
      {
        // org/008：用户管理路径迁移（/settings/users → /org/users）。
        // 验收明确要求 301；Next 的 permanentRedirect() 会返回 308，
        // 因此走配置层重定向并显式指定 statusCode=301。
        source: "/settings/users",
        destination: "/org/users",
        statusCode: 301,
      },
    ];
  },
};

export default nextConfig;
