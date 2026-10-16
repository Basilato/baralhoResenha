-- SAB-06 · Vale Entrosa: roubar a próxima vez de um adversário.
begin;
create extension if not exists pgtap with schema extensions;

select plan(28);

-- Auxiliares ------------------------------------------------------------------

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

create temp table t (k text primary key, v text);
create function pg_temp.v(p_k text) returns text language sql stable as $$ select v from t where k = p_k $$;
create function pg_temp.set(p_k text, p_v text) returns void language sql
as $$ insert into t values (p_k, p_v) on conflict (k) do update set v = excluded.v $$;

create function pg_temp.g() returns uuid language sql stable as $$ select v::uuid from t where k = 'g' $$;

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

-- Jogador por lugar: A = lugar 1, B = lugar 2, C = lugar 3.
create function pg_temp.p(p_seat int) returns uuid language sql stable
as $$ select id from app_private.game_players where game_id = pg_temp.g() and seat = p_seat $$;
create function pg_temp.u(p_seat int) returns text language sql stable
as $$ select substr(user_id::text, 36) from app_private.game_players where game_id = pg_temp.g() and seat = p_seat $$;
create function pg_temp.hand(p_seat int) returns int language sql stable
as $$ select count(*)::int from app_private.game_cards where owner_player_id = pg_temp.p(p_seat) and zone = 'player_hand' $$;

-- Mesa zerada: rodada 1, lugar 1 na vez, todos vivos, mãos vazias, sem vales.
create function pg_temp.reset()
returns void
language plpgsql
as $$
declare
  v_game uuid := pg_temp.g();
  v_main_top integer;
  v_ghost_top integer;
begin
  update app_private.pending_actions set status = 'resolved' where game_id = v_game and status = 'open';
  delete from app_private.status_effects where game_id = v_game;
  update app_private.games
  set phase = 'turn_main', actions_used = 0, active_seat = 1, resume_seat = null, round_number = 1,
      leader_player_id = null, pending_action_id = null, auto_flow = false
  where id = v_game;
  update app_private.game_players
  set life_status = 'alive', hp = 16, max_hp = 16, knockouts = 0
  where game_id = v_game;
  select coalesce(max(pile_position) filter (where zone = 'main_deck'), 0),
         coalesce(max(pile_position) filter (where zone = 'ghost_deck'), 0)
    into v_main_top, v_ghost_top
  from app_private.game_cards where game_id = v_game;

  update app_private.game_cards c
  set zone = c.deck_type || '_deck', owner_player_id = null,
      pile_position = case c.deck_type when 'main' then v_main_top else v_ghost_top end + s.n
  from (
    select x.id, row_number() over (partition by x.deck_type) as n
    from app_private.game_cards x
    where x.game_id = v_game and x.zone in ('player_hand', 'ghost_hand', 'in_resolution')
  ) s
  where c.id = s.id;
end;
$$;

create function pg_temp.give(p_seat int, p_code text)
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
begin
  select id into v_id from app_private.game_cards
  where game_id = pg_temp.g() and card_code = p_code and owner_player_id is null
    and zone in ('main_deck', 'main_discard')
  limit 1;
  update app_private.game_cards
  set zone = 'player_hand', owner_player_id = pg_temp.p(p_seat),
      pile_position = coalesce((select max(pile_position) from app_private.game_cards
                                where owner_player_id = pg_temp.p(p_seat) and zone = 'player_hand'), 0) + 1
  where id = v_id;
  return v_id;
end;
$$;

create function pg_temp.cmd(p_seat int, p_command jsonb)
returns jsonb
language plpgsql
as $$
declare
  v_game uuid := pg_temp.g();
  v_version bigint := (select version from app_private.games where id = pg_temp.g());
  v_user text := pg_temp.u(p_seat);
  v_result jsonb;
begin
  perform pg_temp.login(v_user);
  v_result := public.submit_game_command(v_game, v_version, gen_random_uuid(), p_command);
  perform set_config('role', 'postgres', true);
  return v_result;
end;
$$;

create function pg_temp.play(p_seat int, p_card uuid, p_target int)
returns jsonb
language sql
as $$
  select pg_temp.cmd(p_seat, jsonb_build_object(
    'type', 'PLAY_CARD', 'cardInstanceId', p_card,
    'targetPlayerIds', jsonb_build_array(pg_temp.p(p_target))))
$$;

create function pg_temp.pending() returns uuid language sql stable
as $$ select id from app_private.pending_actions where game_id = pg_temp.g() and status = 'open' $$;

