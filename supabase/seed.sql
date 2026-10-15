-- =============================================================================
-- Seed de DESENVOLVIMENTO LOCAL — nunca rodar em produção.
-- =============================================================================
-- Três contas de teste. Senha de todas: resenha123
-- O domínio do e-mail técnico precisa bater com VITE_AUTH_EMAIL_DOMAIN.

do $$
declare
  v_domain constant text := 'contas.baralhoresenha.test';
  v_user record;
begin
  for v_user in
    select *
    from (values
      ('00000000-0000-4000-8000-000000000001'::uuid, 'teste1', 'Teste Um'),
      ('00000000-0000-4000-8000-000000000002'::uuid, 'teste2', 'Teste Dois'),
      ('00000000-0000-4000-8000-000000000003'::uuid, 'teste3', 'Teste Três')
    ) as t (id, username, display_name)
  loop
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at,
      confirmation_token, recovery_token, email_change, email_change_token_new
    )
    values (
      '00000000-0000-0000-0000-000000000000',
      v_user.id,
      'authenticated',
      'authenticated',
      v_user.username || '@' || v_domain,
      extensions.crypt('resenha123', extensions.gen_salt('bf')),
      now(),
      jsonb_build_object(
        'provider', 'email',
        'providers', jsonb_build_array('email'),
        'username', v_user.username,
        'display_name', v_user.display_name
      ),
      '{}'::jsonb,
      now(),
      now(),
      '', '', '', ''
    );

    insert into auth.identities (
      id, user_id, provider_id, identity_data, provider,
      last_sign_in_at, created_at, updated_at
    )
    values (
      gen_random_uuid(),
      v_user.id,
      v_user.id::text,
      jsonb_build_object(
        'sub', v_user.id::text,
        'email', v_user.username || '@' || v_domain,
        'email_verified', true
      ),
      'email',
      now(),
      now(),
      now()
    );
  end loop;
end;
$$;
