-- 消息中心 / 审批 / 系统 · app 内部函数 EXECUTE 收口（message 批次 4 并入项 3）
-- 背景：Data API 只暴露 public schema（config.toml），app.* 实现层按 INDEX 规则 10
--   不应直接对 API 角色开放；但历史迁移里 app.submit_instance / act_task /
--   urge_instance / publish_announcement 曾直接 GRANT authenticated（当时在 public
--   包装落地前过渡），publish_announcement 的 ACL 亦随 create or replace 保留至今。
--   收口后调用只经各自 public 薄包装（包装内 security definer 转调 app 实现），
--   authenticated 无法绕过包装直调实现层（避免跳过参数/审计的旁路）。
-- 方式：幂等 do 块逐签名 revoke（to_regprocedure 守卫；重复执行安全）；
--   不影响 public 包装的既有 GRANT，也不影响函数属主 / 内部 SECURITY DEFINER 互调。
-- 依赖：20261004190000（submit_instance/act_task/public 包装）、
--       20261004223000（urge_instance）、20261005081000（publish_announcement）、
--       20261005222000（submit_instance 6 参版）。

do $$
declare
  v_sig  text;
  v_sigs constant text[] := array[
    'app.submit_instance(text,text,text,text,jsonb,uuid[])',
    'app.act_task(uuid,text,text)',
    'app.urge_instance(uuid)',
    'app.publish_announcement(uuid,boolean)'
  ];
begin
  foreach v_sig in array v_sigs loop
    if to_regprocedure(v_sig) is null then
      raise exception '待收口函数不存在：%', v_sig using errcode = '42883';
    end if;
    execute format(
      'revoke execute on function %s from public, anon, authenticated, service_role',
      v_sig
    );
  end loop;
end $$;
