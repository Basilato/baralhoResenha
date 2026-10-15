-- =============================================================================
-- Fase 6: ataques, defesas e reações
-- =============================================================================
-- Fluxo de uma jogada de ataque:
--   1. PLAY_CARD valida carta, alvos e custo, gasta a ação e abre uma janela
--      de reação (pending_actions + pending_responses) com o dano já fixado.
--   2. Cada alvo responde (RESPOND): passar ou usar uma reação permitida. O
--      botão de passar sempre existe, para não revelar quem tem defesa.
--   3. Reverso do Reverso devolve o ataque: o autor ganha uma contradefesa
--      simples (estágio "counter"), sem novo redirecionamento.
--   4. Com todas as respostas, o dano é aplicado em lote; mortes viram
--      fantasma; Última Palavra retalia; o dano próprio da A Braba vem por
--      último (B6) e, se for fatal, abre o estágio "self_fatal".
--   5. Quem morre no próprio turno perde o resto do turno (B5).

alter table app_private.games
  drop constraint games_phase_check,
  add constraint games_phase_check
    check (phase is null or phase in ('turn_main', 'turn_ghost', 'awaiting_reactions'));

create table app_private.pending_actions (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references app_private.games (id) on delete cascade,
  actor_player_id uuid not null references app_private.game_players (id),
  card_instance_id uuid not null references app_private.game_cards (id),
  card_code text not null,
  effect_code text not null,
  effect_params jsonb not null,
  stage text not null check (stage in ('defense', 'counter', 'self_fatal')),
  status text not null default 'open' check (status in ('open', 'resolved')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

-- No máximo uma jogada esperando resposta por partida.
create unique index pending_actions_one_open
  on app_private.pending_actions (game_id) where status = 'open';

create table app_private.pending_responses (
  pending_action_id uuid not null references app_private.pending_actions (id) on delete cascade,
  responder_player_id uuid not null references app_private.game_players (id),
  -- target: alvo do ataque · counter: autor recebendo o ataque devolvido ·
  -- self: autor sofrendo o dano próprio fatal da A Braba
  role text not null check (role in ('target', 'counter', 'self')),
  stage text not null check (stage in ('defense', 'counter', 'self_fatal')),
  base_damage smallint not null check (base_damage >= 0),
  -- Quem leva a eliminação se esse dano matar (null = ninguém).
  credited_player_id uuid references app_private.game_players (id),
  response text check (response in ('pass', 'react')),
  reaction_card_code text,
  reaction_effect text,
  final_damage smallint,
  responded_at timestamptz,
  primary key (pending_action_id, responder_player_id, role)
);

alter table app_private.pending_actions enable row level security;
alter table app_private.pending_responses enable row level security;
revoke all on table app_private.pending_actions from public, anon, authenticated;
revoke all on table app_private.pending_responses from public, anon, authenticated;

alter table app_private.games
  add column pending_action_id uuid references app_private.pending_actions (id);

-- -----------------------------------------------------------------------------
-- Regras de reação
-- -----------------------------------------------------------------------------

-- Efeitos de reação permitidos para quem está respondendo.
create function app_private.allowed_reactions(
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
      -- Reverso do Reverso só contra ataque individual.
      || case when p_attack_effect in ('damage', 'damage_draw', 'damage_self')
              then array['redirect_attack'] else array[]::text[] end
      -- Reações de dano fatal só quando o golpe mataria.
      || case when p_base_damage >= p_hp
              then array['survive_fatal', 'last_word'] else array[]::text[] end
    -- Contradefesa simples: sem redirecionar de novo (5.4, item 6).
    when 'counter' then
      array['block_attack', 'reduce_attack', 'reduce_attack_draw']
    -- Dano próprio da A Braba: só Ressuscitou o Tio Paulo (B6).
    when 'self' then
      case when p_base_damage >= p_hp then array['survive_fatal'] else array[]::text[] end
    else array[]::text[]
  end;
$$;

-- Dano final depois da reação (piso 0).
create function app_private.damage_after_reaction(
  p_base smallint,
  p_effect text,
  p_params jsonb
)
returns smallint
language sql
immutable
set search_path = ''
as $$
  select case p_effect
    when 'block_attack' then 0
    when 'redirect_attack' then 0
    when 'reduce_attack' then greatest(p_base - coalesce((p_params ->> 'amount')::int, 0), 0)
    when 'reduce_attack_draw' then greatest(p_base - coalesce((p_params ->> 'amount')::int, 0), 0)
    else p_base
  end::smallint;
$$;

create function app_private.json_uuid(p_value jsonb)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_value is null or p_value = 'null'::jsonb then
    return null;
  end if;
  return (p_value #>> '{}')::uuid;
exception
  when invalid_text_representation then
    perform app_private.fail('INVALID_COMMAND', 'Jogada inválida.');
    return null;
end;
$$;

-- -----------------------------------------------------------------------------
-- Morte e dano
-- -----------------------------------------------------------------------------

-- Vira fantasma: PV 0, cartas da mão principal para o descarte, eliminação
-- para quem causou (se houver).
create function app_private.kill_player(p_game_id uuid, p_victim uuid, p_credited uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hand uuid[];
begin
  update app_private.game_players
  set life_status = 'ghost', hp = 0
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

-- Aplica de uma vez (lote) o dano das respostas do estágio atual.
create function app_private.apply_damage_batch(p_pending app_private.pending_actions)
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
begin
  -- 1) Dano final de cada resposta.
  for v_row in
    select r.*, gp.hp, gp.seat, d.effect_params as reaction_params
    from app_private.pending_responses r
    join app_private.game_players gp on gp.id = r.responder_player_id
    left join app_private.card_definitions d
      on d.code = r.reaction_card_code
     and d.set_version = (select card_set_version from app_private.games where id = p_pending.game_id)
    where r.pending_action_id = p_pending.id and r.role in ('target', 'counter')
    order by gp.seat
  loop
    update app_private.pending_responses
    set final_damage = app_private.damage_after_reaction(v_row.base_damage, v_row.reaction_effect, v_row.reaction_params)
    where pending_action_id = p_pending.id
      and responder_player_id = v_row.responder_player_id
      and role = v_row.role;
  end loop;

  -- 2) PV de todos ao mesmo tempo (Ressuscitou o Tio Paulo segura em 1).
  for v_row in
    select r.*, gp.hp, gp.seat
    from app_private.pending_responses r
    join app_private.game_players gp on gp.id = r.responder_player_id
    where r.pending_action_id = p_pending.id and r.role in ('target', 'counter')
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

  -- 3) Mortes do lote (simultâneas).
  for v_row in
    select r.responder_player_id, r.credited_player_id
    from app_private.pending_responses r
    join app_private.game_players gp on gp.id = r.responder_player_id
    where r.pending_action_id = p_pending.id and r.role in ('target', 'counter')
      and gp.hp = 0 and gp.life_status = 'alive'
    order by gp.seat
  loop
    perform app_private.kill_player(p_pending.game_id, v_row.responder_player_id, v_row.credited_player_id);
  end loop;

  -- 4) Compras de reação (Último do After), só para quem sobreviveu.
  for v_row in
    select r.responder_player_id, d.effect_params
    from app_private.pending_responses r
    join app_private.game_players gp on gp.id = r.responder_player_id
    join app_private.card_definitions d
      on d.code = r.reaction_card_code
     and d.set_version = (select card_set_version from app_private.games where id = p_pending.game_id)
    where r.pending_action_id = p_pending.id and r.reaction_effect = 'reduce_attack_draw'
      and gp.life_status = 'alive'
  loop
    perform app_private.draw_cards(p_pending.game_id, v_row.responder_player_id, 'main',
      coalesce((v_row.effect_params ->> 'draw')::int, 1));
  end loop;

  -- 5) Última Palavra: cada alvo eliminado que a usou causa 2 no autor.
  select * into v_actor from app_private.game_players where id = p_pending.actor_player_id;

  if v_actor.life_status = 'alive' then
    select coalesce(sum(coalesce((d.effect_params ->> 'amount')::int, 2)), 0),
           (array_agg(r.responder_player_id order by gp.seat))[1]
      into v_retaliation, v_retaliator
    from app_private.pending_responses r
    join app_private.game_players gp on gp.id = r.responder_player_id
    join app_private.card_definitions d
      on d.code = r.reaction_card_code
     and d.set_version = (select card_set_version from app_private.games where id = p_pending.game_id)
    where r.pending_action_id = p_pending.id and r.reaction_effect = 'last_word'
      and gp.life_status = 'ghost';

    if v_retaliation > 0 then
      v_new_hp := greatest(v_actor.hp - v_retaliation, 0);
      update app_private.game_players set hp = v_new_hp where id = v_actor.id;

      perform app_private.log_event(p_pending.game_id, 'last_word', v_retaliator,
        jsonb_build_object('targetPlayerId', v_actor.id, 'damage', v_retaliation, 'hp', v_new_hp));

      -- Retaliação não admite reação; a eliminação vai para quem a usou
      -- (o primeiro em ordem de lugar, se mais de um).
      if v_new_hp = 0 then
        perform app_private.kill_player(p_pending.game_id, v_actor.id, v_retaliator);
      end if;
    end if;
  end if;
