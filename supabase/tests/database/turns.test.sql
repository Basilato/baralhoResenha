-- Fase 5: motor de turnos.
begin;
create extension if not exists pgtap with schema extensions;

select plan(41);

create function pg_temp.login(p_uid text)
returns void
language plpgsql
as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', '00000000-0000-4000-8000-00000000000' || p_uid, 'role', 'authenticated')::text,
    true
  );
end;
$$;

create function pg_temp.uid(p_n text) returns uuid language sql
as $$ select ('00000000-0000-4000-8000-00000000000' || p_n)::uuid $$;

create temp table t (k text primary key, v text);
create function pg_temp.v(p_k text) returns text language sql stable as $$ select v from t where k = p_k $$;

create function pg_temp.started_game(p_users text[])
returns uuid
language plpgsql
as $$
declare
  v_game uuid;
  v_code text;
  v_user text;
begin
  perform pg_temp.login(p_users[1]);
  v_game := (public.create_room() ->> 'id')::uuid;
  v_code := public.get_room_view(v_game) ->> 'code';
  foreach v_user in array p_users[2:] loop
    perform set_config('role', 'postgres', true);
    perform pg_temp.login(v_user);
    perform public.join_room(v_code);
  end loop;
  perform set_config('role', 'postgres', true);
  perform pg_temp.login(p_users[1]);
  perform public.start_game(v_game, (public.get_room_view(v_game) ->> 'version')::bigint);
  perform set_config('role', 'postgres', true);
  return v_game;
end;
$$;

-- Número do usuário (teste<N>) que está no lugar indicado.
create function pg_temp.user_at(p_game uuid, p_seat int) returns text language sql
as $$ select substr(user_id::text, 36) from app_private.game_players where game_id = p_game and seat = p_seat $$;

create function pg_temp.player_at(p_game uuid, p_seat int) returns uuid language sql
as $$ select id from app_private.game_players where game_id = p_game and seat = p_seat $$;

create function pg_temp.version(p_game uuid) returns bigint language sql
as $$ select version from app_private.games where id = p_game $$;

-- Envia um comando como o usuário N e volta a ser postgres.
create function pg_temp.cmd(p_user text, p_game uuid, p_command jsonb, p_request uuid default gen_random_uuid(),
                            p_version bigint default null)
returns jsonb
language plpgsql
as $$
declare
  v_version bigint := coalesce(p_version, pg_temp.version(p_game));
  v_result jsonb;
begin
  perform pg_temp.login(p_user);
  v_result := public.submit_game_command(p_game, v_version, p_request, p_command);
  perform set_config('role', 'postgres', true);
  return v_result;
end;
$$;

-- Encerra o turno de quem está jogando, descartando o excedente mais antigo.
create function pg_temp.end_turn_auto(p_game uuid)
returns void
language plpgsql
as $$
declare
  v_seat int := (select active_seat from app_private.games where id = p_game);
  v_player uuid := pg_temp.player_at(p_game, v_seat);
  v_ghost boolean := (select life_status = 'ghost' from app_private.game_players where id = v_player);
  v_zone text := case when v_ghost then 'ghost_hand' else 'player_hand' end;
  v_limit int := case when v_ghost then 3 else 7 end;
  v_ids jsonb;
begin
  -- Fantasma com 3 fichas decide antes: aqui ele continua fantasma.
  if (select phase from app_private.games where id = p_game) = 'ghost_decision' then
    perform pg_temp.cmd(pg_temp.user_at(p_game, v_seat), p_game, '{"type": "GHOST_STAY"}'::jsonb);
  end if;
  select coalesce(jsonb_agg(id), '[]'::jsonb) into v_ids from (
    select id from app_private.game_cards
    where owner_player_id = v_player and zone = v_zone
    order by pile_position
    limit greatest((select count(*) from app_private.game_cards
                    where owner_player_id = v_player and zone = v_zone) - v_limit, 0)
  ) x;
  perform pg_temp.cmd(pg_temp.user_at(p_game, v_seat), p_game,
    jsonb_build_object('type', 'END_TURN', 'discardCardIds', v_ids));
