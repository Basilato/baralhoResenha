-- =============================================================================
-- Fase 8: fantasmas, cartas do Além, Ressaca, fim de partida, ausência e
-- revanche
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Estrutura
-- -----------------------------------------------------------------------------

alter table app_private.games
  drop constraint games_phase_check,
  add constraint games_phase_check check (phase is null or phase in (
    'turn_main', 'turn_ghost', 'ghost_decision', 'awaiting_reactions'
  )),
  add column rematch_game_id uuid references app_private.games (id);

-- quit = desistente (removido por ausência, E2): fora dos turnos e da vitória.
alter table app_private.game_players
  drop constraint game_players_life_status_check,
  add constraint game_players_life_status_check
    check (life_status in ('alive', 'ghost', 'quit')),
  -- Para o desempate de "todos mortos": lote da morte e PV antes do golpe.
  add column died_batch integer,
  add column hp_before_damage smallint;

-- PV imediatamente antes de qualquer dano (desempate do lote fatal).
create function app_private.track_hp_before_damage()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.hp < old.hp then
    new.hp_before_damage := old.hp;
  end if;
  return new;
end;
$$;

revoke execute on function app_private.track_hp_before_damage() from public, anon, authenticated;

create trigger game_players_track_hp
  before update of hp on app_private.game_players
  for each row execute function app_private.track_hp_before_damage();

-- Maldição da Ressaca: uma por partida (não acumula).
create unique index status_effects_one_curse
  on app_private.status_effects (game_id) where type = 'curse';

-- GHO-05: o fantasma escolhe só entre as cartas reveladas a ele.
alter table app_private.pending_responses
  add column option_card_ids uuid[];

