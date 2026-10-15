-- =============================================================================
-- Fase 3: salas (lobby), entrada por código e avisos em tempo real
-- =============================================================================
-- Tabelas ficam em app_private, sem nenhum grant para o navegador. O acesso é
-- só pelas RPCs: wrappers SECURITY INVOKER em public chamam as implementações
-- SECURITY DEFINER em app_private, que validam auth.uid() e associação à sala.
--
-- Erros de regra usam errcode P0001, message = código estável (ex.: ROOM_FULL)
-- e detail = texto para o jogador. O frontend traduz pelo código.

grant usage on schema app_private to authenticated;

-- -----------------------------------------------------------------------------
-- Tabelas
-- -----------------------------------------------------------------------------

create table app_private.games (
  id uuid primary key default gen_random_uuid(),
  host_user_id uuid not null references auth.users (id),
  status text not null default 'lobby'
    check (status in ('lobby', 'playing', 'finished', 'cancelled')),
  -- Fase do motor (Fase 5); nula enquanto não há partida em andamento.
  phase text,
  round_number integer not null default 0 check (round_number >= 0),
  -- Cresce a cada mudança de estado; o cliente usa para detectar conflito.
  version bigint not null default 1 check (version >= 1),
  rules_version text not null default 'resenha-simples-7.1',
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  check (status <> 'playing' or started_at is not null),
  check (status not in ('finished', 'cancelled') or finished_at is not null)
);

create index games_host_user_id_idx on app_private.games (host_user_id);
create index games_status_idx on app_private.games (status);