end;
$$;

-- Fecha a jogada: compra do Lor!, carta jogada para o descarte, fase de volta.
-- Se o autor morreu no próprio turno, o turno acaba na hora (B5).
create function app_private.finish_pending(p_pending app_private.pending_actions)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor app_private.game_players;
  v_next integer;
begin
  select * into v_actor from app_private.game_players where id = p_pending.actor_player_id;

  if p_pending.effect_code = 'damage_draw' and v_actor.life_status = 'alive' then
    perform app_private.draw_cards(p_pending.game_id, v_actor.id, 'main',
      coalesce((p_pending.effect_params ->> 'draw')::int, 1));
  end if;

  select coalesce(max(pile_position), 0) + 1 into v_next
  from app_private.game_cards where game_id = p_pending.game_id and zone = 'main_discard';

  update app_private.game_cards
  set zone = 'main_discard', owner_player_id = null, pile_position = v_next
  where id = p_pending.card_instance_id;

  update app_private.pending_actions
  set status = 'resolved', resolved_at = now()
  where id = p_pending.id;

  update app_private.games
  set pending_action_id = null, phase = 'turn_main'
  where id = p_pending.game_id;

  if v_actor.life_status <> 'alive' then
    perform app_private.log_event(p_pending.game_id, 'turn_ended', v_actor.id,
      jsonb_build_object('reason', 'died', 'discarded', '[]'::jsonb));
    perform app_private.advance_turn(p_pending.game_id);
  end if;
