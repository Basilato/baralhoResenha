-- CAO-06 · Bonde da Tempestade: 1 de dano de caos em todos os vivos; depois quem
-- jogou compra 2 e os outros sobreviventes compram 1.
begin;
create extension if not exists pgtap with schema extensions;

select plan(23);

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

create function pg_temp.hp(p_seat int) returns int language sql stable
as $$ select hp::int from app_private.game_players where id = pg_temp.p(p_seat) $$;
create function pg_temp.status(p_seat int) returns text language sql stable
as $$ select life_status from app_private.game_players where id = pg_temp.p(p_seat) $$;
create function pg_temp.kos(p_seat int) returns int language sql stable
as $$ select knockouts::int from app_private.game_players where id = pg_temp.p(p_seat) $$;
create function pg_temp.storm() returns jsonb language sql
as $$ select pg_temp.cmd(1, jsonb_build_object('type', 'PLAY_CARD',
        'cardInstanceId', pg_temp.v('cao')::uuid, 'targetPlayerIds', '[]'::jsonb)) $$;
-- Compra da última tempestade: [[lugar, cartas], ...] em ordem de lugar.
create function pg_temp.draws() returns jsonb language sql stable
as $$ select coalesce(jsonb_agg(jsonb_build_array(gp.seat, (d ->> 'count')::int) order by gp.seat), '[]'::jsonb)
      from jsonb_array_elements((select public_payload -> 'draws' from app_private.game_events
                                 where game_id = pg_temp.g() and kind = 'storm_draw'
                                 order by seq desc limit 1)) d
      join app_private.game_players gp on gp.id = (d ->> 'playerId')::uuid $$;

-- Mesa padrão: só A tem carta (o Bonde); todos com 16 PV.
create function pg_temp.setup()
returns void
language plpgsql
as $$
begin
  perform pg_temp.reset();
  perform pg_temp.set('cao', pg_temp.give(1, 'CAO-06')::text);
end;
$$;

select pg_temp.set('g', pg_temp.started_game(array['1', '2', '3'])::text);

-- 0. Catálogo -------------------------------------------------------------------

select is(
  (select row(category, character_name, copies, effect_code, effect_params, target_rule, is_reaction)::text
   from app_private.card_definitions where set_version = '7.1' and code = 'CAO-06'),
  row('chaos', 'Anna, Léo, Adeir, Manu, Victor e Artur', 3::smallint, 'chaos_storm',
      '{"draw": 1, "amount": 1, "self_draw": 2}'::jsonb, 'all_alive', false)::text,
  'CAO-06 é caos para todos os vivos, 3 cópias, quem jogou compra 2');
select is((select count(*)::int from app_private.game_cards
           where game_id = pg_temp.g() and card_code = 'CAO-06'), 3,
  'cada partida tem as 3 cópias');

-- 1. Todos levam 1, quem jogou compra 2, os outros 1 -----------------------------

select pg_temp.setup();
update app_private.games set leader_player_id = pg_temp.p(2) where id = pg_temp.g();
select throws_ok(format(
  'select pg_temp.cmd(1, jsonb_build_object(''type'', ''PLAY_CARD'', ''cardInstanceId'', %L::uuid, ''targetPlayerIds'', jsonb_build_array(pg_temp.p(2))))',
  pg_temp.v('cao')), 'P0001', 'INVALID_TARGET', 'não tem alvo');
select pg_temp.storm();
select is(array[pg_temp.hp(1), pg_temp.hp(2), pg_temp.hp(3)], array[15, 15, 15],
  '1 de dano em todos, inclusive quem jogou, sem bônus do Mais Odiado');
select is(array[pg_temp.hand(1), pg_temp.hand(2), pg_temp.hand(3)], array[2, 1, 1],
  'quem jogou compra 2; os outros, 1');
select is(pg_temp.draws(), '[[1, 2], [2, 1], [3, 1]]'::jsonb, 'o histórico mostra quanto cada um comprou');
select is((select zone from app_private.game_cards where id = pg_temp.v('cao')::uuid), 'main_discard',
  'a carta jogada vai para o descarte');
select is((select phase || '/' || actions_used || '/' || (pending_action_id is null)
           from app_private.games where id = pg_temp.g()), 'turn_main/1/true',
  'sem golpe fatal, resolve na hora e gasta 1 ação');

-- 2. Golpe fatal num adversário -------------------------------------------------

select pg_temp.setup();
update app_private.game_players set hp = 1 where id = pg_temp.p(2);
select pg_temp.storm();
select ok(pg_temp.pending() is not null and pg_temp.hp(2) = 1,
  'quem cairia pode reagir: a jogada espera');
