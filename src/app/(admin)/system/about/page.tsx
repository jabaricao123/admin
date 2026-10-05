import fs from "node:fs";
import path from "node:path";

import type { Metadata } from "next";
import {
  BookOpenIcon,
  GitCommitHorizontalIcon,
  InfoIcon,
  MessageSquareWarningIcon,
  ScaleIcon,
  ServerCogIcon,
  TagsIcon,
} from "lucide-react";

import { InfoHint } from "@/components/info-hint";
import { Badge } from "@/components/ui/badge";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Separator } from "@/components/ui/separator";
import { STATE_BADGE_CLASSES } from "@/lib/dictionaries";
import packageJson from "../../../../../package.json";

// @next-codemod-ignore Cache Components：管理端路由均为服务端动态鉴权，允许阻塞式导航。
export const instant = false;

export const metadata: Metadata = {
  title: "关于系统",
};

// ---------------------------------------------------------------------------
// CHANGELOG 简易解析（不引新依赖）：`## [版本] - 日期` 版本段、`### 类型` 分组、
// `- 条目` 列表项。解析失败回退空列表并显式提示，不白屏。
// ---------------------------------------------------------------------------

type ChangeGroup = { title: string; items: string[] };
type ChangeVersion = { version: string; date: string | null; groups: ChangeGroup[] };

const CHANGELOG_FALLBACK = "更新记录暂不可用（CHANGELOG.md 未随部署包发布）";

function stripInlineMarkdown(text: string): string {
  return text
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/\*/g, "")
    .trim();
}

function parseChangelog(markdown: string): ChangeVersion[] {
  const versions: ChangeVersion[] = [];
  let current: ChangeVersion | null = null;
  let currentGroup: ChangeGroup | null = null;

  for (const rawLine of markdown.split(/\r?\n/)) {
    const line = rawLine.trim();

    const versionMatch = /^##\s+\[?([^\]]+?)\]?\s*(?:[-–—]\s*(.+))?$/.exec(line);
    if (versionMatch) {
      current = {
        version: versionMatch[1].trim(),
        date: versionMatch[2]?.trim() ?? null,
        groups: [],
      };
      versions.push(current);
      currentGroup = null;
      continue;
    }

    const groupMatch = /^###\s+(.+)$/.exec(line);
    if (groupMatch && current) {
      currentGroup = { title: stripInlineMarkdown(groupMatch[1]), items: [] };
      current.groups.push(currentGroup);
      continue;
    }

    const itemMatch = /^(?:[-*]|\d+\.)\s+(.+)$/.exec(line);
    if (itemMatch && currentGroup) {
      currentGroup.items.push(stripInlineMarkdown(itemMatch[1]));
    }
  }

  return versions;
}

/** 变更类型 Badge 配色：新增绿 / 变更蓝 / 修复红 / 其他灰（复用统一语义色） */
function changeTypeBadgeClass(title: string): string {
  const normalized = title.toLowerCase();
  if (normalized.includes("added") || title.includes("新增")) {
    return STATE_BADGE_CLASSES.success;
  }
  if (normalized.includes("changed") || title.includes("变更")) {
    return STATE_BADGE_CLASSES.info;
  }
  if (
    normalized.includes("fixed") ||
    normalized.includes("removed") ||
    title.includes("修复")
  ) {
    return STATE_BADGE_CLASSES.danger;
  }
  return STATE_BADGE_CLASSES.neutral;
}

function loadChangelog(): { versions: ChangeVersion[]; error: string | null } {
  try {
    const file = path.join(process.cwd(), "CHANGELOG.md");
    const markdown = fs.readFileSync(file, "utf8");
    return { versions: parseChangelog(markdown), error: null };
  } catch {
    return { versions: [], error: CHANGELOG_FALLBACK };
  }
}

const TECH_STACK = [
  { name: "Next.js", version: packageJson.dependencies.next },
  { name: "React", version: packageJson.dependencies.react },
  {
    name: "Supabase",
    version: `supabase-js ${packageJson.dependencies["@supabase/supabase-js"]} · SSR ${packageJson.dependencies["@supabase/ssr"]}`,
  },
  { name: "Tailwind CSS", version: packageJson.devDependencies.tailwindcss },
];

const stripRange = (value: string) => value.replace(/^[\^~]/, "");

