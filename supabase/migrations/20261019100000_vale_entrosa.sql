-- =============================================================================
-- SAB-06 · Vale Entrosa: sabotagem que rouba a próxima vez de um adversário
-- =============================================================================
-- Regra:
--   · Jogada no próprio turno (gasta 1 ação), mira 1 adversário vivo. É
--     sabotagem direcionada: Evento Raro cancela.
--   · Resolvida, o alvo fica "entrosado" (público, como a marca do SAB-03).
--   · Quando chegar a vez do alvo, quem joga é o autor: compra 2, tem 2 ações,
--     prazo e limite de mão normais. O alvo pula a vez (não compra nada).
--     Depois, a vez segue a ordem a partir do lugar do alvo.
--   · O vale só vale para a próxima vez do alvo. Caduca se, nessa hora, o
--     autor ou o alvo não estiver vivo (fantasma não tem a vez roubada).
--   · Não acumula: um vale novo no mesmo alvo substitui o anterior.
--
-- Implementação: o efeito fica em status_effects (tipo turn_steal). O
-- start_turn troca o lugar da vez pelo do autor e guarda em games.resume_seat
-- o lugar roubado; o advance_turn continua a partir dele.

-- -----------------------------------------------------------------------------
-- Catálogo
-- -----------------------------------------------------------------------------

insert into app_private.card_definitions
  (set_version, code, category, deck_type, name, character_name, copies,
   effect_code, effect_params, target_rule, is_reaction, rules_text, is_provisional)
values
  ('7.1', 'SAB-06', 'sabotage', 'main', 'Vale Entrosa', 'Todo Mundo', 3,
   'steal_turn', '{}', 'opponent', false,
   'Roube a próxima vez de um adversário: no turno dele, quem joga é você (compra 2 e tem 2 ações). Ele pula a vez.',
   false);

-- Partidas em andamento recebem as cópias novas no fundo do baralho, para a
-- conferência de integridade continuar batendo com o catálogo.
insert into app_private.game_cards (game_id, set_version, card_code, deck_type, zone, pile_position)
select g.id, '7.1', 'SAB-06', 'main', 'main_deck',
       coalesce((select min(c.pile_position) from app_private.game_cards c
                 where c.game_id = g.id and c.zone = 'main_deck'), 1) - n
from app_private.games g
cross join generate_series(1, 3) as n
where g.started_at is not null and g.card_set_version = '7.1'
  and not exists (
    select 1 from app_private.game_cards c where c.game_id = g.id and c.card_code = 'SAB-06'
  );

-- -----------------------------------------------------------------------------
-- Estrutura
-- -----------------------------------------------------------------------------

-- Lugar cuja vez está sendo jogada por outra pessoa (null = vez normal).
alter table app_private.games add column resume_seat smallint;

alter table app_private.status_effects
  drop constraint status_effects_type_check,
  add constraint status_effects_type_check check (type in ('mark', 'curse', 'turn_steal')),
  drop constraint status_effects_bonus_check,
  add constraint status_effects_bonus_check check (bonus > 0 or type = 'turn_steal');

-- Um vale por alvo (o novo substitui).
create unique index status_effects_one_turn_steal
  on app_private.status_effects (game_id, target_player_id) where type = 'turn_steal';

-- -----------------------------------------------------------------------------
-- Resolução da sabotagem (mesmo corpo, com o caso steal_turn)
-- -----------------------------------------------------------------------------

create or replace function app_private.resolve_sabotage(p_pending app_private.pending_actions)
returns boolean -- true = terminou; false = abriu escolha
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target uuid := p_pending.target_player_id;
  v_card uuid;
  v_count integer;
  v_round smallint;