select pg_temp.respond(2);
select ok(pg_temp.status(2) = 'ghost' and pg_temp.kos(1) = 1,
  'aceitou: cai e o abate conta para quem jogou');
select is(pg_temp.draws(), '[[1, 2], [3, 1]]'::jsonb, 'quem caiu não compra');

-- 3. Ressuscitou o Tio Paulo ------------------------------------------------------

select pg_temp.setup();
update app_private.game_players set hp = 1 where id = pg_temp.p(2);
select pg_temp.give(2, 'DEF-01');
select pg_temp.set('rev01', pg_temp.give(2, 'REV-01')::text);
select pg_temp.set('rev03', pg_temp.give(2, 'REV-03')::text);
select pg_temp.storm();
select is(pg_temp.view(2) -> 'myDecision' -> 'eligibleCardIds',
  jsonb_build_array(pg_temp.v('rev01'), pg_temp.v('rev03')),
  'adversário: só reações de golpe fatal, sem defesa comum (B4)');
select pg_temp.respond(2, pg_temp.v('rev01')::uuid);
select ok(pg_temp.hp(2) = 1 and pg_temp.hand(2) = 3,
  'segura em 1 PV e, sobrevivente, compra 1');

-- 4. Golpe fatal em quem jogou ----------------------------------------------------

select pg_temp.setup();
update app_private.game_players set hp = 1 where id = pg_temp.p(1);
select pg_temp.set('rev01', pg_temp.give(1, 'REV-01')::text);
select pg_temp.set('rev03', pg_temp.give(1, 'REV-03')::text);
select pg_temp.storm();
select is(pg_temp.view(1) -> 'myDecision' ->> 'role', 'chaos_self', 'quem jogou responde como chaos_self');
select is(pg_temp.view(1) -> 'myDecision' -> 'eligibleCardIds', jsonb_build_array(pg_temp.v('rev01')),
  'quem jogou não pode usar a Última Palavra contra si mesmo');
select throws_ok(format('select pg_temp.respond(1, %L::uuid)', pg_temp.v('rev03')),
  'P0001', 'REACTION_NOT_ALLOWED', 'a Última Palavra é recusada');
select pg_temp.respond(1, pg_temp.v('rev01')::uuid);
select ok(pg_temp.hp(1) = 1 and pg_temp.hand(1) = 3 and pg_temp.hp(2) = 15,
  'segura em 1 PV e compra 2');

select pg_temp.setup();
update app_private.game_players set hp = 1 where id = pg_temp.p(1);
select pg_temp.storm();
select pg_temp.respond(1);
select ok(pg_temp.status(1) = 'ghost' and pg_temp.kos(1) + pg_temp.kos(2) + pg_temp.kos(3) = 0,
  'quem jogou cai com a própria carta, sem abate para ninguém');
select is(pg_temp.draws(), '[[2, 1], [3, 1]]'::jsonb, 'só os sobreviventes compram');
select ok(exists (select 1 from app_private.game_events where game_id = pg_temp.g()
                  and kind = 'turn_ended' and actor_player_id = pg_temp.p(1)
                  and public_payload ->> 'reason' = 'died'),
  'e perde o resto do turno (B5)');

-- 5. Fantasma fica de fora --------------------------------------------------------

select pg_temp.setup();
update app_private.game_players set life_status = 'ghost', hp = 0 where id = pg_temp.p(3);
select pg_temp.storm();
select ok(pg_temp.hp(3) = 0 and pg_temp.hand(3) = 0 and pg_temp.draws() = '[[1, 2], [2, 1]]'::jsonb,
  'fantasma não sofre dano nem compra');

-- 6. Última Palavra derruba quem jogou ---------------------------------------------

select pg_temp.setup();
update app_private.game_players set hp = 2 where id = pg_temp.p(1);
update app_private.game_players set hp = 1 where id = pg_temp.p(2);
select pg_temp.set('rev03', pg_temp.give(2, 'REV-03')::text);
select pg_temp.storm();
select pg_temp.respond(2, pg_temp.v('rev03')::uuid);
select ok(pg_temp.status(1) = 'ghost' and pg_temp.status(2) = 'ghost'
          and pg_temp.kos(1) = 1 and pg_temp.kos(2) = 1,
  'a Última Palavra causa 2 em quem jogou e o derruba; cada um leva um abate');
select is(pg_temp.draws(), '[[3, 1]]'::jsonb, 'quem caiu pela Última Palavra não compra');

select * from finish();
rollback;
