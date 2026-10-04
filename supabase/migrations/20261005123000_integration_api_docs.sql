-- 接口/集成中心 · 接口文档（工单 integration/009：api_docs + OpenAPI 发布）
-- 契约：docs/modules/integration/docs.md：
--   * 文档渲染：OpenAPI 3 规格（JSON）发布快照，页面交互式浏览（目录树/锚点/代码复制）；
--   * 分组导航：按模块分组的 API 目录 + Webhook 事件清单；
--   * 鉴权说明：API key 获取与 webhook HMAC 验签示例；
--   * 版本切换：多版本并存，默认最新；
--   * RLS：登录用户 SELECT；仅 admin 发布新版本。
-- 组成：
--   1. public.api_docs：发布快照（version 唯一；spec jsonb；changelog；published_by）；
--   2. app.publish_api_doc：admin 发布（版本格式/OpenAPI 结构校验 + 唯一冲突 + 审计）；
--   3. seed v1 规格：现有开放面（issue_api_token / api_departments）+ 首期 webhook 事件清单
--      + HMAC-SHA256 验签示例（Node/Python）。
-- 说明：规格源文件纳入 git 管理，表存发布快照；重新发布同版本视为冲突（快照不可变），
--   需要修订时发布新版本号。
-- 依赖：integration/002（开放面现状）、integration/004（事件清单）、app.audit_log、app.current_role。

-- ---------------------------------------------------------------------------
-- 1. api_docs：OpenAPI 发布快照
-- ---------------------------------------------------------------------------
create table public.api_docs (
  id           uuid primary key default gen_random_uuid(),
  version      text not null,
  spec         jsonb not null,
  changelog    text,
  published_by uuid,
  created_at   timestamptz not null default now(),
  constraint api_docs_version_key unique (version),
  constraint api_docs_version_check check (version ~ '^v[0-9]+(\.[0-9]+)*$'),
  constraint api_docs_spec_object_check check (jsonb_typeof(spec) = 'object'),
  constraint api_docs_spec_openapi_check check (
    coalesce(spec ->> 'openapi', '') ~ '^3\.[0-9]+'
    and coalesce(jsonb_typeof(spec -> 'info') = 'object', false)
    and coalesce(jsonb_typeof(spec -> 'paths') = 'object', false)
  )
);

comment on table public.api_docs is
  'OpenAPI 发布快照（集成/009）：version 唯一且不可变（修订发布新版本）；'
  'spec 为 OpenAPI 3 JSON（含 x-webhook-events / x-webhook-signature 扩展）；'
  '登录用户只读，发布仅经 app.publish_api_doc（admin）';
comment on column public.api_docs.version is '版本号（v1 / v1.2 形态；页面默认展示最新）';
comment on column public.api_docs.spec is 'OpenAPI 3 规格 JSON（info/paths/components + 扩展键）';
comment on column public.api_docs.changelog is '版本变更说明（Markdown 纯文本，页面直接展示）';
comment on column public.api_docs.published_by is '发布人 auth.uid()（迁移 seed 为 NULL）';

create index api_docs_created_idx
  on public.api_docs (created_at desc, id desc);

alter table public.api_docs enable row level security;