create function pg_temp.respond(p_seat int, p_card uuid default null)
returns jsonb
language sql
as $$
  select pg_temp.cmd(p_seat, jsonb_build_object(
    'type', 'RESPOND', 'pendingActionId', pg_temp.pending(),
    'response', case when p_card is null then 'PASS' else 'REACT' end,
    'cardInstanceId', p_card))
$$;

-- Encerra o turno descartando ao acaso o que passar de 7 cartas.
create function pg_temp.end_turn(p_seat int)
returns jsonb
language sql
as $$
  select pg_temp.cmd(p_seat, jsonb_build_object('type', 'END_TURN',
    'discardCardIds', coalesce((
      select jsonb_agg(id) from (
        select id from app_private.game_cards
        where owner_player_id = pg_temp.p(p_seat) and zone = 'player_hand'
        order by pile_position
        limit greatest(pg_temp.hand(p_seat) - 7, 0)
      ) s), '[]'::jsonb)))
$$;

create function pg_temp.view(p_seat int)
returns jsonb
language plpgsql
as $$
declare
  v_game uuid := pg_temp.g();
  v_user text := pg_temp.u(p_seat);
  v jsonb;
begin
  perform pg_temp.login(v_user);
  v := public.get_game_view(v_game);
  perform set_config('role', 'postgres', true);
  return v;
end;
$$;

create function pg_temp.active() returns int language sql stable
as $$ select active_seat::int from app_private.games where id = pg_temp.g() $$;
create function pg_temp.steals() returns int language sql stable
as $$ select count(*)::int from app_private.status_effects where game_id = pg_temp.g() and type = 'turn_steal' $$;
create function pg_temp.last_event() returns text language sql stable
as $$ select kind from app_private.game_events where game_id = pg_temp.g() and kind <> 'turn_started'
      order by seq desc limit 1 $$;

select pg_temp.set('g', pg_temp.started_game(array['1', '2', '3'])::text);

-- 0. Catálogo -------------------------------------------------------------------

select is(
  (select row(category, copies, effect_code, target_rule, is_reaction)::text
   from app_private.card_definitions where set_version = '7.1' and code = 'SAB-06'),
  row('sabotage', 3::smallint, 'steal_turn', 'opponent', false)::text,
  'SAB-06 é sabotagem com alvo, 3 cópias');
select is((select count(*)::int from app_private.game_cards
           where game_id = pg_temp.g() and card_code = 'SAB-06'), 3,
  'cada partida tem as 3 cópias');

-- 1. Alvo logo depois: quem roubou joga duas vezes seguidas ------------------

select pg_temp.reset();
select pg_temp.set('vale', pg_temp.give(1, 'SAB-06')::text);
select pg_temp.play(1, pg_temp.v('vale')::uuid, 2);
select is(pg_temp.view(2) -> 'myDecision' ->> 'role', 'sabotage_target', 'o alvo pode reagir');
select pg_temp.respond(2);
select is(pg_temp.last_event(), 'turn_steal_set', 'histórico registra o vale');
select is(pg_temp.view(3) -> 'turnSteals',
  jsonb_build_array(jsonb_build_object('targetPlayerId', pg_temp.p(2), 'thiefPlayerId', pg_temp.p(1))),
  'todos veem quem vai ter a vez roubada e por quem');
select is((select actions_used::int from app_private.games where id = pg_temp.g()), 1, 'o vale gasta 1 ação');

select pg_temp.end_turn(1);
select is(pg_temp.active(), 1, 'na vez de B, quem joga é A');
select is((select resume_seat::int from app_private.games where id = pg_temp.g()), 2,
  'o banco lembra qual lugar foi roubado');
select is(pg_temp.view(2) ->> 'activePlayerId', pg_temp.p(1)::text, 'a tela mostra A jogando');
select is(pg_temp.view(3) ->> 'stolenFromPlayerId', pg_temp.p(2)::text, 'e de quem é a vez roubada');
select ok(pg_temp.hand(1) = 2 and pg_temp.hand(2) = 0, 'A compra 2 na vez roubada; B não compra nada');
select is((select phase || '/' || actions_used from app_private.games where id = pg_temp.g()), 'turn_main/0',
  'a vez roubada é um turno completo, com 2 ações');
select is(pg_temp.steals(), 0, 'o vale é consumido');
select ok(exists (select 1 from app_private.game_events where game_id = pg_temp.g() and kind = 'turn_stolen'
                  and actor_player_id = pg_temp.p(1)
                  and public_payload ->> 'fromPlayerId' = pg_temp.p(2)::text),
  'histórico registra a vez roubada');
