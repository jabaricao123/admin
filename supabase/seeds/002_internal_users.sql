-- 内部角色测试账号（engineer/planner/buyer/quality）
-- 复用 001_admin.sql 的插入模式；密码统一 <role>123

do $$
declare
  v_roles text[] := array['engineer','planner','buyer','quality'];
  v_role text;
  v_id uuid;
begin
  foreach v_role in array v_roles loop
    v_id := ('22222222-2222-2222-2222-22222222' || lpad(((array_position(v_roles, v_role))::text), 4, '0'))::uuid;

    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at, confirmation_token, recovery_token,
      email_change_token_new, email_change
    ) values (
      '00000000-0000-0000-0000-000000000000',
      v_id, 'authenticated', 'authenticated',
      v_role || '@example.com',
      crypt(v_role || '123', gen_salt('bf')),
      now(),
      '{"provider":"email","providers":["email"]}',
      jsonb_build_object('full_name', initcap(v_role) || ' 测试'),
      now(), now(), '', '', '', ''
    )
    on conflict (id) do nothing;

    insert into auth.identities (
      id, user_id, provider_id, identity_data, provider,
      last_sign_in_at, created_at, updated_at
    )
    select
      gen_random_uuid(), v_id, v_id::text,
      jsonb_build_object('sub', v_id::text, 'email', v_role || '@example.com',
                         'email_verified', true, 'phone_verified', false),
      'email', now(), now(), now()
    where not exists (
      select 1 from auth.identities where user_id = v_id and provider = 'email'
    );

    update public.profiles
       set role = v_role::public.user_role
     where id = v_id and role <> v_role::public.user_role;
  end loop;
end $$;
