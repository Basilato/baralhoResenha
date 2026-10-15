-- =============================================================================
-- Fase 5: motor de turnos (sem efeitos de cartas)
-- =============================================================================
-- Toda jogada entra por submit_game_command: valida quem joga, a versão e a
-- fase, aplica na mesma transação (com a sala travada), grava evento público e
-- avisa o canal. O mesmo request_id nunca é aplicado duas vezes.
--
-- Fases de uma partida em andamento:
--   turn_main  — jogador vivo da vez: até 2 ações, depois encerra o turno
--   turn_ghost — fantasma da vez (cartas do Além e ressurreição: Fase 8)
-- As fases de reação/escolha entram na Fase 6.

alter table app_private.games
  add column active_seat smallint check (active_seat between 1 and 8),
  add column actions_used smallint not null default 0 check (actions_used between 0 and 2),
  add column leader_player_id uuid references app_private.game_players (id),
  add column event_seq integer not null default 0,
  add column result_json jsonb,
  add constraint games_phase_check
    check (phase is null or phase in ('turn_main', 'turn_ghost'));

-- -----------------------------------------------------------------------------
-- Eventos públicos (histórico) e recibos de comandos (idempotência)
-- -----------------------------------------------------------------------------
-- public_payload nunca traz cartas ocultas: compras aparecem só como contagem;
-- descartes são públicos (a pilha é aberta).

create table app_private.game_events (
  id bigint generated always as identity primary key,
  game_id uuid not null references app_private.games (id) on delete cascade,
  seq integer not null,
  kind text not null check (kind ~ '^[a-z_]+$'),
  actor_player_id uuid references app_private.game_players (id),
  public_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (game_id, seq)
);

create table app_private.command_receipts (
  game_id uuid not null references app_private.games (id) on delete cascade,
  player_id uuid not null references app_private.game_players (id),
  request_id uuid not null,
  command_type text not null,
  result_json jsonb not null,
  created_at timestamptz not null default now(),
  primary key (game_id, player_id, request_id)
);

alter table app_private.game_events enable row level security;
alter table app_private.command_receipts enable row level security;
revoke all on table app_private.game_events from public, anon, authenticated;
revoke all on table app_private.command_receipts from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Constantes de regra (Resenha Simples 7.1)
-- -----------------------------------------------------------------------------

create function app_private.max_actions() returns smallint
language sql immutable set search_path = '' as $$ select 2::smallint $$;

create function app_private.max_rounds() returns smallint
language sql immutable set search_path = '' as $$ select 10::smallint $$;

create function app_private.hand_limit() returns smallint
language sql immutable set search_path = '' as $$ select 7::smallint $$;

create function app_private.ghost_hand_limit() returns smallint
language sql immutable set search_path = '' as $$ select 3::smallint $$;

-- -----------------------------------------------------------------------------
-- Auxiliares
-- -----------------------------------------------------------------------------

