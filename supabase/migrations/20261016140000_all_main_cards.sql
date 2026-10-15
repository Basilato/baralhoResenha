-- =============================================================================
-- Fase 7: sabotagem, caos, recuperação e reviravolta — 30 modelos jogáveis
-- =============================================================================
-- Reaproveita a jogada pendente da Fase 6, com dois tipos novos de resposta:
--   · reação (estágio "defense"): sabotage_target só aceita Evento Raro;
--     chaos_target só aceita reações de golpe fatal (B4)
--   · escolha de cartas (estágio "choice"): actor_pick (Terapia de Boteco),
--     target_discard (Plano Dental Negado), pass_pick (Tio Paulo) e
--     discard_pick (Bucetada, O Acre Existe!). Escolhas são privadas e
--     simultâneas; o efeito só acontece quando todos escolhem.
-- Recuperação e Lucboy & Laragirl resolvem na hora (não há reação possível).

-- -----------------------------------------------------------------------------
-- Estrutura
-- -----------------------------------------------------------------------------

alter table app_private.pending_actions
  drop constraint pending_actions_stage_check,
  add constraint pending_actions_stage_check
    check (stage in ('defense', 'counter', 'self_fatal', 'choice')),
  add column target_player_id uuid references app_private.game_players (id),
  add column own_card_id uuid references app_private.game_cards (id);

alter table app_private.pending_responses
  drop constraint pending_responses_role_check,
  add constraint pending_responses_role_check check (role in (
    'target', 'counter', 'self', 'sabotage_target', 'chaos_target',
    'actor_pick', 'target_discard', 'pass_pick', 'discard_pick'
  )),
  drop constraint pending_responses_stage_check,
  add constraint pending_responses_stage_check
    check (stage in ('defense', 'counter', 'self_fatal', 'choice')),
  drop constraint pending_responses_response_check,
  add constraint pending_responses_response_check
    check (response in ('pass', 'react', 'choose')),
  add column choice_count smallint,
  -- De quem são as cartas a escolher (Terapia de Boteco: mão do alvo).
  add column source_player_id uuid references app_private.game_players (id),
  add column selected_card_ids uuid[];

-- Efeitos temporários: marca do Tem Alguém Seguindo (e, na Fase 8, a
-- Maldição da Ressaca).
create table app_private.status_effects (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references app_private.games (id) on delete cascade,
  target_player_id uuid references app_private.game_players (id),
  type text not null check (type in ('mark', 'curse')),
  bonus smallint not null check (bonus > 0),
  source_player_id uuid references app_private.game_players (id),
  applied_round smallint not null,
  -- Vale até o fim desta rodada (inclusive).
  expires_after_round smallint not null,
  created_at timestamptz not null default now()
);

-- Marcas não acumulam: uma por alvo (a nova substitui).
create unique index status_effects_one_mark
  on app_private.status_effects (game_id, target_player_id) where type = 'mark';

alter table app_private.status_effects enable row level security;
revoke all on table app_private.status_effects from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Regras de reação (estende a Fase 6)
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
      array['block_attack', 'reduce_attack', 'reduce_attack_draw']
      || case when p_attack_effect in ('damage', 'damage_draw', 'damage_self')
              then array['redirect_attack'] else array[]::text[] end
      || case when p_base_damage >= p_hp
              then array['survive_fatal', 'last_word'] else array[]::text[] end
    when 'counter' then
      array['block_attack', 'reduce_attack', 'reduce_attack_draw']
    when 'self' then
      case when p_base_damage >= p_hp then array['survive_fatal'] else array[]::text[] end
    -- Evento Raro: só contra sabotagem direcionada.
    when 'sabotage_target' then array['block_sabotage']
    -- Família Basilato: sem defesa comum; só reação de golpe fatal (B4).
    when 'chaos_target' then
      case when p_base_damage >= p_hp
           then array['survive_fatal', 'last_word'] else array[]::text[] end
    else array[]::text[]
  end;
$$;

