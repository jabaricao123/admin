/**
 * 站内信未读数变更事件：站内信 / 工作台完成已读、标未读、全部已读等操作后广播，
 * sidebar 徽标监听后立即刷新（与 60s 轮询、窗口 focus 刷新互补）。
 * 与菜单数据（visible_menus）无关，徽标状态独立维护。
 */
export const UNREAD_COUNT_CHANGED_EVENT = "message:unread-count-changed";

export function notifyUnreadCountChanged(): void {
  if (typeof window !== "undefined") {
    window.dispatchEvent(new Event(UNREAD_COUNT_CHANGED_EVENT));
  }
}
