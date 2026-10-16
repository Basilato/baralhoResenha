-- Fase 10: correção achada pelas simulações (pnpm sim).
--
-- A Braba derrubava o último rival na rodada 10 e a partida acabava ali, com
-- o dano próprio do autor ainda pendente: o autor vencia sem pagar o custo
-- (regra B6: resolver o alvo e DEPOIS o dano próprio) e a carta ficava presa
-- "em resolução".
--
-- 1. O fim antecipado (último vivo / todos caíram) espera a jogada pendente
--    terminar; a próxima resposta decide a partida.
-- 2. Por segurança, encerrar a partida devolve ao descarte qualquer carta
--    que ainda esteja em resolução.

create or replace function app_private.check_game_end(p_game_id uuid)
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

  -- Jogada no meio da resolução (ex.: dano próprio da A Braba): ainda não acabou.
  if (select pending_action_id from app_private.games where id = p_game_id) is not null then
    return false;
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

create or replace function app_private.finish_game(
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

  -- Nenhuma carta fica presa em resolução: vai para o descarte do seu baralho.
  update app_private.game_cards c
  set zone = app_private.pile_zone(c.deck_type, 'discard'),
      owner_player_id = null,
      pile_position = top.n + s.ord
  from (
    select id, deck_type, row_number() over (partition by deck_type order by pile_position) as ord
    from app_private.game_cards
    where game_id = p_game_id and zone = 'in_resolution'
  ) s
  join lateral (
    select coalesce(max(pile_position), 0) as n from app_private.game_cards
    where game_id = p_game_id and zone = app_private.pile_zone(s.deck_type, 'discard')
  ) top on true
  where c.id = s.id;

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
