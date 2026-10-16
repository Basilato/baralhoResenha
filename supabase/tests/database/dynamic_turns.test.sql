-- Partidas dinâmicas: respostas automáticas, fim de turno automático e prazos.
begin;
create extension if not exists pgtap with schema extensions;

select plan(31);

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

-- Jogador por lugar: A = lugar 1 (joga), B = lugar 2, C = lugar 3.
create function pg_temp.p(p_seat int) returns uuid language sql stable
as $$ select id from app_private.game_players where game_id = pg_temp.g() and seat = p_seat $$;
create function pg_temp.u(p_seat int) returns text language sql stable
as $$ select substr(user_id::text, 36) from app_private.game_players where game_id = pg_temp.g() and seat = p_seat $$;
create function pg_temp.hp(p_seat int) returns int language sql stable
as $$ select hp from app_private.game_players where id = pg_temp.p(p_seat) $$;
create function pg_temp.hand(p_seat int) returns int language sql stable
as $$ select count(*)::int from app_private.game_cards where owner_player_id = pg_temp.p(p_seat) and zone = 'player_hand' $$;

-- Mesa zerada: lugar 1 na vez, todos vivos com 16 PV, mãos vazias.
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
  update app_private.games
  set phase = 'turn_main', actions_used = 0, active_seat = 1, leader_player_id = null, pending_action_id = null,
      auto_flow = false
  where id = pg_temp.g();
  update app_private.game_players
  set life_status = 'alive', hp = 16, max_hp = 16, knockouts = 0
  where game_id = pg_temp.g();
  -- Topo de cada baralho calculado uma vez (sem subconsulta por linha).
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

-- Coloca uma cópia da carta na mão do jogador e devolve o id da instância.
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

create function pg_temp.cmd(p_seat int, p_command jsonb, p_request uuid default gen_random_uuid())
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
  v_result := public.submit_game_command(v_game, v_version, p_request, p_command);
  perform set_config('role', 'postgres', true);
  return v_result;
end;
$$;

create function pg_temp.play(p_seat int, p_card uuid, p_targets int[], p_cost uuid default null)
returns jsonb
language sql
as $$
  select pg_temp.cmd(p_seat, jsonb_build_object(
    'type', 'PLAY_CARD',
    'cardInstanceId', p_card,
    'targetPlayerIds', (select coalesce(jsonb_agg(pg_temp.p(s)), '[]'::jsonb) from unnest(p_targets) s),
    'discardCostCardId', p_cost))
$$;

create function pg_temp.pending() returns uuid language sql stable
as $$ select id from app_private.pending_actions where game_id = pg_temp.g() and status = 'open' $$;

create function pg_temp.respond(p_seat int, p_card uuid default null)
returns jsonb
language sql
as $$
  select pg_temp.cmd(p_seat, jsonb_build_object(
    'type', 'RESPOND',
    'pendingActionId', pg_temp.pending(),
    'response', case when p_card is null then 'PASS' else 'REACT' end,
    'cardInstanceId', p_card))
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

create function pg_temp.phase() returns text language sql stable
as $$ select phase from app_private.games where id = pg_temp.g() $$;

create function pg_temp.choose(p_seat int, p_cards uuid[])
returns jsonb
language sql
as $$
  select pg_temp.cmd(p_seat, jsonb_build_object(
    'type', 'RESPOND',
    'pendingActionId', pg_temp.pending(),
    'response', 'CHOOSE',
    'selectedCardIds', to_jsonb(p_cards)))
$$;

-- Auxiliares desta fase --------------------------------------------------------

create function pg_temp.give_ghost(p_seat int, p_code text)
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
begin
  select id into v_id from app_private.game_cards
  where game_id = pg_temp.g() and card_code = p_code and owner_player_id is null
    and zone in ('ghost_deck', 'ghost_discard')
  limit 1;
  update app_private.game_cards
  set zone = 'ghost_hand', owner_player_id = pg_temp.p(p_seat),
      pile_position = coalesce((select max(pile_position) from app_private.game_cards
                                where owner_player_id = pg_temp.p(p_seat) and zone = 'ghost_hand'), 0) + 1
  where id = v_id;
  return v_id;
end;
$$;

create function pg_temp.ghost_hand(p_seat int) returns int language sql stable
as $$ select count(*)::int from app_private.game_cards where owner_player_id = pg_temp.p(p_seat) and zone = 'ghost_hand' $$;

-- Transforma o lugar em fantasma (mão principal descartada).
create function pg_temp.make_ghost(p_seat int, p_tokens int default 0, p_revived boolean default false)
returns void
language plpgsql
as $$
begin
  perform app_private.discard_cards(pg_temp.g(), pg_temp.p(p_seat),
    coalesce((select array_agg(id) from app_private.game_cards
              where owner_player_id = pg_temp.p(p_seat) and zone = 'player_hand'), array[]::uuid[]));
  update app_private.game_players
  set life_status = 'ghost', hp = 0, ghost_tokens = p_tokens, revival_used = p_revived
  where id = pg_temp.p(p_seat);
end;
$$;

