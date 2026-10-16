-- SAB-07 · Bate e Joga: o alvo compra 1 e descarta 2; quem jogou compra 1.
begin;
create extension if not exists pgtap with schema extensions;

select plan(15);

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

create function pg_temp.play(p_seat int, p_card uuid, p_targets int[])
returns jsonb
language sql
as $$
  select pg_temp.cmd(p_seat, jsonb_build_object(
    'type', 'PLAY_CARD', 'cardInstanceId', p_card,
    'targetPlayerIds', (select coalesce(jsonb_agg(pg_temp.p(s)), '[]'::jsonb) from unnest(p_targets) s)))
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

create function pg_temp.hp(p_seat int) returns int language sql stable
as $$ select hp from app_private.game_players where id = pg_temp.p(p_seat) $$;
create function pg_temp.drawn(p_seat int) returns int language sql stable
as $$ select count(*)::int from app_private.game_events where game_id = pg_temp.g() and kind = 'cards_drawn'
      and actor_player_id = pg_temp.p(p_seat) $$;

create function pg_temp.choose(p_seat int, p_cards uuid[])
returns jsonb
language sql
as $$
  select pg_temp.cmd(p_seat, jsonb_build_object(
    'type', 'RESPOND', 'pendingActionId', pg_temp.pending(),
    'response', 'CHOOSE', 'selectedCardIds', to_jsonb(p_cards)))
$$;
create function pg_temp.hand_ids(p_seat int) returns uuid[] language sql stable
as $$ select coalesce(array_agg(id order by pile_position), array[]::uuid[]) from app_private.game_cards
      where owner_player_id = pg_temp.p(p_seat) and zone = 'player_hand' $$;

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
  (select row(category, character_name, copies, effect_code, target_rule, is_reaction)::text
   from app_private.card_definitions where set_version = '7.1' and code = 'SAB-07'),
  row('sabotage', 'Adeir e Victor', 4::smallint, 'draw_force_discard', 'opponent', false)::text,
  'SAB-07 é sabotagem com alvo, 4 cópias');
select is((select count(*)::int from app_private.game_cards
           where game_id = pg_temp.g() and card_code = 'SAB-07'), 4,
  'cada partida tem as 4 cópias');

-- 1. Aceita: ele compra 1 e descarta 2; você compra 1 ---------------------------

select pg_temp.reset();
select pg_temp.set('sab', pg_temp.give(1, 'SAB-07')::text);
select pg_temp.give(2, 'ATK-01');
select pg_temp.give(2, 'REC-01');
select pg_temp.play(1, pg_temp.v('sab')::uuid, array[2]);
select is(pg_temp.view(2) -> 'myDecision' ->> 'role', 'sabotage_target', 'o alvo pode reagir');
select pg_temp.respond(2);
select is(pg_temp.hand(1), 1, 'quem jogou compra 1');
select is(pg_temp.view(2) -> 'myDecision' ->> 'role', 'target_discard', 'o alvo escolhe o descarte');
select is((pg_temp.view(2) -> 'myDecision' ->> 'choiceCount')::int, 2, 'são 2 cartas');
select is(jsonb_array_length(pg_temp.view(2) -> 'myDecision' -> 'options'), 3,
  'escolhe entre as 2 que tinha e a que comprou');
select throws_ok(format('select pg_temp.choose(2, array[%L]::uuid[])', (pg_temp.hand_ids(2))[1]),
  'P0001', 'WRONG_CHOICE', 'precisa escolher exatamente 2');
select pg_temp.set('kept', (pg_temp.hand_ids(2))[3]::text);
select pg_temp.choose(2, (pg_temp.hand_ids(2))[1:2]);
select ok(pg_temp.hand(2) = 1 and (pg_temp.hand_ids(2))[1] = pg_temp.v('kept')::uuid,
  'fica só com a carta que escolheu manter');
select is((select phase || '/' || actions_used from app_private.games where id = pg_temp.g()), 'turn_main/1',
  'gasta 1 ação e a vez volta para quem jogou');
select is((select count(*)::int from app_private.game_events where game_id = pg_temp.g() and kind = 'cards_drawn'
           and public_payload ->> 'cardCode' = 'SAB-07'), 2, 'histórico mostra as duas compras');

-- 2. Evento Raro cancela tudo ---------------------------------------------------

select pg_temp.reset();
select pg_temp.set('sab', pg_temp.give(1, 'SAB-07')::text);
select pg_temp.set('def05', pg_temp.give(2, 'DEF-05')::text);
select pg_temp.give(2, 'ATK-01');
select pg_temp.play(1, pg_temp.v('sab')::uuid, array[2]);
select pg_temp.respond(2, pg_temp.v('def05')::uuid);
select ok(pg_temp.hand(1) = 0 and pg_temp.hand(2) = 1 and pg_temp.pending() is null,
  'cancelada: ninguém compra nem descarta');

-- 3. Alvo sem cartas: compra 1 e descarta essa ---------------------------------

select pg_temp.reset();
select pg_temp.set('sab', pg_temp.give(1, 'SAB-07')::text);
select pg_temp.play(1, pg_temp.v('sab')::uuid, array[2]);
select pg_temp.respond(2);
select is((pg_temp.view(2) -> 'myDecision' ->> 'choiceCount')::int, 1, 'com 1 carta, descarta 1');
select pg_temp.choose(2, pg_temp.hand_ids(2));
select ok(pg_temp.hand(2) = 0 and pg_temp.hand(1) = 1, 'o alvo fica sem nada; quem jogou ganha 1');

-- 4. Escolha forçada é automática (G2) ------------------------------------------

select pg_temp.reset();
update app_private.games set auto_flow = true where id = pg_temp.g();
select pg_temp.set('sab', pg_temp.give(1, 'SAB-07')::text);
select pg_temp.give(1, 'ATK-02');
select pg_temp.give(3, 'ATK-01');
select pg_temp.play(1, pg_temp.v('sab')::uuid, array[3]);
select pg_temp.respond(3);
select ok(pg_temp.pending() is null and pg_temp.hand(3) = 0, 'com 2 cartas e 2 a descartar, o banco escolhe');

select * from finish();
rollback;
