"use client";

import * as React from "react";
import {
  ChevronDownIcon,
  ChevronUpIcon,
  MegaphoneIcon,
} from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import type { Database } from "@/lib/database.types";

type AnnouncementRow =
  Database["public"]["Views"]["published_announcements_v"]["Row"];

const formatDate = (value: string | null) =>
  value ? new Date(value).toLocaleDateString("zh-CN") : "";

/**
 * 公告横幅（dashboard/004）：消费 published_announcements_v（已按 pinned/发布时间倒序）。
 * 首条为横幅，其余折叠；无公告返回 null（不占位）。
 */
export function AnnouncementBanner({
  announcements,
}: {
  announcements: AnnouncementRow[];
}) {
  const [expanded, setExpanded] = React.useState(false);

  if (announcements.length === 0) {
    return null;
  }

  const [headline, ...rest] = announcements;

  return (
    <div className="px-[5px] lg:px-[5px]">
      <Card className="border-primary/30 bg-gradient-to-r from-primary/10 to-transparent shadow-xs pilot-5">
        <CardContent className="flex flex-col gap-[5px]">
          <div className="flex items-start gap-[5px]">
            <span className="mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-full bg-primary/15 text-primary">
              <MegaphoneIcon className="size-4" />
            </span>
            <div className="min-w-0 flex-1">
              <div className="flex flex-wrap items-center gap-[5px]">
                {headline.pinned ? (
                  <Badge>置顶</Badge>
                ) : (
                  <Badge variant="outline">公告</Badge>
                )}
                <span className="font-medium">{headline.title ?? "公告"}</span>
                {headline.published_at ? (
                  <span className="text-xs text-muted-foreground">
                    {formatDate(headline.published_at)}
                  </span>
                ) : null}
              </div>
              {headline.content ? (
                <p className="mt-1 line-clamp-2 text-sm whitespace-pre-wrap text-muted-foreground">
                  {headline.content}
                </p>
              ) : null}
            </div>
            {rest.length > 0 ? (
              <Button
                variant="outline"
                size="sm"
                onClick={() => setExpanded((value) => !value)}
                aria-expanded={expanded}
                className="shrink-0"
              >
                {expanded ? (
                  <>
                    收起
                    <ChevronUpIcon data-icon="inline-end" />
                  </>
                ) : (
                  <>
                    其余 {rest.length} 条
                    <ChevronDownIcon data-icon="inline-end" />
                  </>
                )}
              </Button>
            ) : null}
          </div>

          {expanded ? (
            <ul className="flex flex-col divide-y rounded-lg border bg-card">
              {rest.map((item) => (
                <li
                  key={item.id ?? `${item.title}-${item.published_at ?? ""}`}
                  className="flex flex-col gap-1 p-[5px]"
                >
                  <div className="flex flex-wrap items-center gap-[5px]">
                    {item.pinned ? <Badge>置顶</Badge> : null}
                    <span className="text-sm font-medium">
                      {item.title ?? "公告"}
                    </span>
                    {item.published_at ? (
                      <span className="text-xs text-muted-foreground">
                        {formatDate(item.published_at)}
                      </span>
                    ) : null}
                  </div>
                  {item.content ? (
                    <p className="line-clamp-3 text-xs whitespace-pre-wrap text-muted-foreground">
                      {item.content}
                    </p>
                  ) : null}
                </li>
              ))}
            </ul>
          ) : null}
        </CardContent>
      </Card>
    </div>
  );
}
