"use client";

// PC 扫码登录面板（im/007）：ticket 轮询模式。
//
// 链路：
//   1. 打开面板 → anon 调 public.im_start_qr_login(provider, redirect_uri) → {ticket, authorize_url}；
//   2. 渲染「真二维码」：
//      - 企业微信：官方托管二维码页 qrConnect（<iframe>，授权成功由该页回调本系统）；
//      - 飞书 / 钉钉：qrcode.react 生成授权 URL 二维码（手机相机扫码打开 App 授权页）；
//   3. 每 1 秒 anon 调 public.im_poll_qr_login(ticket)（只回状态，不泄露身份）；
//   4. 状态 logged_in → 整页跳 /auth/qr/exchange?ticket=… 换 session（服务端一次消费）。

import * as React from "react";
import { Loader2Icon, QrCodeIcon, RefreshCwIcon, ScanLineIcon } from "lucide-react";
import { QRCodeSVG } from "qrcode.react";

import { Button } from "@/components/ui/button";
import { imLoginErrorMessage } from "@/lib/im/messages";
import {
  IM_QR_POLL_INTERVAL_MS,
  imQrCallbackBase,
} from "@/lib/im/qr";
import { createClient } from "@/lib/supabase/client";

type PanelState =
  | { phase: "loading" }
  | { phase: "ready"; ticket: string; authorizeUrl: string; expiresAt: number }
  | { phase: "confirmed" }
  | { phase: "expired"; reason: string | null }
  | { phase: "failed"; message: string };

function parseStartResult(
  data: unknown,
):
  | { ok: true; ticket: string; authorizeUrl: string; expiresAt: number }
  | { ok: false; error: string } {
  if (data && typeof data === "object") {
    const row = data as Record<string, unknown>;
    if (
      row.ok === true &&
      typeof row.ticket === "string" &&
      typeof row.authorize_url === "string"
    ) {
      const parsed = Date.parse(String(row.expires_at));
      return {
        ok: true,
        ticket: row.ticket,
        authorizeUrl: row.authorize_url,
        expiresAt: Number.isFinite(parsed) ? parsed : Date.now() + 5 * 60 * 1000,
      };
    }
    if (typeof row.error === "string") {
      return { ok: false, error: row.error };
    }
  }
  return { ok: false, error: "im_failed" };
}

