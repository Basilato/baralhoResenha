-- =============================================================================
-- Base: schema privado + perfis de jogadores
-- =============================================================================
-- `app_private` guarda funções internas e, nas próximas fases, as tabelas do
-- motor do jogo. Ele NÃO deve ser adicionado aos schemas expostos da Data API.

create schema if not exists app_private;

revoke all on schema app_private from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- profiles (public, com RLS)
-- -----------------------------------------------------------------------------
-- Um perfil por conta do Auth. Nunca guarda senha nem e-mail técnico.
-- `username` é imutável pelo cliente (sem grant de UPDATE na coluna).

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null unique
    check (username ~ '^[a-z0-9_]{3,20}$'),
  display_name text not null
    check (char_length(btrim(display_name)) between 1 and 32),
  avatar_path text
    check (avatar_path is null or char_length(avatar_path) <= 256),
  is_admin boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is
  'Perfil público de cada jogador. Contas são provisionadas pelo administrador.';

alter table public.profiles enable row level security;

-- Privilégios mínimos: navegador lê perfis e só altera apelido/avatar.
revoke all on table public.profiles from public, anon, authenticated;
grant select on table public.profiles to authenticated;
grant update (display_name, avatar_path) on table public.profiles to authenticated;

create policy "profiles_select_authenticated"
  on public.profiles
  for select
  to authenticated
  using (true);

create policy "profiles_update_own"
  on public.profiles
  for update
  to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- -----------------------------------------------------------------------------
-- updated_at automático
-- -----------------------------------------------------------------------------

create function app_private.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_touch_updated_at
  before update on public.profiles
  for each row
  execute function app_private.touch_updated_at();

-- -----------------------------------------------------------------------------
-- Criação automática do perfil ao provisionar uma conta no Auth
-- -----------------------------------------------------------------------------
-- O username vem de `raw_app_meta_data`, que só o administrador define (via
-- secret key); o usuário não consegue alterar app_metadata.
--
-- O Auth grava o usuário e só depois o app_metadata, em comandos separados.
-- Por isso o trigger roda no INSERT e no UPDATE: o perfil nasce quando o
-- username aparece. Conta sem username fica sem perfil e o app não a deixa
-- entrar. Depois de criado, o perfil não muda se o app_metadata mudar.

create function app_private.handle_auth_user_metadata()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_username text := lower(btrim(new.raw_app_meta_data ->> 'username'));
  v_display_name text := btrim(coalesce(
    new.raw_app_meta_data ->> 'display_name',
    new.raw_app_meta_data ->> 'username'
  ));
begin
  if v_username is null
    or exists (select 1 from public.profiles where id = new.id) then
    return new;
  end if;

  if v_username !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'app_metadata.username inválido para o usuário %', new.id
      using errcode = 'check_violation';
  end if;

  insert into public.profiles (id, username, display_name)
  values (new.id, v_username, left(v_display_name, 32));

  return new;
end;
$$;

revoke execute on function app_private.handle_auth_user_metadata()
  from public, anon, authenticated;

create trigger on_auth_user_metadata
  after insert or update of raw_app_meta_data on auth.users
  for each row
  execute function app_private.handle_auth_user_metadata();
