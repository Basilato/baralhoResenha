-- =============================================================================
-- CAO-06 · Bonde da Tempestade: 1 de dano de caos em todos os vivos; depois
-- os sobreviventes compram (quem jogou compra 2, os outros 1)
-- =============================================================================
-- Regra:
--   · Caos jogado no próprio turno (gasta 1 ação), sem alvo: vale para todos os
--     vivos, inclusive quem jogou. Fantasmas ficam de fora.
--   · O dano é de caos, como o da Família Basilato (B4): não admite defesa
--     comum nem bônus do Mais Odiado. Quem cairia pode usar uma reação de
--     golpe fatal. Quem jogou só pode usar o Ressuscitou o Tio Paulo: a Última
--     Palavra contra si mesmo não faz sentido (papel chaos_self).
--   · Todos levam o dano no mesmo lote (mortes simultâneas, mesmo died_batch).
--     Os abates contam para quem jogou; a própria morte não conta.
--   · Depois do dano (e da Última Palavra, se houver), cada vivo compra em
--     ordem de lugar: quem jogou compra 2, os outros compram 1. Quem caiu não
--     compra; quem se salvou com 1 PV compra.
--   · Quem jogou e caiu perde o resto do turno (B5). Se todos caírem, vale o
--     desempate de "todos mortos".
--   · Balanceamento: com a compra de 1 para quem jogou, a carta só piorava a
--     mão dele em relação à dos outros (gasta ação e carta, todo mundo ganha
--     1). Comprando 2, o saldo de cartas fica igual ao dos adversários, e o
--     ganho de quem joga são os abates de quem estava com 1 PV.

insert into app_private.card_definitions
  (set_version, code, category, deck_type, name, character_name, copies,
   effect_code, effect_params, target_rule, is_reaction, rules_text, is_provisional)
values
  ('7.1', 'CAO-06', 'chaos', 'main', 'Bonde da Tempestade', 'Anna, Léo, Adeir, Manu, Victor e Artur', 3,
   'chaos_storm', '{"amount": 1, "draw": 1, "self_draw": 2}', 'all_alive', false,
   'Todos os vivos (inclusive você) sofrem 1 de dano de caos. Depois, você compra 2 cartas e cada outro sobrevivente compra 1.',
   false);

-- Partidas em andamento recebem as cópias novas no fundo do baralho, para a
-- conferência de integridade continuar batendo com o catálogo.
insert into app_private.game_cards (game_id, set_version, card_code, deck_type, zone, pile_position)
select g.id, '7.1', 'CAO-06', 'main', 'main_deck',
       coalesce((select min(c.pile_position) from app_private.game_cards c
                 where c.game_id = g.id and c.zone = 'main_deck'), 1) - n
from app_private.games g
cross join generate_series(1, 3) as n
where g.started_at is not null and g.card_set_version = '7.1'
  and not exists (
    select 1 from app_private.game_cards c where c.game_id = g.id and c.card_code = 'CAO-06'
  );

-- Quem jogou também sofre o dano, com papel próprio.
alter table app_private.pending_responses
  drop constraint pending_responses_role_check,
  add constraint pending_responses_role_check check (role in (
    'target', 'counter', 'self', 'sabotage_target', 'chaos_target', 'chaos_self',
    'actor_pick', 'target_discard', 'pass_pick', 'discard_pick'
  ));

-- -----------------------------------------------------------------------------
-- Reações permitidas (mesmo corpo, com o chaos_self)
-- -----------------------------------------------------------------------------

