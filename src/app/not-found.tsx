import Link from "next/link";
import { FileQuestionIcon } from "lucide-react";

import { InfoHint } from "@/components/info-hint";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";

export default function NotFound() {
  return (
    <div className="flex min-h-svh items-center justify-center p-6">
      <Card className="max-w-md">
        <CardHeader className="text-center">
          <div className="mx-auto mb-2 flex size-12 items-center justify-center rounded-full bg-muted">
            <FileQuestionIcon className="size-6 text-muted-foreground" />
          </div>
          <CardTitle className="flex items-center justify-center gap-1.5">
            页面不存在
            <InfoHint>你访问的地址不存在或已被移动。</InfoHint>
          </CardTitle>
        </CardHeader>
        <CardContent className="flex justify-center">
          <Button asChild>
            <Link href="/">返回工作台</Link>
          </Button>
        </CardContent>
      </Card>
    </div>
  );
}
