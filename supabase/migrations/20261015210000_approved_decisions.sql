-- =============================================================================
-- Decisões aprovadas (BARALHO_DA_RESENHA_DECISOES_APROVADAS.md)
-- =============================================================================
-- A1 sorteio de lugares · B1 GHO-05 privada · E1 código de 10 caracteres com
-- rotação · E3 trava por usuário · E5 removido não volta sem liberação ·
-- E6 host passa para o conectado mais antigo (sinal de presença no servidor)

-- -----------------------------------------------------------------------------
-- E1: códigos de 10 caracteres, nunca reutilizados, com rotação pelo host
-- -----------------------------------------------------------------------------

-- NOT VALID: códigos antigos de 6 caracteres continuam válidos até expirarem;
-- todo código novo precisa ter 10.
alter table app_private.game_invites
  drop constraint game_invites_code_check,
  add constraint game_invites_code_check
    check (code ~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{10}$') not valid;

-- Todo código já emitido, inclusive os trocados pela rotação.
create table app_private.room_codes_used (
  code text primary key,
  created_at timestamptz not null default now()
);

alter table app_private.room_codes_used enable row level security;
revoke all on table app_private.room_codes_used from public, anon, authenticated;

insert into app_private.room_codes_used (code)
select code from app_private.game_invites
on conflict do nothing;

create or replace function app_private.new_room_code()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_length constant integer := 10;
  v_bytes bytea;
  v_code text;
begin
  loop
    v_bytes := extensions.gen_random_bytes(v_length);
    v_code := '';
    for i in 0..v_length - 1 loop
      v_code := v_code || substr(v_alphabet, (get_byte(v_bytes, i) % length(v_alphabet)) + 1, 1);
    end loop;

    insert into app_private.room_codes_used (code) values (v_code)
    on conflict do nothing;
    exit when found;
  end loop;

  return v_code;
end;
$$;

-- Host gera um código novo; o anterior para de funcionar na hora.
create function app_private.rotate_room_code(p_game_id uuid)
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
  perform app_private.assert_lobby(v_game);

  update app_private.game_invites
  set code = app_private.new_room_code(), created_at = now()
  where game_id = p_game_id;

  perform app_private.touch_game(p_game_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- E5: quem o host removeu não volta só com o código
-- -----------------------------------------------------------------------------

create table app_private.game_bans (
  game_id uuid not null references app_private.games (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  banned_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (game_id, user_id)
);

alter table app_private.game_bans enable row level security;
revoke all on table app_private.game_bans from public, anon, authenticated;

create or replace function app_private.kick_player(p_game_id uuid, p_player_id uuid)
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

  insert into app_private.game_bans (game_id, user_id, banned_by)
  values (p_game_id, v_target_user, v_uid)
  on conflict (game_id, user_id) do nothing;

  perform app_private.touch_game(p_game_id);
end;
$$;

-- Host libera explicitamente a volta de quem removeu.
create function app_private.allow_rejoin(p_game_id uuid, p_user_id uuid)
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
  perform app_private.assert_lobby(v_game);

  delete from app_private.game_bans where game_id = p_game_id and user_id = p_user_id;

  if found then
    perform app_private.touch_game(p_game_id);
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- E6 (e base para E2): presença registrada pelo servidor
-- -----------------------------------------------------------------------------
-- O navegador chama heartbeat() a cada ~20 s enquanto a tela está aberta. O
-- horário é do banco. "Conectado" = sinal nos últimos 60 s. Fingir presença
-- não prejudica ninguém; a remoção por ausência (E2) exige o sinal parado.

alter table app_private.game_players
  add column last_seen_at timestamptz not null default now();

create function app_private.connected_window()
returns interval
language sql
immutable
set search_path = ''
as $$ select interval '60 seconds' $$;

create function app_private.heartbeat(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_user();
begin
  update app_private.game_players
  set last_seen_at = now()
  where game_id = p_game_id and user_id = v_uid;

  if not found then
    perform app_private.fail('ROOM_NOT_FOUND', 'Sala não encontrada ou você não faz parte dela.');
  end if;
end;
$$;

create or replace function app_private.leave_room(p_game_id uuid)
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
  -- Durante a partida ninguém sai (o estado fica salvo e dá para voltar).
  perform app_private.assert_lobby(v_game);

  delete from app_private.game_players where game_id = p_game_id and user_id = v_uid;

  -- Conectado mais antigo primeiro; ordem de entrada como desempate.
  select user_id into v_next_host
  from app_private.game_players
  where game_id = p_game_id
  order by (last_seen_at > now() - app_private.connected_window()) desc, joined_at, seat
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

-- -----------------------------------------------------------------------------
-- join_room: trava por usuário (E3) e bloqueio de removidos (E5)
-- -----------------------------------------------------------------------------

create or replace function app_private.join_room(p_code text)
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
  -- Serializa as tentativas do mesmo usuário: o limite vale mesmo com
  -- pedidos simultâneos.
  perform pg_advisory_xact_lock(hashtextextended('join:' || v_uid::text, 0));

  delete from app_private.join_failures
  where user_id = v_uid and created_at < now() - interval '1 day';

  if (
    select count(*) from app_private.join_failures
    where user_id = v_uid and created_at > now() - interval '10 minutes'
  ) >= 10 then
    perform app_private.fail(
      'TOO_MANY_ATTEMPTS',
      'Muitas tentativas com código errado. Espere alguns minutos.'
    );
  end if;

  -- Código trocado pela rotação não existe mais aqui: conta como errado.
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

  if exists (
    select 1 from app_private.game_bans where game_id = v_game.id and user_id = v_uid
  ) then
    perform app_private.fail(
      'REMOVED_FROM_ROOM',
      'O host removeu você desta sala. Peça para ele liberar a sua volta.'
    );
  end if;

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

-- -----------------------------------------------------------------------------
-- room_view: conexão por jogador e lista de removidos (só para o host)
-- -----------------------------------------------------------------------------

create or replace function app_private.room_view(p_game_id uuid, p_user_id uuid)
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
          'connected', gp.last_seen_at > now() - app_private.connected_window(),
          'displayName', p.display_name,
          'username', p.username,
          'avatarPath', p.avatar_path
        )
        order by gp.seat
      )
      from app_private.game_players gp
      join public.profiles p on p.id = gp.user_id
      where gp.game_id = g.id
    ), '[]'::jsonb),
    'removedPlayers', case when g.host_user_id = p_user_id then coalesce((
      select jsonb_agg(
        jsonb_build_object('userId', b.user_id, 'displayName', p.display_name)
        order by b.created_at
      )
      from app_private.game_bans b
      join public.profiles p on p.id = b.user_id
      where b.game_id = g.id
    ), '[]'::jsonb) else '[]'::jsonb end
  )
  from app_private.games g
  left join app_private.game_invites i on i.game_id = g.id and i.active
  where g.id = p_game_id;