export default function SystemAboutPage() {
  const { versions, error: changelogError } = loadChangelog();
  const commitSha =
    process.env.NEXT_PUBLIC_VERCEL_GIT_COMMIT_SHA ??
    process.env.VERCEL_GIT_COMMIT_SHA ??
    process.env.NEXT_PUBLIC_GIT_COMMIT_SHA ??
    "";
  const shortSha = commitSha ? commitSha.slice(0, 7) : null;

  return (
    <div className="flex flex-col gap-2 p-0 md:p-6">
      <div className="grid gap-4 lg:grid-cols-2">
        {/* 版本信息 */}
        <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <TagsIcon className="size-4 text-muted-foreground" />
              版本信息
              <InfoHint>当前部署包版本与构建标识（构建时注入）</InfoHint>
            </CardTitle>
          </CardHeader>
          <CardContent className="flex flex-col gap-3 p-4 text-sm md:p-6">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <span className="text-muted-foreground">系统版本</span>
              <span className="font-mono">v{packageJson.version}</span>
            </div>
            <Separator />
            <div className="flex flex-wrap items-center justify-between gap-2">
              <span className="text-muted-foreground">构建 commit</span>
              {shortSha ? (
                <span className="flex items-center gap-2">
                  <GitCommitHorizontalIcon className="size-3.5 text-muted-foreground" />
                  <span className="font-mono">{shortSha}</span>
                </span>
              ) : (
                <span className="text-muted-foreground">
                  本地构建 · 未注入 commit
                </span>
              )}
            </div>
            <Separator />
            <div className="flex flex-wrap items-center justify-between gap-2">
              <span className="text-muted-foreground">构建时间</span>
              <span className="text-muted-foreground">
                以部署平台记录为准（本页不额外注入）
              </span>
            </div>
          </CardContent>
        </Card>

        {/* 技术栈摘要 */}
        <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <ServerCogIcon className="size-4 text-muted-foreground" />
              技术栈摘要
              <InfoHint>
                前端框架与平台依赖版本（读取自 package.json，不含敏感配置）
              </InfoHint>
            </CardTitle>
          </CardHeader>
          <CardContent className="flex flex-col gap-3 p-4 text-sm md:p-6">
            {TECH_STACK.map((item, index) => (
              <div key={item.name}>
                {index > 0 ? <Separator className="mb-3" /> : null}
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="text-muted-foreground">{item.name}</span>
                  <span className="font-mono text-xs">
                    {item.version.split(" · ").map(stripRange).join(" · ")}
                  </span>
                </div>
              </div>
            ))}
          </CardContent>
        </Card>

        {/* 许可信息 */}
        <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <ScaleIcon className="size-4 text-muted-foreground" />
              许可信息
              <InfoHint>软件许可与使用范围声明</InfoHint>
            </CardTitle>
          </CardHeader>
          <CardContent className="flex flex-col gap-3 p-4 text-sm md:p-6">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <span className="text-muted-foreground">许可类型</span>
              <Badge variant="outline">私有软件 · 内部使用</Badge>
            </div>
            <Separator />
            <p className="text-xs text-muted-foreground">
              本系统为内部管理系统，商业化前仅限公司内部授权范围使用；
              未经许可禁止对外分发、转售或用于第三方托管服务。
            </p>
          </CardContent>
        </Card>

        {/* 问题上报 */}
        <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <MessageSquareWarningIcon className="size-4 text-muted-foreground" />
              问题上报
              <InfoHint>内部反馈通道说明</InfoHint>
            </CardTitle>
          </CardHeader>
          <CardContent className="flex flex-col gap-3 p-4 text-sm md:p-6">
            <div className="flex items-start gap-2 text-muted-foreground">
              <InfoIcon className="mt-0.5 size-4 shrink-0" />
              <p className="text-xs">
                遇到功能异常或使用问题，请通过内部问题反馈通道（系统管理员 / 研发团队）
                上报，并附上页面路径、操作步骤与报错截图；生产环境不提供对外公开的反馈入口。
              </p>
            </div>
          </CardContent>
        </Card>
      </div>

      {/* 更新记录 */}
      <Card className="rounded-none border-0 md:rounded-xl md:border md:@container/card">
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <BookOpenIcon className="size-4 text-muted-foreground" />
            更新记录
            <InfoHint>
              来自仓库 CHANGELOG.md（随发布流程维护），按版本分段时间线展示
            </InfoHint>
          </CardTitle>
        </CardHeader>
        <CardContent className="p-4 md:p-6">
          {changelogError ? (
            <p className="py-8 text-center text-sm text-muted-foreground">
              {changelogError}
            </p>
          ) : versions.length === 0 ? (
            <p className="py-8 text-center text-sm text-muted-foreground">
              暂无更新记录
            </p>
          ) : (
            <ol className="flex flex-col gap-6 border-l pl-6">
              {versions.map((version) => (
                <li key={`${version.version}-${version.date ?? ""}`} className="relative">
                  <span className="absolute top-1.5 -left-[1.72rem] size-2.5 rounded-full bg-primary" />
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-medium">
                      {version.version === "Unreleased"
                        ? "未发布"
                        : `v${version.version}`}
                    </span>
                    {version.date ? (
                      <span className="text-xs text-muted-foreground">
                        {version.date}
                      </span>
                    ) : null}
                  </div>
                  <div className="mt-2 flex flex-col gap-3">
                    {version.groups.map((group) => (
                      <div key={group.title} className="flex flex-col gap-1.5">
                        <Badge
                          variant="outline"
                          className={`w-fit ${changeTypeBadgeClass(group.title)}`}
                        >
                          {group.title}
                        </Badge>
                        <ul className="flex list-disc flex-col gap-1 pl-5 text-sm text-muted-foreground">
                          {group.items.map((item, index) => (
                            <li key={index}>{item}</li>
                          ))}
                        </ul>
                      </div>
                    ))}
                  </div>
                </li>
              ))}
            </ol>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