end;
$$;

-- Partida de 3 ---------------------------------------------------------------

insert into t values ('g', pg_temp.started_game(array['1', '2', '3'])::text);

select results_eq(
  format($$ select phase, round_number, active_seat::int, actions_used::int, leader_player_id
            from app_private.games where id = %L $$, pg_temp.v('g')),
  $$ values ('turn_main'::text, 1, 1, 0, null::uuid) $$,
  'rodada 1: lugar 1 joga, nenhuma ação usada, sem Mais Odiado (PV empatados)');

select is(
  (select array_agg(kind order by seq) from app_private.game_events where game_id = pg_temp.v('g')::uuid),
  array['game_started', 'round_started', 'turn_started'],
  'eventos de início registrados em ordem');

select is(
  (select (public_payload ->> 'drew')::int from app_private.game_events
   where game_id = pg_temp.v('g')::uuid and kind = 'turn_started'),
  2, 'o lugar 1 compra 2 no primeiro turno (A3)');

-- Validações -----------------------------------------------------------------

select throws_ok(
  format($$ select pg_temp.cmd(%L, %L, '{"type": "END_TURN"}') $$,
         pg_temp.user_at(pg_temp.v('g')::uuid, 2), pg_temp.v('g')),
  'P0001', 'NOT_YOUR_TURN', 'quem não está na vez não joga');
reset role;

select throws_ok(
  format($$ select pg_temp.cmd(%L, %L, '{"type": "END_TURN"}', gen_random_uuid(), 1) $$,
         pg_temp.user_at(pg_temp.v('g')::uuid, 1), pg_temp.v('g')),
  'P0001', 'VERSION_CONFLICT', 'versão desatualizada é recusada');
reset role;

select throws_ok(
  format($$ select pg_temp.cmd(%L, %L, '{"type": "ROUBAR"}') $$,
         pg_temp.user_at(pg_temp.v('g')::uuid, 1), pg_temp.v('g')),
  'P0001', 'INVALID_COMMAND', 'comando desconhecido é recusado');
reset role;

select throws_ok(
  format($$ select pg_temp.cmd(%L, %L, '{"type": "END_TURN", "discardCardIds": ["nao-e-uuid"]}') $$,
         pg_temp.user_at(pg_temp.v('g')::uuid, 1), pg_temp.v('g')),
  'P0001', 'INVALID_COMMAND', 'lista de cartas malformada é recusada');
reset role;

select is((select active_seat::int from app_private.games where id = pg_temp.v('g')::uuid), 1,
  'jogadas recusadas não mudam o estado');

-- Encerrar turno e idempotência ----------------------------------------------

insert into t values ('req1', gen_random_uuid()::text);
insert into t values ('ver_before', pg_temp.version(pg_temp.v('g')::uuid)::text);

select ok(
  (pg_temp.cmd(pg_temp.user_at(pg_temp.v('g')::uuid, 1), pg_temp.v('g')::uuid,
     '{"type": "END_TURN"}', pg_temp.v('req1')::uuid) ->> 'ok')::boolean,
  'lugar 1 encerra o turno com 7 cartas sem descartar');

select is((select active_seat::int from app_private.games where id = pg_temp.v('g')::uuid), 2,
  'a vez passa para o lugar 2');
select is(
  (select count(*)::int from app_private.game_cards
   where owner_player_id = pg_temp.player_at(pg_temp.v('g')::uuid, 2) and zone = 'player_hand'),
  7, 'lugar 2 comprou 2 ao começar o turno');
insert into t values ('ver_after', pg_temp.version(pg_temp.v('g')::uuid)::text);

