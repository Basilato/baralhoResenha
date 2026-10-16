-- =============================================================================
-- SAB-07 · Bate e Joga: o alvo compra 1 e descarta 2; quem jogou compra 1
-- =============================================================================
-- Regra:
--   · Sabotagem jogada no próprio turno (gasta 1 ação), mira 1 adversário
--     vivo. Evento Raro cancela tudo (ninguém compra nem descarta).
--   · Aceita: o alvo compra 1, quem jogou compra 1, e o alvo escolhe 2 cartas
--     da mão para descartar (ou todas, se tiver menos). Escolha privada,
--     descarte público, prazo de escolha normal; com escolha forçada, o banco
--     responde sozinho (G2).
--   · Pode mirar quem está sem cartas: ele compra 1 e descarta essa.
--   · Desenho: a proposta original (sem a compra de quem joga) ficava
--     estritamente pior que o Plano Dental Negado (SAB-05). Com a compra, a
--     diferença de cartas entre os dois é a mesma, mas a Bate e Joga renova a
--     mão de quem joga em vez de tirar mais do alvo.

insert into app_private.card_definitions
  (set_version, code, category, deck_type, name, character_name, copies,
   effect_code, effect_params, target_rule, is_reaction, rules_text, is_provisional)
values
  ('7.1', 'SAB-07', 'sabotage', 'main', 'Bate e Joga', 'Adeir e Victor', 4,
   'draw_force_discard', '{"target_draw": 1, "count": 2, "actor_draw": 1}', 'opponent', false,
   'Um adversário compra 1 carta e depois descarta 2, à escolha dele. Você compra 1.', false);

-- Partidas em andamento recebem as cópias novas no fundo do baralho, para a
-- conferência de integridade continuar batendo com o catálogo.
insert into app_private.game_cards (game_id, set_version, card_code, deck_type, zone, pile_position)
select g.id, '7.1', 'SAB-07', 'main', 'main_deck',
       coalesce((select min(c.pile_position) from app_private.game_cards c
                 where c.game_id = g.id and c.zone = 'main_deck'), 1) - n
from app_private.games g
cross join generate_series(1, 4) as n
where g.started_at is not null and g.card_set_version = '7.1'
  and not exists (
    select 1 from app_private.game_cards c where c.game_id = g.id and c.card_code = 'SAB-07'
  );

-- -----------------------------------------------------------------------------
-- Resolução da sabotagem (mesmo corpo, com o caso draw_force_discard)
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

    -- Bate e Joga: o alvo compra, quem jogou compra, e o alvo escolhe o
    -- descarte (2, ou o que tiver). Mão vazia antes não impede: ele compra.
    when 'draw_force_discard' then
      v_count := app_private.draw_cards(p_pending.game_id, v_target, 'main',
        coalesce((p_pending.effect_params ->> 'target_draw')::int, 1));
      perform app_private.log_event(p_pending.game_id, 'cards_drawn', v_target,
        jsonb_build_object('count', v_count, 'cardCode', p_pending.card_code));
      v_count := app_private.draw_cards(p_pending.game_id, p_pending.actor_player_id, 'main',
        coalesce((p_pending.effect_params ->> 'actor_draw')::int, 1));
      perform app_private.log_event(p_pending.game_id, 'cards_drawn', p_pending.actor_player_id,
        jsonb_build_object('count', v_count, 'cardCode', p_pending.card_code));

      v_count := least(coalesce((p_pending.effect_params ->> 'count')::int, 2), app_private.hand_size(v_target));
      if v_count = 0 then
        return true;
      end if;
      insert into app_private.pending_responses
        (pending_action_id, responder_player_id, role, stage, base_damage, choice_count, source_player_id)
      values (p_pending.id, v_target, 'target_discard', 'choice', 0, v_count, v_target);
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

revoke execute on function app_private.resolve_sabotage(app_private.pending_actions)
from public, anon, authenticated;
