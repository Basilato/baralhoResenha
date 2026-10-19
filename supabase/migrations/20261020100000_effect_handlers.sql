-- =============================================================================
-- Motor de cartas em handlers: cada efeito tem a própria função
-- =============================================================================
-- Antes, cada carta nova copiava funções inteiras do motor (cmd_play_card já
-- tinha 5 versões) para acrescentar um ramo. Agora o núcleo não conhece nenhum
-- efeito: valida, chama o handler registrado e cuida do fluxo comum.
--
-- Carta nova, daqui em diante:
--   1. insert em card_definitions (e as cópias nas partidas em andamento);
--   2. create function com o efeito (assinatura do ponto de extensão abaixo);
--   3. insert em card_effect_handlers ligando effect_code + ponto à função.
-- O teste effect_handlers.test.sql confere assinaturas e cobertura.
--
-- Pontos de extensão (hook) e assinaturas:
--   validate      (games, game_players, game_cards, card_definitions, uuid[], jsonb) → void
--                 antes de gastar a ação. Sem handler, o núcleo recusa ownSwapCardId.
--   play          (games, game_players, game_cards, card_definitions, uuid[], jsonb, text) → jsonb
--                 a jogada em si (o text é a carta paga como custo). Obrigatório.
--   resolve       (pending_actions) → boolean   sabotagem depois da defesa;
--                 false = abriu escolha e a jogada continua. Sem handler: nada.
--   after_damage  (pending_actions) → boolean   depois do dano em lote (ataque e
--                 caos); false = abriu nova etapa e a jogada continua.
--   finish        (pending_actions) → void      ao fechar a jogada.
--   choices       (pending_actions) → void      aplica as escolhas; sem handler,
--                 as cartas escolhidas são descartadas.
--
-- Os corpos abaixo são os mesmos das versões anteriores, só divididos por efeito.

create table app_private.card_effect_handlers (
  effect_code text not null check (effect_code ~ '^[a-z_]+$'),
  hook text not null check (hook in ('validate', 'play', 'resolve', 'after_damage', 'finish', 'choices')),
  -- regproc: nome de função errado falha já na migração.
  handler regproc not null,
  primary key (effect_code, hook)
);

alter table app_private.card_effect_handlers enable row level security;
revoke all on table app_private.card_effect_handlers from public, anon, authenticated;

create function app_private.effect_handler(p_effect_code text, p_hook text)
returns regproc
language sql
stable
set search_path = ''
as $$
  select handler from app_private.card_effect_handlers
  where effect_code = p_effect_code and hook = p_hook;
$$;

-- =============================================================================
-- validate
-- =============================================================================