select ok(
  (pg_temp.cmd(pg_temp.user_at(pg_temp.v('g')::uuid, 1), pg_temp.v('g')::uuid,
     '{"type": "END_TURN"}', pg_temp.v('req1')::uuid, pg_temp.v('ver_before')::bigint) ->> 'replayed')::boolean,
  'mesmo request_id devolve o resultado anterior');
select is((select active_seat::int from app_private.games where id = pg_temp.v('g')::uuid), 2,
  'repetição não aplica a jogada de novo');
select is(pg_temp.version(pg_temp.v('g')::uuid)::text, pg_temp.v('ver_after'),
  'repetição não muda a versão');

-- Limite de 7 ----------------------------------------------------------------

select app_private.draw_cards(pg_temp.v('g')::uuid, pg_temp.player_at(pg_temp.v('g')::uuid, 2), 'main', 2);

select throws_ok(
  format($$ select pg_temp.cmd(%L, %L, '{"type": "END_TURN"}') $$,
         pg_temp.user_at(pg_temp.v('g')::uuid, 2), pg_temp.v('g')),
  'P0001', 'WRONG_DISCARD_COUNT', 'com 9 cartas não encerra sem descartar 2');
reset role;

insert into t
select 'two', jsonb_agg(id)::text from (
  select id from app_private.game_cards
  where owner_player_id = pg_temp.player_at(pg_temp.v('g')::uuid, 2) and zone = 'player_hand'
  order by pile_position limit 2) x;
insert into t
select 'two_codes', jsonb_agg(card_code order by pile_position)::text from app_private.game_cards
where id in (select (jsonb_array_elements_text(pg_temp.v('two')::jsonb))::uuid);

select lives_ok(
  format($$ select pg_temp.cmd(%L, %L, jsonb_build_object('type', 'END_TURN', 'discardCardIds', %L::jsonb)) $$,
         pg_temp.user_at(pg_temp.v('g')::uuid, 2), pg_temp.v('g'), pg_temp.v('two')),
  'descartando as 2 excedentes o turno encerra');
reset role;

select is(
  (select count(*)::int from app_private.game_cards
   where owner_player_id = pg_temp.player_at(pg_temp.v('g')::uuid, 2) and zone = 'player_hand'),
  7, 'mão fica com 7');
select is(
  (select public_payload -> 'discarded' from app_private.game_events
   where game_id = pg_temp.v('g')::uuid and kind = 'turn_ended' order by seq desc limit 1),
  pg_temp.v('two_codes')::jsonb, 'histórico mostra as cartas descartadas (públicas)');

-- Ações (usadas pelas cartas na Fase 6) --------------------------------------

select is(app_private.consume_action(pg_temp.v('g')::uuid, pg_temp.player_at(pg_temp.v('g')::uuid, 3))::int, 1,
  'primeira ação do turno');
select is(app_private.consume_action(pg_temp.v('g')::uuid, pg_temp.player_at(pg_temp.v('g')::uuid, 3))::int, 2,
  'segunda ação do turno');
select throws_ok(
  format('select app_private.consume_action(%L, %L)', pg_temp.v('g'), pg_temp.player_at(pg_temp.v('g')::uuid, 3)),
  'P0001', 'NO_ACTIONS_LEFT', 'não existe terceira ação');
select throws_ok(
  format('select app_private.consume_action(%L, %L)', pg_temp.v('g'), pg_temp.player_at(pg_temp.v('g')::uuid, 1)),
  'P0001', 'NOT_YOUR_TURN', 'quem não está na vez não gasta ação');

-- Fim da rodada e Mais Odiado ------------------------------------------------

update app_private.game_players set hp = case seat when 1 then 16 when 2 then 12 else 14 end
where game_id = pg_temp.v('g')::uuid;

select pg_temp.end_turn_auto(pg_temp.v('g')::uuid);