-- -----------------------------------------------------------------------------
-- Auxiliares
-- -----------------------------------------------------------------------------

create function app_private.hand_size(p_player_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer from app_private.game_cards
  where owner_player_id = p_player_id and zone = 'player_hand';
$$;

-- Move carta(s) para a mão de outro jogador, no fim da fila da mão dele.
create function app_private.give_cards(p_card_ids uuid[], p_to uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  foreach v_id in array coalesce(p_card_ids, array[]::uuid[]) loop
    update app_private.game_cards
    set owner_player_id = p_to,
        zone = 'player_hand',
        pile_position = coalesce((
          select max(pile_position) from app_private.game_cards
          where owner_player_id = p_to and zone = 'player_hand'
        ), 0) + 1
    where id = v_id;
  end loop;
end;
$$;

-- Tira cartas das mãos (para trocas simultâneas) com posições únicas.
create function app_private.lift_cards(p_game_id uuid, p_card_ids uuid[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_top integer;
begin
  select coalesce(max(pile_position), 0) into v_top
  from app_private.game_cards
  where game_id = p_game_id and zone = 'in_resolution' and owner_player_id is null;

  update app_private.game_cards c
  set owner_player_id = null, zone = 'in_resolution', pile_position = v_top + x.ord
  from unnest(p_card_ids) with ordinality as x (id, ord)
  where c.id = x.id;
end;
$$;

-- Próximo vivo "à direita" (sentido dos turnos, dando a volta).
create function app_private.next_alive(p_game_id uuid, p_seat smallint)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from app_private.game_players
  where game_id = p_game_id and life_status = 'alive' and seat <> p_seat
  order by (seat <= p_seat), seat
  limit 1;
$$;

-- Tira a carta jogada da mão e abre uma jogada pendente.
create function app_private.open_pending(
  p_game app_private.games,
  p_player app_private.game_players,
  p_card app_private.game_cards,
  p_def app_private.card_definitions,
  p_stage text,
  p_target uuid default null,
  p_own_card uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pending uuid;
  v_next integer;
begin
  select coalesce(max(pile_position), 0) + 1 into v_next
  from app_private.game_cards
  where game_id = p_game.id and zone = 'in_resolution' and owner_player_id is null;

  update app_private.game_cards
  set zone = 'in_resolution', owner_player_id = null, pile_position = v_next
  where id = p_card.id;

  insert into app_private.pending_actions
    (game_id, actor_player_id, card_instance_id, card_code, effect_code, effect_params, stage,
     target_player_id, own_card_id)
  values (p_game.id, p_player.id, p_card.id, p_def.code, p_def.effect_code, p_def.effect_params,
          p_stage, p_target, p_own_card)
  returning id into v_pending;

  update app_private.games
  set phase = 'awaiting_reactions', pending_action_id = v_pending
  where id = p_game.id;

  return v_pending;
end;
$$;

-- Carta de efeito imediato (sem janela): vai direto para o descarte.
create function app_private.discard_played(p_game_id uuid, p_card_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_next integer;
begin
  select coalesce(max(pile_position), 0) + 1 into v_next
  from app_private.game_cards where game_id = p_game_id and zone = 'main_discard';

  update app_private.game_cards
  set zone = 'main_discard', owner_player_id = null, pile_position = v_next
  where id = p_card_id;
end;
$$;

-- Cria as escolhas de descarte (1 carta) para cada vivo com mão não vazia.
create function app_private.open_discard_picks(p_pending_id uuid, p_game_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  insert into app_private.pending_responses
    (pending_action_id, responder_player_id, role, stage, base_damage, choice_count, source_player_id)
  select p_pending_id, gp.id, 'discard_pick', 'choice', 0, 1, gp.id
  from app_private.game_players gp
  where gp.game_id = p_game_id and gp.life_status = 'alive' and app_private.hand_size(gp.id) > 0;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- -----------------------------------------------------------------------------
-- Jogar carta: despachante por categoria
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

-- -----------------------------------------------------------------------------
-- Resolução
-- -----------------------------------------------------------------------------

-- Efeito da sabotagem depois da janela do Evento Raro.
create function app_private.resolve_sabotage(p_pending app_private.pending_actions)
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

-- Aplica todas as escolhas do estágio "choice" ao mesmo tempo.
create function app_private.apply_choices(p_pending app_private.pending_actions)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row record;
  v_codes jsonb;
  v_cards uuid[];
  v_receivers uuid[];
begin
  if p_pending.effect_code = 'pass_right' then
    -- Entrega simultânea: todos saem da mão antes de alguém receber, para
    -- ninguém repassar a carta recém-recebida.
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
    return;
  end if;

  -- Descartes (Terapia de Boteco, Plano Dental Negado, Bucetada, O Acre Existe!).
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
    -- Família Basilato: dano de caos em lote (sem bônus nem defesa comum).
    perform app_private.apply_damage_batch(v_pending);
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

-- O dano em lote passa a incluir a vítima da Família Basilato.
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
  v_actor app_private.game_players;
  v_set text := (select card_set_version from app_private.games where id = p_pending.game_id);
begin
  for v_row in
    select r.*, d.effect_params as reaction_params
    from app_private.pending_responses r
    left join app_private.card_definitions d on d.code = r.reaction_card_code and d.set_version = v_set
    where r.pending_action_id = p_pending.id and r.role in ('target', 'counter', 'chaos_target')
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
    where r.pending_action_id = p_pending.id and r.role in ('target', 'counter', 'chaos_target')
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
    where r.pending_action_id = p_pending.id and r.role in ('target', 'counter', 'chaos_target')
      and gp.hp = 0 and gp.life_status = 'alive'
    order by gp.seat
  loop
    perform app_private.kill_player(p_pending.game_id, v_row.responder_player_id, v_row.credited_player_id);
  end loop;

  for v_row in
    select r.responder_player_id, d.effect_params
    from app_private.pending_responses r
    join app_private.game_players gp on gp.id = r.responder_player_id
    join app_private.card_definitions d on d.code = r.reaction_card_code and d.set_version = v_set
    where r.pending_action_id = p_pending.id and r.reaction_effect = 'reduce_attack_draw'
      and gp.life_status = 'alive'
  loop
    perform app_private.draw_cards(p_pending.game_id, v_row.responder_player_id, 'main',
      coalesce((v_row.effect_params ->> 'draw')::int, 1));
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
-- Responder: agora também com escolha de cartas
-- -----------------------------------------------------------------------------

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
    if (select count(distinct x) from unnest(v_selected) as x) <> v_row.choice_count
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

-- -----------------------------------------------------------------------------
-- Fim de rodada: expira marcas (Ressaca entra na Fase 8)
-- -----------------------------------------------------------------------------

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

  -- Efeitos valem até o fim da rodada indicada.
  delete from app_private.status_effects
  where game_id = p_game_id and expires_after_round <= v_game.round_number;

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

-- -----------------------------------------------------------------------------
-- Visão: decisões de escolha e marcas
-- -----------------------------------------------------------------------------

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

-- Catálogo passa a informar o código de efeito (público; a tela usa para
-- montar o diálogo de cada carta).
create or replace function app_private.get_card_catalog(p_set_version text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app_private.require_user();

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'code', d.code,
        'name', d.name,
        'characterName', d.character_name,
        'category', d.category,
        'deckType', d.deck_type,
        'copies', d.copies,
        'targetRule', d.target_rule,
        'effectCode', d.effect_code,
        'isReaction', d.is_reaction,
        'discardCost', d.effect_params ? 'discard_cost',
        'rulesText', d.rules_text,
        'imagePath', d.image_path,
        'isProvisional', d.is_provisional
      )
      order by d.deck_type desc, d.code
    )
    from app_private.card_definitions d
    where d.set_version = coalesce(p_set_version, '7.1') and d.enabled
  ), '[]'::jsonb);
end;
$$;