create or replace function app_private.allowed_reactions(
  p_role text,
  p_attack_effect text,
  p_base_damage smallint,
  p_hp smallint
)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select case p_role
    when 'target' then
      array['block_attack', 'reduce_attack', 'reduce_attack_draw', 'reduce_attack_draw_if_hit']
      || case when p_attack_effect in ('damage', 'damage_draw', 'damage_self')
              then array['redirect_attack'] else array[]::text[] end
      || case when p_base_damage >= p_hp
              then array['survive_fatal', 'last_word'] else array[]::text[] end
    when 'counter' then
      array['block_attack', 'reduce_attack', 'reduce_attack_draw', 'reduce_attack_draw_if_hit']
    when 'self' then
      case when p_base_damage >= p_hp then array['survive_fatal'] else array[]::text[] end
    -- Evento Raro: só contra sabotagem direcionada.
    when 'sabotage_target' then array['block_sabotage']
    -- Família Basilato: sem defesa comum; só reação de golpe fatal (B4).
    when 'chaos_target' then
      case when p_base_damage >= p_hp
           then array['survive_fatal', 'last_word'] else array[]::text[] end
    -- Bonde da Tempestade em quem jogou: só sobreviver com 1 PV.
    when 'chaos_self' then
      case when p_base_damage >= p_hp then array['survive_fatal'] else array[]::text[] end
    else array[]::text[]
  end;
$$;

-- -----------------------------------------------------------------------------
-- Dano em lote (mesmo corpo, com o chaos_self entre os atingidos)
-- -----------------------------------------------------------------------------

create or replace function app_private.apply_damage_batch(p_pending app_private.pending_actions)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row record;
  v_results jsonb := '[]'::jsonb;
  v_new_hp integer;
  v_retaliation integer := 0;
  v_retaliator uuid;
  v_drew integer;
  v_actor app_private.game_players;
  v_set text := (select card_set_version from app_private.games where id = p_pending.game_id);
begin
  for v_row in
    select r.*, d.effect_params as reaction_params
    from app_private.pending_responses r
    left join app_private.card_definitions d on d.code = r.reaction_card_code and d.set_version = v_set
    where r.pending_action_id = p_pending.id and r.role in ('target', 'counter', 'chaos_target', 'chaos_self')
  loop
    update app_private.pending_responses
    set final_damage = app_private.damage_after_reaction(v_row.base_damage, v_row.reaction_effect, v_row.reaction_params)
    where pending_action_id = p_pending.id
      and responder_player_id = v_row.responder_player_id
      and role = v_row.role;
  end loop;

  for v_row in
    select r.*, gp.hp, gp.seat
    from app_private.pending_responses r
    join app_private.game_players gp on gp.id = r.responder_player_id
    where r.pending_action_id = p_pending.id and r.role in ('target', 'counter', 'chaos_target', 'chaos_self')
    order by gp.seat
  loop
    v_new_hp := v_row.hp - v_row.final_damage;
    if v_new_hp <= 0 and v_row.reaction_effect = 'survive_fatal' then
      v_new_hp := 1;
    end if;
    v_new_hp := greatest(v_new_hp, 0);

    update app_private.game_players set hp = v_new_hp where id = v_row.responder_player_id;

    v_results := v_results || jsonb_build_object(
      'playerId', v_row.responder_player_id,
      'damage', v_row.final_damage,
      'hp', v_new_hp,
      'survived', v_row.reaction_effect = 'survive_fatal' and v_row.hp - v_row.final_damage <= 0
    );
  end loop;

  perform app_private.log_event(p_pending.game_id, 'damage_dealt', p_pending.actor_player_id,
    jsonb_build_object('cardCode', p_pending.card_code, 'results', v_results));

  for v_row in
    select r.responder_player_id, r.credited_player_id
    from app_private.pending_responses r
    join app_private.game_players gp on gp.id = r.responder_player_id
    where r.pending_action_id = p_pending.id and r.role in ('target', 'counter', 'chaos_target', 'chaos_self')
      and gp.hp = 0 and gp.life_status = 'alive'
    order by gp.seat
  loop
    perform app_private.kill_player(p_pending.game_id, v_row.responder_player_id, v_row.credited_player_id);
  end loop;

  -- Último do After compra sempre; Nem Bateu só se ainda sofreu dano.
  for v_row in
    select r.responder_player_id, r.reaction_effect, r.reaction_card_code, d.effect_params
    from app_private.pending_responses r
    join app_private.game_players gp on gp.id = r.responder_player_id
    join app_private.card_definitions d on d.code = r.reaction_card_code and d.set_version = v_set
    where r.pending_action_id = p_pending.id
      and (r.reaction_effect = 'reduce_attack_draw'
           or (r.reaction_effect = 'reduce_attack_draw_if_hit' and r.final_damage > 0))
      and gp.life_status = 'alive'
  loop
    v_drew := app_private.draw_cards(p_pending.game_id, v_row.responder_player_id, 'main',
      coalesce((v_row.effect_params ->> 'draw')::int, 1));
    if v_row.reaction_effect = 'reduce_attack_draw_if_hit' then
      perform app_private.log_event(p_pending.game_id, 'cards_drawn', v_row.responder_player_id,
        jsonb_build_object('count', v_drew, 'cardCode', v_row.reaction_card_code));
    end if;
  end loop;

  select * into v_actor from app_private.game_players where id = p_pending.actor_player_id;

  if v_actor.life_status = 'alive' then
    select coalesce(sum(coalesce((d.effect_params ->> 'amount')::int, 2)), 0),
           (array_agg(r.responder_player_id order by gp.seat))[1]
      into v_retaliation, v_retaliator
    from app_private.pending_responses r
    join app_private.game_players gp on gp.id = r.responder_player_id
    join app_private.card_definitions d on d.code = r.reaction_card_code and d.set_version = v_set
    where r.pending_action_id = p_pending.id and r.reaction_effect = 'last_word'
      and gp.life_status = 'ghost';

    if v_retaliation > 0 then
      v_new_hp := greatest(v_actor.hp - v_retaliation, 0);
      update app_private.game_players set hp = v_new_hp where id = v_actor.id;

      perform app_private.log_event(p_pending.game_id, 'last_word', v_retaliator,
        jsonb_build_object('targetPlayerId', v_actor.id, 'damage', v_retaliation, 'hp', v_new_hp));

      if v_new_hp = 0 then
        perform app_private.kill_player(p_pending.game_id, v_actor.id, v_retaliator);
      end if;
    end if;
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Compra dos sobreviventes
-- -----------------------------------------------------------------------------