select results_eq(
  format($$ select round_number, active_seat::int, actions_used::int, leader_player_id
            from app_private.games where id = %L $$, pg_temp.v('g')),
  format($$ values (2, 1, 0, %L::uuid) $$, pg_temp.player_at(pg_temp.v('g')::uuid, 1)),
  'rodada 2 começa no lugar 1, ações zeradas e Mais Odiado = maior PV único');

-- Fantasma tem turno ---------------------------------------------------------

update app_private.game_players set life_status = 'ghost', hp = 0
where id = pg_temp.player_at(pg_temp.v('g')::uuid, 2);
update app_private.game_cards c
set zone = 'main_discard', owner_player_id = null, pile_position = 5000 + s.n
from (select id, row_number() over () as n from app_private.game_cards
      where owner_player_id = pg_temp.player_at(pg_temp.v('g')::uuid, 2)) s
where c.id = s.id;

select pg_temp.end_turn_auto(pg_temp.v('g')::uuid);

select results_eq(
  format($$ select g.active_seat::int, g.phase, gp.ghost_tokens::int,
                   (select count(*)::int from app_private.game_cards where owner_player_id = gp.id and zone = 'ghost_hand')
            from app_private.games g join app_private.game_players gp on gp.game_id = g.id and gp.seat = g.active_seat
            where g.id = %L $$, pg_temp.v('g')),
  $$ values (2, 'turn_ghost'::text, 1, 1) $$,
  'fantasma não é pulado: recebe a ficha e compra 1 do Além');

select lives_ok(
  format($$ select pg_temp.cmd(%L, %L, '{"type": "END_TURN"}') $$,
         pg_temp.user_at(pg_temp.v('g')::uuid, 2), pg_temp.v('g')),
  'fantasma encerra o turno');
reset role;
select is((select active_seat::int from app_private.games where id = pg_temp.v('g')::uuid), 3,
  'depois do fantasma vem o lugar 3');

-- Privacidade dos eventos ----------------------------------------------------

select ok(
  not exists (
    select 1 from app_private.game_events e
    join app_private.game_cards c on c.game_id = e.game_id
    -- (select …): avaliado uma vez, usa o índice em vez de varrer todas as partidas.
    where e.game_id = (select pg_temp.v('g')::uuid)
      and position(c.id::text in e.public_payload::text) > 0
  ),
  'nenhum evento público traz id de carta');

-- Até o fim da rodada 10 -----------------------------------------------------

do $$
declare
  v_game uuid := (select v::uuid from t where k = 'g');
  i int := 0;
begin
  while (select status from app_private.games where id = v_game) = 'playing' and i < 200 loop
    perform pg_temp.end_turn_auto(v_game);
    i := i + 1;
  end loop;
end;
$$;

select results_eq(
  format($$ select status, round_number, phase, active_seat from app_private.games where id = %L $$, pg_temp.v('g')),
  $$ values ('finished'::text, 10, null::text, null::smallint) $$,
  'partida sem efeitos atravessa as 10 rodadas e termina');
select is(
  (select result_json from app_private.games where id = pg_temp.v('g')::uuid),
  jsonb_build_object('reason', 'round_limit', 'criteria', 'hp',
    'winnerPlayerIds', jsonb_build_array(pg_temp.player_at(pg_temp.v('g')::uuid, 1))),
  'vence o vivo com mais PV');
select is(
  (select ghost_tokens::int from app_private.game_players where id = pg_temp.player_at(pg_temp.v('g')::uuid, 2)),
  3, 'fichas de fantasma param em 3');
select is((select count(*)::int from app_private.game_cards where game_id = pg_temp.v('g')::uuid), 180,
  'nenhuma carta criada ou perdida em 10 rodadas');
select ok(
  (select bool_and(n <= 7) from (
     select count(*) as n from app_private.game_cards c
     join app_private.game_players gp on gp.id = c.owner_player_id
     where gp.game_id = pg_temp.v('g')::uuid and c.zone = 'player_hand' group by gp.id) x),
  'ninguém termina acima do limite de 7');