-- Revelações privadas (GHO-02): só o destinatário vê.
create table app_private.private_events (
  id bigint generated always as identity primary key,
  game_id uuid not null references app_private.games (id) on delete cascade,
  recipient_player_id uuid not null references app_private.game_players (id),
  kind text not null check (kind ~ '^[a-z_]+$'),
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table app_private.private_events enable row level security;
revoke all on table app_private.private_events from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Morte: registra o lote (para o desempate de "todos mortos")
-- -----------------------------------------------------------------------------
-- O lote é o último evento de dano registrado antes das mortes: quem cai no
-- mesmo golpe/Ressaca compartilha o lote.

create or replace function app_private.kill_player(p_game_id uuid, p_victim uuid, p_credited uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hand uuid[];
  v_batch integer;
begin
  select max(seq) into v_batch
  from app_private.game_events
  where game_id = p_game_id and kind in ('damage_dealt', 'last_word', 'self_damage', 'hangover');

  update app_private.game_players
  set life_status = 'ghost', hp = 0, died_batch = v_batch
  where id = p_victim;

  select coalesce(array_agg(id order by pile_position), array[]::uuid[]) into v_hand
  from app_private.game_cards
  where owner_player_id = p_victim and zone = 'player_hand';

  perform app_private.discard_cards(p_game_id, p_victim, v_hand);

  if p_credited is not null and p_credited <> p_victim then
    update app_private.game_players set knockouts = knockouts + 1 where id = p_credited;
  end if;

  perform app_private.log_event(
    p_game_id, 'player_died', p_victim,
    jsonb_build_object('byPlayerId', p_credited, 'discarded', cardinality(v_hand))
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- Fim de partida
-- -----------------------------------------------------------------------------

create function app_private.finish_game(
  p_game_id uuid,
  p_reason text,
  p_criteria text,
  p_winners uuid[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update app_private.pending_actions set status = 'resolved', resolved_at = now()
  where game_id = p_game_id and status = 'open';

  update app_private.games
  set status = 'finished',
      phase = null,
      active_seat = null,
      pending_action_id = null,
      finished_at = now(),
      result_json = jsonb_build_object(
        'reason', p_reason,
        'criteria', p_criteria,
        'winnerPlayerIds', to_jsonb(coalesce(p_winners, array[]::uuid[]))
      )
  where id = p_game_id;

  delete from app_private.status_effects where game_id = p_game_id;

  perform app_private.log_event(p_game_id, 'game_finished', null,
    (select result_json from app_private.games where id = p_game_id));
end;
$$;

-- Desempate entre candidatos: mais eliminações; persistindo, compartilhada.
create function app_private.break_tie_by_knockouts(p_candidates uuid[], p_first_criteria text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_top smallint;
  v_winners uuid[];
begin
  if cardinality(p_candidates) <= 1 then
    return jsonb_build_object('criteria', p_first_criteria, 'winners', to_jsonb(p_candidates));
  end if;

  select max(knockouts) into v_top from app_private.game_players where id = any (p_candidates);
  select array_agg(id order by seat) into v_winners
  from app_private.game_players where id = any (p_candidates) and knockouts = v_top;

  return jsonb_build_object(
    'criteria', case when cardinality(v_winners) > 1 then 'shared' else 'knockouts' end,
    'winners', to_jsonb(v_winners)
  );
end;
$$;

-- Todos mortos: vence quem caiu no lote mais tardio; empate no lote, maior PV
-- antes do golpe; depois eliminações; depois compartilhada.
create function app_private.finish_all_dead(p_game_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch integer;
  v_hp smallint;
  v_candidates uuid[];
  v_tie jsonb;
begin
  select max(died_batch) into v_batch
  from app_private.game_players where game_id = p_game_id and life_status = 'ghost';

  select max(hp_before_damage) into v_hp
  from app_private.game_players
  where game_id = p_game_id and life_status = 'ghost' and died_batch is not distinct from v_batch;

  select array_agg(id order by seat) into v_candidates
  from app_private.game_players
  where game_id = p_game_id and life_status = 'ghost'
    and died_batch is not distinct from v_batch
    and hp_before_damage is not distinct from v_hp;

  v_tie := app_private.break_tie_by_knockouts(v_candidates, 'last_standing');
  perform app_private.finish_game(p_game_id, p_reason, v_tie ->> 'criteria',
    array(select jsonb_array_elements_text(v_tie -> 'winners')::uuid));
end;
$$;

-- Fim da rodada 10: mais PV entre os vivos (ou regra de todos mortos).
create or replace function app_private.finish_by_round_limit(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_top smallint;
  v_candidates uuid[];
  v_tie jsonb;
begin
  if not exists (
    select 1 from app_private.game_players where game_id = p_game_id and life_status = 'alive'
  ) then
    perform app_private.finish_all_dead(p_game_id, 'round_limit');
    return;
  end if;

  select max(hp) into v_top
  from app_private.game_players where game_id = p_game_id and life_status = 'alive';

  select array_agg(id order by seat) into v_candidates
  from app_private.game_players
  where game_id = p_game_id and life_status = 'alive' and hp = v_top;

  v_tie := app_private.break_tie_by_knockouts(v_candidates, 'hp');
  perform app_private.finish_game(p_game_id, 'round_limit', v_tie ->> 'criteria',
    array(select jsonb_array_elements_text(v_tie -> 'winners')::uuid));
end;
$$;

-- Um fantasma ainda pode ressuscitar até o fim da rodada 10? Conta fichas e
-- os turnos de fantasma que ainda faltam para ele (5.9).
create function app_private.can_still_revive(p_game_id uuid, p_player_id uuid)
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
      (app_private.max_rounds() - g.round_number + case when gp.seat > g.active_seat then 1 else 0 end) >= 1
      and gp.ghost_tokens
          + (app_private.max_rounds() - g.round_number + case when gp.seat > g.active_seat then 1 else 0 end) >= 3
    )
  )
  from app_private.game_players gp
  join app_private.games g on g.id = gp.game_id
  where gp.id = p_player_id;
$$;

-- Verifica o fim antecipado. Devolve true se a partida acabou.
create function app_private.check_game_end(p_game_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_alive integer;
  v_last uuid;
begin
  if (select status from app_private.games where id = p_game_id) <> 'playing' then
    return true;
  end if;

  select count(*), (array_agg(id))[1] into v_alive, v_last
  from app_private.game_players where game_id = p_game_id and life_status = 'alive';

  if v_alive >= 2 then
    return false;
  end if;

  -- Algum fantasma ainda pode voltar: a partida continua.
  if exists (
    select 1 from app_private.game_players
    where game_id = p_game_id and app_private.can_still_revive(p_game_id, id)
  ) then
    return false;
  end if;

  if v_alive = 1 then
    perform app_private.finish_game(p_game_id, 'last_alive', 'last_alive', array[v_last]);
  else
    perform app_private.finish_all_dead(p_game_id, 'all_dead');
  end if;
  return true;
end;
$$;

-- -----------------------------------------------------------------------------
-- Ressaca Progressiva e ciclo de rodadas
-- -----------------------------------------------------------------------------

create function app_private.hangover_damage(p_round integer)
returns smallint
language sql
immutable
set search_path = ''
as $$
  select (case when p_round between 5 and 6 then 1
               when p_round between 7 and 8 then 2
               when p_round between 9 and 10 then 3
               else 0 end)::smallint;
$$;

-- Dano ambiental simultâneo em todos os vivos: sem reação, sem eliminação
-- atribuída (B.1).
create function app_private.apply_hangover(p_game_id uuid, p_round integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_damage smallint := app_private.hangover_damage(p_round);
  v_results jsonb;
  v_victim uuid;
begin
  if v_damage = 0 then
    return;
  end if;

  update app_private.game_players
  set hp = greatest(hp - v_damage, 0)
  where game_id = p_game_id and life_status = 'alive';

  select coalesce(jsonb_agg(jsonb_build_object('playerId', id, 'hp', hp) order by seat), '[]'::jsonb)
    into v_results
  from app_private.game_players where game_id = p_game_id and life_status = 'alive';

  perform app_private.log_event(p_game_id, 'hangover', null,
    jsonb_build_object('round', p_round, 'damage', v_damage, 'results', v_results));

  for v_victim in
    select id from app_private.game_players
    where game_id = p_game_id and life_status = 'alive' and hp = 0
    order by seat
  loop
    perform app_private.kill_player(p_game_id, v_victim, null);
  end loop;
end;
$$;

create or replace function app_private.end_round(p_game_id uuid)
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

  perform app_private.apply_hangover(p_game_id, v_game.round_number);

  delete from app_private.status_effects
  where game_id = p_game_id and expires_after_round <= v_game.round_number;

  if v_game.round_number >= app_private.max_rounds() then
    perform app_private.finish_by_round_limit(p_game_id);
    return;
  end if;

  if app_private.check_game_end(p_game_id) then
    return;
  end if;

  v_leader := app_private.compute_leader(p_game_id);

  update app_private.games
  set round_number = round_number + 1,
      leader_player_id = v_leader,
      active_seat = (
        select min(seat) from app_private.game_players
        where game_id = p_game_id and life_status <> 'quit'
      )
  where id = p_game_id;

  perform app_private.log_event(
    p_game_id, 'round_started', null,
    jsonb_build_object('round', v_game.round_number + 1, 'leaderPlayerId', v_leader)
  );

  perform app_private.start_turn(p_game_id);
end;
$$;

-- Próximo lugar, pulando desistentes (vivos e fantasmas jogam).
create or replace function app_private.advance_turn(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_next smallint;
begin
  if (select status from app_private.games where id = p_game_id) <> 'playing' then
    return;
  end if;

  select min(gp.seat) into v_next
  from app_private.game_players gp
  join app_private.games g on g.id = gp.game_id
  where gp.game_id = p_game_id and gp.seat > g.active_seat and gp.life_status <> 'quit';

  if v_next is null then
    perform app_private.end_round(p_game_id);
  else
    update app_private.games set active_seat = v_next where id = p_game_id;
    perform app_private.start_turn(p_game_id);
  end if;
end;
$$;

-- Início do turno: vivo compra 2. Fantasma recebe a ficha; com 3 fichas e a
-- ressurreição disponível, decide antes de comprar (ressuscitar encerra o
-- turno sem carta do Além).
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

-- Carta jogada vai para o descarte do próprio baralho (principal ou Além).
create or replace function app_private.finish_pending(p_pending app_private.pending_actions)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor app_private.game_players;
  v_card app_private.game_cards;
  v_next integer;
begin
  select * into v_actor from app_private.game_players where id = p_pending.actor_player_id;
  select * into v_card from app_private.game_cards where id = p_pending.card_instance_id;

  if p_pending.effect_code = 'damage_draw' and v_actor.life_status = 'alive' then
    perform app_private.draw_cards(p_pending.game_id, v_actor.id, 'main',
      coalesce((p_pending.effect_params ->> 'draw')::int, 1));
  end if;

  select coalesce(max(pile_position), 0) + 1 into v_next
  from app_private.game_cards
  where game_id = p_pending.game_id and zone = app_private.pile_zone(v_card.deck_type, 'discard');

  update app_private.game_cards
  set zone = app_private.pile_zone(v_card.deck_type, 'discard'), owner_player_id = null, pile_position = v_next
  where id = v_card.id;

  update app_private.pending_actions
  set status = 'resolved', resolved_at = now()
  where id = p_pending.id;

  -- Carta do Além volta ao turno de fantasma; as outras, ao turno normal.
  update app_private.games
  set pending_action_id = null,
      phase = case when v_card.deck_type = 'ghost' then 'turn_ghost' else 'turn_main' end
  where id = p_pending.game_id;

  -- B5: autor vivo que morreu (ou desistente) perde o resto do turno.
  if v_card.deck_type = 'main' and v_actor.life_status <> 'alive' then
    perform app_private.log_event(p_pending.game_id, 'turn_ended', v_actor.id,
      jsonb_build_object('reason', 'died', 'discarded', '[]'::jsonb));
    perform app_private.advance_turn(p_pending.game_id);
  elsif v_card.deck_type = 'ghost' and v_actor.life_status = 'quit' then
    perform app_private.advance_turn(p_pending.game_id);
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Comandos do fantasma
-- -----------------------------------------------------------------------------

-- Ressuscitar: 6 PV, 3 cartas principais, sem cartas do Além, uma vez só.
create function app_private.cmd_ghost_decision(
  p_game app_private.games,
  p_player app_private.game_players,
  p_revive boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ghost_hand uuid[];
  v_drawn integer;
begin
  if p_game.phase <> 'ghost_decision' then
    perform app_private.fail('WRONG_PHASE', 'Agora não dá para ressuscitar.');
  end if;

  if not p_revive then
    v_drawn := app_private.draw_cards(p_game.id, p_player.id, 'ghost', 1);
    update app_private.games set phase = 'turn_ghost' where id = p_game.id;
    perform app_private.log_event(p_game.id, 'revive_declined', p_player.id,
      jsonb_build_object('drew', v_drawn));
    return jsonb_build_object('ok', true);
  end if;

  select coalesce(array_agg(id order by pile_position), array[]::uuid[]) into v_ghost_hand
  from app_private.game_cards where owner_player_id = p_player.id and zone = 'ghost_hand';
  perform app_private.discard_cards(p_game.id, p_player.id, v_ghost_hand);

  update app_private.game_players
  set life_status = 'alive', hp = least(6, max_hp), revival_used = true, ghost_tokens = 0,
      died_batch = null
  where id = p_player.id;

  v_drawn := app_private.draw_cards(p_game.id, p_player.id, 'main', 3);

  perform app_private.log_event(p_game.id, 'player_revived', p_player.id,
    jsonb_build_object('hp', least(6, p_player.max_hp), 'drew', v_drawn));

  -- Ressuscitar encerra o turno sem jogar carta do Além.
  perform app_private.advance_turn(p_game.id);
  return jsonb_build_object('ok', true);
end;
$$;

-- Carta do Além: até 1 por turno de fantasma. Alvos são jogadores vivos.
-- Evento Raro não cancela cartas do Além (B3), então não há janela.
create function app_private.cmd_play_ghost_card(
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
  v_card_id uuid := app_private.json_uuid(p_command -> 'cardInstanceId');
  v_targets uuid[] := app_private.jsonb_uuid_array(p_command -> 'targetPlayerIds');
  v_card app_private.game_cards;
  v_def app_private.card_definitions;
  v_target uuid;
  v_victim uuid;
  v_peek uuid[];
  v_codes jsonb;
  v_round smallint;
  v_pending uuid;
  v_min integer;
begin
  if p_game.phase <> 'turn_ghost' then
    perform app_private.fail('WRONG_PHASE', 'Agora não dá para jogar carta do Além.');
  end if;

  if p_game.actions_used >= 1 then
    perform app_private.fail('NO_ACTIONS_LEFT', 'Fantasma joga no máximo 1 carta do Além por turno.');
  end if;

  select * into v_card from app_private.game_cards
  where id = v_card_id and owner_player_id = p_player.id and zone = 'ghost_hand';
  if not found then
    perform app_private.fail('CARD_NOT_IN_HAND', 'Essa carta não está na sua mão.');
  end if;

  select * into v_def from app_private.card_definitions
  where set_version = v_card.set_version and code = v_card.card_code;

  if v_def.target_rule = 'alive_player' then
    if coalesce(cardinality(v_targets), 0) <> 1 or not exists (
      select 1 from app_private.game_players
      where id = v_targets[1] and game_id = p_game.id and life_status = 'alive'
    ) then
      perform app_private.fail('INVALID_TARGET', 'Escolha um jogador vivo.');
    end if;
    v_target := v_targets[1];
    if app_private.hand_size(v_target) = 0 then
      perform app_private.fail('INVALID_TARGET', 'Esse jogador está sem cartas na mão.');
    end if;
  elsif coalesce(cardinality(v_targets), 0) <> 0 then
    perform app_private.fail('INVALID_TARGET', 'Essa carta não tem alvo.');
  end if;

  update app_private.games set actions_used = 1 where id = p_game.id;

  perform app_private.log_event(p_game.id, 'card_played', p_player.id,
    jsonb_build_object('cardCode', v_def.code,
      'targets', case when v_target is null then '[]'::jsonb
                      else jsonb_build_array(jsonb_build_object('playerId', v_target)) end));

  -- GHO-05: o fantasma vê até 2 cartas aleatórias (só ele) e escolhe 1.
  if v_def.effect_code = 'ghost_peek_discard' then
    v_pending := app_private.open_pending(p_game, p_player, v_card, v_def, 'choice', v_target);
    select array_agg(id) into v_peek from (
      select id from app_private.game_cards
      where owner_player_id = v_target and zone = 'player_hand'
      order by gen_random_uuid()
      limit coalesce((v_def.effect_params ->> 'peek')::int, 2)
    ) x;
    insert into app_private.pending_responses
      (pending_action_id, responder_player_id, role, stage, base_damage, choice_count,
       source_player_id, option_card_ids)
    values (v_pending, p_player.id, 'actor_pick', 'choice', 0, 1, v_target, v_peek);
    return jsonb_build_object('ok', true, 'pendingActionId', v_pending);
  end if;

  perform app_private.discard_cards(p_game.id, p_player.id, array[v_card.id]);

  case v_def.effect_code
    when 'ghost_random_discard' then
      select id into v_victim from app_private.game_cards
      where owner_player_id = v_target and zone = 'player_hand'
      order by gen_random_uuid() limit 1;
      select jsonb_build_array(card_code) into v_codes from app_private.game_cards where id = v_victim;
      perform app_private.discard_cards(p_game.id, v_target, array[v_victim]);
      perform app_private.log_event(p_game.id, 'cards_discarded', v_target,
        jsonb_build_object('codes', v_codes, 'chosenBy', null, 'cardCode', v_def.code));

    when 'ghost_peek' then
      select coalesce(jsonb_agg(card_code), '[]'::jsonb) into v_codes from (
        select card_code from app_private.game_cards
        where owner_player_id = v_target and zone = 'player_hand'
        order by gen_random_uuid()
        limit coalesce((v_def.effect_params ->> 'count')::int, 2)
      ) x;
      insert into app_private.private_events (game_id, recipient_player_id, kind, payload)
      values (p_game.id, p_player.id, 'cards_peeked',
              jsonb_build_object('targetPlayerId', v_target, 'codes', v_codes));
      perform app_private.log_event(p_game.id, 'ghost_peeked', p_player.id,
        jsonb_build_object('targetPlayerId', v_target, 'count', jsonb_array_length(v_codes)));

    when 'ghost_bottom_deck' then
      select id into v_victim from app_private.game_cards
      where owner_player_id = v_target and zone = 'player_hand'
      order by gen_random_uuid() limit 1;
      select coalesce(min(pile_position), 1) - 1 into v_min
      from app_private.game_cards where game_id = p_game.id and zone = 'main_deck';
      update app_private.game_cards
      set zone = 'main_deck', owner_player_id = null, pile_position = v_min
      where id = v_victim;
      perform app_private.log_event(p_game.id, 'card_to_bottom', v_target,
        jsonb_build_object('cardCode', v_def.code));

    when 'ghost_curse' then
      v_round := p_game.round_number;
      delete from app_private.status_effects where game_id = p_game.id and type = 'curse';
      insert into app_private.status_effects
        (game_id, target_player_id, type, bonus, source_player_id, applied_round, expires_after_round)
      values (p_game.id, null, 'curse', coalesce((v_def.effect_params ->> 'bonus')::int, 1),
              p_player.id, v_round, v_round + 1);
      perform app_private.log_event(p_game.id, 'curse_cast', p_player.id,
        jsonb_build_object('untilRound', v_round + 1));
    else
      null;
  end case;

  return jsonb_build_object('ok', true);
end;
$$;

-- -----------------------------------------------------------------------------
-- Ausência (E2) e sucessão de host
-- -----------------------------------------------------------------------------

create function app_private.absence_limit()
returns interval
language sql
immutable
set search_path = ''
as $$ select interval '2 minutes' $$;

-- Host remove quem está sem sinal há mais de 2 minutos: vira desistente.
create function app_private.cmd_remove_absent(
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
  v_target app_private.game_players;
  v_cards uuid[];
  v_pending app_private.pending_actions;
begin
  if p_game.host_user_id <> p_player.user_id then
    perform app_private.fail('NOT_HOST', 'Só o host pode remover um jogador ausente.');
  end if;

  select * into v_target from app_private.game_players
  where id = app_private.json_uuid(p_command -> 'playerId') and game_id = p_game.id;

  if not found or v_target.id = p_player.id or v_target.life_status = 'quit' then
    perform app_private.fail('PLAYER_NOT_FOUND', 'Essa pessoa não pode ser removida.');
  end if;

  if v_target.last_seen_at > now() - app_private.absence_limit() then
    perform app_private.fail('PLAYER_NOT_ABSENT',
      'Só dá para remover quem está sem conexão há mais de 2 minutos.');
  end if;

  update app_private.game_players
  set life_status = 'quit', hp = 0
  where id = v_target.id;

  select coalesce(array_agg(id order by zone, pile_position), array[]::uuid[]) into v_cards
  from app_private.game_cards
  where owner_player_id = v_target.id and zone in ('player_hand', 'ghost_hand');
  perform app_private.discard_cards(p_game.id, v_target.id, v_cards);

  perform app_private.log_event(p_game.id, 'player_removed', v_target.id,
    jsonb_build_object('byPlayerId', p_player.id, 'reason', 'absent'));

  -- Decisões pendentes do removido se resolvem como "passar" (a partida não
  -- trava). Escolhas sobre a mão dele somem: as cartas já foram descartadas.
  select * into v_pending from app_private.pending_actions
  where game_id = p_game.id and status = 'open';

  if found then
    update app_private.pending_responses
    set response = 'pass', responded_at = now()
    where pending_action_id = v_pending.id and responder_player_id = v_target.id
      and response is null and stage <> 'choice';
    delete from app_private.pending_responses
    where pending_action_id = v_pending.id and response is null and stage = 'choice'
      and (responder_player_id = v_target.id or source_player_id = v_target.id);
    perform app_private.resolve_pending(p_game.id);
  elsif v_target.seat = p_game.active_seat then
    perform app_private.log_event(p_game.id, 'turn_ended', v_target.id,
      jsonb_build_object('reason', 'removed', 'discarded', '[]'::jsonb));
    perform app_private.advance_turn(p_game.id);
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- Host sumiu há mais de 2 minutos: outro jogador assume o posto.
create function app_private.cmd_claim_host(
  p_game app_private.games,
  p_player app_private.game_players
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_game.host_user_id = p_player.user_id then
    perform app_private.fail('ALREADY_HOST', 'Você já é o host.');
  end if;

  if p_player.life_status = 'quit' then
    perform app_private.fail('NOT_ALLOWED', 'Quem desistiu não assume o posto de host.');
  end if;

  if exists (
    select 1 from app_private.game_players
    where game_id = p_game.id and user_id = p_game.host_user_id
      and life_status <> 'quit' and last_seen_at > now() - app_private.absence_limit()
  ) then
    perform app_private.fail('HOST_PRESENT', 'O host ainda está conectado.');
  end if;

  update app_private.games set host_user_id = p_player.user_id where id = p_game.id;
  perform app_private.log_event(p_game.id, 'host_changed', p_player.id, '{}'::jsonb);
  return jsonb_build_object('ok', true);
end;
$$;

-- -----------------------------------------------------------------------------
-- Envio de comandos
-- -----------------------------------------------------------------------------

create or replace function app_private.submit_game_command(
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

  if v_player.life_status = 'quit' then
    perform app_private.fail('PLAYER_QUIT', 'Você foi removido desta partida por ausência.');
  end if;

  -- Responder, remover ausente e assumir host não exigem estar na vez.
  if v_type not in ('RESPOND', 'REMOVE_ABSENT', 'CLAIM_HOST')
     and v_player.seat is distinct from v_game.active_seat then
    perform app_private.fail('NOT_YOUR_TURN', 'Agora não é a sua vez.');
  end if;

  case v_type
    when 'END_TURN' then
      if v_game.phase = 'ghost_decision' then
        perform app_private.fail('WRONG_PHASE', 'Decida primeiro se vai ressuscitar.');
      end if;
      v_result := app_private.cmd_end_turn(v_game, v_player, p_command);
    when 'PLAY_CARD' then
      if v_game.phase = 'turn_ghost' then
        v_result := app_private.cmd_play_ghost_card(v_game, v_player, p_command);
      else
        v_result := app_private.cmd_play_card(v_game, v_player, p_command);
      end if;
    when 'RESPOND' then
      v_result := app_private.cmd_respond(v_game, v_player, p_command);
    when 'GHOST_REVIVE' then
      v_result := app_private.cmd_ghost_decision(v_game, v_player, true);
    when 'GHOST_STAY' then
      v_result := app_private.cmd_ghost_decision(v_game, v_player, false);
    when 'REMOVE_ABSENT' then
      v_result := app_private.cmd_remove_absent(v_game, v_player, p_command);
    when 'CLAIM_HOST' then
      v_result := app_private.cmd_claim_host(v_game, v_player);
    else
      perform app_private.fail('INVALID_COMMAND', 'Jogada inválida.');
  end case;

  -- Mortes, ressurreições e remoções podem decidir a partida.
  perform app_private.check_game_end(p_game_id);

  v_result := v_result || jsonb_build_object('version', app_private.touch_game(p_game_id));

  insert into app_private.command_receipts (game_id, player_id, request_id, command_type, result_json)
  values (p_game_id, v_player.id, p_request_id, v_type, v_result);

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- Revanche: outra partida com o mesmo grupo
-- -----------------------------------------------------------------------------

create function app_private.create_rematch(p_game_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_user();
  v_game app_private.games := app_private.lock_member_game(p_game_id, v_uid);
  v_room jsonb;
begin
  if v_game.status not in ('finished', 'cancelled') then
    perform app_private.fail('GAME_NOT_FINISHED', 'A revanche só começa depois que a partida acaba.');
  end if;

  -- Já existe: quem chegar depois entra nela (idempotente).
  if v_game.rematch_game_id is not null then
    return app_private.join_rematch(p_game_id);
  end if;

  v_room := app_private.create_room();
  update app_private.games set rematch_game_id = (v_room ->> 'id')::uuid where id = p_game_id;
  perform app_private.touch_game(p_game_id);

  return jsonb_build_object('gameId', v_room ->> 'id', 'status', 'lobby');
end;
$$;

-- Quem jogou a partida anterior entra na revanche sem precisar do código.
create function app_private.join_rematch(p_game_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_user();
  v_rematch uuid;
  v_code text;
  v_result jsonb;
begin
  if not app_private.is_game_member(p_game_id, v_uid) then
    perform app_private.fail('ROOM_NOT_FOUND', 'Sala não encontrada ou você não faz parte dela.');
  end if;

  select rematch_game_id into v_rematch from app_private.games where id = p_game_id;
  select code into v_code from app_private.game_invites where game_id = v_rematch and active;

  if v_rematch is null then
    perform app_private.fail('NO_REMATCH', 'Ainda não há revanche para esta partida.');
  end if;

  if app_private.is_game_member(v_rematch, v_uid) then
    return jsonb_build_object('gameId', v_rematch,
      'status', (select status from app_private.games where id = v_rematch));
  end if;

  if v_code is null then
    perform app_private.fail('ROOM_ALREADY_STARTED', 'A revanche já começou.');
  end if;

  v_result := app_private.join_room(v_code);
  return v_result;
end;
$$;

create function public.create_rematch(p_game_id uuid)
returns jsonb language sql security invoker set search_path = ''
as $$ select app_private.create_rematch(p_game_id); $$;

create function public.join_rematch(p_game_id uuid)
returns jsonb language sql security invoker set search_path = ''
as $$ select app_private.join_rematch(p_game_id); $$;

grant execute on function
  public.create_rematch(uuid),
  public.join_rematch(uuid),
  app_private.create_rematch(uuid),
  app_private.join_rematch(uuid)
to authenticated;

-- -----------------------------------------------------------------------------
-- Visão: extras desta fase (presença, revelações privadas, revanche, maldição)
-- -----------------------------------------------------------------------------

create function app_private.extras_view(p_game_id uuid, p_player_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'maxGhostActions', 1,
    'absenceLimitSeconds', extract(epoch from app_private.absence_limit())::int,
    'rematchGameId', (select rematch_game_id from app_private.games where id = p_game_id),
    'curseActive', exists (
      select 1 from app_private.status_effects where game_id = p_game_id and type = 'curse'
    ),
    -- Segundos desde o último sinal de cada jogador (horário do servidor).
    'presence', coalesce((
      select jsonb_agg(jsonb_build_object(
        'playerId', id,
        'secondsAway', greatest(0, extract(epoch from now() - last_seen_at))::int,
        'quit', life_status = 'quit'
      ) order by seat)
      from app_private.game_players where game_id = p_game_id
    ), '[]'::jsonb),
    -- Só as revelações destinadas a mim.
    'myPrivateEvents', coalesce((
      select jsonb_agg(jsonb_build_object('kind', kind, 'payload', payload, 'at', created_at)
                       order by id desc)
      from (
        select * from app_private.private_events
        where game_id = p_game_id and recipient_player_id = p_player_id
        order by id desc limit 20
      ) e
    ), '[]'::jsonb)
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
    || app_private.extras_view(p_game_id, v_player);
end;
$$;

-- -----------------------------------------------------------------------------
-- Ajustes nas funções da Fase 7 (mesmo corpo, com as mudanças marcadas)
-- -----------------------------------------------------------------------------

create or replace function app_private.cmd_play_card(
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
  v_card_id uuid := app_private.json_uuid(p_command -> 'cardInstanceId');
  v_cost_id uuid := app_private.json_uuid(p_command -> 'discardCostCardId');
  v_own_id uuid := app_private.json_uuid(p_command -> 'ownSwapCardId');
  v_targets uuid[] := app_private.jsonb_uuid_array(p_command -> 'targetPlayerIds');
  v_card app_private.game_cards;
  v_def app_private.card_definitions;
  v_target uuid;
  v_opponents integer;
  v_pending uuid;
  v_amount integer;
  v_bonus integer;
  v_cost_code text;
  v_announced jsonb := '[]'::jsonb;
  v_heal integer;
  v_hp smallint;
  v_drew integer := 0;
  v_actor_cards uuid[];
  v_target_cards uuid[];
  v_count integer;
  v_max integer;
  v_mark smallint;
  v_curse smallint;
  v_curse_used boolean := false;
begin
  if p_game.phase <> 'turn_main' then
    perform app_private.fail('WRONG_PHASE', 'Agora não dá para jogar carta.');
  end if;

  select * into v_card from app_private.game_cards
  where id = v_card_id and owner_player_id = p_player.id and zone = 'player_hand';
  if not found then
    perform app_private.fail('CARD_NOT_IN_HAND', 'Essa carta não está na sua mão.');
  end if;

  select * into v_def from app_private.card_definitions
  where set_version = v_card.set_version and code = v_card.card_code;

  if v_def.is_reaction then
    perform app_private.fail('REACTION_ONLY', 'Essa carta só pode ser usada como reação, fora do seu turno.');
  end if;

  if v_def.deck_type = 'ghost' then
    perform app_private.fail('NOT_AVAILABLE_YET', 'Cartas do Além são jogadas no turno de fantasma.');
  end if;

  select count(*) into v_opponents
  from app_private.game_players
  where game_id = p_game.id and life_status = 'alive' and id <> p_player.id;

  -- Alvos (quando a carta tem alvo): adversários vivos e distintos.
  if (select count(distinct x) from unnest(v_targets) as x) <> coalesce(cardinality(v_targets), 0)
    or exists (
      select 1 from unnest(v_targets) as x (id)
      where not exists (
        select 1 from app_private.game_players gp
        where gp.id = x.id and gp.game_id = p_game.id and gp.life_status = 'alive' and gp.id <> p_player.id
      )
    ) then
    perform app_private.fail('INVALID_TARGET', 'Escolha adversários vivos.');
  end if;

  if v_def.target_rule in ('opponent', 'opponent_most_cards', 'opponent_highest_hp', 'up_to_two_opponents')
     and v_opponents = 0 then
    perform app_private.fail('NO_VALID_TARGET', 'Não há adversário vivo.');
  end if;

  if v_def.target_rule = 'up_to_two_opponents' then
    if coalesce(cardinality(v_targets), 0) <> least(2, v_opponents) then
      perform app_private.fail('INVALID_TARGET',
        case when v_opponents >= 2 then 'Escolha 2 adversários diferentes.' else 'Escolha o adversário.' end);
    end if;
  elsif v_def.target_rule in ('opponent', 'opponent_most_cards', 'opponent_highest_hp') then
    if coalesce(cardinality(v_targets), 0) <> 1 then
      perform app_private.fail('INVALID_TARGET', 'Escolha 1 adversário.');
    end if;
    v_target := v_targets[1];
  elsif coalesce(cardinality(v_targets), 0) <> 0 then
    perform app_private.fail('INVALID_TARGET', 'Essa carta não tem alvo.');
  end if;

  if v_def.target_rule = 'opponent_most_cards' then
    select max(app_private.hand_size(id)) into v_max
    from app_private.game_players
    where game_id = p_game.id and life_status = 'alive' and id <> p_player.id;
    if app_private.hand_size(v_target) <> v_max then
      perform app_private.fail('INVALID_TARGET', 'O alvo precisa ser o adversário com mais cartas na mão.');
    end if;
  end if;

  -- Família Basilato: adversário vivo com mais PV no momento (empate: autor escolhe).
  if v_def.target_rule = 'opponent_highest_hp' then
    select max(hp) into v_max
    from app_private.game_players
    where game_id = p_game.id and life_status = 'alive' and id <> p_player.id;
    if (select hp from app_private.game_players where id = v_target) <> v_max then
      perform app_private.fail('INVALID_TARGET', 'O alvo precisa ser o adversário com mais PV.');
    end if;
  end if;

  -- Sabotagens que mexem na mão do alvo não podem mirar mão vazia.
  if v_def.effect_code in ('steal_random', 'inspect_discard', 'swap_card', 'force_discard')
     and app_private.hand_size(v_target) = 0 then
    perform app_private.fail('INVALID_TARGET', 'Esse adversário está sem cartas na mão.');
  end if;

  -- Eu Amo Mentir: precisa de outra carta sua para trocar.
  if v_def.effect_code = 'swap_card' then
    if v_own_id is null or v_own_id = v_card_id or not exists (
      select 1 from app_private.game_cards
      where id = v_own_id and owner_player_id = p_player.id and zone = 'player_hand'
    ) then
      perform app_private.fail('SWAP_CARD_REQUIRED', 'Escolha outra carta sua para trocar.');
    end if;
  elsif v_own_id is not null then
    perform app_private.fail('INVALID_COMMAND', 'Essa carta não troca cartas.');
  end if;

  -- Custo: descartar outra carta da mão (nunca a própria carta jogada).
  if v_def.effect_params ? 'discard_cost' then
    if v_cost_id is null or v_cost_id = v_card_id or v_cost_id = v_own_id or not exists (
      select 1 from app_private.game_cards
      where id = v_cost_id and owner_player_id = p_player.id and zone = 'player_hand'
    ) then
      perform app_private.fail('COST_REQUIRED', 'Escolha outra carta da sua mão para descartar como custo.');
    end if;
  elsif v_cost_id is not null then
    perform app_private.fail('INVALID_COMMAND', 'Essa carta não tem custo.');
  end if;

  -- Tudo válido: gasta a ação e paga o custo.
  perform app_private.consume_action(p_game.id, p_player.id);

  if v_cost_id is not null then
    select card_code into v_cost_code from app_private.game_cards where id = v_cost_id;
    perform app_private.discard_cards(p_game.id, p_player.id, array[v_cost_id]);
  end if;

  -- ---------------------------------------------------------------- ataque
  if v_def.category = 'attack' then
    v_pending := app_private.open_pending(p_game, p_player, v_card, v_def, 'defense');
    v_amount := coalesce((v_def.effect_params ->> 'amount')::int, 0);

    foreach v_target in array v_targets loop
      -- +1 no Mais Odiado; +2 se marcado (a marca é consumida no anúncio,
      -- mesmo que o ataque seja defendido depois).
      v_mark := null;
      delete from app_private.status_effects
      where game_id = p_game.id and target_player_id = v_target and type = 'mark'
      returning bonus into v_mark;
      v_bonus := case when v_target = p_game.leader_player_id then 1 else 0 end + coalesce(v_mark, 0);
      -- Maldição da Ressaca: +1 no próximo ataque ao Mais Odiado, consumida
      -- no anúncio. Sem Mais Odiado, continua pendente até expirar.
      if v_target = p_game.leader_player_id and not v_curse_used then
        v_curse := null;
        delete from app_private.status_effects
        where game_id = p_game.id and type = 'curse'
        returning bonus into v_curse;
        if v_curse is not null then
          v_bonus := v_bonus + v_curse;
          v_curse_used := true;
        end if;
      end if;
      insert into app_private.pending_responses
        (pending_action_id, responder_player_id, role, stage, base_damage, credited_player_id)
      values (v_pending, v_target, 'target', 'defense', v_amount + v_bonus, p_player.id);
      v_announced := v_announced || jsonb_build_object('playerId', v_target, 'damage', v_amount + v_bonus);
    end loop;

    perform app_private.log_event(p_game.id, 'card_played', p_player.id,
      jsonb_build_object('cardCode', v_def.code, 'targets', v_announced, 'costCode', v_cost_code));
    return jsonb_build_object('ok', true, 'pendingActionId', v_pending);
  end if;

  -- ------------------------------------------------------------- sabotagem
  if v_def.category = 'sabotage' then
    v_pending := app_private.open_pending(p_game, p_player, v_card, v_def, 'defense', v_target, v_own_id);
    insert into app_private.pending_responses
      (pending_action_id, responder_player_id, role, stage, base_damage)
    values (v_pending, v_target, 'sabotage_target', 'defense', 0);

    perform app_private.log_event(p_game.id, 'card_played', p_player.id,
      jsonb_build_object('cardCode', v_def.code, 'targets', jsonb_build_array(jsonb_build_object('playerId', v_target))));
    return jsonb_build_object('ok', true, 'pendingActionId', v_pending);
  end if;

  -- ------------------------------------------------------------------ caos
  if v_def.category = 'chaos' then
    perform app_private.log_event(p_game.id, 'card_played', p_player.id,
      jsonb_build_object('cardCode', v_def.code,
        'targets', case when v_target is null then '[]'::jsonb
                        else jsonb_build_array(jsonb_build_object('playerId', v_target,
                               'damage', (v_def.effect_params ->> 'amount')::int)) end));

    if v_def.effect_code = 'chaos_damage' then
      -- Sem defesa comum. Se o golpe for fatal, a vítima pode escolher uma
      -- reação de golpe fatal (B4); senão, aplica direto.
      v_pending := app_private.open_pending(p_game, p_player, v_card, v_def, 'defense', v_target);
      v_amount := coalesce((v_def.effect_params ->> 'amount')::int, 0);
      v_hp := (select hp from app_private.game_players where id = v_target);
      insert into app_private.pending_responses
        (pending_action_id, responder_player_id, role, stage, base_damage, credited_player_id, response)
      values (v_pending, v_target, 'chaos_target', 'defense', v_amount, p_player.id,
              case when v_amount >= v_hp then null else 'pass' end);
      perform app_private.resolve_pending(p_game.id);
      return jsonb_build_object('ok', true);
    end if;

    v_pending := app_private.open_pending(p_game, p_player, v_card, v_def, 'choice');

    if v_def.effect_code = 'all_draw_discard' then
      -- Todos os vivos compram 1 (em ordem de lugar) e depois escolhem 1.
      perform app_private.draw_cards(p_game.id, gp.id, 'main', 1)
      from app_private.game_players gp
      where gp.game_id = p_game.id and gp.life_status = 'alive'
      order by gp.seat;
    end if;

    if v_def.effect_code = 'pass_right' then
      insert into app_private.pending_responses
        (pending_action_id, responder_player_id, role, stage, base_damage, choice_count, source_player_id)
      select v_pending, gp.id, 'pass_pick', 'choice', 0, 1, gp.id
      from app_private.game_players gp
      where gp.game_id = p_game.id and gp.life_status = 'alive' and app_private.hand_size(gp.id) > 0;
      get diagnostics v_count = row_count;
      -- Menos de 2 vivos com carta: não há troca.
      if v_count < 2 then
        delete from app_private.pending_responses where pending_action_id = v_pending;
        perform app_private.log_event(p_game.id, 'chaos_no_effect', p_player.id,
          jsonb_build_object('cardCode', v_def.code));
      end if;
    else
      v_count := app_private.open_discard_picks(v_pending, p_game.id);
    end if;

    perform app_private.resolve_pending(p_game.id);
    return jsonb_build_object('ok', true);
  end if;

  -- ---------------------------------------------------------- recuperação
  if v_def.category = 'recovery' then
    v_heal := coalesce((v_def.effect_params ->> 'amount')::int, 0);
    update app_private.game_players
    set hp = least(max_hp, hp + v_heal)
    where id = p_player.id
    returning hp into v_hp;

    perform app_private.discard_played(p_game.id, v_card.id);
    v_drew := app_private.draw_cards(p_game.id, p_player.id, 'main',
      coalesce((v_def.effect_params ->> 'draw')::int, 0));

    perform app_private.log_event(p_game.id, 'card_played', p_player.id,
      jsonb_build_object('cardCode', v_def.code, 'targets', '[]'::jsonb, 'costCode', v_cost_code));
    perform app_private.log_event(p_game.id, 'healed', p_player.id,
      jsonb_build_object('amount', v_heal, 'hp', v_hp, 'drew', v_drew));
    return jsonb_build_object('ok', true);
  end if;

  -- ------------------------------------------- reviravolta: troca de mãos
  if v_def.effect_code = 'swap_hands' then
    -- Reviravolta não é sabotagem: Evento Raro não cancela (B2).
    perform app_private.discard_played(p_game.id, v_card.id);

    select coalesce(array_agg(id order by pile_position), array[]::uuid[]) into v_actor_cards
    from app_private.game_cards where owner_player_id = p_player.id and zone = 'player_hand';
    select coalesce(array_agg(id order by pile_position), array[]::uuid[]) into v_target_cards
    from app_private.game_cards where owner_player_id = v_target and zone = 'player_hand';

    -- Tira tudo das mãos antes de redistribuir (posições não colidem).
    perform app_private.lift_cards(p_game.id, v_actor_cards || v_target_cards);
    perform app_private.give_cards(v_target_cards, p_player.id);
    perform app_private.give_cards(v_actor_cards, v_target);

    perform app_private.log_event(p_game.id, 'card_played', p_player.id,
      jsonb_build_object('cardCode', v_def.code, 'targets', jsonb_build_array(jsonb_build_object('playerId', v_target))));
    perform app_private.log_event(p_game.id, 'hands_swapped', p_player.id,
      jsonb_build_object('targetPlayerId', v_target,
        'actorReceived', cardinality(v_target_cards), 'targetReceived', cardinality(v_actor_cards)));
    return jsonb_build_object('ok', true);
  end if;

  perform app_private.fail('NOT_AVAILABLE_YET', 'Essa carta ainda não pode ser jogada.');
  return null;
end;
$$;

create or replace function app_private.cmd_respond(
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
  v_pending app_private.pending_actions;
  v_row app_private.pending_responses;
  v_choice text := p_command ->> 'response';
  v_card_id uuid := app_private.json_uuid(p_command -> 'cardInstanceId');
  v_selected uuid[] := app_private.jsonb_uuid_array(p_command -> 'selectedCardIds');
  v_card app_private.game_cards;
  v_def app_private.card_definitions;
begin
  select * into v_pending from app_private.pending_actions
  where game_id = p_game.id and status = 'open';

  if not found or v_pending.id is distinct from app_private.json_uuid(p_command -> 'pendingActionId') then
    perform app_private.fail('NO_PENDING_DECISION', 'Não há nada esperando a sua resposta.');
  end if;

  select * into v_row from app_private.pending_responses
  where pending_action_id = v_pending.id and responder_player_id = p_player.id
    and stage = v_pending.stage and response is null;

  if not found then
    perform app_private.fail('NOT_YOUR_DECISION', 'Não há nada esperando a sua resposta.');
  end if;

  if v_row.stage = 'choice' then
    if v_choice <> 'CHOOSE' then
      perform app_private.fail('CHOICE_REQUIRED', 'Escolha as cartas para continuar.');
    end if;
    if (v_row.option_card_ids is not null and not (v_selected <@ v_row.option_card_ids))
       or (select count(distinct x) from unnest(v_selected) as x) <> v_row.choice_count
       or coalesce(cardinality(v_selected), 0) <> v_row.choice_count
       or exists (
         select 1 from unnest(v_selected) as x (id)
         where not exists (
           select 1 from app_private.game_cards c
           where c.id = x.id and c.owner_player_id = v_row.source_player_id and c.zone = 'player_hand'
         )
       ) then
      perform app_private.fail('WRONG_CHOICE',
        case v_row.choice_count when 1 then 'Escolha 1 carta.'
             else format('Escolha %s cartas.', v_row.choice_count) end);
    end if;

    update app_private.pending_responses
    set response = 'choose', selected_card_ids = v_selected, responded_at = now()
    where pending_action_id = v_row.pending_action_id
      and responder_player_id = v_row.responder_player_id and role = v_row.role;

    -- Escolha é secreta até todos escolherem: o evento só diz que escolheu.
    perform app_private.log_event(p_game.id, 'choice_made', p_player.id,
      jsonb_build_object('role', v_row.role));
  elsif v_choice = 'PASS' then
    update app_private.pending_responses
    set response = 'pass', responded_at = now()
    where pending_action_id = v_row.pending_action_id
      and responder_player_id = v_row.responder_player_id and role = v_row.role;

    perform app_private.log_event(p_game.id, 'response_passed', p_player.id,
      jsonb_build_object('role', v_row.role));
  elsif v_choice = 'REACT' then
    select * into v_card from app_private.game_cards
    where id = v_card_id and owner_player_id = p_player.id and zone = 'player_hand';
    if not found then
      perform app_private.fail('CARD_NOT_IN_HAND', 'Essa carta não está na sua mão.');
    end if;

    select * into v_def from app_private.card_definitions
    where set_version = v_card.set_version and code = v_card.card_code;

    if not v_def.is_reaction or not (
      v_def.effect_code = any (
        app_private.allowed_reactions(v_row.role, v_pending.effect_code, v_row.base_damage, p_player.hp)
      )
    ) then
      perform app_private.fail('REACTION_NOT_ALLOWED', 'Essa carta não pode ser usada contra esta jogada.');
    end if;

    perform app_private.discard_cards(p_game.id, p_player.id, array[v_card.id]);

    update app_private.pending_responses
    set response = 'react', reaction_card_code = v_def.code, reaction_effect = v_def.effect_code,
        responded_at = now()
    where pending_action_id = v_row.pending_action_id
      and responder_player_id = v_row.responder_player_id and role = v_row.role;

    perform app_private.log_event(p_game.id, 'reaction_played', p_player.id,
      jsonb_build_object('cardCode', v_def.code, 'role', v_row.role));
  else
    perform app_private.fail('INVALID_COMMAND', 'Jogada inválida.');
  end if;

  perform app_private.resolve_pending(p_game.id);

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function app_private.pending_view(p_game_id uuid, p_player_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'pendingAction', (
      select jsonb_build_object(
        'id', pa.id,
        'actorPlayerId', pa.actor_player_id,
        'cardCode', pa.card_code,
        'stage', pa.stage,
        'responses', coalesce((
          select jsonb_agg(jsonb_build_object(
            'playerId', r.responder_player_id,
            'role', r.role,
            'baseDamage', r.base_damage,
            'responded', r.response is not null,
            'reactionCode', r.reaction_card_code
          ) order by r.role, gp.seat)
          from app_private.pending_responses r
          join app_private.game_players gp on gp.id = r.responder_player_id
          where r.pending_action_id = pa.id
        ), '[]'::jsonb)
      )
      from app_private.pending_actions pa
      where pa.game_id = p_game_id and pa.status = 'open'
    ),
    'myDecision', (
      select jsonb_build_object(
        'pendingActionId', pa.id,
        'role', r.role,
        'baseDamage', r.base_damage,
        'actorPlayerId', pa.actor_player_id,
        'cardCode', pa.card_code,
        'targetPlayerId', pa.target_player_id,
        'choiceCount', r.choice_count,
        'eligibleCardIds', case when r.stage = 'choice' then '[]'::jsonb else coalesce((
          select jsonb_agg(c.id order by c.pile_position)
          from app_private.game_cards c
          join app_private.card_definitions d on d.set_version = c.set_version and d.code = c.card_code
          where c.owner_player_id = p_player_id and c.zone = 'player_hand' and d.is_reaction
            and d.effect_code = any (app_private.allowed_reactions(r.role, pa.effect_code, r.base_damage, gp.hp))
        ), '[]'::jsonb) end,
        -- Cartas a escolher. Na Terapia de Boteco, a mão do alvo aparece só
        -- para quem jogou.
        'options', case when r.stage = 'choice' then coalesce((
          select jsonb_agg(jsonb_build_object('instanceId', c.id, 'code', c.card_code) order by c.pile_position)
          from app_private.game_cards c
          where c.owner_player_id = r.source_player_id and c.zone = 'player_hand'
            and (r.option_card_ids is null or c.id = any (r.option_card_ids))
        ), '[]'::jsonb) else '[]'::jsonb end
      )
      from app_private.pending_actions pa
      join app_private.pending_responses r
        on r.pending_action_id = pa.id and r.stage = pa.stage and r.response is null
       and r.responder_player_id = p_player_id
      join app_private.game_players gp on gp.id = p_player_id
      where pa.game_id = p_game_id and pa.status = 'open'
    ),
    -- Marcas são públicas (a carta foi jogada aberta).
    'markedPlayerIds', coalesce((
      select jsonb_agg(target_player_id)
      from app_private.status_effects
      where game_id = p_game_id and type = 'mark'
    ), '[]'::jsonb)
  );
$$;
