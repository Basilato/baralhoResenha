-- Fase 10: verificação de integridade de uma partida.
--
-- Devolve a lista de violações (vazia = partida consistente). Usada pelas
-- simulações depois de cada jogada (scripts/simulate.mjs) e útil para
-- investigar partidas reais. Só lê; uso exclusivo do administrador.

create function app_private.check_game_integrity(p_game_id uuid)
returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_game app_private.games;
  v_problems text[] := '{}';
  v_count int;
  v_text text;
begin
  select * into v_game from app_private.games where id = p_game_id;
  if not found then
    return array['partida não existe'];
  end if;
  -- Sala que nunca começou (no lobby ou cancelada antes de iniciar) não tem cartas.
  if v_game.started_at is null then
    return v_problems;
  end if;

  -- Cartas: exatamente as cópias do catálogo, nem mais nem menos.
  select string_agg(format('%s: %s de %s', d.code, coalesce(c.n, 0), d.copies), ', ' order by d.code)
  into v_text
  from app_private.card_definitions d
  left join (
    select card_code, count(*)::int as n from app_private.game_cards
    where game_id = p_game_id group by card_code
  ) c on c.card_code = d.code
  where d.set_version = v_game.card_set_version and d.enabled
    and coalesce(c.n, 0) <> d.copies;
  if v_text is not null then
    v_problems := v_problems || ('cópias erradas: ' || v_text);
  end if;

  select count(*) into v_count from app_private.game_cards c
  where c.game_id = p_game_id
    and not exists (
      select 1 from app_private.card_definitions d
      where d.set_version = v_game.card_set_version and d.code = c.card_code and d.enabled
    );
  if v_count > 0 then
    v_problems := v_problems || format('%s cartas fora do catálogo', v_count);
  end if;

  -- Carta em mão: dono da mesma partida e no estado certo.
  select count(*) into v_count
  from app_private.game_cards c
  left join app_private.game_players p on p.id = c.owner_player_id
  where c.game_id = p_game_id and c.owner_player_id is not null
    and (p.id is null or p.game_id <> p_game_id
         or (c.zone = 'player_hand' and p.life_status <> 'alive')
         or (c.zone = 'ghost_hand' and p.life_status <> 'ghost'));
  if v_count > 0 then
    v_problems := v_problems || format('%s cartas na mão de quem não pode ter', v_count);
  end if;

  -- Carta "em resolução" só existe enquanto há jogada pendente.
  select count(*) into v_count from app_private.game_cards
  where game_id = p_game_id and zone = 'in_resolution';
  if v_count > 0 and v_game.pending_action_id is null then
    v_problems := v_problems || format('%s cartas em resolução sem jogada pendente', v_count);
  end if;

  -- Jogadores.
  select count(*) into v_count from app_private.game_players
  where game_id = p_game_id and life_status = 'alive' and hp < 1;
  if v_count > 0 then
    v_problems := v_problems || format('%s vivos com 0 PV', v_count);
  end if;

  select count(*) into v_count from app_private.game_players
  where game_id = p_game_id and life_status = 'ghost' and hp <> 0;
  if v_count > 0 then
    v_problems := v_problems || format('%s fantasmas com PV', v_count);
  end if;

  select count(*) into v_count from app_private.game_players
  where game_id = p_game_id and ghost_tokens > 3;
  if v_count > 0 then
    v_problems := v_problems || format('%s jogadores com mais de 3 fichas', v_count);
  end if;

  if v_game.leader_player_id is not null and not exists (
    select 1 from app_private.game_players
    where id = v_game.leader_player_id and game_id = p_game_id
  ) then
    v_problems := v_problems || 'Mais Odiado não é desta partida'::text;
  end if;

  -- Jogadas pendentes: no máximo uma aberta, e é a que a partida aponta.
  select count(*) into v_count from app_private.pending_actions
  where game_id = p_game_id and status = 'open';
  if v_count > 1 then
    v_problems := v_problems || format('%s jogadas pendentes abertas', v_count);
  end if;
  if v_game.pending_action_id is not null and not exists (
    select 1 from app_private.pending_actions
    where id = v_game.pending_action_id and game_id = p_game_id and status = 'open'
  ) then
    v_problems := v_problems || 'partida aponta para jogada pendente que não está aberta'::text;
  end if;
  if (v_game.pending_action_id is not null) <> (v_game.phase = 'awaiting_reactions') then
    v_problems := v_problems || format('fase %s não combina com a jogada pendente', v_game.phase);
  end if;

  -- Estado da partida.
  if v_game.status = 'playing' then
    if v_game.round_number < 1 or v_game.round_number > 10 then
      v_problems := v_problems || format('rodada %s fora de 1–10', v_game.round_number);
    end if;
    if v_game.phase is null then
      v_problems := v_problems || 'partida em andamento sem fase'::text;
    end if;
    select count(*) into v_count from app_private.game_players
    where game_id = p_game_id and seat = v_game.active_seat and life_status <> 'quit';
    if v_count <> 1 then
      v_problems := v_problems || format('lugar da vez (%s) sem jogador ativo', v_game.active_seat);
    elsif v_game.phase in ('turn_main', 'turn_ghost', 'ghost_decision') and not exists (
      select 1 from app_private.game_players
      where game_id = p_game_id and seat = v_game.active_seat
        and life_status = case when v_game.phase = 'turn_main' then 'alive' else 'ghost' end
    ) then
      v_problems := v_problems || format('fase %s não combina com quem está na vez', v_game.phase);
    end if;
  elsif v_game.status = 'finished' then
    if v_game.result_json is null then
      v_problems := v_problems || 'partida encerrada sem resultado'::text;
    end if;
    if v_game.pending_action_id is not null then
      v_problems := v_problems || 'partida encerrada com jogada pendente'::text;
    end if;
  end if;

  return v_problems;
end;
$$;

revoke all on function app_private.check_game_integrity(uuid) from public, anon, authenticated;

-- Definer: o service_role não usa o esquema app_private diretamente.
create function public.admin_check_game_integrity(p_game_id uuid)
returns text[] language sql stable security definer set search_path = ''
as $$ select app_private.check_game_integrity(p_game_id); $$;

revoke all on function public.admin_check_game_integrity(uuid) from public, anon, authenticated;
grant execute on function public.admin_check_game_integrity(uuid) to service_role;