$$;

-- -----------------------------------------------------------------------------
-- A1: lugares sorteados no banco ao iniciar (o lugar 1 começa — Fase 5)
-- -----------------------------------------------------------------------------

alter table app_private.game_players
  drop constraint game_players_game_id_seat_key,
  add constraint game_players_game_id_seat_key
    unique (game_id, seat) deferrable initially immediate;

create function app_private.shuffle_seats(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- A permutação troca lugares entre si; a unicidade é conferida no fim.
  set constraints app_private.game_players_game_id_seat_key deferred;

  update app_private.game_players gp
  set seat = s.new_seat
  from (
    select id, row_number() over (order by gen_random_uuid())::smallint as new_seat
    from app_private.game_players
    where game_id = p_game_id
  ) s
  where gp.id = s.id;

  set constraints app_private.game_players_game_id_seat_key immediate;
end;
$$;

create or replace function app_private.start_game(p_game_id uuid, p_expected_version bigint)
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

  update app_private.games
  set status = 'playing', started_at = now(), round_number = 1
  where id = p_game_id;

  update app_private.game_invites set active = false where game_id = p_game_id;

  -- Uma vez só, aqui dentro da transação travada: reload não muda nada.
  perform app_private.shuffle_seats(p_game_id);
  perform app_private.setup_game_cards(p_game_id);

  -- O motor de turnos (Fase 5) define o primeiro turno (lugar 1) aqui.

  perform app_private.touch_game(p_game_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- B1: GHO-05 aprovada, com informação privada
-- -----------------------------------------------------------------------------
-- Ajuste antes do lançamento (nenhuma partida real usou a 7.1). Depois do
-- lançamento, mudanças de efeito exigem nova set_version.

update app_private.card_definitions
set effect_code = 'ghost_peek_discard',
    effect_params = '{"peek": 2, "discard": 1}',
    rules_text = 'Veja até 2 cartas aleatórias da mão de um vivo (só você vê) e escolha 1 delas para ele descartar.',
    is_provisional = false
where set_version = '7.1' and code = 'GHO-05';

-- -----------------------------------------------------------------------------
-- RPCs públicas novas
-- -----------------------------------------------------------------------------

create function public.rotate_room_code(p_game_id uuid)
returns void language sql security invoker set search_path = ''
as $$ select app_private.rotate_room_code(p_game_id); $$;

create function public.allow_rejoin(p_game_id uuid, p_user_id uuid)
returns void language sql security invoker set search_path = ''
as $$ select app_private.allow_rejoin(p_game_id, p_user_id); $$;

create function public.heartbeat(p_game_id uuid)
returns void language sql security invoker set search_path = ''
as $$ select app_private.heartbeat(p_game_id); $$;

grant execute on function
  public.rotate_room_code(uuid),
  public.allow_rejoin(uuid, uuid),
  public.heartbeat(uuid),
  app_private.rotate_room_code(uuid),
  app_private.allow_rejoin(uuid, uuid),
  app_private.heartbeat(uuid)
to authenticated;