create function pg_temp.status() returns text language sql stable
as $$ select status from app_private.games where id = pg_temp.g() $$;
create function pg_temp.result() returns jsonb language sql stable
as $$ select result_json from app_private.games where id = pg_temp.g() $$;
create function pg_temp.host_seat() returns int language sql stable
as $$ select gp.seat::int from app_private.game_players gp join app_private.games g on g.id = gp.game_id
      where g.id = pg_temp.g() and gp.user_id = g.host_user_id $$;


select pg_temp.set('g', pg_temp.started_game(array['1', '2', '3'])::text);

-- Mesa zerada com os automatismos ligados (como nas partidas de verdade).
create function pg_temp.fresh() returns void language sql
as $$
  select pg_temp.reset();
  update app_private.games set auto_flow = true where id = pg_temp.g();
$$;

create function pg_temp.seat() returns int language sql stable
as $$ select active_seat::int from app_private.games where id = pg_temp.g() $$;

create function pg_temp.last(p_kind text) returns jsonb language sql stable
as $$ select public_payload from app_private.game_events
      where game_id = pg_temp.g() and kind = p_kind order by seq desc limit 1 $$;

create function pg_temp.hand_ids(p_seat int) returns uuid[] language sql stable
as $$ select coalesce(array_agg(id order by pile_position), array[]::uuid[]) from app_private.game_cards
      where owner_player_id = pg_temp.p(p_seat) and zone = 'player_hand' $$;

create function pg_temp.timeout(p_seat int) returns jsonb language sql
as $$ select pg_temp.cmd(p_seat, '{"type": "TIMEOUT"}') $$;

-- 1. Fim de turno automático ----------------------------------------------------

select pg_temp.fresh();
select pg_temp.set('r1', pg_temp.give(1, 'REC-01')::text);
select pg_temp.set('r2', pg_temp.give(1, 'REC-02')::text);
select pg_temp.give(1, 'ATK-01');
select pg_temp.play(1, pg_temp.v('r1')::uuid, array[]::int[]);
select ok(pg_temp.seat() = 1 and pg_temp.phase() = 'turn_main', 'com ação sobrando, a vez continua');
select pg_temp.play(1, pg_temp.v('r2')::uuid, array[]::int[]);
select is(pg_temp.seat(), 2, 'gastou as 2 ações: o turno passa sozinho');
select is(pg_temp.last('turn_ended') ->> 'reason', 'auto', 'histórico marca o encerramento automático');

select pg_temp.fresh();
select pg_temp.set('r1', pg_temp.give(1, 'REC-01')::text);
select pg_temp.set('r2', pg_temp.give(1, 'REC-02')::text);
select pg_temp.give(1, c) from unnest(array['ATK-01', 'ATK-02', 'ATK-03', 'ATK-04', 'ATK-05', 'ATK-06', 'ATK-07', 'SAB-03']) c;
select pg_temp.play(1, pg_temp.v('r1')::uuid, array[]::int[]);
select pg_temp.play(1, pg_temp.v('r2')::uuid, array[]::int[]);
select ok(pg_temp.seat() = 1 and pg_temp.hand(1) = 8, 'acima do limite da mão, espera o descarte');
select lives_ok(
  format($$ select pg_temp.cmd(1, jsonb_build_object('type', 'END_TURN', 'discardCardIds', jsonb_build_array(%L))) $$,
         (pg_temp.hand_ids(1))[1]),
  'descartando, encerra normalmente');
select is(pg_temp.seat(), 2, 'e a vez passa');

select pg_temp.fresh();
select pg_temp.set('r1', pg_temp.give(1, 'REC-01')::text);
select pg_temp.play(1, pg_temp.v('r1')::uuid, array[]::int[]);
select is(pg_temp.seat(), 2, 'mão vazia com ação sobrando: não há o que fazer, o turno passa');

select pg_temp.fresh();
select pg_temp.make_ghost(2);
update app_private.games set active_seat = 2, phase = 'turn_ghost', actions_used = 0 where id = pg_temp.g();
select pg_temp.set('g4', pg_temp.give_ghost(2, 'GHO-04')::text);
select pg_temp.give_ghost(2, 'GHO-01');
select pg_temp.play(2, pg_temp.v('g4')::uuid, array[]::int[]);
select is(pg_temp.seat(), 3, 'fantasma que jogou a carta do Além passa a vez sozinho');

-- 2. Respostas automáticas ------------------------------------------------------

select pg_temp.fresh();
select pg_temp.set('atk', pg_temp.give(1, 'ATK-01')::text);
select pg_temp.give(1, 'REC-01');
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2]);
select ok(pg_temp.pending() is null and pg_temp.hp(2) = 13, 'alvo sem cartas na mão aceita o dano na hora');
select is(pg_temp.last('response_passed') ->> 'auto', 'true', 'histórico marca a resposta automática');

