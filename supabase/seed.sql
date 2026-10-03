-- 本地开发种子数据（仅用于 supabase db reset，本地环境）
-- 测试账号：admin@example.com / admin123

-- 1) 测试用户
insert into auth.users (
  instance_id,
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at,
  confirmation_token,
  recovery_token,
  email_change_token_new,
  email_change
)
values (
  '00000000-0000-0000-0000-000000000000',
  '11111111-1111-1111-1111-111111111111',
  'authenticated',
  'authenticated',
  'admin@example.com',
  crypt('admin123', gen_salt('bf')),
  now(),
  '{"provider":"email","providers":["email"]}',
  '{"full_name":"系统管理员"}',
  now(),
  now(),
  '',
  '',
  '',
  ''
)
on conflict (id) do nothing;

-- 2) 身份绑定（邮箱登录必需）
insert into auth.identities (
  id,
  user_id,
  provider_id,
  identity_data,
  provider,
  last_sign_in_at,
  created_at,
  updated_at
)
select
  gen_random_uuid(),
  '11111111-1111-1111-1111-111111111111',
  '11111111-1111-1111-1111-111111111111',
  '{"sub":"11111111-1111-1111-1111-111111111111","email":"admin@example.com","email_verified":true,"phone_verified":false}'::jsonb,
  'email',
  now(),
  now(),
  now()
where not exists (
  select 1 from auth.identities
  where user_id = '11111111-1111-1111-1111-111111111111'
    and provider = 'email'
);