-- Sabotagens que mexem na mão do alvo não podem mirar mão vazia.
create function app_private.validate_target_has_cards(
  p_game app_private.games,
  p_player app_private.game_players,
  p_card app_private.game_cards,
  p_def app_private.card_definitions,
  p_targets uuid[],
  p_command jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app_private.hand_size(p_targets[1]) = 0 then
    perform app_private.fail('INVALID_TARGET', 'Esse adversário está sem cartas na mão.');
  end if;
  if app_private.json_uuid(p_command -> 'ownSwapCardId') is not null then
    perform app_private.fail('INVALID_COMMAND', 'Essa carta não troca cartas.');
  end if;
end;
$$;

-- Eu Amo Mentir: alvo com cartas e outra carta sua para trocar.
create function app_private.validate_swap_card(
  p_game app_private.games,
  p_player app_private.game_players,
  p_card app_private.game_cards,
  p_def app_private.card_definitions,
  p_targets uuid[],
  p_command jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_own_id uuid := app_private.json_uuid(p_command -> 'ownSwapCardId');
begin
  if app_private.hand_size(p_targets[1]) = 0 then
    perform app_private.fail('INVALID_TARGET', 'Esse adversário está sem cartas na mão.');
  end if;
  if v_own_id is null or v_own_id = p_card.id or not exists (
    select 1 from app_private.game_cards
    where id = v_own_id and owner_player_id = p_player.id and zone = 'player_hand'
  ) then
    perform app_private.fail('SWAP_CARD_REQUIRED', 'Escolha outra carta sua para trocar.');
  end if;
end;
$$;

-- =============================================================================
-- play: baralho principal
-- =============================================================================

create function app_private.play_attack(
  p_game app_private.games,
  p_player app_private.game_players,
  p_card app_private.game_cards,
  p_def app_private.card_definitions,
  p_targets uuid[],
  p_command jsonb,
  p_cost_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pending uuid;
  v_amount integer;
  v_target uuid;
  v_mark smallint;
  v_bonus integer;
  v_curse smallint;
  v_curse_used boolean := false;
  v_announced jsonb := '[]'::jsonb;
begin
  v_pending := app_private.open_pending(p_game, p_player, p_card, p_def, 'defense');
  v_amount := coalesce((p_def.effect_params ->> 'amount')::int, 0);

  foreach v_target in array p_targets loop
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
    jsonb_build_object('cardCode', p_def.code, 'targets', v_announced, 'costCode', p_cost_code));
  return jsonb_build_object('ok', true, 'pendingActionId', v_pending);
end;
$$;

create function app_private.play_sabotage(
  p_game app_private.games,
  p_player app_private.game_players,
  p_card app_private.game_cards,
  p_def app_private.card_definitions,
  p_targets uuid[],
  p_command jsonb,
  p_cost_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target uuid := p_targets[1];
  v_pending uuid;
begin
  v_pending := app_private.open_pending(p_game, p_player, p_card, p_def, 'defense', v_target,
    app_private.json_uuid(p_command -> 'ownSwapCardId'));
  insert into app_private.pending_responses
    (pending_action_id, responder_player_id, role, stage, base_damage)
  values (v_pending, v_target, 'sabotage_target', 'defense', 0);

  perform app_private.log_event(p_game.id, 'card_played', p_player.id,
    jsonb_build_object('cardCode', p_def.code, 'targets', jsonb_build_array(jsonb_build_object('playerId', v_target))));
  return jsonb_build_object('ok', true, 'pendingActionId', v_pending);
end;
$$;

-- Anúncio comum das cartas de caos.
create function app_private.log_chaos_played(
  p_game_id uuid,
  p_player_id uuid,
  p_def app_private.card_definitions,
  p_target uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.log_event(p_game_id, 'card_played', p_player_id,
    jsonb_build_object('cardCode', p_def.code,
      'targets', case when p_target is null then '[]'::jsonb
                      else jsonb_build_array(jsonb_build_object('playerId', p_target,
                             'damage', (p_def.effect_params ->> 'amount')::int)) end));
end;
$$;

-- Rolê no Sítio: a carta jogada sai antes de juntar as mãos.
create function app_private.play_shuffle_hands(
  p_game app_private.games,
  p_player app_private.game_players,
  p_card app_private.game_cards,
  p_def app_private.card_definitions,
  p_targets uuid[],
  p_command jsonb,
  p_cost_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app_private.log_chaos_played(p_game.id, p_player.id, p_def, p_targets[1]);
  perform app_private.discard_played(p_game.id, p_card.id);
  perform app_private.shuffle_hands(p_game.id, p_player.id);
  return jsonb_build_object('ok', true);
end;
$$;

-- Bonde da Tempestade: todos os vivos levam o dano no mesmo lote. Só quem
-- cairia responde (reação de golpe fatal); o resto já entra como passe.
create function app_private.play_chaos_storm(
  p_game app_private.games,
  p_player app_private.game_players,
  p_card app_private.game_cards,
  p_def app_private.card_definitions,
  p_targets uuid[],
  p_command jsonb,
  p_cost_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pending uuid;
  v_amount integer;
begin
  perform app_private.log_chaos_played(p_game.id, p_player.id, p_def, p_targets[1]);
  v_pending := app_private.open_pending(p_game, p_player, p_card, p_def, 'defense');
  v_amount := coalesce((p_def.effect_params ->> 'amount')::int, 0);
  insert into app_private.pending_responses
    (pending_action_id, responder_player_id, role, stage, base_damage, credited_player_id, response)
  select v_pending, gp.id,
         case when gp.id = p_player.id then 'chaos_self' else 'chaos_target' end,
         'defense', v_amount,
         case when gp.id = p_player.id then null else p_player.id end,
         case when v_amount >= gp.hp then null else 'pass' end
  from app_private.game_players gp
  where gp.game_id = p_game.id and gp.life_status = 'alive';
  perform app_private.resolve_pending(p_game.id);
  return jsonb_build_object('ok', true);
end;
$$;

-- Família Basilato: sem defesa comum. Se o golpe for fatal, a vítima pode
-- escolher uma reação de golpe fatal (B4); senão, aplica direto.
create function app_private.play_chaos_damage(
  p_game app_private.games,
  p_player app_private.game_players,
  p_card app_private.game_cards,
  p_def app_private.card_definitions,
  p_targets uuid[],
  p_command jsonb,
  p_cost_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target uuid := p_targets[1];
  v_pending uuid;
  v_amount integer;
  v_hp smallint;
begin
  perform app_private.log_chaos_played(p_game.id, p_player.id, p_def, v_target);
  v_pending := app_private.open_pending(p_game, p_player, p_card, p_def, 'defense', v_target);
  v_amount := coalesce((p_def.effect_params ->> 'amount')::int, 0);
  v_hp := (select hp from app_private.game_players where id = v_target);
  insert into app_private.pending_responses
    (pending_action_id, responder_player_id, role, stage, base_damage, credited_player_id, response)
  values (v_pending, v_target, 'chaos_target', 'defense', v_amount, p_player.id,
          case when v_amount >= v_hp then null else 'pass' end);
  perform app_private.resolve_pending(p_game.id);
  return jsonb_build_object('ok', true);
end;
$$;

-- Passa pra Direita: cada vivo com carta escolhe 1 para o próximo vivo.
create function app_private.play_pass_right(
  p_game app_private.games,
  p_player app_private.game_players,
  p_card app_private.game_cards,
  p_def app_private.card_definitions,
  p_targets uuid[],
  p_command jsonb,
  p_cost_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pending uuid;
  v_count integer;
begin
  perform app_private.log_chaos_played(p_game.id, p_player.id, p_def, p_targets[1]);
  v_pending := app_private.open_pending(p_game, p_player, p_card, p_def, 'choice');

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
      jsonb_build_object('cardCode', p_def.code));
  end if;

  perform app_private.resolve_pending(p_game.id);
  return jsonb_build_object('ok', true);
end;
$$;

-- Todos descartam 1 (com "draw" nos parâmetros, todos os vivos compram antes,
-- em ordem de lugar).
create function app_private.play_discard_round(
  p_game app_private.games,
  p_player app_private.game_players,
  p_card app_private.game_cards,
  p_def app_private.card_definitions,
  p_targets uuid[],
  p_command jsonb,
  p_cost_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pending uuid;
begin
  perform app_private.log_chaos_played(p_game.id, p_player.id, p_def, p_targets[1]);
  v_pending := app_private.open_pending(p_game, p_player, p_card, p_def, 'choice');

  if p_def.effect_params ? 'draw' then
    perform app_private.draw_cards(p_game.id, gp.id, 'main', (p_def.effect_params ->> 'draw')::int)
    from app_private.game_players gp
    where gp.game_id = p_game.id and gp.life_status = 'alive'
    order by gp.seat;
  end if;

  perform app_private.open_discard_picks(v_pending, p_game.id);
  perform app_private.resolve_pending(p_game.id);
  return jsonb_build_object('ok', true);
end;
$$;

-- Só Mais Uma!: compra e depois escolhe o descarte (pode ser uma das cartas
-- recém-compradas). A carta jogada fica em resolução até a escolha, então
-- não pode ser a descartada.
create function app_private.play_draw_discard(
  p_game app_private.games,
  p_player app_private.game_players,
  p_card app_private.game_cards,
  p_def app_private.card_definitions,
  p_targets uuid[],
  p_command jsonb,
  p_cost_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pending uuid;
  v_heal integer;
  v_drew integer;
  v_count integer;
begin
  v_pending := app_private.open_pending(p_game, p_player, p_card, p_def, 'choice');
  perform app_private.log_event(p_game.id, 'card_played', p_player.id,
    jsonb_build_object('cardCode', p_def.code, 'targets', '[]'::jsonb));

  v_heal := coalesce((p_def.effect_params ->> 'amount')::int, 0);
  if v_heal > 0 then
    update app_private.game_players
    set hp = least(max_hp, hp + v_heal)
    where id = p_player.id;
  end if;

  v_drew := app_private.draw_cards(p_game.id, p_player.id, 'main',
    coalesce((p_def.effect_params ->> 'draw')::int, 2));
  perform app_private.log_event(p_game.id, 'cards_drawn', p_player.id,
    jsonb_build_object('count', v_drew, 'cardCode', p_def.code));

  v_count := least(coalesce((p_def.effect_params ->> 'discard')::int, 1),
                   app_private.hand_size(p_player.id));
  if v_count > 0 then
    insert into app_private.pending_responses
      (pending_action_id, responder_player_id, role, stage, base_damage, choice_count, source_player_id)
    values (v_pending, p_player.id, 'discard_pick', 'choice', 0, v_count, p_player.id);
  end if;

  perform app_private.resolve_pending(p_game.id);
  return jsonb_build_object('ok', true, 'pendingActionId', v_pending);
end;
$$;

create function app_private.play_heal(
  p_game app_private.games,
  p_player app_private.game_players,
  p_card app_private.game_cards,
  p_def app_private.card_definitions,
  p_targets uuid[],
  p_command jsonb,
  p_cost_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_heal integer;
  v_hp smallint;
  v_drew integer;
begin
  v_heal := coalesce((p_def.effect_params ->> 'amount')::int, 0);
  update app_private.game_players
  set hp = least(max_hp, hp + v_heal)
  where id = p_player.id
  returning hp into v_hp;

  perform app_private.discard_played(p_game.id, p_card.id);
  v_drew := app_private.draw_cards(p_game.id, p_player.id, 'main',
    coalesce((p_def.effect_params ->> 'draw')::int, 0));

  perform app_private.log_event(p_game.id, 'card_played', p_player.id,
    jsonb_build_object('cardCode', p_def.code, 'targets', '[]'::jsonb, 'costCode', p_cost_code));
  perform app_private.log_event(p_game.id, 'healed', p_player.id,
    jsonb_build_object('amount', v_heal, 'hp', v_hp, 'drew', v_drew));
  return jsonb_build_object('ok', true);
end;
$$;

-- Reviravolta: troca de mãos. Não é sabotagem: Evento Raro não cancela (B2).
create function app_private.play_swap_hands(
  p_game app_private.games,
  p_player app_private.game_players,
  p_card app_private.game_cards,
  p_def app_private.card_definitions,
  p_targets uuid[],
  p_command jsonb,
  p_cost_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target uuid := p_targets[1];
  v_actor_cards uuid[];
  v_target_cards uuid[];
begin
  perform app_private.discard_played(p_game.id, p_card.id);

  select coalesce(array_agg(id order by pile_position), array[]::uuid[]) into v_actor_cards
  from app_private.game_cards where owner_player_id = p_player.id and zone = 'player_hand';
  select coalesce(array_agg(id order by pile_position), array[]::uuid[]) into v_target_cards
  from app_private.game_cards where owner_player_id = v_target and zone = 'player_hand';

  -- Tira tudo das mãos antes de redistribuir (posições não colidem).
  perform app_private.lift_cards(p_game.id, v_actor_cards || v_target_cards);
  perform app_private.give_cards(v_target_cards, p_player.id);
  perform app_private.give_cards(v_actor_cards, v_target);

  perform app_private.log_event(p_game.id, 'card_played', p_player.id,
    jsonb_build_object('cardCode', p_def.code, 'targets', jsonb_build_array(jsonb_build_object('playerId', v_target))));
  perform app_private.log_event(p_game.id, 'hands_swapped', p_player.id,
    jsonb_build_object('targetPlayerId', v_target,
      'actorReceived', cardinality(v_target_cards), 'targetReceived', cardinality(v_actor_cards)));
  return jsonb_build_object('ok', true);
end;
$$;

-- =============================================================================
-- play: Baralho do Além (o núcleo já gastou a ação e anunciou a carta)
-- =============================================================================

-- GHO-05: o fantasma vê até 2 cartas aleatórias (só ele) e escolhe 1.
create function app_private.play_ghost_peek_discard(
  p_game app_private.games,
  p_player app_private.game_players,
  p_card app_private.game_cards,
  p_def app_private.card_definitions,
  p_targets uuid[],
  p_command jsonb,
  p_cost_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target uuid := p_targets[1];
  v_pending uuid;
  v_peek uuid[];
begin
  v_pending := app_private.open_pending(p_game, p_player, p_card, p_def, 'choice', v_target);
  select array_agg(id) into v_peek from (
    select id from app_private.game_cards
    where owner_player_id = v_target and zone = 'player_hand'
    order by gen_random_uuid()
    limit coalesce((p_def.effect_params ->> 'peek')::int, 2)
  ) x;
  insert into app_private.pending_responses
    (pending_action_id, responder_player_id, role, stage, base_damage, choice_count,
     source_player_id, option_card_ids)
  values (v_pending, p_player.id, 'actor_pick', 'choice', 0, 1, v_target, v_peek);
  return jsonb_build_object('ok', true, 'pendingActionId', v_pending);
end;
$$;

create function app_private.play_ghost_random_discard(
  p_game app_private.games,
  p_player app_private.game_players,
  p_card app_private.game_cards,
  p_def app_private.card_definitions,
  p_targets uuid[],
  p_command jsonb,
  p_cost_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target uuid := p_targets[1];
  v_victim uuid;
  v_codes jsonb;
begin
  perform app_private.discard_cards(p_game.id, p_player.id, array[p_card.id]);

  select id into v_victim from app_private.game_cards
  where owner_player_id = v_target and zone = 'player_hand'
  order by gen_random_uuid() limit 1;
  select jsonb_build_array(card_code) into v_codes from app_private.game_cards where id = v_victim;
  perform app_private.discard_cards(p_game.id, v_target, array[v_victim]);
  perform app_private.log_event(p_game.id, 'cards_discarded', v_target,
    jsonb_build_object('codes', v_codes, 'chosenBy', null, 'cardCode', p_def.code));
  return jsonb_build_object('ok', true);
end;
$$;

create function app_private.play_ghost_peek(
  p_game app_private.games,
  p_player app_private.game_players,
  p_card app_private.game_cards,
  p_def app_private.card_definitions,
  p_targets uuid[],
  p_command jsonb,
  p_cost_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target uuid := p_targets[1];
  v_codes jsonb;
begin
  perform app_private.discard_cards(p_game.id, p_player.id, array[p_card.id]);

  select coalesce(jsonb_agg(card_code), '[]'::jsonb) into v_codes from (
    select card_code from app_private.game_cards
    where owner_player_id = v_target and zone = 'player_hand'
    order by gen_random_uuid()
    limit coalesce((p_def.effect_params ->> 'count')::int, 2)
  ) x;
  insert into app_private.private_events (game_id, recipient_player_id, kind, payload)
  values (p_game.id, p_player.id, 'cards_peeked',
          jsonb_build_object('targetPlayerId', v_target, 'codes', v_codes));
  perform app_private.log_event(p_game.id, 'ghost_peeked', p_player.id,
    jsonb_build_object('targetPlayerId', v_target, 'count', jsonb_array_length(v_codes)));
  return jsonb_build_object('ok', true);
end;
$$;

create function app_private.play_ghost_bottom_deck(
  p_game app_private.games,
  p_player app_private.game_players,
  p_card app_private.game_cards,
  p_def app_private.card_definitions,
  p_targets uuid[],
  p_command jsonb,
  p_cost_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target uuid := p_targets[1];
  v_victim uuid;
  v_min integer;
begin
  perform app_private.discard_cards(p_game.id, p_player.id, array[p_card.id]);

  select id into v_victim from app_private.game_cards
  where owner_player_id = v_target and zone = 'player_hand'
  order by gen_random_uuid() limit 1;
  select coalesce(min(pile_position), 1) - 1 into v_min
  from app_private.game_cards where game_id = p_game.id and zone = 'main_deck';
  update app_private.game_cards
  set zone = 'main_deck', owner_player_id = null, pile_position = v_min
  where id = v_victim;
  perform app_private.log_event(p_game.id, 'card_to_bottom', v_target,
    jsonb_build_object('cardCode', p_def.code));
  return jsonb_build_object('ok', true);
end;
$$;

create function app_private.play_ghost_curse(
  p_game app_private.games,
  p_player app_private.game_players,
  p_card app_private.game_cards,
  p_def app_private.card_definitions,
  p_targets uuid[],
  p_command jsonb,
  p_cost_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_round smallint := p_game.round_number;
begin
  perform app_private.discard_cards(p_game.id, p_player.id, array[p_card.id]);

  delete from app_private.status_effects where game_id = p_game.id and type = 'curse';
  insert into app_private.status_effects
    (game_id, target_player_id, type, bonus, source_player_id, applied_round, expires_after_round)
  values (p_game.id, null, 'curse', coalesce((p_def.effect_params ->> 'bonus')::int, 1),
          p_player.id, v_round, v_round + 1);
  perform app_private.log_event(p_game.id, 'curse_cast', p_player.id,
    jsonb_build_object('untilRound', v_round + 1));
  return jsonb_build_object('ok', true);
end;
$$;

-- =============================================================================
-- resolve: sabotagens depois da defesa
-- =============================================================================

create function app_private.resolve_steal_random(p_pending app_private.pending_actions)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target uuid := p_pending.target_player_id;
  v_card uuid;
begin
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
end;
$$;

create function app_private.resolve_mark_target(p_pending app_private.pending_actions)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target uuid := p_pending.target_player_id;
  v_round smallint;
begin
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
end;
$$;

-- Vale Entrosa: a próxima vez do alvo é do autor. A próxima vez sempre cai
-- nesta rodada ou na seguinte; o prazo é só uma rede de segurança.
create function app_private.resolve_steal_turn(p_pending app_private.pending_actions)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target uuid := p_pending.target_player_id;
  v_round smallint;
begin
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
end;
$$;

-- Troca simultânea: carta escolhida do autor x carta sorteada do alvo.
create function app_private.resolve_swap_card(p_pending app_private.pending_actions)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target uuid := p_pending.target_player_id;
  v_card uuid;
begin
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
end;
$$;

create function app_private.resolve_inspect_discard(p_pending app_private.pending_actions)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target uuid := p_pending.target_player_id;
begin
  if app_private.hand_size(v_target) = 0 then
    return true;
  end if;
  insert into app_private.pending_responses
    (pending_action_id, responder_player_id, role, stage, base_damage, choice_count, source_player_id)
  values (p_pending.id, p_pending.actor_player_id, 'actor_pick', 'choice', 0, 1, v_target);
  update app_private.pending_actions set stage = 'choice' where id = p_pending.id;
  return false;
end;
$$;

create function app_private.resolve_force_discard(p_pending app_private.pending_actions)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target uuid := p_pending.target_player_id;
  v_count integer;
begin
  v_count := least(coalesce((p_pending.effect_params ->> 'count')::int, 2), app_private.hand_size(v_target));
  if v_count = 0 then
    return true;
  end if;
  insert into app_private.pending_responses
    (pending_action_id, responder_player_id, role, stage, base_damage, choice_count, source_player_id)
  values (p_pending.id, v_target, 'target_discard', 'choice', 0, v_count, v_target);
  update app_private.pending_actions set stage = 'choice' where id = p_pending.id;
  return false;
end;
$$;

-- Bate e Joga: o alvo compra, quem jogou compra, e o alvo escolhe o descarte
-- (2, ou o que tiver). Mão vazia antes não impede: ele compra.
create function app_private.resolve_draw_force_discard(p_pending app_private.pending_actions)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target uuid := p_pending.target_player_id;
  v_count integer;
begin
  v_count := app_private.draw_cards(p_pending.game_id, v_target, 'main',
    coalesce((p_pending.effect_params ->> 'target_draw')::int, 1));
  perform app_private.log_event(p_pending.game_id, 'cards_drawn', v_target,
    jsonb_build_object('count', v_count, 'cardCode', p_pending.card_code));
  v_count := app_private.draw_cards(p_pending.game_id, p_pending.actor_player_id, 'main',
    coalesce((p_pending.effect_params ->> 'actor_draw')::int, 1));
  perform app_private.log_event(p_pending.game_id, 'cards_drawn', p_pending.actor_player_id,
    jsonb_build_object('count', v_count, 'cardCode', p_pending.card_code));

  return app_private.resolve_force_discard(p_pending);
end;
$$;

-- =============================================================================
-- after_damage, finish e choices
-- =============================================================================

-- A Braba: depois do ataque, quem jogou sofre o próprio dano. Se for fatal,
-- abre a etapa self_fatal (só sobreviver com 1 PV).
create function app_private.after_damage_self_damage(p_pending app_private.pending_actions)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor app_private.game_players;
  v_self integer;
begin
  select * into v_actor from app_private.game_players where id = p_pending.actor_player_id;
  if v_actor.life_status <> 'alive' then
    return true;
  end if;

  v_self := coalesce((p_pending.effect_params ->> 'self_damage')::int, 0);
  if v_self >= v_actor.hp then
    insert into app_private.pending_responses
      (pending_action_id, responder_player_id, role, stage, base_damage, credited_player_id)
    values (p_pending.id, v_actor.id, 'self', 'self_fatal', v_self, null);
    update app_private.pending_actions set stage = 'self_fatal' where id = p_pending.id;
    return false;
  end if;
  update app_private.game_players set hp = hp - v_self where id = v_actor.id;
  perform app_private.log_event(p_pending.game_id, 'self_damage', v_actor.id,
    jsonb_build_object('damage', v_self, 'hp', v_actor.hp - v_self, 'survived', false));
  return true;
end;
$$;

-- Bonde da Tempestade: cada sobrevivente compra, em ordem de lugar (quem
-- jogou compra self_draw; os outros, draw).
create function app_private.after_damage_storm_draw(p_pending app_private.pending_actions)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row record;
  v_drew integer;
  v_draws jsonb := '[]'::jsonb;
begin
  for v_row in
    select gp.id
    from app_private.game_players gp
    where gp.game_id = p_pending.game_id and gp.life_status = 'alive'
      and exists (
        select 1 from app_private.pending_responses r
        where r.pending_action_id = p_pending.id and r.responder_player_id = gp.id
      )
    order by gp.seat
  loop
    v_drew := app_private.draw_cards(p_pending.game_id, v_row.id, 'main',
      case when v_row.id = p_pending.actor_player_id
           then coalesce((p_pending.effect_params ->> 'self_draw')::int, 1)
           else coalesce((p_pending.effect_params ->> 'draw')::int, 1) end);
    v_draws := v_draws || jsonb_build_object('playerId', v_row.id, 'count', v_drew);
  end loop;

  perform app_private.log_event(p_pending.game_id, 'storm_draw', p_pending.actor_player_id,
    jsonb_build_object('cardCode', p_pending.card_code, 'draws', v_draws));
  return true;
end;
$$;

drop function app_private.storm_draw(app_private.pending_actions);

-- Ataque que compra: quem jogou compra ao fim, se continua vivo.
create function app_private.finish_draw_if_alive(p_pending app_private.pending_actions)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1 from app_private.game_players
    where id = p_pending.actor_player_id and life_status = 'alive'
  ) then
    perform app_private.draw_cards(p_pending.game_id, p_pending.actor_player_id, 'main',
      coalesce((p_pending.effect_params ->> 'draw')::int, 1));
  end if;
end;
$$;

-- Entrega simultânea: todos saem da mão antes de alguém receber, para
-- ninguém repassar a carta recém-recebida.
create function app_private.choices_pass_right(p_pending app_private.pending_actions)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cards uuid[];
  v_receivers uuid[];
begin
  select array_agg(r.selected_card_ids[1] order by gp.seat),
         array_agg(app_private.next_alive(p_pending.game_id, gp.seat) order by gp.seat)
    into v_cards, v_receivers
  from app_private.pending_responses r
  join app_private.game_players gp on gp.id = r.responder_player_id
  where r.pending_action_id = p_pending.id and r.role = 'pass_pick';

  if v_cards is not null then
    perform app_private.lift_cards(p_pending.game_id, v_cards);
    for i in 1..cardinality(v_cards) loop
      perform app_private.give_cards(array[v_cards[i]], v_receivers[i]);
    end loop;
    perform app_private.log_event(p_pending.game_id, 'cards_passed', p_pending.actor_player_id,
      jsonb_build_object('count', cardinality(v_cards)));
  end if;
end;
$$;

-- =============================================================================
-- Registro
-- =============================================================================

insert into app_private.card_effect_handlers (effect_code, hook, handler) values
  -- validate
  ('steal_random',         'validate',     'app_private.validate_target_has_cards'),
  ('inspect_discard',      'validate',     'app_private.validate_target_has_cards'),
  ('force_discard',        'validate',     'app_private.validate_target_has_cards'),
  ('swap_card',            'validate',     'app_private.validate_swap_card'),
  -- play: ataques
  ('damage',               'play',         'app_private.play_attack'),
  ('damage_split',         'play',         'app_private.play_attack'),
  ('damage_draw',          'play',         'app_private.play_attack'),
  ('damage_self',          'play',         'app_private.play_attack'),
  -- play: sabotagens
  ('steal_random',         'play',         'app_private.play_sabotage'),
  ('inspect_discard',      'play',         'app_private.play_sabotage'),
  ('mark_target',          'play',         'app_private.play_sabotage'),
  ('swap_card',            'play',         'app_private.play_sabotage'),
  ('force_discard',        'play',         'app_private.play_sabotage'),
  ('steal_turn',           'play',         'app_private.play_sabotage'),
  ('draw_force_discard',   'play',         'app_private.play_sabotage'),
  -- play: caos
  ('pass_right',           'play',         'app_private.play_pass_right'),
  ('all_discard',          'play',         'app_private.play_discard_round'),
  ('all_draw_discard',     'play',         'app_private.play_discard_round'),
  ('chaos_damage',         'play',         'app_private.play_chaos_damage'),
  ('chaos_storm',          'play',         'app_private.play_chaos_storm'),
  ('shuffle_hands',        'play',         'app_private.play_shuffle_hands'),
  -- play: recuperação e reviravolta
  ('heal',                 'play',         'app_private.play_heal'),
  ('heal_draw',            'play',         'app_private.play_heal'),
  ('draw_discard',         'play',         'app_private.play_draw_discard'),
  ('swap_hands',           'play',         'app_private.play_swap_hands'),
  -- play: Além
  ('ghost_random_discard', 'play',         'app_private.play_ghost_random_discard'),
  ('ghost_peek',           'play',         'app_private.play_ghost_peek'),
  ('ghost_bottom_deck',    'play',         'app_private.play_ghost_bottom_deck'),
  ('ghost_curse',          'play',         'app_private.play_ghost_curse'),
  ('ghost_peek_discard',   'play',         'app_private.play_ghost_peek_discard'),
  -- resolve
  ('steal_random',         'resolve',      'app_private.resolve_steal_random'),
  ('mark_target',          'resolve',      'app_private.resolve_mark_target'),
  ('steal_turn',           'resolve',      'app_private.resolve_steal_turn'),
  ('swap_card',            'resolve',      'app_private.resolve_swap_card'),
  ('inspect_discard',      'resolve',      'app_private.resolve_inspect_discard'),
  ('force_discard',        'resolve',      'app_private.resolve_force_discard'),
  ('draw_force_discard',   'resolve',      'app_private.resolve_draw_force_discard'),
  -- after_damage, finish, choices
  ('damage_self',          'after_damage', 'app_private.after_damage_self_damage'),
  ('chaos_storm',          'after_damage', 'app_private.after_damage_storm_draw'),
  ('damage_draw',          'finish',       'app_private.finish_draw_if_alive'),
  ('pass_right',           'choices',      'app_private.choices_pass_right');

-- =============================================================================
-- Núcleo (última cópia): sem nenhum efeito escrito à mão
-- =============================================================================

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
  v_max integer;
  v_cost_code text;
  v_validate regproc;
  v_play regproc;
  v_result jsonb;
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

  v_validate := app_private.effect_handler(v_def.effect_code, 'validate');
  v_play := app_private.effect_handler(v_def.effect_code, 'play');

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

  -- Regras próprias do efeito. Sem handler, a jogada não pode trazer carta
  -- própria para trocar (só quem valida sabe o que fazer com ela).
  if v_validate is not null then
    execute format('select %s($1, $2, $3, $4, $5, $6)', v_validate)
      using p_game, p_player, v_card, v_def, v_targets, p_command;
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

  if v_play is null then
    perform app_private.fail('NOT_AVAILABLE_YET', 'Essa carta ainda não pode ser jogada.');
  end if;

  -- Tudo válido: gasta a ação e paga o custo.
  perform app_private.consume_action(p_game.id, p_player.id);

  if v_cost_id is not null then
    select card_code into v_cost_code from app_private.game_cards where id = v_cost_id;
    perform app_private.discard_cards(p_game.id, p_player.id, array[v_cost_id]);
  end if;

  execute format('select %s($1, $2, $3, $4, $5, $6, $7)', v_play)
    into v_result
    using p_game, p_player, v_card, v_def, v_targets, p_command, v_cost_code;
  return v_result;
end;
$$;

create or replace function app_private.cmd_play_ghost_card(
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
  v_play regproc;
  v_result jsonb;
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

  v_play := app_private.effect_handler(v_def.effect_code, 'play');
  if v_play is null then
    perform app_private.fail('NOT_AVAILABLE_YET', 'Essa carta ainda não pode ser jogada.');
  end if;

  update app_private.games set actions_used = 1 where id = p_game.id;

  perform app_private.log_event(p_game.id, 'card_played', p_player.id,
    jsonb_build_object('cardCode', v_def.code,
      'targets', case when v_target is null then '[]'::jsonb
                      else jsonb_build_array(jsonb_build_object('playerId', v_target)) end));

  execute format('select %s($1, $2, $3, $4, $5, $6, $7)', v_play)
    into v_result
    using p_game, p_player, v_card, v_def, v_targets, p_command, null::text;
  return v_result;
end;
$$;

create or replace function app_private.resolve_sabotage(p_pending app_private.pending_actions)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_resolve regproc;
  v_done boolean;
begin
  if exists (
    select 1 from app_private.pending_responses
    where pending_action_id = p_pending.id and reaction_effect = 'block_sabotage'
  ) then
    perform app_private.log_event(p_pending.game_id, 'sabotage_blocked', p_pending.target_player_id,
      jsonb_build_object('cardCode', p_pending.card_code));
    return true;
  end if;

  v_resolve := app_private.effect_handler(p_pending.effect_code, 'resolve');
  if v_resolve is null then
    return true;
  end if;
  execute format('select %s($1)', v_resolve) into v_done using p_pending;
  return v_done;
end;
$$;

create or replace function app_private.resolve_pending(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pending app_private.pending_actions;
  v_redirector uuid;
  v_actor app_private.game_players;
  v_leader uuid;
  v_row app_private.pending_responses;
  v_new_hp integer;
  v_family text;
  v_after regproc;
  v_continue boolean;
begin
  select * into v_pending from app_private.pending_actions
  where game_id = p_game_id and status = 'open';

  if exists (
    select 1 from app_private.pending_responses
    where pending_action_id = v_pending.id and stage = v_pending.stage and response is null
  ) then
    return;
  end if;

  v_family := (
    select d.category from app_private.card_definitions d
    join app_private.games g on g.card_set_version = d.set_version
    where g.id = p_game_id and d.code = v_pending.card_code
  );
  v_after := app_private.effect_handler(v_pending.effect_code, 'after_damage');

  -- Escolhas de cartas (caos e o segundo passo de duas sabotagens).
  if v_pending.stage = 'choice' then
    perform app_private.apply_choices(v_pending);
    perform app_private.finish_pending(v_pending);
    return;
  end if;

  if v_family = 'sabotage' then
    if app_private.resolve_sabotage(v_pending) then
      perform app_private.finish_pending(v_pending);
    end if;
    return;
  end if;

  if v_family = 'chaos' then
    -- Dano de caos em lote (sem bônus nem defesa comum).
    perform app_private.apply_damage_batch(v_pending);
    if v_after is not null then
      execute format('select %s($1)', v_after) into v_continue using v_pending;
      if not v_continue then
        return;
      end if;
    end if;
    perform app_private.finish_pending(v_pending);
    return;
  end if;

  -- Ataques ---------------------------------------------------------------
  select * into v_actor from app_private.game_players where id = v_pending.actor_player_id;

  if v_pending.stage = 'defense' then
    select responder_player_id into v_redirector
    from app_private.pending_responses
    where pending_action_id = v_pending.id and reaction_effect = 'redirect_attack';

    if v_redirector is not null then
      v_leader := (select leader_player_id from app_private.games where id = p_game_id);
      insert into app_private.pending_responses
        (pending_action_id, responder_player_id, role, stage, base_damage, credited_player_id)
      values (
        v_pending.id, v_actor.id, 'counter', 'counter',
        coalesce((v_pending.effect_params ->> 'amount')::int, 0)
          + case when v_actor.id = v_leader then 1 else 0 end,
        v_redirector
      );
      update app_private.pending_actions set stage = 'counter' where id = v_pending.id;
      return;
    end if;
  end if;

  if v_pending.stage in ('defense', 'counter') then
    perform app_private.apply_damage_batch(v_pending);
    if v_after is not null then
      execute format('select %s($1)', v_after) into v_continue using v_pending;
      if not v_continue then
        return;
      end if;
    end if;
  elsif v_pending.stage = 'self_fatal' then
    select * into v_row from app_private.pending_responses
    where pending_action_id = v_pending.id and role = 'self';

    v_new_hp := v_actor.hp - v_row.base_damage;
    if v_new_hp <= 0 and v_row.reaction_effect = 'survive_fatal' then
      v_new_hp := 1;
    end if;
    v_new_hp := greatest(v_new_hp, 0);

    update app_private.game_players set hp = v_new_hp where id = v_actor.id;
    perform app_private.log_event(p_game_id, 'self_damage', v_actor.id,
      jsonb_build_object('damage', v_row.base_damage, 'hp', v_new_hp,
                         'survived', v_row.reaction_effect = 'survive_fatal'));

    if v_new_hp = 0 then
      perform app_private.kill_player(p_game_id, v_actor.id, null);
    end if;
  end if;

  perform app_private.finish_pending(v_pending);
end;
$$;

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
  v_finish regproc;
begin
  v_finish := app_private.effect_handler(p_pending.effect_code, 'finish');
  if v_finish is not null then
    execute format('select %s($1)', v_finish) using p_pending;
  end if;

  select * into v_actor from app_private.game_players where id = p_pending.actor_player_id;
  select * into v_card from app_private.game_cards where id = p_pending.card_instance_id;

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

create or replace function app_private.apply_choices(p_pending app_private.pending_actions)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row record;
  v_codes jsonb;
  v_choices regproc;
begin
  v_choices := app_private.effect_handler(p_pending.effect_code, 'choices');
  if v_choices is not null then
    execute format('select %s($1)', v_choices) using p_pending;
    return;
  end if;

  -- Padrão: as cartas escolhidas vão para o descarte (Terapia de Boteco,
  -- Plano Dental Negado, Bucetada, O Acre Existe!, Só Mais Uma!...).
  for v_row in
    select r.*, gp.seat
    from app_private.pending_responses r
    join app_private.game_players gp on gp.id = r.source_player_id
    where r.pending_action_id = p_pending.id and r.stage = 'choice'
    order by gp.seat
  loop
    select coalesce(jsonb_agg(c.card_code order by x.ord), '[]'::jsonb) into v_codes
    from unnest(v_row.selected_card_ids) with ordinality as x (id, ord)
    join app_private.game_cards c on c.id = x.id;

    perform app_private.discard_cards(p_pending.game_id, v_row.source_player_id, v_row.selected_card_ids);

    perform app_private.log_event(p_pending.game_id, 'cards_discarded', v_row.source_player_id,
      jsonb_build_object('codes', v_codes, 'chosenBy', v_row.responder_player_id,
                         'cardCode', p_pending.card_code));
  end loop;
end;
$$;