select pg_temp.fresh();
select pg_temp.set('atk', pg_temp.give(1, 'ATK-01')::text);
select pg_temp.give(1, 'REC-01');
select pg_temp.give(2, 'REC-02');
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2]);
select isnt(pg_temp.pending(), null, 'alvo com cartas, mesmo sem defesa, decide (ninguém deduz a mão dele)');
select is(pg_temp.view(2) -> 'myDecision' -> 'eligibleCardIds', '[]'::jsonb, 'só a tela dele sabe que não há defesa');
select ok((pg_temp.view(3) ->> 'responseDeadlineAt')::timestamptz = now() + interval '20 seconds',
  'a resposta tem 20 segundos de prazo');
select pg_temp.respond(2);
select is(pg_temp.hp(2), 13, 'aceitando, o dano entra');

select pg_temp.fresh();
select pg_temp.set('sab', pg_temp.give(1, 'SAB-05')::text);
select pg_temp.give(1, 'REC-01');
select pg_temp.give(2, 'REC-02');
select pg_temp.give(2, 'ATK-02');
select pg_temp.play(1, pg_temp.v('sab')::uuid, array[2]);
select pg_temp.respond(2);
select ok(pg_temp.pending() is null and pg_temp.hand(2) = 0,
  'descartar 2 com 2 cartas na mão: escolha forçada, feita sozinha');

-- 3. Prazos ---------------------------------------------------------------------

select pg_temp.fresh();
select ok((select turn_deadline_at = now() + interval '60 seconds' from app_private.games where id = pg_temp.g()),
  'o turno tem 60 segundos de prazo');
select ok(pg_temp.view(2) ?& array['turnDeadlineAt', 'serverNow', 'turnLimitSeconds'],
  'a visão traz os prazos e o relógio do servidor');
select throws_ok('select pg_temp.timeout(2)', 'P0001', 'NOT_EXPIRED', 'antes do prazo, TIMEOUT é recusado');

update app_private.games set turn_deadline_at = now() - interval '1 second' where id = pg_temp.g();
select ok((select turn_deadline_at < now() from app_private.games where id = pg_temp.g()),
  'mexer em outra coisa não reinicia o prazo');
select pg_temp.give(1, c) from unnest(array['ATK-01', 'ATK-02', 'ATK-03', 'ATK-04', 'ATK-05', 'ATK-06', 'ATK-07', 'REC-01', 'REC-02']) c;
select lives_ok('select pg_temp.timeout(3)', 'prazo vencido: qualquer um cobra, mesmo fora da vez');
select is(pg_temp.seat(), 2, 'o turno de quem demorou acaba');
select is(pg_temp.hand(1), 7, 'o excesso da mão é descartado ao acaso');
select ok(pg_temp.last('turn_ended') ->> 'reason' = 'timeout'
          and jsonb_array_length(pg_temp.last('turn_ended') -> 'discarded') = 2,
  'histórico registra o tempo esgotado e os descartes');
select ok((select turn_deadline_at = now() + interval '60 seconds' from app_private.games where id = pg_temp.g()),
  'o próximo turno ganha prazo novo');

select pg_temp.fresh();
select pg_temp.set('atk', pg_temp.give(1, 'ATK-01')::text);
select pg_temp.give(1, 'REC-01');
select pg_temp.give(2, 'DEF-01');
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2]);
select throws_ok('select pg_temp.timeout(1)', 'P0001', 'NOT_EXPIRED', 'resposta dentro do prazo não é cobrada');
update app_private.pending_actions set deadline_at = now() - interval '1 second' where id = pg_temp.pending();
select pg_temp.timeout(1);
select ok(pg_temp.pending() is null and pg_temp.hp(2) = 13 and pg_temp.hand(2) = 1,
  'quem não respondeu a tempo aceita (a defesa fica na mão)');
select is(pg_temp.last('response_passed') ->> 'timedOut', 'true', 'histórico registra o tempo esgotado');

select pg_temp.fresh();
select pg_temp.set('sab', pg_temp.give(1, 'SAB-05')::text);
select pg_temp.give(1, 'REC-01');
select pg_temp.give(2, c) from unnest(array['REC-02', 'ATK-02', 'ATK-03']) c;
select pg_temp.play(1, pg_temp.v('sab')::uuid, array[2]);
select pg_temp.respond(2);
select is((select stage from app_private.pending_actions where id = pg_temp.pending()), 'choice',
  'com 3 cartas, o alvo escolhe as 2 do descarte');
update app_private.pending_actions set deadline_at = now() - interval '1 second' where id = pg_temp.pending();
select pg_temp.timeout(3);
select ok(pg_temp.pending() is null and pg_temp.hand(2) = 1, 'sem escolha a tempo, as 2 são sorteadas');

select pg_temp.fresh();
select pg_temp.make_ghost(2, 3);
update app_private.games set active_seat = 2, phase = 'ghost_decision', actions_used = 0 where id = pg_temp.g();
update app_private.games set turn_deadline_at = now() - interval '1 second' where id = pg_temp.g();
select pg_temp.timeout(1);
select ok(pg_temp.phase() = 'turn_ghost'
          and (select life_status = 'ghost' from app_private.game_players where id = pg_temp.p(2)),
  'sem decidir a tempo, o fantasma fica no Além');
select is(pg_temp.last('turn_timed_out') ->> 'phase', 'ghost_decision', 'histórico registra a demora');

select * from finish();
rollback;