end;
$$;

-- Avança a jogada pendente quando o estágio atual tem todas as respostas.
create function app_private.resolve_pending(p_game_id uuid)
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
begin
  select * into v_pending from app_private.pending_actions
  where game_id = p_game_id and status = 'open';

  if exists (
    select 1 from app_private.pending_responses
    where pending_action_id = v_pending.id and stage = v_pending.stage and response is null
  ) then
    return;
  end if;

  select * into v_actor from app_private.game_players where id = v_pending.actor_player_id;

  if v_pending.stage = 'defense' then
    select responder_player_id into v_redirector
    from app_private.pending_responses
    where pending_action_id = v_pending.id and reaction_effect = 'redirect_attack';

    if v_redirector is not null then
      -- O ataque volta para o autor com o dano do próprio ataque (+1 se ele
      -- for o Mais Odiado). A eliminação, se houver, é de quem devolveu.
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

    -- B6: dano próprio da A Braba depois do ataque e das reações.
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
      -- Dano próprio não é eliminação de ninguém.
      perform app_private.kill_player(p_game_id, v_actor.id, null);
    end if;
  end if;

  perform app_private.finish_pending(v_pending);
end;
$$;

-- -----------------------------------------------------------------------------
-- Comandos
-- -----------------------------------------------------------------------------

