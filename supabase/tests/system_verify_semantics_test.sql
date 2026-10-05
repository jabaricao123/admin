-- pgTAP：system 批次 2 修复项 3 —— 服务测试验证语义（system_verify_semantics）
-- 覆盖（storage 侧见 system_storage_init_test.sql 第 7-8 节）：
--   * test_mail_config：port 数字/范围校验（非数字、>65535 → failed 可读提示）；
--     from_addr 格式校验（非法 → failed；缺省可选 → 仍可 verified）；
--   * test_push_config：钉钉渠道启用后加签 Secret 必填（缺 / 空 → failed）；
--     企业微信不需 secret（启用即可 passed）；钉钉带 secret → verified；
--     凭据解密失败 → failed 可读提示（不裸抛）。
-- 说明：夹具只在本事务内生效，finish 后 rollback，不污染其他测试文件。

begin;

select plan(14);

delete from public.system_services;

select set_config(
  'request.jwt.claims',
  '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}',
  true
);
set local role authenticated;

-- ---------------------------------------------------------------------------
-- 1. test_mail_config：port 数字/范围 + from_addr 格式（8）
-- ---------------------------------------------------------------------------
select public.upsert_service_config(
  'mail',
  '{"host":"smtp.example.com","port":"abc","username":"u@example.com"}'::jsonb,
  null
);
select is(
  (select (public.test_mail_config('to@example.com')) ->> 'ok'),
  'false',
  'port 非数字：test_mail_config 返回 ok=false'
);
select is(
  (select (public.test_mail_config('to@example.com')) ->> 'message'),
  '端口需为 1-65535 的数字：abc',
  'port 非数字：message 指明合法范围'
);
select is(
  (select (public.test_mail_config('to@example.com')) ->> 'verify_status'),
  'failed',
  'port 非数字：verify_status=failed'
);

select public.upsert_service_config(
  'mail',
  '{"host":"smtp.example.com","port":70000,"username":"u@example.com"}'::jsonb,
  null
);
select is(
  (select (public.test_mail_config('to@example.com')) ->> 'message'),
  '端口需为 1-65535 的数字：70000',
  'port 超范围：message 指明合法范围'
);

select public.upsert_service_config(
  'mail',
  '{"host":"smtp.example.com","port":587,"username":"u@example.com","from_addr":"not-an-email"}'::jsonb,
  null
);
select is(
  (select (public.test_mail_config('to@example.com')) ->> 'message'),
  '发件人地址格式不正确：not-an-email',
  'from_addr 非法：message 指明格式错误'
);

select public.upsert_service_config(
  'mail',
  '{"host":"smtp.example.com","port":587,"username":"u@example.com","from_addr":"noreply@example.com"}'::jsonb,
  null
);
select is(
  (select (public.test_mail_config('to@example.com')) ->> 'ok'),
  'true',
  'port/from_addr 合法：test_mail_config 返回 ok=true'
);
select is(
  (select (public.test_mail_config('to@example.com')) ->> 'verify_status'),
  'verified',
  '合法配置：verify_status=verified'
);

-- from_addr 缺省可选（不强制），仍可 verified
select public.upsert_service_config(
  'mail',
  '{"host":"smtp.example.com","port":25,"username":"u@example.com"}'::jsonb,
  null
);
select is(
  (select (public.test_mail_config('to@example.com')) ->> 'ok'),
  'true',
  'from_addr 缺省：不阻断 verified（格式校验仅对已填值）'
);

-- ---------------------------------------------------------------------------
-- 2. test_push_config：钉钉加签 Secret 必填（6）
-- ---------------------------------------------------------------------------
select public.upsert_push_channel(
  'wecom',
  'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abc123',
  null, true
);
select public.upsert_push_channel(
  'dingtalk',
  'https://oapi.dingtalk.com/robot/send?access_token=xyz789',
  null, true
);

select is(
  (select (public.test_push_config('dingtalk')) ->> 'ok'),
  'false',
  '钉钉启用但未配 Secret：ok=false'
);
select is(
  (select (public.test_push_config('dingtalk')) ->> 'message'),
  '钉钉渠道启用后需填写加签 Secret（当前未配置）',
  '钉钉缺 Secret：message 指明加签要求'
);

select is(
  (select (public.test_push_config('wecom')) ->> 'ok'),
  'true',
  '企业微信不需要 secret：ok=true（语义不变）'
);

select public.upsert_push_channel(
  'dingtalk',
  'https://oapi.dingtalk.com/robot/send?access_token=xyz789',
  'ding-secret-xyz',
  true
);
select is(
  (select (public.test_push_config('dingtalk')) ->> 'ok'),
  'true',
  '钉钉配置加签 Secret：ok=true'
);

reset role;

-- 凭据损坏：钉钉密钥解密失败 → failed 可读提示（不裸抛 pgcrypto 错误）
update public.system_services
   set credentials = '\xdeadbeef'::bytea
 where service = 'push';

set local role authenticated;
select is(
  (select (public.test_push_config('dingtalk')) ->> 'ok'),
  'false',
  '凭据损坏：test_push_config 不抛错且 ok=false'
);
select ok(
  (select (public.test_push_config('dingtalk')) ->> 'message') like '%Secret 解密失败%',
  '凭据损坏：message 标注解密失败（可能密钥已轮换）'
);

reset role;

select * from finish();
rollback;