-- ---------------------------------------------------------------------------
-- 2. app.publish_api_doc：admin 发布新版本
-- ---------------------------------------------------------------------------
create function app.publish_api_doc(
  p_version   text,
  p_spec      jsonb,
  p_changelog text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_version text := btrim(coalesce(p_version, ''));
  v_id      uuid;
  v_paths   integer;
begin
  if (select app.current_role()) is distinct from 'admin' then
    raise exception '仅管理员可执行此操作' using errcode = '42501';
  end if;

  if v_version !~ '^v[0-9]+(\.[0-9]+)*$' then
    raise exception '版本号需形如 v1 或 v1.2' using errcode = '22023';
  end if;

  if p_spec is null or jsonb_typeof(p_spec) <> 'object' then
    raise exception '规格必须为 OpenAPI 3 JSON 对象' using errcode = '22023';
  end if;

  if coalesce(p_spec ->> 'openapi', '') !~ '^3\.[0-9]+' then
    raise exception '规格缺少 OpenAPI 3 版本字段（openapi）' using errcode = '22023';
  end if;

  if jsonb_typeof(p_spec -> 'info') is distinct from 'object' then
    raise exception '规格缺少 info 对象' using errcode = '22023';
  end if;

  if jsonb_typeof(p_spec -> 'paths') is distinct from 'object' then
    raise exception '规格缺少 paths 对象' using errcode = '22023';
  end if;

  if exists (select 1 from public.api_docs d where d.version = v_version) then
    raise exception '版本已存在：%（修订请发布新版本号）', v_version using errcode = 'P0001';
  end if;

  insert into public.api_docs (version, spec, changelog, published_by)
  values (v_version, p_spec, nullif(btrim(coalesce(p_changelog, '')), ''), (select auth.uid()))
  returning id into v_id;

  select count(*)::integer into v_paths
  from jsonb_object_keys(p_spec -> 'paths');

  perform app.audit_log(
    'integration', 'publish', 'api_doc', v_version,
    jsonb_build_object('version', v_version, 'paths', v_paths)
  );

  return v_id;
end;
$$;

comment on function app.publish_api_doc(text, jsonb, text) is
  '发布 API 文档新版本（admin）：校验版本号格式与 OpenAPI 3 结构（openapi/info/paths），'
  '版本冲突拒绝（快照不可变），写审计摘要（publish/api_doc）并返回快照 id；'
  '不直接 GRANT API 角色（规则 10）';

-- ---------------------------------------------------------------------------
-- 3. seed v1：现有开放面 + 事件清单 + HMAC 验签示例
-- ---------------------------------------------------------------------------
insert into public.api_docs (version, spec, changelog)
values (
  'v1',
  $json$
  {
    "openapi": "3.1.0",
    "info": {
      "title": "企业管理系统 · 开放 API",
      "version": "v1",
      "description": "内部对接优先：先以 API key 换取短期 JWT，再调用开放资源 RPC；Webhook 出站请求带 HMAC-SHA256 签名。规格随实现同步维护，新端点上线必须更新本规格。"
    },
    "servers": [
      {
        "url": "https://<project-ref>.supabase.co/rest/v1",
        "description": "PostgREST 入口（部署时替换为实际域名）"
      }
    ],
    "tags": [
      { "name": "auth", "description": "鉴权：API key 换取短期令牌" },
      { "name": "org", "description": "组织：部门公开视图" },
      { "name": "webhook", "description": "Webhook 事件清单与验签" }
    ],
    "security": [{ "anonKey": [] }],
    "paths": {
      "/rpc/issue_api_token": {
        "post": {
          "tags": ["auth"],
          "summary": "API key 换取短期 JWT",
          "description": "校验 API key（sha256 哈希 + 状态 + 有效期），签发 1 小时有效的 HS256 JWT（role=api_client_role，claims 含 key_id 与 scopes）。key 明文仅在签发时展示一次。",
          "operationId": "issue_api_token",
          "security": [],
          "requestBody": {
            "required": true,
            "content": {
              "application/json": {
                "schema": {
                  "type": "object",
                  "required": ["p_key"],
                  "properties": {
                    "p_key": { "type": "string", "description": "完整 API key（ak_ 开头，签发时一次性展示）" }
                  }
                },
                "example": { "p_key": "ak_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }
              }
            }
          },
          "responses": {
            "200": {
              "description": "签发成功",
              "content": {
                "application/json": {
                  "example": {
                    "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
                    "token_type": "Bearer",
                    "expires_in": 3600,
                    "expires_at": "2026-10-04T12:00:00Z",
                    "key_id": "0f2a6a3e-0000-0000-0000-000000000000",
                    "scopes": ["org:read"]
                  }
                }
              }
            },
            "401": { "description": "key 无效、已吊销或已过期" }
          }
        }
      },
      "/rpc/api_departments": {
        "post": {
          "tags": ["org"],
          "summary": "部门列表（scope: org:read）",
          "description": "token 校验 + scope 守卫后，以 api_client_role 身份读取 departments_v（RLS 最小授权；status=deleted 的部门不可见）。",
          "operationId": "api_departments",
          "security": [{ "bearerToken": [] }],
          "requestBody": {
            "required": true,
            "content": {
              "application/json": {
                "schema": {
                  "type": "object",
                  "required": ["p_token"],
                  "properties": {
                    "p_token": { "type": "string", "description": "issue_api_token 返回的短期 JWT" }
                  }
                },
                "example": { "p_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..." }
              }
            }
          },
          "responses": {
            "200": {
              "description": "部门数组（按树深度/排序号排列）",
              "content": {
                "application/json": {
                  "example": [
                    {
                      "id": "1f0f0f0f-0000-0000-0000-000000000000",
                      "name": "总经办",
                      "parent_id": null,
                      "depth": 0,
                      "sort_order": 1,
                      "status": "active"
                    }
                  ]
                }
              }
            },
            "401": { "description": "token 无效或已过期" },
            "403": { "description": "token 缺少 org:read 范围" }
          }
        }
      }
    },
    "components": {
      "securitySchemes": {
        "anonKey": {
          "type": "apiKey",
          "in": "header",
          "name": "apikey",
          "description": "项目 anon key：调用 PostgREST 入口必带；apikey 只标识项目，不授予业务权限"
        },
        "bearerToken": {
          "type": "http",
          "scheme": "bearer",
          "description": "issue_api_token 换取的短期 JWT；当前演示资源 RPC 以 p_token 参数显式传递（PostgREST RPC 约定），v2 目标形态为 Authorization: Bearer"
        }
      }
    },
    "x-webhook-events": [
      { "event": "approval.submitted", "module": "approval", "summary": "审批提交", "payload_schema": { "instance_id": "uuid", "title": "string" } },
      { "event": "approval.approved", "module": "approval", "summary": "审批通过", "payload_schema": { "instance_id": "uuid", "title": "string" } },
      { "event": "approval.rejected", "module": "approval", "summary": "审批驳回", "payload_schema": { "instance_id": "uuid", "title": "string", "reason": "string" } },
      { "event": "org.user_changed", "module": "org", "summary": "用户变更", "payload_schema": { "user_id": "uuid", "change": "string" } },
      { "event": "sync.run_finished", "module": "sync", "summary": "同步任务完成", "payload_schema": { "task_id": "uuid", "status": "string", "rows": "number" } },
      { "event": "webhook.ping", "module": "webhook", "summary": "测试 ping", "payload_schema": { "webhook_id": "uuid", "test": "boolean" } }
    ],
    "x-webhook-signature": {
      "algorithm": "HMAC-SHA256",
      "headers": {
        "x-webhook-signature": "hex(HMAC-SHA256(secret, raw_body))",
        "x-webhook-event": "事件名（如 approval.approved）"
      },
      "examples": [
        {
          "language": "node",
          "label": "Node.js",
          "code": "const crypto = require(\"crypto\");\n\n// rawBody 必须是原始请求体字节（勿先 JSON.parse 再 stringify）\nconst rawBody = req.rawBody ?? JSON.stringify(req.body);\nconst expected = crypto\n  .createHmac(\"sha256\", process.env.WEBHOOK_SECRET)\n  .update(rawBody)\n  .digest(\"hex\");\n\nconst actual = req.headers[\"x-webhook-signature\"] ?? \"\";\nconst ok =\n  actual.length === expected.length &&\n  crypto.timingSafeEqual(Buffer.from(actual), Buffer.from(expected));\nif (!ok) return res.status(401).end();"
        },
        {
          "language": "python",
          "label": "Python",
          "code": "import hmac, hashlib\n\nraw_body = request.get_data()  # 原始字节，勿用 request.json 重新序列化\nexpected = hmac.new(\n    os.environ[\"WEBHOOK_SECRET\"].encode(),\n    raw_body,\n    hashlib.sha256,\n).hexdigest()\n\nactual = request.headers.get(\"X-Webhook-Signature\", \"\")\nif not hmac.compare_digest(actual, expected):\n    return \"\", 401"
        }
      ]
    }
  }
  $json$::jsonb,
  '首版：开放 token 签发与部门资源 RPC；Webhook 事件清单与 HMAC-SHA256 验签示例。'
)
on conflict (version) do nothing;

-- ---------------------------------------------------------------------------
-- 4. 授权：登录用户只读（RLS 策略 true）；发布 RPC 仅 authenticated（函数内 admin 校验）
-- ---------------------------------------------------------------------------
revoke all on public.api_docs from public, anon, authenticated, service_role;
grant select on public.api_docs to authenticated;

create policy api_docs_select_authenticated
on public.api_docs
for select
to authenticated
using (true);

revoke all on function app.publish_api_doc(text, jsonb, text)
  from public, anon, authenticated, service_role;

create function public.publish_api_doc(
  p_version   text,
  p_spec      jsonb,
  p_changelog text default null
)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select app.publish_api_doc(p_version, p_spec, p_changelog)
$$;

comment on function public.publish_api_doc(text, jsonb, text) is
  'publish_api_doc Data API 薄包装（admin 校验与结构校验在 app 实现内）';

revoke all on function public.publish_api_doc(text, jsonb, text)
  from public, anon, service_role;
grant execute on function public.publish_api_doc(text, jsonb, text)
  to authenticated;
