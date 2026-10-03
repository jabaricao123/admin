"use client";

import { RotateCcwIcon, TriangleAlertIcon } from "lucide-react";

import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";

export default function AdminError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <div className="flex flex-1 items-center justify-center p-6">
      <Card className="max-w-md">
        <CardHeader className="text-center">
          <div className="mx-auto mb-2 flex size-12 items-center justify-center rounded-full bg-destructive/10">
            <TriangleAlertIcon className="size-6 text-destructive" />
          </div>
          <CardTitle>页面加载失败</CardTitle>
          <CardDescription>
            {error.message || "加载时出现未知错误，请重试。"}
          </CardDescription>
        </CardHeader>
        <CardContent className="flex justify-center">
          <Button onClick={reset}>
            <RotateCcwIcon data-icon="inline-start" />
            重试
          </Button>
        </CardContent>
      </Card>
    </div>
  );
}
