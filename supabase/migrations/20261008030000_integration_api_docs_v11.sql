-- 接口/集成中心 · 接口文档 v1.1（integration 批次 2 修复项 2）
-- 契约：docs/modules/integration/docs.md（规格与实际实现同步维护；多版本并存默认最新）。
-- 内容：
--   1. app.publish_api_doc：并发 unique_violation 兜底为中文「版本号已存在」；
--   2. 发布 v1.1 快照：修正事件清单（实际 emit 事件与 payload 键）+ api_departments
--      响应契约更新为 jsonb 状态包（{ok:true,data} / {ok:false,status,error}）；
--      webhook.ping 澄清为 test_webhook 专用（移出事件清单，x-webhook-test 说明）。
-- 说明：快照不可变，v1 保留；本迁移直接 insert v1.1（seed 模式，同 v1）。
-- 依赖：integration/009（api_docs / publish_api_doc）、20261008020000（错误包契约）。

-- ---------------------------------------------------------------------------
-- 1. app.publish_api_doc：唯一冲突友好提示（catch 23505）
-- ---------------------------------------------------------------------------
create or replace function app.publish_api_doc(
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
    raise exception '版本号已存在：%（修订请发布新版本号）', v_version using errcode = 'P0001';
  end if;

  begin
    insert into public.api_docs (version, spec, changelog, published_by)
    values (v_version, p_spec, nullif(btrim(coalesce(p_changelog, '')), ''), (select auth.uid()))
    returning id into v_id;
  exception when unique_violation then
    -- 并发发布同版本：列级唯一约束兜底，统一为中文友好提示
    raise exception '版本号已存在：%（修订请发布新版本号）', v_version using errcode = 'P0001';
  end;

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
  '版本冲突拒绝（快照不可变；exists 预检 + 23505 并发兜底，中文提示「版本号已存在」），'
  '写审计摘要（publish/api_doc）并返回快照 id；不直接 GRANT API 角色（规则 10）';

-- ---------------------------------------------------------------------------
-- 2. v1.1 快照（修正事件清单/载荷 + 响应契约）
-- ---------------------------------------------------------------------------
insert into public.api_docs (version, spec, changelog)
values (
  'v1.1',
  $json$
  {
    "openapi": "3.1.0",
    "info": {
      "title": "企业管理系统 · 开放 API",
      "version": "v1.1",
      "description": "内部对接优先：先以 API key 换取短期 JWT，再调用开放资源 RPC；Webhook 出站请求带 HMAC-SHA256 签名。v1.1：资源 RPC 以 jsonb 状态包返回（成功 {ok:true,data}；守卫失败 {ok:false,status,error}，HTTP 语义由网关适配）；事件清单与实现对齐。规格随实现同步维护，新端点上线必须更新本规格。"
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
                    "token": "short-lived-jwt-from-issue_api_token",
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
          "description": "token 校验 + scope 守卫后，以 api_client_role 身份读取 departments_v（RLS 最小授权；status=deleted 的部门不可见）。返回 jsonb 状态包：成功 {ok:true,data:[...]}；失败 {ok:false,status,error}（401=token 无效，403=缺 scope；失败调用写集成调用日志，HTTP 状态码由网关按 status 适配）。",
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
                "example": { "p_token": "short-lived-jwt-from-issue_api_token" }
              }
            }
          },
          "responses": {
            "200": {
              "description": "成功状态包（data 为部门数组，按树深度/排序号排列）",
              "content": {
                "application/json": {
                  "example": {
                    "ok": true,
                    "data": [
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
              }
            },
            "401": { "description": "token 无效或已过期（响应体 {ok:false,status:401,error}；网关据此返回 HTTP 401）" },
            "403": { "description": "token 缺少 org:read 范围（响应体 {ok:false,status:403,error}；网关据此返回 HTTP 403）" }
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
      {
        "event": "approval.submitted",
        "module": "approval",
        "summary": "审批提交",
        "payload_schema": {
          "instance_id": "uuid",
          "module": "string",
          "template_code": "string",
          "initiator_id": "uuid"
        }
      },
      {
        "event": "approval.node_approved",
        "module": "approval",
        "summary": "中间节点通过（非终审）",
        "payload_schema": {
          "instance_id": "uuid",
          "task_id": "uuid",
          "is_final": "boolean",
          "node_seq": "number"
        }
      },
      {
        "event": "approval.approved",
        "module": "approval",
        "summary": "审批通过（终审 is_final=true）",
        "payload_schema": {
          "instance_id": "uuid",
          "task_id": "uuid",
          "status": "string",
          "is_final": "boolean",
          "node_seq": "number"
        }
      },
      {
        "event": "approval.rejected",
        "module": "approval",
        "summary": "审批驳回",
        "payload_schema": {
          "instance_id": "uuid",
          "task_id": "uuid",
          "comment": "string"
        }
      },
      {
        "event": "approval.withdrawn",
        "module": "approval",
        "summary": "审批撤回",
        "payload_schema": {
          "instance_id": "uuid",
          "title": "string",
          "initiator_id": "uuid"
        }
      },
      {
        "event": "org.user_changed",
        "module": "org",
        "summary": "用户资料/角色变更（按 action 区分载荷）",
        "payload_schema": {
          "user_id": "uuid",
          "action": "profile_updated | role_assigned",
          "full_name": "string?",
          "department_id": "uuid?",
          "position_id": "uuid?",
          "status": "string?",
          "role": "string?",
          "role_id": "uuid?"
        }
      },
      {
        "event": "sync.run_finished",
        "module": "sync",
        "summary": "同步任务完成（终态）",
        "payload_schema": {
          "run_id": "uuid",
          "task_id": "uuid",
          "status": "string",
          "trigger": "string",
          "stats": {
            "insert": "number",
            "update": "number",
            "conflict": "number",
            "skip": "number",
            "failed": "number"
          }
        }
      }
    ],
    "x-webhook-test": {
      "description": "webhook.ping 为管理端 test_webhook 的直发测试事件（x-webhook-event=ping，不经 emit_event 队列，不属于订阅事件清单）。"
    },
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
  'v1.1：api_departments 契约改为 jsonb 状态包（失败留痕，401/403 由网关适配）；事件清单对齐实际 emit——'
  '补 approval.node_approved / approval.withdrawn，修正 approval.approved / org.user_changed / '
  'sync.run_finished 的 payload 键；webhook.ping 移出事件清单（test_webhook 专用，x-webhook-test 说明）。'
)
on conflict (version) do nothing;