-- Em ordem de lugar, só quem foi atingido e continua vivo. Pública: o
-- histórico mostra quantas cartas cada um comprou.
create function app_private.storm_draw(p_pending app_private.pending_actions)
returns void
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
end;
$$;

revoke execute on function app_private.storm_draw(app_private.pending_actions) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Resolver a jogada (mesmo corpo, com a compra do Bonde depois do dano)
-- -----------------------------------------------------------------------------

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
  v_self integer;
  v_row app_private.pending_responses;
  v_new_hp integer;
  v_family text;
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
    -- Família Basilato e Bonde: dano de caos em lote (sem bônus nem defesa comum).
    perform app_private.apply_damage_batch(v_pending);
    if v_pending.effect_code = 'chaos_storm' then
      perform app_private.storm_draw(v_pending);
    end if;
    perform app_private.finish_pending(v_pending);
    return;
  end if;

  -- Ataques (Fase 6) ------------------------------------------------------
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
    select * into v_actor from app_private.game_players where id = v_actor.id;

    if v_pending.effect_code = 'damage_self' and v_actor.life_status = 'alive' then
      v_self := coalesce((v_pending.effect_params ->> 'self_damage')::int, 0);
      if v_self >= v_actor.hp then
        insert into app_private.pending_responses
          (pending_action_id, responder_player_id, role, stage, base_damage, credited_player_id)
        values (v_pending.id, v_actor.id, 'self', 'self_fatal', v_self, null);
        update app_private.pending_actions set stage = 'self_fatal' where id = v_pending.id;
        return;
      end if;
      update app_private.game_players set hp = hp - v_self where id = v_actor.id;
      perform app_private.log_event(p_game_id, 'self_damage', v_actor.id,
        jsonb_build_object('damage', v_self, 'hp', v_actor.hp - v_self, 'survived', false));
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

-- -----------------------------------------------------------------------------
-- Jogar carta (mesmo corpo, com o ramo chaos_storm no caos)
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

    -- Bonde da Tempestade: todos os vivos levam o dano no mesmo lote. Só quem
    -- cairia responde (reação de golpe fatal); o resto já entra como passe.
    if v_def.effect_code = 'chaos_storm' then
      v_pending := app_private.open_pending(p_game, p_player, v_card, v_def, 'defense');
      v_amount := coalesce((v_def.effect_params ->> 'amount')::int, 0);
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
