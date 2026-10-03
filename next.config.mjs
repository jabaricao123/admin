/** @type {import('next').NextConfig} */
const nextConfig = {
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
