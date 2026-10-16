-- DEF-07 · Nem Bateu: reduz 2 e, se ainda sofrer dano, compra 2.
begin;
create extension if not exists pgtap with schema extensions;

select plan(14);

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
   from app_private.card_definitions where set_version = '7.1' and code = 'DEF-07'),
  row('defense', 'Anna', 4::smallint, 'reduce_attack_draw_if_hit', 'attack_reaction', true)::text,
  'DEF-07 é reação de defesa contra ataque, 4 cópias');
select is((select count(*)::int from app_private.game_cards
           where game_id = pg_temp.g() and card_code = 'DEF-07'), 4,
  'cada partida tem as 4 cópias');

-- 1. Ainda apanhou: reduz 2 e compra 2 -----------------------------------------

select pg_temp.reset();
select pg_temp.set('atk', pg_temp.give(1, 'ATK-01')::text);
select pg_temp.set('def', pg_temp.give(2, 'DEF-07')::text);
select pg_temp.set('own', pg_temp.give(1, 'DEF-07')::text);
select throws_ok(format(
  'select pg_temp.cmd(1, jsonb_build_object(''type'', ''PLAY_CARD'', ''cardInstanceId'', %L::uuid, ''targetPlayerIds'', ''[]''::jsonb))',
  pg_temp.v('own')), 'P0001', 'REACTION_ONLY', 'não se joga no próprio turno');
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2]);
select is(pg_temp.view(2) -> 'myDecision' -> 'eligibleCardIds', jsonb_build_array(pg_temp.v('def')),
  'serve contra ataque');
select pg_temp.respond(2, pg_temp.v('def')::uuid);
select is(pg_temp.hp(2), 15, 'ataque de 3 vira 1');
select is(pg_temp.hand(2), 2, 'ainda sofreu dano: compra 2');
select is(pg_temp.drawn(2), 1, 'histórico registra a compra');

-- 2. Dano zerado: não compra ---------------------------------------------------

select pg_temp.reset();
select pg_temp.set('atk', pg_temp.give(1, 'ATK-04')::text);
select pg_temp.set('def', pg_temp.give(2, 'DEF-07')::text);
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2, 3]);
select pg_temp.respond(2, pg_temp.v('def')::uuid);
select pg_temp.respond(3);
select ok(pg_temp.hp(2) = 16 and pg_temp.hand(2) = 0, 'Fofoca Mortal (2) reduzida a 0: nem bateu, nem compra');
select is(pg_temp.hp(3), 14, 'o outro alvo sofre normalmente');

-- 3. Vale contra o ataque devolvido pelo Reverso do Reverso ------------------

select pg_temp.reset();
select pg_temp.set('atk', pg_temp.give(1, 'ATK-01')::text);
select pg_temp.set('def', pg_temp.give(1, 'DEF-07')::text);
select pg_temp.set('rev', pg_temp.give(2, 'DEF-04')::text);
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2]);
select pg_temp.respond(2, pg_temp.v('rev')::uuid);
select is(pg_temp.view(1) -> 'myDecision' -> 'eligibleCardIds', jsonb_build_array(pg_temp.v('def')),
  'o autor pode usar contra o ataque devolvido');
select pg_temp.respond(1, pg_temp.v('def')::uuid);
select ok(pg_temp.hp(1) = 15 and pg_temp.hand(1) = 2, 'o autor sofre 1 e compra 2');

-- 4. Golpe fatal: sobreviveu compra; caiu não compra ---------------------------

select pg_temp.reset();
update app_private.game_players set hp = 2 where id = pg_temp.p(2);
select pg_temp.set('atk', pg_temp.give(1, 'ATK-01')::text);
select pg_temp.set('def', pg_temp.give(2, 'DEF-07')::text);
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2]);
select pg_temp.respond(2, pg_temp.v('def')::uuid);
select ok(pg_temp.hp(2) = 1 and pg_temp.hand(2) = 2, 'com 2 PV: fica com 1 e compra 2');

select pg_temp.reset();
update app_private.game_players set hp = 1 where id = pg_temp.p(2);
select pg_temp.set('atk', pg_temp.give(1, 'ATK-01')::text);
select pg_temp.set('def', pg_temp.give(2, 'DEF-07')::text);
select pg_temp.set('before', pg_temp.drawn(2)::text);
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2]);
select pg_temp.respond(2, pg_temp.v('def')::uuid);
select ok((select life_status from app_private.game_players where id = pg_temp.p(2)) = 'ghost'
  and pg_temp.hand(2) = 0 and pg_temp.drawn(2) = pg_temp.v('before')::int,
  'com 1 PV: cai e não compra');

-- 5. Família Basilato não admite defesa comum (B4) ----------------------------

select pg_temp.reset();
select pg_temp.set('cao', pg_temp.give(1, 'CAO-03')::text);
select pg_temp.set('def', pg_temp.give(2, 'DEF-07')::text);
select pg_temp.play(1, pg_temp.v('cao')::uuid, array[2]);
select ok(pg_temp.hp(2) = 13 and pg_temp.hand(2) = 1, 'caos passa direto: sem redução nem compra');

select * from finish();
rollback;
