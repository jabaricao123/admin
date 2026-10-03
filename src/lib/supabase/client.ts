import { createBrowserClient } from "@supabase/ssr";

import type { Database } from "@/lib/database.types";

/** 浏览器端 Supabase 客户端（组件内使用） */
export function createClient() {
  return createBrowserClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
  );
}
