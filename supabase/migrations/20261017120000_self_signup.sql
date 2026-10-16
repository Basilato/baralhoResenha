-- Fase 11: autocadastro aberto (decisão do administrador em 2026-10-16).
--
-- Antes, o perfil só nascia do app_metadata, que só o administrador grava
-- (pnpm users). Agora qualquer pessoa cria a própria conta na tela /cadastro:
-- o app chama auth.signUp com o e-mail técnico <usuário>@<domínio> e manda
-- usuário e nome de exibição no user_metadata.
--
-- Regras do perfil:
-- - app_metadata (administrador) tem prioridade e continua funcionando igual;
-- - no autocadastro, o usuário precisa ser a parte antes do @ do e-mail: assim
--   o login por usuário sempre encontra a conta;
-- - o perfil nasce uma vez só; mudar o user_metadata depois não altera nada.

create or replace function app_private.handle_auth_user_metadata()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_by_admin boolean := nullif(btrim(new.raw_app_meta_data ->> 'username'), '') is not null;
  v_meta jsonb := case when v_by_admin then new.raw_app_meta_data else new.raw_user_meta_data end;
  v_username text := lower(btrim(v_meta ->> 'username'));
  v_display_name text := coalesce(nullif(btrim(v_meta ->> 'display_name'), ''), v_username);
begin
  if v_username is null
    or exists (select 1 from public.profiles where id = new.id) then
    return new;
  end if;

  if v_username !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'username inválido para o usuário %', new.id
      using errcode = 'check_violation';
  end if;

  if not v_by_admin and lower(split_part(coalesce(new.email, ''), '@', 1)) <> v_username then
    raise exception 'o usuário precisa corresponder ao e-mail técnico (%)', new.id
      using errcode = 'check_violation';
  end if;

  insert into public.profiles (id, username, display_name)
  values (new.id, v_username, btrim(left(v_display_name, 32)))
  -- Perfil já existe (ou duas atualizações simultâneas): mantém o original.
  on conflict (id) do nothing;

  return new;
end;
$$;