begin
  if exists (
    select 1 from app_private.pending_responses
    where pending_action_id = p_pending.id and reaction_effect = 'block_sabotage'
  ) then
    perform app_private.log_event(p_pending.game_id, 'sabotage_blocked', v_target,
      jsonb_build_object('cardCode', p_pending.card_code));
    return true;
  end if;

  case p_pending.effect_code
    when 'steal_random' then
      -- Sorteio só depois da defesa (5.4).
      select id into v_card from app_private.game_cards
      where owner_player_id = v_target and zone = 'player_hand'
      order by gen_random_uuid() limit 1;
      if v_card is not null then
        perform app_private.give_cards(array[v_card], p_pending.actor_player_id);
      end if;
      perform app_private.log_event(p_pending.game_id, 'card_stolen', p_pending.actor_player_id,
        jsonb_build_object('fromPlayerId', v_target, 'count', case when v_card is null then 0 else 1 end));
      return true;

    when 'mark_target' then
      v_round := (select round_number from app_private.games where id = p_pending.game_id);
      -- Marcas não acumulam: a nova substitui e renova.
      delete from app_private.status_effects
      where game_id = p_pending.game_id and target_player_id = v_target and type = 'mark';
      insert into app_private.status_effects
        (game_id, target_player_id, type, bonus, source_player_id, applied_round, expires_after_round)
      values (p_pending.game_id, v_target, 'mark',
              coalesce((p_pending.effect_params ->> 'bonus')::int, 2),
              p_pending.actor_player_id, v_round, v_round + 1);
      perform app_private.log_event(p_pending.game_id, 'target_marked', p_pending.actor_player_id,
        jsonb_build_object('targetPlayerId', v_target, 'untilRound', v_round + 1));
      return true;

    -- Vale Entrosa: a próxima vez do alvo é do autor. A próxima vez sempre
    -- cai nesta rodada ou na seguinte; o prazo é só uma rede de segurança.
    when 'steal_turn' then
      v_round := (select round_number from app_private.games where id = p_pending.game_id);
      delete from app_private.status_effects
      where game_id = p_pending.game_id and target_player_id = v_target and type = 'turn_steal';
      insert into app_private.status_effects
        (game_id, target_player_id, type, bonus, source_player_id, applied_round, expires_after_round)
      values (p_pending.game_id, v_target, 'turn_steal', 0,
              p_pending.actor_player_id, v_round, v_round + 1);
      perform app_private.log_event(p_pending.game_id, 'turn_steal_set', p_pending.actor_player_id,
        jsonb_build_object('targetPlayerId', v_target));
      return true;

    when 'swap_card' then
      -- Troca simultânea: carta escolhida do autor x carta sorteada do alvo.
      select id into v_card from app_private.game_cards
      where owner_player_id = v_target and zone = 'player_hand'
      order by gen_random_uuid() limit 1;
      if v_card is not null and exists (
        select 1 from app_private.game_cards
        where id = p_pending.own_card_id and owner_player_id = p_pending.actor_player_id and zone = 'player_hand'
      ) then
        perform app_private.lift_cards(p_pending.game_id, array[v_card, p_pending.own_card_id]);
        perform app_private.give_cards(array[v_card], p_pending.actor_player_id);
        perform app_private.give_cards(array[p_pending.own_card_id], v_target);
      end if;
      perform app_private.log_event(p_pending.game_id, 'card_swapped', p_pending.actor_player_id,
        jsonb_build_object('targetPlayerId', v_target));
      return true;

    when 'inspect_discard' then
      if app_private.hand_size(v_target) = 0 then
        return true;
      end if;
      insert into app_private.pending_responses
        (pending_action_id, responder_player_id, role, stage, base_damage, choice_count, source_player_id)
      values (p_pending.id, p_pending.actor_player_id, 'actor_pick', 'choice', 0, 1, v_target);
      update app_private.pending_actions set stage = 'choice' where id = p_pending.id;
      return false;

    when 'force_discard' then
      v_count := least(coalesce((p_pending.effect_params ->> 'count')::int, 2), app_private.hand_size(v_target));
      if v_count = 0 then
        return true;
      end if;
      insert into app_private.pending_responses
        (pending_action_id, responder_player_id, role, stage, base_damage, choice_count, source_player_id)
      values (p_pending.id, v_target, 'target_discard', 'choice', 0, v_count, v_target);
      update app_private.pending_actions set stage = 'choice' where id = p_pending.id;
      return false;

    else
      return true;
  end case;
end;
$$;

-- -----------------------------------------------------------------------------
-- Ciclo de turnos
-- -----------------------------------------------------------------------------

