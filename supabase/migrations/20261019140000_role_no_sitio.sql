-- =============================================================================
-- CAO-05 · Rolê no Sítio: junta, embaralha e redistribui as mãos dos vivos
-- =============================================================================
-- Regra:
--   · Caos jogado no próprio turno (gasta 1 ação), sem alvo: vale para todos os
--     vivos, inclusive quem jogou. Ninguém reage (caos não é ataque nem
--     sabotagem; Evento Raro não cancela, como em B3).
--   · A carta jogada vai para o descarte antes; depois as mãos principais de
--     todos os vivos são juntadas, embaralhadas no banco e redistribuídas.
--     Cada um fica com a mesma quantidade de cartas que tinha (mão vazia
--     continua vazia). Fantasmas e cartas do Além ficam de fora.
--   · Sigilo: cada um vê só a própria mão nova; o histórico mostra apenas
--     quantas cartas e quantos jogadores entraram.

insert into app_private.card_definitions
  (set_version, code, category, deck_type, name, character_name, copies,
   effect_code, effect_params, target_rule, is_reaction, rules_text, is_provisional)
values
  ('7.1', 'CAO-05', 'chaos', 'main', 'Rolê no Sítio', 'A Turma', 3,
   'shuffle_hands', '{}', 'all_alive', false,
   'Junte as mãos de todos os vivos (inclusive a sua), embaralhe e redistribua. Cada um fica com a mesma quantidade de cartas que tinha.',
   false);

-- Partidas em andamento recebem as cópias novas no fundo do baralho, para a
-- conferência de integridade continuar batendo com o catálogo.
insert into app_private.game_cards (game_id, set_version, card_code, deck_type, zone, pile_position)
select g.id, '7.1', 'CAO-05', 'main', 'main_deck',
       coalesce((select min(c.pile_position) from app_private.game_cards c
                 where c.game_id = g.id and c.zone = 'main_deck'), 1) - n
from app_private.games g
cross join generate_series(1, 3) as n
where g.started_at is not null and g.card_set_version = '7.1'
  and not exists (
    select 1 from app_private.game_cards c where c.game_id = g.id and c.card_code = 'CAO-05'
  );

-- -----------------------------------------------------------------------------
-- Embaralhar as mãos
-- -----------------------------------------------------------------------------

-- Tira todas as cartas das mãos dos vivos, embaralha e devolve em ordem de
-- lugar, cada um recebendo a quantidade que tinha.
create function app_private.shuffle_hands(p_game_id uuid, p_actor uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_counts integer[];
  v_players uuid[];
  v_cards uuid[];
  v_from integer := 1;
begin
  select array_agg(gp.id order by gp.seat), array_agg(app_private.hand_size(gp.id) order by gp.seat)
    into v_players, v_counts
  from app_private.game_players gp
  where gp.game_id = p_game_id and gp.life_status = 'alive';

  select coalesce(array_agg(c.id order by gen_random_uuid()), array[]::uuid[]) into v_cards
  from app_private.game_cards c
  where c.owner_player_id = any (v_players) and c.zone = 'player_hand';

  perform app_private.lift_cards(p_game_id, v_cards);

  for i in 1..coalesce(cardinality(v_players), 0) loop
    if v_counts[i] > 0 then
      perform app_private.give_cards(v_cards[v_from:v_from + v_counts[i] - 1], v_players[i]);
      v_from := v_from + v_counts[i];
    end if;
  end loop;

  perform app_private.log_event(p_game_id, 'hands_shuffled', p_actor,
    jsonb_build_object('count', cardinality(v_cards), 'players', cardinality(v_players)));
end;
$$;

revoke execute on function app_private.shuffle_hands(uuid, uuid) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Jogar carta (mesmo corpo, com o ramo shuffle_hands no caos)
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

    -- Rolê no Sítio: a carta jogada sai antes de juntar as mãos.
    if v_def.effect_code = 'shuffle_hands' then
      perform app_private.discard_played(p_game.id, v_card.id);
      perform app_private.shuffle_hands(p_game.id, p_player.id);
      return jsonb_build_object('ok', true);
    end if;

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
  -- Só Mais Uma!: compra e depois escolhe o descarte (pode ser uma das cartas
  -- recém-compradas). A carta jogada fica em resolução até a escolha, então
  -- não pode ser a descartada.
  if v_def.effect_code = 'draw_discard' then
    v_pending := app_private.open_pending(p_game, p_player, v_card, v_def, 'choice');
    perform app_private.log_event(p_game.id, 'card_played', p_player.id,
      jsonb_build_object('cardCode', v_def.code, 'targets', '[]'::jsonb));

    v_heal := coalesce((v_def.effect_params ->> 'amount')::int, 0);
    if v_heal > 0 then
      update app_private.game_players
      set hp = least(max_hp, hp + v_heal)
      where id = p_player.id
      returning hp into v_hp;
    end if;

    v_drew := app_private.draw_cards(p_game.id, p_player.id, 'main',
      coalesce((v_def.effect_params ->> 'draw')::int, 2));
    perform app_private.log_event(p_game.id, 'cards_drawn', p_player.id,
      jsonb_build_object('count', v_drew, 'cardCode', v_def.code));

    v_count := least(coalesce((v_def.effect_params ->> 'discard')::int, 1),
                     app_private.hand_size(p_player.id));
    if v_count > 0 then
      insert into app_private.pending_responses
        (pending_action_id, responder_player_id, role, stage, base_damage, choice_count, source_player_id)
      values (v_pending, p_player.id, 'discard_pick', 'choice', 0, v_count, p_player.id);
    end if;

    perform app_private.resolve_pending(p_game.id);
    return jsonb_build_object('ok', true, 'pendingActionId', v_pending);
  end if;

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