create function app_private.log_event(
  p_game_id uuid,
  p_kind text,
  p_actor uuid,
  p_payload jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_seq integer;
begin
  update app_private.games
  set event_seq = event_seq + 1
  where id = p_game_id
  returning event_seq into v_seq;

  insert into app_private.game_events (game_id, seq, kind, actor_player_id, public_payload)
  values (p_game_id, v_seq, p_kind, p_actor, coalesce(p_payload, '{}'::jsonb));
end;
$$;

-- Converte um array JSON em uuid[]; entrada malformada é comando inválido.
create function app_private.jsonb_uuid_array(p_value jsonb)
returns uuid[]
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_value is null or p_value = 'null'::jsonb then
    return array[]::uuid[];
  end if;
  if jsonb_typeof(p_value) <> 'array' or jsonb_array_length(p_value) > 20 then
    perform app_private.fail('INVALID_COMMAND', 'Jogada inválida.');
  end if;
  return array(select x::uuid from jsonb_array_elements_text(p_value) as x);
exception
  when invalid_text_representation then
    perform app_private.fail('INVALID_COMMAND', 'Jogada inválida.');
    return null;
end;
$$;

-- Descarta exatamente o excedente do limite da mão (principal ou do Além).
create function app_private.discard_excess(
  p_game_id uuid,
  p_player_id uuid,
  p_card_ids uuid[],
  p_deck_type text,
  p_limit integer
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hand text := app_private.pile_zone(p_deck_type, 'hand');
  v_excess integer;
begin
  select greatest(count(*) - p_limit, 0) into v_excess
  from app_private.game_cards
  where owner_player_id = p_player_id and zone = v_hand;

  if coalesce(cardinality(p_card_ids), 0) <> v_excess then
    perform app_private.fail(
      'WRONG_DISCARD_COUNT',
      case v_excess
        when 0 then 'Você não precisa descartar.'
        when 1 then 'Você precisa descartar mais 1 carta.'
        else format('Você precisa descartar %s cartas.', v_excess)
      end
    );
  end if;

  if exists (
    select 1 from unnest(coalesce(p_card_ids, array[]::uuid[])) as x (id)
    where not exists (
      select 1 from app_private.game_cards c
      where c.id = x.id and c.owner_player_id = p_player_id and c.zone = v_hand
    )
  ) then
    perform app_private.fail('CARD_NOT_IN_HAND', 'Essa carta não está na sua mão.');
  end if;

  return app_private.discard_cards(p_game_id, p_player_id, p_card_ids);
end;
$$;

create or replace function app_private.discard_to_hand_limit(
  p_game_id uuid,
  p_player_id uuid,
  p_card_ids uuid[],
  p_limit integer default 7
)
returns integer
language sql
security definer
set search_path = ''
as $$
  select app_private.discard_excess(p_game_id, p_player_id, p_card_ids, 'main', p_limit);
$$;

-- Mais Odiado: vivo com o maior PV no início da rodada; empate = ninguém.
create function app_private.compute_leader(p_game_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  with alive as (
    select id, hp from app_private.game_players
    where game_id = p_game_id and life_status = 'alive'
  )
  select id from alive
  where hp = (select max(hp) from alive)
    and (select count(*) from alive where hp = (select max(hp) from alive)) = 1;
$$;

-- Consome uma das 2 ações do turno (usado pelas jogadas de carta, Fase 6).
create function app_private.consume_action(p_game_id uuid, p_player_id uuid)
returns smallint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_game app_private.games;
begin
  select * into v_game from app_private.games where id = p_game_id;

  if v_game.phase is distinct from 'turn_main' or v_game.active_seat is distinct from (
    select seat from app_private.game_players where id = p_player_id
  ) then
    perform app_private.fail('NOT_YOUR_TURN', 'Agora não é a sua vez.');
  end if;

  if v_game.actions_used >= app_private.max_actions() then
    perform app_private.fail('NO_ACTIONS_LEFT', 'Você já usou as 2 ações deste turno. Encerre o turno.');
  end if;

  update app_private.games
  set actions_used = actions_used + 1
  where id = p_game_id;

  return v_game.actions_used + 1;
end;
$$;

-- -----------------------------------------------------------------------------
-- Ciclo de turnos e rodadas
-- -----------------------------------------------------------------------------

-- Início do turno do lugar ativo: vivo compra 2; fantasma recebe a ficha (se
-- ainda não ressuscitou) e compra 1 do Além.
create function app_private.start_turn(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_game app_private.games;
  v_player app_private.game_players;
  v_drawn integer;
begin
  select * into v_game from app_private.games where id = p_game_id;
  select * into v_player from app_private.game_players
  where game_id = p_game_id and seat = v_game.active_seat;

  if v_player.life_status = 'alive' then
    v_drawn := app_private.draw_cards(p_game_id, v_player.id, 'main', 2);
    update app_private.games set phase = 'turn_main', actions_used = 0 where id = p_game_id;
  else
    if not v_player.revival_used then
      update app_private.game_players
      set ghost_tokens = least(ghost_tokens + 1, 3)
      where id = v_player.id;
    end if;
    v_drawn := app_private.draw_cards(p_game_id, v_player.id, 'ghost', 1);
    update app_private.games set phase = 'turn_ghost', actions_used = 0 where id = p_game_id;
  end if;

  perform app_private.log_event(
    p_game_id, 'turn_started', v_player.id,
    jsonb_build_object(
      'round', v_game.round_number,
      'seat', v_player.seat,
      'ghost', v_player.life_status = 'ghost',
      'drew', v_drawn
    )
  );
end;
$$;

-- Fim da partida pela regra das 10 rodadas: mais PV entre os vivos; empate
-- por eliminações; persistindo, vitória compartilhada. (Vitória antecipada,
-- Ressaca e "todos mortos" entram na Fase 8.)
create function app_private.finish_by_round_limit(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_winners uuid[];
  v_criteria text;
  v_top_hp smallint;
  v_top_ko smallint;
begin
  select max(hp) into v_top_hp
  from app_private.game_players
  where game_id = p_game_id and life_status = 'alive';

  select array_agg(id order by seat) into v_winners
  from app_private.game_players
  where game_id = p_game_id and life_status = 'alive' and hp = v_top_hp;

  v_criteria := 'hp';

  if cardinality(v_winners) > 1 then
    select max(knockouts) into v_top_ko
    from app_private.game_players where id = any (v_winners);

    select array_agg(id order by seat) into v_winners
    from app_private.game_players
    where id = any (v_winners) and knockouts = v_top_ko;

    v_criteria := case when cardinality(v_winners) > 1 then 'shared' else 'knockouts' end;
  end if;

  update app_private.games
  set status = 'finished',
      phase = null,
      active_seat = null,
      finished_at = now(),
      result_json = jsonb_build_object(
        'reason', 'round_limit',
        'criteria', v_criteria,
        'winnerPlayerIds', to_jsonb(coalesce(v_winners, array[]::uuid[]))
      )
  where id = p_game_id;

  perform app_private.log_event(
    p_game_id, 'game_finished', null,
    (select result_json from app_private.games where id = p_game_id)
  );
end;
$$;

create function app_private.end_round(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_game app_private.games;
  v_leader uuid;
begin
  select * into v_game from app_private.games where id = p_game_id;

  -- Ressaca Progressiva entra na Fase 8, aqui.

  if v_game.round_number >= app_private.max_rounds() then
    perform app_private.finish_by_round_limit(p_game_id);
    return;
  end if;

  v_leader := app_private.compute_leader(p_game_id);

  update app_private.games
  set round_number = round_number + 1,
      leader_player_id = v_leader,
      active_seat = (
        select min(seat) from app_private.game_players where game_id = p_game_id
      )
  where id = p_game_id;

  perform app_private.log_event(
    p_game_id, 'round_started', null,
    jsonb_build_object('round', v_game.round_number + 1, 'leaderPlayerId', v_leader)
  );

  perform app_private.start_turn(p_game_id);
end;
$$;

-- Passa para o próximo lugar (vivos e fantasmas; ninguém é pulado). Depois do
-- último lugar, fecha a rodada.
create function app_private.advance_turn(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_next smallint;
begin
  select min(gp.seat) into v_next
  from app_private.game_players gp
  join app_private.games g on g.id = gp.game_id
  where gp.game_id = p_game_id and gp.seat > g.active_seat;

  if v_next is null then
    perform app_private.end_round(p_game_id);
  else
    update app_private.games set active_seat = v_next where id = p_game_id;
    perform app_private.start_turn(p_game_id);
  end if;
end;
$$;

-- Prepara a rodada 1 (chamado por start_game depois do sorteio e das cartas).
create function app_private.begin_first_round(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_leader uuid := app_private.compute_leader(p_game_id);
begin
  update app_private.games
  set round_number = 1, active_seat = 1, leader_player_id = v_leader
  where id = p_game_id;

  perform app_private.log_event(p_game_id, 'game_started', null,
    jsonb_build_object('players', (select count(*) from app_private.game_players where game_id = p_game_id)));
  perform app_private.log_event(p_game_id, 'round_started', null,
    jsonb_build_object('round', 1, 'leaderPlayerId', v_leader));

  -- A2/A3: o lugar 1 começa e também compra 2.
  perform app_private.start_turn(p_game_id);
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
  perform app_private.begin_first_round(p_game_id);

  perform app_private.touch_game(p_game_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- Comandos
-- -----------------------------------------------------------------------------

create function app_private.cmd_end_turn(
  p_game app_private.games,
  p_player app_private.game_players,
  p_command jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_discard uuid[] := app_private.jsonb_uuid_array(p_command -> 'discardCardIds');
  v_codes jsonb;
begin
  if p_game.phase not in ('turn_main', 'turn_ghost') then
    perform app_private.fail('WRONG_PHASE', 'Ainda há uma jogada esperando resposta.');
  end if;

  -- Descartes são públicos: guarda os códigos para o histórico.
  select coalesce(jsonb_agg(c.card_code order by x.ord), '[]'::jsonb) into v_codes
  from unnest(v_discard) with ordinality as x (id, ord)
  join app_private.game_cards c on c.id = x.id and c.owner_player_id = p_player.id;

  if p_player.life_status = 'alive' then
    perform app_private.discard_excess(p_game.id, p_player.id, v_discard, 'main', app_private.hand_limit());
  else
    perform app_private.discard_excess(p_game.id, p_player.id, v_discard, 'ghost', app_private.ghost_hand_limit());
  end if;

  perform app_private.log_event(
    p_game.id, 'turn_ended', p_player.id,
    jsonb_build_object('discarded', v_codes, 'actionsUsed', p_game.actions_used)
  );

  perform app_private.advance_turn(p_game.id);

  return jsonb_build_object('ok', true);
end;
$$;

create function app_private.submit_game_command(
  p_game_id uuid,
  p_expected_version bigint,
  p_request_id uuid,
  p_command jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_user();
  v_game app_private.games := app_private.lock_member_game(p_game_id, v_uid);
  v_player app_private.game_players;
  v_type text := p_command ->> 'type';
  v_receipt jsonb;
  v_result jsonb;
begin
  if p_request_id is null or v_type is null then
    perform app_private.fail('INVALID_COMMAND', 'Jogada inválida.');
  end if;

  select * into v_player from app_private.game_players
  where game_id = p_game_id and user_id = v_uid;

  -- Repetição do mesmo pedido (clique duplo, retry de rede): devolve o mesmo
  -- resultado sem aplicar de novo.
  select result_json into v_receipt
  from app_private.command_receipts
  where game_id = p_game_id and player_id = v_player.id and request_id = p_request_id;

  if found then
    return v_receipt || jsonb_build_object('replayed', true);
  end if;

  if v_game.status <> 'playing' then
    perform app_private.fail('GAME_NOT_ACTIVE', 'Esta partida não está em andamento.');
  end if;

  if v_game.version <> p_expected_version then
    perform app_private.fail('VERSION_CONFLICT', 'A mesa mudou enquanto você jogava. Confira e tente de novo.');
  end if;

  if v_player.seat is distinct from v_game.active_seat then
    perform app_private.fail('NOT_YOUR_TURN', 'Agora não é a sua vez.');
  end if;

  case v_type
    when 'END_TURN' then
      v_result := app_private.cmd_end_turn(v_game, v_player, p_command);
    else
      perform app_private.fail('INVALID_COMMAND', 'Jogada inválida.');
  end case;

  v_result := v_result || jsonb_build_object('version', app_private.touch_game(p_game_id));

  insert into app_private.command_receipts (game_id, player_id, request_id, command_type, result_json)
  values (p_game_id, v_player.id, p_request_id, v_type, v_result);

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- Visão da mesa com estado do turno, resultado e histórico
-- -----------------------------------------------------------------------------

create or replace function app_private.game_view(p_game_id uuid, p_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with me as (
    select id from app_private.game_players where game_id = p_game_id and user_id = p_user_id
  ),
  pile as (
    select zone, count(*) as total, max(pile_position) as top_position
    from app_private.game_cards
    where game_id = p_game_id and owner_player_id is null
    group by zone
  )
  select jsonb_build_object(
    'gameId', g.id,
    'version', g.version,
    'status', g.status,
    'phase', g.phase,
    'round', g.round_number,
    'maxRounds', app_private.max_rounds(),
    'cardSetVersion', g.card_set_version,
    'hostUserId', g.host_user_id,
    'activePlayerId', (
      select gp.id from app_private.game_players gp
      where gp.game_id = g.id and gp.seat = g.active_seat
    ),
    'actionsUsed', g.actions_used,
    'maxActions', app_private.max_actions(),
    'handLimit', app_private.hand_limit(),
    'ghostHandLimit', app_private.ghost_hand_limit(),
    'leaderPlayerId', g.leader_player_id,
    'result', g.result_json,
    'myPlayerId', (select id from me),
    'participants', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', gp.id,
          'userId', gp.user_id,
          'displayName', p.display_name,
          'avatarPath', p.avatar_path,
          'seat', gp.seat,
          'isHost', gp.user_id = g.host_user_id,
          'hp', gp.hp,
          'maxHp', gp.max_hp,
          'alive', gp.life_status = 'alive',
          'cardsInHand', (
            select count(*) from app_private.game_cards c
            where c.owner_player_id = gp.id and c.zone = 'player_hand'
          ),
          'ghostCardsInHand', (
            select count(*) from app_private.game_cards c
            where c.owner_player_id = gp.id and c.zone = 'ghost_hand'
          ),
          'ghostTokens', gp.ghost_tokens,
          'revivalUsed', gp.revival_used,
          'knockouts', gp.knockouts
        )
        order by gp.seat
      )
      from app_private.game_players gp
      join public.profiles p on p.id = gp.user_id
      where gp.game_id = g.id
    ), '[]'::jsonb),
    'myHand', coalesce((
      select jsonb_agg(jsonb_build_object('instanceId', c.id, 'code', c.card_code)
                       order by c.pile_position)
      from app_private.game_cards c
      where c.owner_player_id = (select id from me) and c.zone = 'player_hand'
    ), '[]'::jsonb),
    'myGhostHand', coalesce((
      select jsonb_agg(jsonb_build_object('instanceId', c.id, 'code', c.card_code)
                       order by c.pile_position)
      from app_private.game_cards c
      where c.owner_player_id = (select id from me) and c.zone = 'ghost_hand'
    ), '[]'::jsonb),
    'mainDeckCount', coalesce((select total from pile where zone = 'main_deck'), 0),
    'ghostDeckCount', coalesce((select total from pile where zone = 'ghost_deck'), 0),
    'mainDiscardCount', coalesce((select total from pile where zone = 'main_discard'), 0),
    'ghostDiscardCount', coalesce((select total from pile where zone = 'ghost_discard'), 0),
    'mainDiscardTop', (
      select c.card_code from app_private.game_cards c
      where c.game_id = g.id and c.zone = 'main_discard'
        and c.pile_position = (select top_position from pile where zone = 'main_discard')
    ),
    'ghostDiscardTop', (
      select c.card_code from app_private.game_cards c
      where c.game_id = g.id and c.zone = 'ghost_discard'
        and c.pile_position = (select top_position from pile where zone = 'ghost_discard')
    ),
    -- Últimos 50 eventos, do mais antigo para o mais novo.
    'events', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'seq', e.seq,
          'kind', e.kind,
          'actorPlayerId', e.actor_player_id,
          'payload', e.public_payload,
          'at', e.created_at
        )
        order by e.seq
      )
      from (
        select * from app_private.game_events
        where game_id = g.id
        order by seq desc
        limit 50
      ) e
    ), '[]'::jsonb)
  )
  from app_private.games g
  where g.id = p_game_id;
$$;

-- -----------------------------------------------------------------------------
-- RPC pública
-- -----------------------------------------------------------------------------

create function public.submit_game_command(
  p_game_id uuid,
  p_expected_version bigint,
  p_request_id uuid,
  p_command jsonb
)
returns jsonb language sql security invoker set search_path = ''
as $$ select app_private.submit_game_command(p_game_id, p_expected_version, p_request_id, p_command); $$;

grant execute on function
  public.submit_game_command(uuid, bigint, uuid, jsonb),
  app_private.submit_game_command(uuid, bigint, uuid, jsonb)
to authenticated;