create table app_private.game_players (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references app_private.games (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  seat smallint not null check (seat between 1 and 8),
  is_ready boolean not null default false,
  joined_at timestamptz not null default now(),
  unique (game_id, user_id),
  unique (game_id, seat)
);

create index game_players_user_id_idx on app_private.game_players (user_id);

-- Código curto para digitar no celular: 6 caracteres sem 0/O, 1/I/L.
-- Fica em claro porque o host precisa reexibi-lo; o schema não é exposto e o
-- código só sai pela RPC para quem já é membro. Códigos nunca são reutilizados
-- (as linhas não são apagadas, só desativadas).
create table app_private.game_invites (
  game_id uuid primary key references app_private.games (id) on delete cascade,
  code text not null unique check (code ~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$'),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Tentativas com código errado, para limitar força bruta.
create table app_private.join_failures (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

create index join_failures_user_id_created_at_idx
  on app_private.join_failures (user_id, created_at desc);

-- Defesa em profundidade: RLS ligada e sem policies. Só o dono (funções
-- definer) acessa.
alter table app_private.games enable row level security;
alter table app_private.game_players enable row level security;
alter table app_private.game_invites enable row level security;
alter table app_private.join_failures enable row level security;

revoke all on all tables in schema app_private from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Auxiliares internos (sem grant para o navegador)
-- -----------------------------------------------------------------------------

create function app_private.fail(p_code text, p_message text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  raise exception using errcode = 'P0001', message = p_code, detail = p_message;
end;
$$;

-- Usuário autenticado e com conta ativa; senão, erro.
create function app_private.require_user()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    perform app_private.fail('NOT_AUTHENTICATED', 'Faça login para continuar.');
  end if;

  if not exists (select 1 from public.profiles where id = v_uid and is_active) then
    perform app_private.fail('ACCOUNT_DISABLED', 'Esta conta está desativada.');
  end if;

  return v_uid;
end;
$$;

create function app_private.is_game_member(p_game_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from app_private.game_players
    where game_id = p_game_id and user_id = p_user_id
  );
$$;

-- Trava a sala até o fim da transação: serializa comandos da mesma partida.
-- Sala inexistente e "não sou membro" dão o mesmo erro, para não revelar salas.
create function app_private.lock_member_game(p_game_id uuid, p_user_id uuid)
returns app_private.games
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_game app_private.games;
begin
  select * into v_game from app_private.games where id = p_game_id for update;

  if not found or not app_private.is_game_member(p_game_id, p_user_id) then
    perform app_private.fail('ROOM_NOT_FOUND', 'Sala não encontrada ou você não faz parte dela.');
  end if;

  return v_game;
end;
$$;

create function app_private.assert_host(p_game app_private.games, p_user_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_game.host_user_id <> p_user_id then
    perform app_private.fail('NOT_HOST', 'Só o host pode fazer isso.');
  end if;
end;
$$;

create function app_private.assert_lobby(p_game app_private.games)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_game.status = 'playing' then
    perform app_private.fail('ROOM_ALREADY_STARTED', 'Essa resenha já começou.');
  elsif p_game.status <> 'lobby' then
    perform app_private.fail('ROOM_CLOSED', 'Essa resenha já foi encerrada.');
  end if;
end;
$$;

-- Limite de salas abertas por pessoa (evita abuso). O advisory lock serializa
-- criações/entradas simultâneas do mesmo usuário.
create function app_private.assert_room_quota(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('room-quota:' || p_user_id::text, 0));

  if (
    select count(*)
    from app_private.game_players gp
    join app_private.games g on g.id = gp.game_id
    where gp.user_id = p_user_id and g.status in ('lobby', 'playing')
  ) >= 5 then
    perform app_private.fail(
      'TOO_MANY_ROOMS',
      'Você já está em 5 resenhas abertas. Saia ou encerre alguma antes.'
    );
  end if;
end;
$$;

-- Incrementa a versão e avisa o canal privado da sala. O aviso só sai se a
-- transação confirmar, e carrega apenas id + versão (nunca dados secretos).
create function app_private.touch_game(p_game_id uuid)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_version bigint;
begin
  update app_private.games
  set version = version + 1
  where id = p_game_id
  returning version into v_version;

  perform realtime.send(
    jsonb_build_object('game_id', p_game_id, 'version', v_version),
    'game_changed',
    'game:' || p_game_id::text,
    true
  );

  return v_version;
end;
$$;

create function app_private.new_room_code()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_bytes bytea;
  v_code text;
begin
  loop
    v_bytes := extensions.gen_random_bytes(6);
    v_code := '';
    for i in 0..5 loop
      v_code := v_code || substr(v_alphabet, (get_byte(v_bytes, i) % length(v_alphabet)) + 1, 1);
    end loop;
    exit when not exists (select 1 from app_private.game_invites where code = v_code);
  end loop;
  return v_code;
end;
$$;

-- Visão da sala para um membro. O código só aparece enquanto está em lobby.
create function app_private.room_view(p_game_id uuid, p_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', g.id,
    'status', g.status,
    'version', g.version,
    'hostUserId', g.host_user_id,
    'createdAt', g.created_at,
    'startedAt', g.started_at,
    'code', i.code,
    'myPlayerId', (
      select gp.id from app_private.game_players gp
      where gp.game_id = g.id and gp.user_id = p_user_id
    ),
    'players', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', gp.id,
          'userId', gp.user_id,
          'seat', gp.seat,
          'isReady', gp.is_ready,
          'isHost', gp.user_id = g.host_user_id,
          'displayName', p.display_name,
          'username', p.username,
          'avatarPath', p.avatar_path
        )
        order by gp.seat
      )
      from app_private.game_players gp
      join public.profiles p on p.id = gp.user_id
      where gp.game_id = g.id
    ), '[]'::jsonb)
  )
  from app_private.games g
  left join app_private.game_invites i on i.game_id = g.id and i.active
  where g.id = p_game_id;
$$;

-- -----------------------------------------------------------------------------
-- Implementações das RPCs (security definer)
-- -----------------------------------------------------------------------------

create function app_private.create_room()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_user();
  v_game_id uuid;
begin
  perform app_private.assert_room_quota(v_uid);

  insert into app_private.games (host_user_id)
  values (v_uid)
  returning id into v_game_id;

  insert into app_private.game_players (game_id, user_id, seat)
  values (v_game_id, v_uid, 1);

  insert into app_private.game_invites (game_id, code)
  values (v_game_id, app_private.new_room_code());

  return app_private.room_view(v_game_id, v_uid);
end;
$$;

-- Código errado devolve {error: 'INVALID_CODE'} em vez de exceção, para que a
-- tentativa fique registrada (uma exceção desfaria o insert em join_failures).
create function app_private.join_room(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_user();
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_invite app_private.game_invites;
  v_game app_private.games;
  v_seat smallint;
begin
  if (
    select count(*) from app_private.join_failures
    where user_id = v_uid and created_at > now() - interval '10 minutes'
  ) >= 10 then
    perform app_private.fail(
      'TOO_MANY_ATTEMPTS',
      'Muitas tentativas com código errado. Espere alguns minutos.'
    );
  end if;

  select * into v_invite from app_private.game_invites where code = v_code;

  if not found then
    insert into app_private.join_failures (user_id) values (v_uid);
    return jsonb_build_object('error', 'INVALID_CODE');
  end if;

  select * into v_game from app_private.games where id = v_invite.game_id for update;

  -- Já é membro: idempotente (clique duplo, link aberto de novo, partida em curso).
  if app_private.is_game_member(v_game.id, v_uid) then
    return jsonb_build_object('gameId', v_game.id, 'status', v_game.status);
  end if;

  perform app_private.assert_lobby(v_game);
  perform app_private.assert_room_quota(v_uid);

  select min(s)::smallint into v_seat
  from generate_series(1, 8) as s
  where not exists (
    select 1 from app_private.game_players where game_id = v_game.id and seat = s
  );

  if v_seat is null then
    perform app_private.fail('ROOM_FULL', 'A sala já está cheia (8 pessoas).');
  end if;

  insert into app_private.game_players (game_id, user_id, seat)
  values (v_game.id, v_uid, v_seat);

  perform app_private.touch_game(v_game.id);

  return jsonb_build_object('gameId', v_game.id, 'status', v_game.status);
end;
$$;

create function app_private.leave_room(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_user();
  v_game app_private.games := app_private.lock_member_game(p_game_id, v_uid);
  v_next_host uuid;
begin
  -- Durante a partida ninguém sai (o estado fica salvo e dá para voltar);
  -- se travar, o host encerra a sala.
  perform app_private.assert_lobby(v_game);

  delete from app_private.game_players where game_id = p_game_id and user_id = v_uid;

  select user_id into v_next_host
  from app_private.game_players
  where game_id = p_game_id
  order by joined_at, seat
  limit 1;

  if v_next_host is null then
    update app_private.games
    set status = 'cancelled', finished_at = now()
    where id = p_game_id;
    update app_private.game_invites set active = false where game_id = p_game_id;
  elsif v_game.host_user_id = v_uid then
    update app_private.games set host_user_id = v_next_host where id = p_game_id;
  end if;

  perform app_private.touch_game(p_game_id);
end;
$$;

create function app_private.set_ready(p_game_id uuid, p_ready boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_user();
  v_game app_private.games := app_private.lock_member_game(p_game_id, v_uid);
begin
  perform app_private.assert_lobby(v_game);

  update app_private.game_players
  set is_ready = coalesce(p_ready, false)
  where game_id = p_game_id and user_id = v_uid and is_ready is distinct from coalesce(p_ready, false);

  if found then
    perform app_private.touch_game(p_game_id);
  end if;
end;
$$;

create function app_private.kick_player(p_game_id uuid, p_player_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_user();
  v_game app_private.games := app_private.lock_member_game(p_game_id, v_uid);
  v_target_user uuid;
begin
  perform app_private.assert_host(v_game, v_uid);
  perform app_private.assert_lobby(v_game);

  select user_id into v_target_user
  from app_private.game_players
  where id = p_player_id and game_id = p_game_id;

  if v_target_user is null then
    perform app_private.fail('PLAYER_NOT_FOUND', 'Essa pessoa não está mais na sala.');
  end if;

  if v_target_user = v_uid then
    perform app_private.fail('CANNOT_KICK_SELF', 'Para sair, use "Sair da sala".');
  end if;

  delete from app_private.game_players where id = p_player_id;

  perform app_private.touch_game(p_game_id);
end;
$$;

-- p_expected_version impede iniciar com uma lista desatualizada na tela
-- (alguém entrou ou saiu um instante antes do clique).
create function app_private.start_game(p_game_id uuid, p_expected_version bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_user();
  v_game app_private.games := app_private.lock_member_game(p_game_id, v_uid);
  v_count integer;
begin
  perform app_private.assert_host(v_game, v_uid);
  perform app_private.assert_lobby(v_game);

  if v_game.version <> p_expected_version then
    perform app_private.fail('VERSION_CONFLICT', 'A sala mudou. Confira os jogadores e tente de novo.');
  end if;

  select count(*) into v_count from app_private.game_players where game_id = p_game_id;

  if v_count < 3 then
    perform app_private.fail('NOT_ENOUGH_PLAYERS', 'São precisos pelo menos 3 jogadores.');
  end if;

  -- O motor (Fases 4 e 5) vai distribuir cartas e preparar o primeiro turno aqui.
  update app_private.games
  set status = 'playing', started_at = now(), round_number = 1
  where id = p_game_id;

  update app_private.game_invites set active = false where game_id = p_game_id;

  perform app_private.touch_game(p_game_id);
end;
$$;

-- Host encerra a sala inteira (lobby ou partida travada). Não declara vencedor.
create function app_private.close_room(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_user();
  v_game app_private.games := app_private.lock_member_game(p_game_id, v_uid);
begin
  perform app_private.assert_host(v_game, v_uid);

  if v_game.status not in ('lobby', 'playing') then
    perform app_private.fail('ROOM_CLOSED', 'Essa resenha já foi encerrada.');
  end if;

  update app_private.games
  set status = 'cancelled', finished_at = now()
  where id = p_game_id;

  update app_private.game_invites set active = false where game_id = p_game_id;

  perform app_private.touch_game(p_game_id);
end;
$$;

create function app_private.get_room_view(p_game_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_user();
begin
  if not app_private.is_game_member(p_game_id, v_uid) then
    perform app_private.fail('ROOM_NOT_FOUND', 'Sala não encontrada ou você não faz parte dela.');
  end if;

  return app_private.room_view(p_game_id, v_uid);
end;
$$;

create function app_private.list_my_rooms()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_user();
begin
  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', g.id,
        'status', g.status,
        'createdAt', g.created_at,
        'isHost', g.host_user_id = v_uid,
        'hostName', hp.display_name,
        'playerCount', (select count(*) from app_private.game_players x where x.game_id = g.id)
      )
      order by g.created_at desc
    )
    from app_private.games g
    join app_private.game_players gp on gp.game_id = g.id and gp.user_id = v_uid
    join public.profiles hp on hp.id = g.host_user_id
    where g.status in ('lobby', 'playing')
  ), '[]'::jsonb);
end;
$$;

-- Usado pelas policies do Realtime: tópico game:<uuid> só para membros.
create function app_private.can_use_game_topic(p_topic text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_topic is null
    or p_topic !~ '^game:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;

  return app_private.is_game_member(substr(p_topic, 6)::uuid, auth.uid());
end;
$$;

-- -----------------------------------------------------------------------------
-- RPCs públicas (security invoker) — a única superfície exposta
-- -----------------------------------------------------------------------------

create function public.create_room()
returns jsonb language sql security invoker set search_path = ''
as $$ select app_private.create_room(); $$;

create function public.join_room(p_code text)
returns jsonb language sql security invoker set search_path = ''
as $$ select app_private.join_room(p_code); $$;

create function public.leave_room(p_game_id uuid)
returns void language sql security invoker set search_path = ''
as $$ select app_private.leave_room(p_game_id); $$;

create function public.set_ready(p_game_id uuid, p_ready boolean)
returns void language sql security invoker set search_path = ''
as $$ select app_private.set_ready(p_game_id, p_ready); $$;

create function public.kick_player(p_game_id uuid, p_player_id uuid)
returns void language sql security invoker set search_path = ''
as $$ select app_private.kick_player(p_game_id, p_player_id); $$;

create function public.start_game(p_game_id uuid, p_expected_version bigint)
returns void language sql security invoker set search_path = ''
as $$ select app_private.start_game(p_game_id, p_expected_version); $$;

create function public.close_room(p_game_id uuid)
returns void language sql security invoker set search_path = ''
as $$ select app_private.close_room(p_game_id); $$;

create function public.get_room_view(p_game_id uuid)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select app_private.get_room_view(p_game_id); $$;

create function public.list_my_rooms()
returns jsonb language sql stable security invoker set search_path = ''
as $$ select app_private.list_my_rooms(); $$;

-- Grants explícitos: só authenticated, só estas funções.
grant execute on function
  public.create_room(),
  public.join_room(text),
  public.leave_room(uuid),
  public.set_ready(uuid, boolean),
  public.kick_player(uuid, uuid),
  public.start_game(uuid, bigint),
  public.close_room(uuid),
  public.get_room_view(uuid),
  public.list_my_rooms(),
  app_private.create_room(),
  app_private.join_room(text),
  app_private.leave_room(uuid),
  app_private.set_ready(uuid, boolean),
  app_private.kick_player(uuid, uuid),
  app_private.start_game(uuid, bigint),
  app_private.close_room(uuid),
  app_private.get_room_view(uuid),
  app_private.list_my_rooms(),
  app_private.can_use_game_topic(text)
to authenticated;

-- -----------------------------------------------------------------------------
-- Realtime: canais privados game:<uuid>
-- -----------------------------------------------------------------------------
-- Membros recebem broadcasts e presença. O navegador só pode publicar
-- presença; avisos oficiais (game_changed) saem apenas do banco.

create policy "game_members_receive"
  on realtime.messages
  for select
  to authenticated
  using (
    realtime.messages.extension in ('broadcast', 'presence')
    and app_private.can_use_game_topic((select realtime.topic()))
  );

create policy "game_members_track_presence"
  on realtime.messages
  for insert
  to authenticated
  with check (
    realtime.messages.extension = 'presence'
    and app_private.can_use_game_topic((select realtime.topic()))
  );