select throws_ok('select pg_temp.end_turn(2)', 'P0001', 'NOT_YOUR_TURN', 'B não joga a vez roubada');

select pg_temp.end_turn(1);
select is(pg_temp.active(), 3, 'depois da vez roubada, segue a partir do lugar de B');
select is((select resume_seat from app_private.games where id = pg_temp.g()), null, 'o lugar roubado é esquecido');

-- 2. Último lugar da rodada: a vez roubada fecha a rodada ---------------------

select pg_temp.reset();
select pg_temp.set('vale', pg_temp.give(1, 'SAB-06')::text);
select pg_temp.play(1, pg_temp.v('vale')::uuid, 3);
select pg_temp.respond(3);
select pg_temp.end_turn(1);
select is(pg_temp.active(), 2, 'B joga normalmente');
select pg_temp.end_turn(2);
select ok(pg_temp.active() = 1 and pg_temp.hand(3) = 0, 'na vez de C, A joga e C não compra');
select pg_temp.end_turn(1);
select is((select round_number::int || '/' || active_seat from app_private.games where id = pg_temp.g()), '2/1',
  'a rodada fecha e a próxima começa no lugar 1');

-- 3. Evento Raro cancela ------------------------------------------------------

select pg_temp.reset();
select pg_temp.set('vale', pg_temp.give(1, 'SAB-06')::text);
select pg_temp.set('def05', pg_temp.give(2, 'DEF-05')::text);
select pg_temp.play(1, pg_temp.v('vale')::uuid, 2);
select is(pg_temp.view(2) -> 'myDecision' -> 'eligibleCardIds', jsonb_build_array(pg_temp.v('def05')),
  'Evento Raro serve contra o vale');
select pg_temp.respond(2, pg_temp.v('def05')::uuid);
select ok(pg_temp.steals() = 0 and pg_temp.last_event() = 'sabotage_blocked', 'cancelado, nada acontece');
select pg_temp.end_turn(1);
select is(pg_temp.active(), 2, 'B joga a própria vez');

-- 4. Vale novo no mesmo alvo substitui o anterior ------------------------------

select pg_temp.reset();
select pg_temp.set('vale', pg_temp.give(1, 'SAB-06')::text);
select pg_temp.play(1, pg_temp.v('vale')::uuid, 3);
select pg_temp.respond(3);
update app_private.games set active_seat = 2, actions_used = 0 where id = pg_temp.g();
select pg_temp.set('vale2', pg_temp.give(2, 'SAB-06')::text);
select pg_temp.play(2, pg_temp.v('vale2')::uuid, 3);
select pg_temp.respond(3);
select is(pg_temp.view(1) -> 'turnSteals',
  jsonb_build_array(jsonb_build_object('targetPlayerId', pg_temp.p(3), 'thiefPlayerId', pg_temp.p(2))),
  'só fica o vale mais novo');
select pg_temp.end_turn(2);
select is(pg_temp.active(), 2, 'na vez de C, joga quem usou o último vale');

-- 5. Caduca se quem roubou cair antes ------------------------------------------

select pg_temp.reset();
update app_private.games set active_seat = 3 where id = pg_temp.g();
select pg_temp.set('vale', pg_temp.give(3, 'SAB-06')::text);
select pg_temp.play(3, pg_temp.v('vale')::uuid, 2);
select pg_temp.respond(2);
update app_private.game_players set life_status = 'ghost', hp = 0 where id = pg_temp.p(3);
update app_private.games set active_seat = 1, actions_used = 0 where id = pg_temp.g();
select pg_temp.end_turn(1);
select is(pg_temp.active(), 2, 'autor fantasma: B joga a própria vez');
select ok(pg_temp.steals() = 0 and exists (
  select 1 from app_private.game_events where game_id = pg_temp.g() and kind = 'turn_steal_lapsed'
    and public_payload ->> 'reason' = 'thief_down'),
  'o vale caduca e o histórico explica');

-- 6. Caduca se o alvo virou fantasma: fantasma não tem a vez roubada ----------

select pg_temp.reset();
select pg_temp.set('vale', pg_temp.give(1, 'SAB-06')::text);
select pg_temp.play(1, pg_temp.v('vale')::uuid, 2);
select pg_temp.respond(2);
update app_private.game_players set life_status = 'ghost', hp = 0 where id = pg_temp.p(2);
select pg_temp.end_turn(1);
select is((select active_seat || '/' || phase from app_private.games where id = pg_temp.g()), '2/turn_ghost',
  'B joga o turno de fantasma normalmente');

select * from finish();
rollback;
