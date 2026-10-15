-- =============================================================================
-- Revisão da Fase 3
-- =============================================================================

-- 1) Apagar uma conta não pode arrancar a pessoa de uma partida em andamento.
--    Contas são desativadas (pnpm users disable), não apagadas.
alter table app_private.game_players
  drop constraint game_players_user_id_fkey,
  add constraint game_players_user_id_fkey
    foreign key (user_id) references auth.users (id);

-- 2) O limite conta só salas de espera. Partidas em andamento ficam de fora:
--    ninguém sai de uma partida e só o host a encerra, então contá-las podia
--    deixar alguém preso sem conseguir criar ou entrar em salas.
create or replace function app_private.assert_room_quota(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('room-quota:' || p_user_id::text, 0));

  if (
    select count(*)
    from app_private.game_players gp
    join app_private.games g on g.id = gp.game_id
    where gp.user_id = p_user_id and g.status = 'lobby'
  ) >= 5 then
    perform app_private.fail(
      'TOO_MANY_ROOMS',
      'Você já está em 5 salas de espera. Saia ou encerre alguma antes.'
    );
  end if;
end;
$$;

-- 3) Tentativas antigas com código errado não precisam ficar guardadas.
create or replace function app_private.join_room(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_user();
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_invite app_private.game_invites;
  v_game app_private.games;
  v_seat smallint;
begin
  delete from app_private.join_failures
  where user_id = v_uid and created_at < now() - interval '1 day';

  if (
    select count(*) from app_private.join_failures
    where user_id = v_uid and created_at > now() - interval '10 minutes'
  ) >= 10 then
    perform app_private.fail(
      'TOO_MANY_ATTEMPTS',
      'Muitas tentativas com código errado. Espere alguns minutos.'
    );
  end if;

  select * into v_invite from app_private.game_invites where code = v_code;

  if not found then
    insert into app_private.join_failures (user_id) values (v_uid);
    return jsonb_build_object('error', 'INVALID_CODE');
  end if;

  select * into v_game from app_private.games where id = v_invite.game_id for update;

  -- Já é membro: idempotente (clique duplo, link aberto de novo, partida em curso).
  if app_private.is_game_member(v_game.id, v_uid) then
    return jsonb_build_object('gameId', v_game.id, 'status', v_game.status);
  end if;

  perform app_private.assert_lobby(v_game);
  perform app_private.assert_room_quota(v_uid);

  select min(s)::smallint into v_seat
  from generate_series(1, 8) as s
  where not exists (
    select 1 from app_private.game_players where game_id = v_game.id and seat = s
  );

  if v_seat is null then
    perform app_private.fail('ROOM_FULL', 'A sala já está cheia (8 pessoas).');
  end if;

  insert into app_private.game_players (game_id, user_id, seat)
  values (v_game.id, v_uid, v_seat);

  perform app_private.touch_game(v_game.id);

  return jsonb_build_object('gameId', v_game.id, 'status', v_game.status);
end;
$$;

-- 4) Tópico com o UUID em maiúsculas (URL digitada) também é aceito.
create or replace function app_private.can_use_game_topic(p_topic text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_topic is null
    or p_topic !~* '^game:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;

  return app_private.is_game_member(substr(p_topic, 6)::uuid, auth.uid());
end;
$$;