export function ImQrLogin({
  provider,
  providerLabel,
  adminContact = "",
}: {
  provider: string;
  providerLabel: string;
  /** 管理员联系方式（im/not_bound 时随卷标展示，与密码 Tab 的提示一致） */
  adminContact?: string;
}) {
  const supabase = React.useMemo(() => createClient(), []);

  const [state, setState] = React.useState<PanelState>({ phase: "loading" });

  const start = React.useCallback(async () => {
    setState({ phase: "loading" });
    const redirectUri = `${imQrCallbackBase()}/auth/callback/${provider}`;
    const { data, error } = await supabase.rpc("im_start_qr_login", {
      p_provider: provider,
      p_redirect_uri: redirectUri,
    });
    const parsed = parseStartResult(data);
    if (error || !parsed.ok) {
      const code = parsed.ok ? "im_failed" : parsed.error;
      setState({
        phase: "failed",
        message: imLoginErrorMessage(code, provider) ?? "二维码生成失败，请稍后重试",
      });
      return;
    }
    setState({
      phase: "ready",
      ticket: parsed.ticket,
      authorizeUrl: parsed.authorizeUrl,
      expiresAt: parsed.expiresAt,
    });
  }, [provider, supabase]);

  React.useEffect(() => {
    void start();
  }, [start]);

  // 轮询：状态变为 logged_in 立即整页跳转换 session；过期 / 作废 / 非法停止轮询
  React.useEffect(() => {
    if (state.phase !== "ready") {
      return;
    }
    const { ticket } = state;
    let stopped = false;

    const tick = async () => {
      const { data } = await supabase.rpc("im_poll_qr_login", {
        p_ticket: ticket,
      });
      if (stopped) {
        return;
      }
      const row = (data ?? null) as {
        status?: string;
        reason?: string | null;
      } | null;
      if (row?.status === "logged_in") {
        stopped = true;
        setState({ phase: "confirmed" });
        window.location.assign(
          `/auth/qr/exchange?ticket=${encodeURIComponent(ticket)}`,
        );
      } else if (
        row?.status === "expired" ||
        row?.status === "consumed" ||
        row?.status === "invalid"
      ) {
        stopped = true;
        setState({
          phase: "expired",
          reason: row.status === "expired" ? (row.reason ?? null) : null,
        });
      }
    };

    // 立即查一次（覆盖打开页面时已扫码的极端时序），之后按间隔轮询
    void tick();
    const timer = window.setInterval(() => {
      void tick();
    }, IM_QR_POLL_INTERVAL_MS);
    return () => {
      stopped = true;
      window.clearInterval(timer);
    };
  }, [state, supabase]);

  // 本地过期兜底：到点即显示「已过期」，不必等下一次轮询
  React.useEffect(() => {
    if (state.phase !== "ready") {
      return;
    }
    const delay = Math.max(0, state.expiresAt - Date.now()) + 50;
    const timer = window.setTimeout(() => {
      setState({ phase: "expired", reason: null });
    }, delay);
    return () => window.clearTimeout(timer);
  }, [state]);

  if (state.phase === "loading") {
    return (
      <div className="flex flex-col items-center gap-4 py-2 text-center">
        <div className="flex size-16 items-center justify-center rounded-2xl border bg-muted">
          <Loader2Icon className="size-7 animate-spin text-muted-foreground" />
        </div>
        <p className="text-sm text-muted-foreground">正在生成二维码…</p>
      </div>
    );
  }

  if (state.phase === "confirmed") {
    return (
      <div className="flex flex-col items-center gap-4 py-2 text-center">
        <div className="flex size-16 items-center justify-center rounded-2xl border bg-muted">
          <ScanLineIcon className="size-7 text-muted-foreground" />
        </div>
        <p className="text-sm text-muted-foreground">扫码成功，正在登录…</p>
      </div>
    );
  }

  if (state.phase === "expired" || state.phase === "failed") {
    const message =
      state.phase === "failed"
        ? state.message
        : state.reason
          ? (imLoginErrorMessage(state.reason, provider) ??
            "二维码已过期，请刷新后重试")
          : "二维码已过期，请刷新后重试";
    return (
      <div className="flex flex-col items-center gap-4 py-2 text-center">
        <div className="flex size-16 items-center justify-center rounded-2xl border bg-muted">
          <QrCodeIcon className="size-8 text-muted-foreground" />
        </div>
        <p className="text-sm text-muted-foreground">{message}</p>
        {state.phase === "expired" && state.reason === "im_not_bound" && adminContact ? (
          <p className="font-mono text-xs break-all text-muted-foreground">
            {adminContact}
          </p>
        ) : null}
        <Button type="button" variant="outline" onClick={() => void start()}>
          <RefreshCwIcon data-icon="inline-start" />
          刷新二维码
        </Button>
      </div>
    );
  }

  // ready：真二维码（企业微信官方托管页可 iframe；飞书 / 钉钉用 qrcode.react）
  const useIframe = provider === "wecom";
  return (
    <div className="flex flex-col items-center gap-3 py-2 text-center">
      {useIframe ? (
        <iframe
          src={state.authorizeUrl}
          title={`${providerLabel}扫码登录`}
          data-testid="im-qr-iframe"
          className="h-[400px] w-[320px] rounded-xl border bg-white"
        />
      ) : (
        <div className="rounded-xl border bg-white p-3" data-testid="im-qr-image">
          <QRCodeSVG
            value={state.authorizeUrl}
            size={176}
            level="M"
            marginSize={1}
            title={`${providerLabel}扫码登录二维码`}
          />
        </div>
      )}
      <p className="text-sm text-muted-foreground" data-testid="im-qr-status">
        使用{providerLabel} App 扫码并确认，即可登录系统
      </p>
      <div className="flex items-center gap-3">
        <span className="text-xs text-muted-foreground">
          二维码 5 分钟内有效
        </span>
        <Button
          type="button"
          size="sm"
          variant="ghost"
          className="h-11 lg:h-8"
          onClick={() => void start()}
        >
          <RefreshCwIcon data-icon="inline-start" />
          刷新
        </Button>
      </div>
      {useIframe ? (
        <a
          className="text-xs text-muted-foreground underline underline-offset-2"
          href={state.authorizeUrl}
          target="_blank"
          rel="noreferrer"
        >
          二维码未显示？点此新窗口打开
        </a>
      ) : null}
    </div>
  );
}
