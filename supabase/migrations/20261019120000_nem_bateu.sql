-- =============================================================================
-- DEF-07 · Nem Bateu: reduz 2 e, se ainda sofrer dano, compra 2
-- =============================================================================
-- Regra:
--   · Reação de defesa contra ataque (alvo ou ataque devolvido pelo Reverso do
--     Reverso), como as outras defesas comuns. Não vale contra a Família
--     Basilato (caos, B4) nem contra sabotagem.
--   · Reduz em 2 o dano. Se o dano final ainda for maior que 0 e a pessoa
--     continuar viva, compra 2 cartas. Reduzido a 0: não compra.
--   · Desenho: o Último do After (DEF-06) reduz 2 e compra 1 sempre; a Nem
--     Bateu compra mais, mas só quando apanha. Vale mais contra pancada grande.
--   · A compra é pública no histórico (cards_drawn), como a do Só Mais Uma!.

insert into app_private.card_definitions
  (set_version, code, category, deck_type, name, character_name, copies,
   effect_code, effect_params, target_rule, is_reaction, rules_text, is_provisional)
values
  ('7.1', 'DEF-07', 'defense', 'main', 'Nem Bateu', 'Anna', 4,
   'reduce_attack_draw_if_hit', '{"amount": 2, "draw": 2}', 'attack_reaction', true,
   'Reação: reduz em 2 o dano de 1 ataque contra você. Se ainda sofrer dano, compre 2 cartas.', false);

-- Partidas em andamento recebem as cópias novas no fundo do baralho, para a
-- conferência de integridade continuar batendo com o catálogo.
insert into app_private.game_cards (game_id, set_version, card_code, deck_type, zone, pile_position)
select g.id, '7.1', 'DEF-07', 'main', 'main_deck',
       coalesce((select min(c.pile_position) from app_private.game_cards c
                 where c.game_id = g.id and c.zone = 'main_deck'), 1) - n
from app_private.games g
cross join generate_series(1, 4) as n
where g.started_at is not null and g.card_set_version = '7.1'
  and not exists (
    select 1 from app_private.game_cards c where c.game_id = g.id and c.card_code = 'DEF-07'
  );

-- -----------------------------------------------------------------------------
-- Reações permitidas (mesmo corpo, com a Nem Bateu entre as defesas comuns)
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
    else array[]::text[]
  end;
$$;

-- -----------------------------------------------------------------------------
-- Dano depois da reação (mesmo corpo, com a Nem Bateu)
-- -----------------------------------------------------------------------------

create or replace function app_private.damage_after_reaction(
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
    when 'reduce_attack_draw_if_hit' then greatest(p_base - coalesce((p_params ->> 'amount')::int, 0), 0)
    else p_base
  end::smallint;
$$;

-- -----------------------------------------------------------------------------
-- Dano em lote (mesmo corpo, com a compra condicional da Nem Bateu)
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