-- Próximo lugar, pulando desistentes. Depois de uma vez roubada, segue a
-- partir do lugar roubado (não do lugar de quem roubou).
create or replace function app_private.advance_turn(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_game app_private.games;
  v_next smallint;
begin
  select * into v_game from app_private.games where id = p_game_id;
  if v_game.status <> 'playing' then
    return;
  end if;

  if v_game.resume_seat is not null then
    update app_private.games set resume_seat = null where id = p_game_id;
  end if;

  select min(seat) into v_next
  from app_private.game_players
  where game_id = p_game_id
    and seat > coalesce(v_game.resume_seat, v_game.active_seat)
    and life_status <> 'quit';

  if v_next is null then
    perform app_private.end_round(p_game_id);
  else
    update app_private.games set active_seat = v_next where id = p_game_id;
    perform app_private.start_turn(p_game_id);
  end if;
end;
$$;

-- Início do turno (mesmo corpo, com o Vale Entrosa na frente): se o dono do
-- lugar tem a vez roubada, quem joga é o autor do vale.
create or replace function app_private.start_turn(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_game app_private.games;
  v_player app_private.game_players;
  v_drawn integer := 0;
  v_steal app_private.status_effects;
  v_thief app_private.game_players;
begin
  select * into v_game from app_private.games where id = p_game_id;
  select * into v_player from app_private.game_players
  where game_id = p_game_id and seat = v_game.active_seat;

  -- Vale Entrosa: consumido na próxima vez do alvo, valendo ou não.
  delete from app_private.status_effects
  where game_id = p_game_id and target_player_id = v_player.id and type = 'turn_steal'
  returning * into v_steal;

  if found then
    select * into v_thief from app_private.game_players where id = v_steal.source_player_id;

    if v_player.life_status = 'alive' and v_thief.life_status = 'alive' then
      update app_private.games
      set active_seat = v_thief.seat, resume_seat = v_player.seat
      where id = p_game_id;
      perform app_private.log_event(p_game_id, 'turn_stolen', v_thief.id,
        jsonb_build_object('fromPlayerId', v_player.id, 'round', v_game.round_number));
      v_player := v_thief;
    else
      perform app_private.log_event(p_game_id, 'turn_steal_lapsed', v_thief.id,
        jsonb_build_object('targetPlayerId', v_player.id,
          'reason', case when v_thief.life_status <> 'alive' then 'thief_down' else 'target_down' end));
    end if;
  end if;

  if v_player.life_status = 'alive' then
    v_drawn := app_private.draw_cards(p_game_id, v_player.id, 'main', 2);
    update app_private.games set phase = 'turn_main', actions_used = 0 where id = p_game_id;
  else
    if not v_player.revival_used then
      update app_private.game_players
      set ghost_tokens = least(ghost_tokens + 1, 3)
      where id = v_player.id
      returning * into v_player;
    end if;

    if not v_player.revival_used and v_player.ghost_tokens >= 3 then
      update app_private.games set phase = 'ghost_decision', actions_used = 0 where id = p_game_id;
    else
      v_drawn := app_private.draw_cards(p_game_id, v_player.id, 'ghost', 1);
      update app_private.games set phase = 'turn_ghost', actions_used = 0 where id = p_game_id;
    end if;
  end if;

  perform app_private.log_event(
    p_game_id, 'turn_started', v_player.id,
    jsonb_build_object(
      'round', v_game.round_number,
      'seat', v_player.seat,
      'ghost', v_player.life_status = 'ghost',
      'drew', v_drawn,
      'tokens', v_player.ghost_tokens,
      'canRevive', v_player.life_status = 'ghost' and not v_player.revival_used and v_player.ghost_tokens >= 3
    )
  );
end;
$$;

-- Turnos que um fantasma ainda tem (mesmo corpo): numa vez roubada, a ordem
-- da rodada é a do lugar roubado.
create or replace function app_private.can_still_revive(p_game_id uuid, p_player_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select gp.life_status = 'ghost' and not gp.revival_used and (
    -- Está decidindo agora, com 3 fichas.
    (g.phase = 'ghost_decision' and g.active_seat = gp.seat)
    or (
      -- Turnos futuros: o desta rodada (se ainda não jogou) + as próximas.
      (app_private.max_rounds() - g.round_number
        + case when gp.seat > coalesce(g.resume_seat, g.active_seat) then 1 else 0 end) >= 1
      and gp.ghost_tokens
          + (app_private.max_rounds() - g.round_number
             + case when gp.seat > coalesce(g.resume_seat, g.active_seat) then 1 else 0 end) >= 3
    )
  )
  from app_private.game_players gp
  join app_private.games g on g.id = gp.game_id
  where gp.id = p_player_id;
$$;

-- -----------------------------------------------------------------------------
-- Visão: vales em aberto e vez roubada (tudo público: a carta foi jogada aberta)
-- -----------------------------------------------------------------------------

create function app_private.steal_view(p_game_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'turnSteals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'targetPlayerId', s.target_player_id, 'thiefPlayerId', s.source_player_id
      ) order by s.created_at)
      from app_private.status_effects s
      where s.game_id = p_game_id and s.type = 'turn_steal'
    ), '[]'::jsonb),
    -- Dono do lugar cuja vez está sendo jogada agora por quem roubou.
    'stolenFromPlayerId', (
      select gp.id from app_private.games g
      join app_private.game_players gp on gp.game_id = g.id and gp.seat = g.resume_seat
      where g.id = p_game_id and g.status = 'playing'
    )
  );
$$;

create or replace function app_private.get_game_view(p_game_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_user();
  v_player uuid;
begin
  select id into v_player from app_private.game_players
  where game_id = p_game_id and user_id = v_uid;

  if v_player is null then
    perform app_private.fail('ROOM_NOT_FOUND', 'Sala não encontrada ou você não faz parte dela.');
  end if;

  return app_private.game_view(p_game_id, v_uid)
    || app_private.pending_view(p_game_id, v_player)
    || app_private.extras_view(p_game_id, v_player)
    || app_private.timers_view(p_game_id)
    || app_private.steal_view(p_game_id);
end;
$$;

revoke execute on function
  app_private.resolve_sabotage(app_private.pending_actions),
  app_private.advance_turn(uuid),
  app_private.start_turn(uuid),
  app_private.can_still_revive(uuid, uuid),
  app_private.steal_view(uuid)
from public, anon, authenticated;
