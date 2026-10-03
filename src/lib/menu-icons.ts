// 菜单图标映射（access/008）
//
// 设计取舍：menu_items 只存业务拓扑（key/label/route/sort_order），图标属展示细节，
// 不落库——按 menu_items.key 在前端映射到 lucide 组件；未命中的 key 由消费方兜底
// （app-sidebar.tsx 使用 DEFAULT_MENU_ICON）。新增菜单项时按需在本表补一行即可。

import {
  BarChart3Icon,
  BellIcon,
  BellRingIcon,
  BookOpenIcon,
  BriefcaseIcon,
  Building2Icon,
  CalendarClockIcon,
  CircleIcon,
  ClipboardCheckIcon,
  ClockIcon,
  CopyIcon,
  DatabaseIcon,
  DownloadIcon,
  FileCheckIcon,
  FileClockIcon,
  FileTextIcon,
  FingerprintIcon,
  GitBranchIcon,
  GitCompareIcon,
  HardDriveIcon,
  HistoryIcon,
  InboxIcon,
  InfoIcon,
  KeyRoundIcon,
  LayoutDashboardIcon,
  LineChartIcon,
  ListChecksIcon,
  ListTodoIcon,
  LogInIcon,
  MailIcon,
  MailPlusIcon,
  MegaphoneIcon,
  MessageSquareIcon,
  NetworkIcon,
  PlugIcon,
  RefreshCwIcon,
  ScanEyeIcon,
  ScrollTextIcon,
  SendIcon,
  SettingsIcon,
  ShieldCheckIcon,
  UsersIcon,
  WebhookIcon,
  type LucideIcon,
} from "lucide-react";

/** menu_items.key → lucide 图标组件（含静态兜底菜单使用的 "/"） */
export const ICON_MAP: Record<string, LucideIcon> = {
  // 静态兜底：首页工作台（app-sidebar RPC 失败回退菜单）
  "/": LayoutDashboardIcon,

  // 工作台 dashboard
  "/dashboard": LayoutDashboardIcon,
  "/dashboard/todos": ListTodoIcon,
  "/dashboard/notifications": BellIcon,

  // 组织管理 org
  "/org": Building2Icon,
  "/org/users": UsersIcon,
  "/org/departments": Building2Icon,
  "/org/positions": BriefcaseIcon,
  "/org/chart": NetworkIcon,

  // 权限管理 access
  "/access": ShieldCheckIcon,
  "/access/roles": ShieldCheckIcon,
  "/access/permissions": KeyRoundIcon,
  "/access/data-scopes": ScanEyeIcon,
  "/access/audit": ScrollTextIcon,

  // 审批中心 approval
  "/approval": ClipboardCheckIcon,
  "/approval/todo": ListTodoIcon,
  "/approval/mine": SendIcon,
  "/approval/cc": CopyIcon,
  "/approval/templates": FileTextIcon,
  "/approval/flows": GitBranchIcon,

  // 报表中心 report
  "/report": BarChart3Icon,
  "/report/builtin": BarChart3Icon,
  "/report/custom": LineChartIcon,
  "/report/subscriptions": BellRingIcon,
  "/report/exports": DownloadIcon,

  // 审计中心 audit
  "/audit": ScrollTextIcon,
  "/audit/operations": ScrollTextIcon,
  "/audit/logins": LogInIcon,
  "/audit/changes": GitCompareIcon,
  "/audit/compliance": FileCheckIcon,

  // 接口/集成中心 integration
  "/integration": PlugIcon,
  "/integration/api-keys": KeyRoundIcon,
  "/integration/webhooks": WebhookIcon,
  "/integration/logs": FileClockIcon,
  "/integration/docs": FileTextIcon,

  // 第三方数据同步 sync
  "/sync": RefreshCwIcon,
  "/sync/sources": DatabaseIcon,
  "/sync/tasks": ListChecksIcon,
  "/sync/runs": HistoryIcon,
  "/sync/schedules": CalendarClockIcon,

  // 系统管理 system
  "/system": SettingsIcon,
  "/system/services/mail": MailPlusIcon,
  "/system/services/storage": HardDriveIcon,
  "/system/services/sms": MessageSquareIcon,
  "/system/services/push": BellRingIcon,
  "/system/services/auth": FingerprintIcon,
  "/system/settings": SettingsIcon,
  "/system/dictionaries": BookOpenIcon,
  "/system/jobs": ClockIcon,
  "/system/announcements": MegaphoneIcon,
  "/system/about": InfoIcon,

  // 消息中心 message
  "/message": MailIcon,
  "/message/inbox": InboxIcon,
  "/message/templates": FileTextIcon,
  "/message/history": HistoryIcon,
};

/** 未登记 key 的兜底图标（CircleIcon） */
export const DEFAULT_MENU_ICON: LucideIcon = CircleIcon;
