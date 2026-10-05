-- 消息中心 · 投递明细保留期回收：过期分区 DETACH+DROP（message 批次 4 并入项 2）
-- 背景：app.cleanup_message_deliveries 原先只按行 DELETE（90 天前明细逐行删）；
--   message_deliveries 按月分区，整月已过保留期的分区逐行删效率低、且死元组占用空间。
-- 本迁移：参照 app.cleanup_integration_call_logs（integration/007 分区清理先例）——
--   整月已过期的分区先 ALTER TABLE ... DETACH PARTITION 再 DROP（父表锁窗口取 DETACH 一次，
--   避免 DROP 直连父表分区间隙的元数据抖动），保留分区内再按行删除（保证保留期边界精确）；
--   同时清理 message_delivery_attempts 明细（同保留期，弱引用无级联）。
-- 授权与签名不变（create or replace 保留 ACL）：security invoker，仅 pg_cron / owner 可达。
-- 依赖：20261005090000（message_deliveries / cleanup_message_deliveries）、
--       20261005121000（integration 分区清理先例）、20261012020000（attempts 明细表）。

-- ---------------------------------------------------------------------------
-- app.cleanup_message_deliveries：过期分区 DETACH+DROP + 行级删除 + 明细清理
-- ---------------------------------------------------------------------------
create or replace function app.cleanup_message_deliveries(p_retention_days integer default 90)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_days    integer := p_retention_days;
  v_cutoff  timestamptz;
  v_part    record;
  v_deleted integer;
begin
  if p_retention_days is null or p_retention_days < 1 then
    raise exception '保留天数必须 >= 1：%', coalesce(p_retention_days::text, '(null)')
      using errcode = '22023';
  end if;

  v_cutoff := now() - make_interval(days => v_days);
  -- 1) 整月分区已整体过期 → DETACH + DROP（比重行删高效；分区名后缀 YYYYMM 由 ensure 保证）
  for v_part in
    select c.relname
    from pg_catalog.pg_class c
    join pg_catalog.pg_inherits i on i.inhrelid = c.oid
    where i.inhparent = 'public.message_deliveries'::regclass
      and c.relname ~ '^message_deliveries_[0-9]{6}$'
  loop
    if to_date(substring(v_part.relname from '([0-9]{6})$'), 'YYYYMM')
         + interval '1 month' <= v_cutoff then
      execute format(
        'alter table public.message_deliveries detach partition public.%I',
        v_part.relname
      );
      execute format('drop table public.%I', v_part.relname);
    end if;
  end loop;

  -- 2) 保留分区内按行清理（保证保留期边界精确；最多一天清理延迟）
  delete from public.message_deliveries
   where created_at < v_cutoff;

  get diagnostics v_deleted = row_count;

  -- 3) 重发明细同保留期清理（弱引用无级联；dropped 分区残留的孤儿行也在此到期清除）
  delete from public.message_delivery_attempts
   where attempted_at < v_cutoff;

  return v_deleted;
end;
$$;

comment on function app.cleanup_message_deliveries(integer) is
  '投递明细清理（默认 90 天；history.md 保留策略）：整月过期分区先 DETACH+DROP，'
  '保留分区内按行删除超期 deliveries；同时清理同保留期的 message_delivery_attempts 明细；'
  '返回删除行数（不含 drop 分区内行与明细）；security invoker + 撤销 API 角色，仅 pg_cron 可达';

-- 显式再收口（create or replace 保留原 ACL；防未来重建函数时权限漂移）
revoke all on function app.cleanup_message_deliveries(integer)
  from public, anon, authenticated, service_role;