create function app_private.cmd_play_card(
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
  v_targets uuid[] := app_private.jsonb_uuid_array(p_command -> 'targetPlayerIds');
  v_card app_private.game_cards;
  v_def app_private.card_definitions;
  v_opponents integer;
  v_max_hand integer;
  v_pending uuid;
  v_target uuid;
  v_amount integer;
  v_next integer;
  v_cost_code text;
  v_announced jsonb := '[]'::jsonb;
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

  if v_def.category <> 'attack' then
    perform app_private.fail('NOT_AVAILABLE_YET', 'Essa carta ainda não pode ser jogada nesta versão.');
  end if;

  -- Alvos: adversários vivos e distintos, conforme a regra da carta.
  select count(*) into v_opponents
  from app_private.game_players
  where game_id = p_game.id and life_status = 'alive' and id <> p_player.id;

  if v_opponents = 0 then
    perform app_private.fail('NO_VALID_TARGET', 'Não há adversário vivo para atacar.');
  end if;

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

  if v_def.target_rule = 'up_to_two_opponents' then
    if coalesce(cardinality(v_targets), 0) <> least(2, v_opponents) then
      perform app_private.fail('INVALID_TARGET',
        case when v_opponents >= 2 then 'Escolha 2 adversários diferentes.' else 'Escolha o adversário.' end);
    end if;
  elsif coalesce(cardinality(v_targets), 0) <> 1 then
    perform app_private.fail('INVALID_TARGET', 'Escolha 1 adversário.');
  end if;

  if v_def.target_rule = 'opponent_most_cards' then
    select max(n) into v_max_hand from (
      select count(c.id) as n
      from app_private.game_players gp
      left join app_private.game_cards c on c.owner_player_id = gp.id and c.zone = 'player_hand'
      where gp.game_id = p_game.id and gp.life_status = 'alive' and gp.id <> p_player.id
      group by gp.id
    ) x;
    if (select count(*) from app_private.game_cards
        where owner_player_id = v_targets[1] and zone = 'player_hand') <> v_max_hand then
      perform app_private.fail('INVALID_TARGET', 'O alvo precisa ser o adversário com mais cartas na mão.');
    end if;
  end if;

  -- Custo: descartar outra carta da mão (nunca a própria carta jogada).
  if v_def.effect_params ? 'discard_cost' then
    if v_cost_id is null or v_cost_id = v_card_id or not exists (
      select 1 from app_private.game_cards
      where id = v_cost_id and owner_player_id = p_player.id and zone = 'player_hand'
    ) then
      perform app_private.fail('COST_REQUIRED', 'Escolha outra carta da sua mão para descartar como custo.');
    end if;
  elsif v_cost_id is not null then
    perform app_private.fail('INVALID_COMMAND', 'Essa carta não tem custo.');
  end if;

  -- Tudo válido: gasta a ação, paga o custo e anuncia.
  perform app_private.consume_action(p_game.id, p_player.id);

  if v_cost_id is not null then
    select card_code into v_cost_code from app_private.game_cards where id = v_cost_id;
    perform app_private.discard_cards(p_game.id, p_player.id, array[v_cost_id]);
  end if;

  select coalesce(max(pile_position), 0) + 1 into v_next
  from app_private.game_cards
  where game_id = p_game.id and zone = 'in_resolution' and owner_player_id is null;

  update app_private.game_cards
  set zone = 'in_resolution', owner_player_id = null, pile_position = v_next
  where id = v_card.id;

  insert into app_private.pending_actions
    (game_id, actor_player_id, card_instance_id, card_code, effect_code, effect_params, stage)
  values (p_game.id, p_player.id, v_card.id, v_def.code, v_def.effect_code, v_def.effect_params, 'defense')
  returning id into v_pending;

  -- Dano fixado no anúncio: valor da carta + 1 se o alvo for o Mais Odiado.
  v_amount := coalesce((v_def.effect_params ->> 'amount')::int, 0);
  foreach v_target in array v_targets loop
    insert into app_private.pending_responses
      (pending_action_id, responder_player_id, role, stage, base_damage, credited_player_id)
    values (
      v_pending, v_target, 'target', 'defense',
      v_amount + case when v_target = p_game.leader_player_id then 1 else 0 end,
      p_player.id
    );
    v_announced := v_announced || jsonb_build_object(
      'playerId', v_target,
      'damage', v_amount + case when v_target = p_game.leader_player_id then 1 else 0 end
    );
  end loop;

  update app_private.games
  set phase = 'awaiting_reactions', pending_action_id = v_pending
  where id = p_game.id;

  perform app_private.log_event(p_game.id, 'card_played', p_player.id,
    jsonb_build_object('cardCode', v_def.code, 'targets', v_announced, 'costCode', v_cost_code));

  return jsonb_build_object('ok', true, 'pendingActionId', v_pending);
end;
$$;

create function app_private.cmd_respond(
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

  if v_choice = 'PASS' then
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

    -- A reação é revelada: vai para o descarte público.
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

  -- Responder a uma jogada não exige estar na vez; o resto exige.
  if v_type <> 'RESPOND' and v_player.seat is distinct from v_game.active_seat then
    perform app_private.fail('NOT_YOUR_TURN', 'Agora não é a sua vez.');
  end if;

  case v_type
    when 'END_TURN' then
      v_result := app_private.cmd_end_turn(v_game, v_player, p_command);
    when 'PLAY_CARD' then
      v_result := app_private.cmd_play_card(v_game, v_player, p_command);
    when 'RESPOND' then
      v_result := app_private.cmd_respond(v_game, v_player, p_command);
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
-- Visão: jogada pendente (pública) e decisão do próprio jogador (privada)
-- -----------------------------------------------------------------------------

create function app_private.pending_view(p_game_id uuid, p_player_id uuid)
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
        -- Quem respondeu aparece; o que respondeu só se for reação (pública).
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
        -- Só as cartas da minha mão que servem contra esta jogada.
        'eligibleCardIds', coalesce((
          select jsonb_agg(c.id order by c.pile_position)
          from app_private.game_cards c
          join app_private.card_definitions d on d.set_version = c.set_version and d.code = c.card_code
          where c.owner_player_id = p_player_id and c.zone = 'player_hand' and d.is_reaction
            and d.effect_code = any (app_private.allowed_reactions(r.role, pa.effect_code, r.base_damage, gp.hp))
        ), '[]'::jsonb)
      )
      from app_private.pending_actions pa
      join app_private.pending_responses r
        on r.pending_action_id = pa.id and r.stage = pa.stage and r.response is null
       and r.responder_player_id = p_player_id
      join app_private.game_players gp on gp.id = p_player_id
      where pa.game_id = p_game_id and pa.status = 'open'
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

  return app_private.game_view(p_game_id, v_uid) || app_private.pending_view(p_game_id, v_player);
end;
$$;

-- Catálogo informa se a carta exige descartar outra como custo (para a tela
-- pedir a carta de custo antes de enviar a jogada).
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