select is(
  (select kind from app_private.game_events where game_id = pg_temp.v('g')::uuid order by seq desc limit 1),
  'game_finished', 'último evento é o fim da partida');

select throws_ok(
  format($$ select pg_temp.cmd(%L, %L, '{"type": "END_TURN"}') $$,
         pg_temp.user_at(pg_temp.v('g')::uuid, 1), pg_temp.v('g')),
  'P0001', 'GAME_NOT_ACTIVE', 'partida encerrada não aceita jogadas');
reset role;

-- 8 jogadores: reciclagem do baralho e desempates ----------------------------

insert into t values ('g8', pg_temp.started_game(array['1', '2', '3', '4', '5', '6', '7', '8'])::text);
update app_private.game_players set knockouts = 1
where id = pg_temp.player_at(pg_temp.v('g8')::uuid, 5);

do $$
declare
  v_game uuid := (select v::uuid from t where k = 'g8');
  i int := 0;
begin
  while (select status from app_private.games where id = v_game) = 'playing' and i < 500 loop
    perform pg_temp.end_turn_auto(v_game);
    i := i + 1;
  end loop;
end;
$$;

select is((select status from app_private.games where id = pg_temp.v('g8')::uuid), 'finished',
  '8 jogadores atravessam as 10 rodadas (o baralho recicla no meio)');
select is((select count(*)::int from app_private.game_cards where game_id = pg_temp.v('g8')::uuid), 180,
  'reciclagem não cria nem perde cartas');
select is(
  (select result_json from app_private.games where id = pg_temp.v('g8')::uuid),
  jsonb_build_object('reason', 'round_limit', 'criteria', 'knockouts',
    'winnerPlayerIds', jsonb_build_array(pg_temp.player_at(pg_temp.v('g8')::uuid, 5))),
  'PV empatado: vence quem tem mais eliminações');

insert into t values ('g3b', pg_temp.started_game(array['4', '5', '6'])::text);
do $$
declare
  v_game uuid := (select v::uuid from t where k = 'g3b');
  i int := 0;
begin
  while (select status from app_private.games where id = v_game) = 'playing' and i < 200 loop
    perform pg_temp.end_turn_auto(v_game);
    i := i + 1;
  end loop;
end;
$$;

select is(
  (select result_json ->> 'criteria' from app_private.games where id = pg_temp.v('g3b')::uuid),
  'shared', 'empate em PV e eliminações: vitória compartilhada');
select is(
  (select jsonb_array_length(result_json -> 'winnerPlayerIds') from app_private.games where id = pg_temp.v('g3b')::uuid),
  3, 'todos os empatados vencem');

-- Visão da mesa --------------------------------------------------------------

insert into t values ('gv', pg_temp.started_game(array['7', '8', '9'])::text);
create function pg_temp.view_as(p_user text, p_game uuid)
returns jsonb
language plpgsql
as $$
declare
  v_view jsonb;
begin
  perform pg_temp.login(p_user);
  v_view := public.get_game_view(p_game);
  perform set_config('role', 'postgres', true);
  return v_view;
end;
$$;

insert into t select 'view',
  pg_temp.view_as(pg_temp.user_at(pg_temp.v('gv')::uuid, 2), pg_temp.v('gv')::uuid)::text;

select is((pg_temp.v('view')::jsonb ->> 'activePlayerId')::uuid, pg_temp.player_at(pg_temp.v('gv')::uuid, 1),
  'visão mostra de quem é a vez');
select ok(
  (pg_temp.v('view')::jsonb ->> 'actionsUsed')::int = 0
  and (pg_temp.v('view')::jsonb ->> 'maxActions')::int = 2
  and jsonb_array_length(pg_temp.v('view')::jsonb -> 'events') = 3,
  'visão mostra ações e o histórico');

select * from finish();
rollback;
