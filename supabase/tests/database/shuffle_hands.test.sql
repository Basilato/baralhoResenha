-- CAO-05 · Rolê no Sítio: junta, embaralha e redistribui as mãos dos vivos.
begin;
create extension if not exists pgtap with schema extensions;

select plan(12);

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

create function pg_temp.hand_ids(p_seat int) returns uuid[] language sql stable
as $$ select coalesce(array_agg(id order by id), array[]::uuid[]) from app_private.game_cards
      where owner_player_id = pg_temp.p(p_seat) and zone = 'player_hand' $$;
create function pg_temp.all_hands() returns uuid[] language sql stable
as $$ select coalesce(array_agg(id order by id), array[]::uuid[]) from app_private.game_cards
      where game_id = pg_temp.g() and zone = 'player_hand' $$;
create function pg_temp.shuffle_play() returns jsonb language sql
as $$ select pg_temp.cmd(1, jsonb_build_object('type', 'PLAY_CARD',
        'cardInstanceId', pg_temp.v('cao')::uuid, 'targetPlayerIds', '[]'::jsonb)) $$;

-- Mesa padrão: A tem o Rolê no Sítio + 2 cartas, B tem 3, C nenhuma.
create function pg_temp.setup()
returns void
language plpgsql
as $$
begin
  perform pg_temp.reset();
  perform pg_temp.set('cao', pg_temp.give(1, 'CAO-05')::text);
  perform pg_temp.give(1, 'ATK-01');
  perform pg_temp.give(1, 'ATK-02');
  perform pg_temp.give(2, 'DEF-01');
  perform pg_temp.give(2, 'DEF-02');
  perform pg_temp.give(2, 'REC-01');
end;
$$;

-- Repete a jogada e conta quantas vezes a mão de A mudou.
create function pg_temp.times_changed(p_runs int)
returns int
language plpgsql
as $$
declare
  v_before uuid[];
  v_changed int := 0;
begin
  for i in 1..p_runs loop
    perform pg_temp.setup();
    v_before := array(select x from unnest(pg_temp.hand_ids(1)) x where x <> pg_temp.v('cao')::uuid order by x);
    perform pg_temp.shuffle_play();
    if pg_temp.hand_ids(1) <> v_before then
      v_changed := v_changed + 1;
    end if;
  end loop;
  return v_changed;
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
  (select row(category, character_name, copies, effect_code, target_rule, is_reaction)::text
   from app_private.card_definitions where set_version = '7.1' and code = 'CAO-05'),
  row('chaos', 'A Turma', 3::smallint, 'shuffle_hands', 'all_alive', false)::text,
  'CAO-05 é caos para todos os vivos, 3 cópias');
select is((select count(*)::int from app_private.game_cards
           where game_id = pg_temp.g() and card_code = 'CAO-05'), 3,
  'cada partida tem as 3 cópias');

-- 1. Junta, embaralha e devolve a mesma quantidade ----------------------------

select pg_temp.setup();
select pg_temp.set('pool', array(select x from unnest(pg_temp.all_hands()) x
                                 where x <> pg_temp.v('cao')::uuid order by x)::text);
select throws_ok(format(
  'select pg_temp.cmd(1, jsonb_build_object(''type'', ''PLAY_CARD'', ''cardInstanceId'', %L::uuid, ''targetPlayerIds'', jsonb_build_array(pg_temp.p(2))))',
  pg_temp.v('cao')), 'P0001', 'INVALID_TARGET', 'não tem alvo');
select pg_temp.shuffle_play();
select is(array[pg_temp.hand(1), pg_temp.hand(2), pg_temp.hand(3)], array[2, 3, 0],
  'cada um fica com a quantidade que tinha (a carta jogada não conta)');
select is(pg_temp.all_hands()::text, pg_temp.v('pool'), 'as mesmas cartas, nenhuma criada ou perdida');
select is((select zone from app_private.game_cards where id = pg_temp.v('cao')::uuid), 'main_discard',
  'a carta jogada vai para o descarte, fora da mistura');
select is((select phase || '/' || actions_used || '/' || (pending_action_id is null)
           from app_private.games where id = pg_temp.g()), 'turn_main/1/true',
  'resolve na hora: ninguém reage, gasta 1 ação');
select is((select public_payload from app_private.game_events where game_id = pg_temp.g()
           and kind = 'hands_shuffled' order by seq desc limit 1),
  '{"count": 5, "players": 3}'::jsonb, 'o histórico mostra só quantidades');
select ok(not exists (
    select 1 from app_private.game_events e
    join app_private.game_cards c on c.game_id = e.game_id
    where e.game_id = (select pg_temp.g()) and position(c.id::text in e.public_payload::text) > 0),
  'nenhum id de carta vaza no histórico');

-- 2. Embaralha de verdade -------------------------------------------------------

select cmp_ok(pg_temp.times_changed(8), '>=', 1, 'a mão de quem jogou muda (8 tentativas)');

-- 3. Fantasma fica de fora ------------------------------------------------------

select pg_temp.setup();
update app_private.game_players set life_status = 'ghost', hp = 0 where id = pg_temp.p(3);
update app_private.game_cards set zone = 'ghost_hand', owner_player_id = pg_temp.p(3), pile_position = 1
where id = (select id from app_private.game_cards where game_id = pg_temp.g() and zone = 'ghost_deck' limit 1)
returning pg_temp.set('ghost', id::text);
select pg_temp.shuffle_play();
select ok((select owner_player_id = pg_temp.p(3) and zone = 'ghost_hand'
           from app_private.game_cards where id = pg_temp.v('ghost')::uuid),
  'a carta do Além do fantasma não entra');
select is((select public_payload ->> 'players' from app_private.game_events where game_id = pg_temp.g()
           and kind = 'hands_shuffled' order by seq desc limit 1), '2', 'só os vivos participam');

select * from finish();
rollback;
