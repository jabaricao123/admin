<!-- BEGIN:nextjs-agent-rules -->

# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->

## Agent skills

### Project positioning

本仓库是**通用企业管理系统**（admin），不是 PLM。PLM 仅作为项目历史阶段的术语出现在 docs/PLAN.md 的变更记录中；任何 skill、agent、新文档都不要以 PLM 作为项目定位或命名依据。

### Issue tracker

Issues 追踪在 GitHub Issues（`jabaricao123/admin`，`gh` CLI 未装时回退 `.scratch/` 本地文件）。See `docs/agents/issue-tracker.md`.

### Triage labels

默认五角色标签：`needs-triage` / `needs-info` / `ready-for-agent` / `ready-for-human` / `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context：根目录 `GLOSSARY.md` + `docs/adr/`（尚未创建，由 `/domain-modeling` 懒创建）. See `docs/agents/domain.md`.
