-- Fase 6: ataques, defesas e reações.
begin;
create extension if not exists pgtap with schema extensions;

select plan(69);

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
  where id = v_game;
  update app_private.game_players
  set life_status = 'alive', hp = 16, max_hp = 16, knockouts = 0
  where game_id = v_game;
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

select pg_temp.set('g', pg_temp.started_game(array['1', '2', '3'])::text);

-- 1. Ataque simples e a janela de reação --------------------------------------

select pg_temp.reset();
select pg_temp.set('atk', pg_temp.give(1, 'ATK-01')::text);
select pg_temp.set('def05', pg_temp.give(2, 'DEF-05')::text);
select pg_temp.set('def02', pg_temp.give(2, 'DEF-02')::text);
select pg_temp.set('rev01', pg_temp.give(2, 'REV-01')::text);

select lives_ok(
  format('select pg_temp.play(1, %L, array[2])', pg_temp.v('atk')),
  'lugar 1 joga Falou Merda no lugar 2');
select is(pg_temp.phase(), 'awaiting_reactions', 'a jogada abre a janela de reação');
select is(pg_temp.hp(2), 16, 'o dano não é aplicado antes da resposta');
select is((select actions_used::int from app_private.games where id = pg_temp.g()), 1, 'gastou 1 ação');

select is(pg_temp.view(2) -> 'myDecision' ->> 'baseDamage', '3', 'o alvo vê quanto vai sofrer');
select is(pg_temp.view(2) -> 'myDecision' -> 'eligibleCardIds', jsonb_build_array(pg_temp.v('def02')),
  'só aparecem as reações que servem (Evento Raro e Tio Paulo não, o golpe não é fatal)');
select ok(pg_temp.view(3) -> 'myDecision' = 'null'::jsonb, 'quem não é alvo não tem decisão');
select is(pg_temp.view(3) -> 'pendingAction' -> 'responses' -> 0 ->> 'responded', 'false',
  'todos veem que o alvo ainda não respondeu');
select ok(position(pg_temp.v('def02') in pg_temp.view(3)::text) = 0,
  'as cartas do alvo não aparecem para os outros');

select throws_ok('select pg_temp.cmd(1, ''{"type": "END_TURN"}'')',
  'P0001', 'WRONG_PHASE', 'não encerra o turno com jogada pendente');
select throws_ok('select pg_temp.respond(3)',
  'P0001', 'NOT_YOUR_DECISION', 'quem não é alvo não responde');
select throws_ok(format('select pg_temp.respond(2, %L)', pg_temp.v('def05')),
  'P0001', 'REACTION_NOT_ALLOWED', 'Evento Raro não serve contra ataque');
select throws_ok(format('select pg_temp.respond(2, %L)', pg_temp.v('rev01')),
  'P0001', 'REACTION_NOT_ALLOWED', 'Ressuscitou o Tio Paulo só contra golpe fatal');

select pg_temp.set('req', gen_random_uuid()::text);
select lives_ok(format('select pg_temp.cmd(2, jsonb_build_object(''type'', ''RESPOND'', ''pendingActionId'', %L, ''response'', ''PASS''), %L)',
  pg_temp.pending(), pg_temp.v('req')), 'o alvo aceita');
select is(pg_temp.hp(2), 13, 'sofre 3');
select is(pg_temp.phase(), 'turn_main', 'a vez volta para quem atacou');
select is((select zone from app_private.game_cards where id = pg_temp.v('atk')::uuid), 'main_discard',
  'carta jogada vai para o descarte');
select ok((pg_temp.cmd(2, jsonb_build_object('type', 'RESPOND', 'response', 'PASS'), pg_temp.v('req')::uuid) ->> 'replayed')::boolean,
  'resposta repetida não é aplicada de novo');
select is(pg_temp.hp(2), 13, 'repetição não causa dano extra');

-- 2. Mais Odiado e defesas ----------------------------------------------------

select pg_temp.reset();
update app_private.games set leader_player_id = pg_temp.p(2) where id = pg_temp.g();
select pg_temp.set('atk', pg_temp.give(1, 'ATK-01')::text);
select pg_temp.set('def02', pg_temp.give(2, 'DEF-02')::text);
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2]);
select is(pg_temp.view(2) -> 'myDecision' ->> 'baseDamage', '4', 'ataque no Mais Odiado causa +1');
select pg_temp.respond(2, pg_temp.v('def02')::uuid);
select is(pg_temp.hp(2), 15, 'Inimiga do Banho reduz 3: sofre 1');
select is((select zone from app_private.game_cards where id = pg_temp.v('def02')::uuid), 'main_discard',
  'reação usada vai para o descarte público');

select pg_temp.reset();
select pg_temp.set('atk', pg_temp.give(1, 'ATK-02')::text);
select pg_temp.set('def01', pg_temp.give(2, 'DEF-01')::text);
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2]);
select pg_temp.respond(2, pg_temp.v('def01')::uuid);
select is(pg_temp.hp(2), 16, 'It''s Not Amazing anula o dano');

select pg_temp.reset();
select pg_temp.set('atk', pg_temp.give(1, 'ATK-01')::text);
select pg_temp.set('def06', pg_temp.give(2, 'DEF-06')::text);
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2]);
select pg_temp.respond(2, pg_temp.v('def06')::uuid);
select is(pg_temp.hp(2), 15, 'Último do After reduz 2');
select is(pg_temp.hand(2), 1, 'e compra 1 carta');

-- 3. Fofoca Mortal: dois alvos respondem separadamente ------------------------

select pg_temp.reset();
select pg_temp.set('atk', pg_temp.give(1, 'ATK-04')::text);
select throws_ok(format('select pg_temp.play(1, %L, array[2])', pg_temp.v('atk')),
  'P0001', 'INVALID_TARGET', 'com 2 adversários vivos, precisa escolher os 2');
select is((select actions_used::int from app_private.games where id = pg_temp.g()), 0,
  'jogada inválida não gasta ação');
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2, 3]);
select pg_temp.respond(2);
select is(pg_temp.phase(), 'awaiting_reactions', 'espera o segundo alvo responder');
select is(pg_temp.hp(2), 16, 'nada é aplicado antes de todos responderem');
select pg_temp.respond(3);
select ok(pg_temp.hp(2) = 14 and pg_temp.hp(3) = 14, 'os dois sofrem 2 no mesmo lote');

select pg_temp.reset();
update app_private.game_players set life_status = 'ghost', hp = 0 where id = pg_temp.p(3);
select pg_temp.set('atk', pg_temp.give(1, 'ATK-04')::text);
select throws_ok(format('select pg_temp.play(1, %L, array[2, 3])', pg_temp.v('atk')),
  'P0001', 'INVALID_TARGET', 'fantasma não é alvo de ataque');
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2]);
select pg_temp.respond(2);
select is(pg_temp.hp(2), 14, 'com um só adversário vivo, causa 2 nele (não dobra)');

-- 4. Print Comprometedor: alvo com mais cartas --------------------------------

select pg_temp.reset();
select pg_temp.set('atk', pg_temp.give(1, 'ATK-05')::text);
select pg_temp.give(3, 'REC-01');
select pg_temp.give(3, 'REC-02');
select pg_temp.give(2, 'REC-03');
select throws_ok(format('select pg_temp.play(1, %L, array[2])', pg_temp.v('atk')),
  'P0001', 'INVALID_TARGET', 'só pode mirar no adversário com mais cartas');
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[3]);
select pg_temp.respond(3);
select is(pg_temp.hp(3), 12, 'causa 4 em quem tem mais cartas');

-- 5. Peneira Suprema: custo de descarte ---------------------------------------

select pg_temp.reset();
select pg_temp.set('atk', pg_temp.give(1, 'ATK-03')::text);
select throws_ok(format('select pg_temp.play(1, %L, array[2])', pg_temp.v('atk')),
  'P0001', 'COST_REQUIRED', 'sem outra carta para pagar o custo, não joga');
select throws_ok(format('select pg_temp.play(1, %L, array[2], %L)', pg_temp.v('atk'), pg_temp.v('atk')),
  'P0001', 'COST_REQUIRED', 'a própria carta não paga o custo');
select is((select zone from app_private.game_cards where id = pg_temp.v('atk')::uuid), 'player_hand',
  'jogada recusada não consome nada');
select pg_temp.set('cost', pg_temp.give(1, 'REC-01')::text);
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2], pg_temp.v('cost')::uuid);
select is((select zone from app_private.game_cards where id = pg_temp.v('cost')::uuid), 'main_discard',
  'o custo vai para o descarte no anúncio');
select pg_temp.respond(2);
select is(pg_temp.hp(2), 11, 'causa 5');

-- 6. Restrições de jogada -----------------------------------------------------

select pg_temp.reset();
select pg_temp.set('def01', pg_temp.give(1, 'DEF-01')::text);
select throws_ok(format('select pg_temp.play(1, %L, array[2])', pg_temp.v('def01')),
  'P0001', 'REACTION_ONLY', 'reação não é jogada como ação');
select pg_temp.set('rec', pg_temp.give(1, 'REC-01')::text);
select throws_ok(format('select pg_temp.play(1, %L, array[2])', pg_temp.v('rec')),
  'P0001', 'INVALID_TARGET', 'recuperação não tem alvo');
update app_private.games set actions_used = 2 where id = pg_temp.g();
select pg_temp.set('atk', pg_temp.give(1, 'ATK-01')::text);
select throws_ok(format('select pg_temp.play(1, %L, array[2])', pg_temp.v('atk')),
  'P0001', 'NO_ACTIONS_LEFT', 'não existe terceira ação');
select throws_ok(format('select pg_temp.play(2, %L, array[1])', pg_temp.give(2, 'ATK-01')),
  'P0001', 'NOT_YOUR_TURN', 'fora da vez não ataca');

-- 7. Dano fatal ---------------------------------------------------------------

select pg_temp.reset();
update app_private.game_players set hp = 3 where id = pg_temp.p(2);
select pg_temp.set('atk', pg_temp.give(1, 'ATK-01')::text);
select pg_temp.set('rev01', pg_temp.give(2, 'REV-01')::text);
select pg_temp.set('rev03', pg_temp.give(2, 'REV-03')::text);
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2]);
select is(jsonb_array_length(pg_temp.view(2) -> 'myDecision' -> 'eligibleCardIds'), 2,
  'golpe fatal libera Ressuscitou o Tio Paulo e Última Palavra');
select pg_temp.respond(2, pg_temp.v('rev01')::uuid);
select results_eq(
  format($$ select hp::int, life_status, revival_used from app_private.game_players where id = %L $$, pg_temp.p(2)),
  $$ values (1, 'alive'::text, false) $$,
  'Ressuscitou o Tio Paulo: fica com 1 PV sem gastar a ressurreição');

select pg_temp.reset();
update app_private.game_players set hp = 3 where id = pg_temp.p(2);
update app_private.game_players set hp = 10 where id = pg_temp.p(1);
select pg_temp.set('atk', pg_temp.give(1, 'ATK-01')::text);
select pg_temp.set('rev03', pg_temp.give(2, 'REV-03')::text);
select pg_temp.give(2, 'REC-01');
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2]);
select pg_temp.respond(2, pg_temp.v('rev03')::uuid);
select results_eq(
  format($$ select hp::int, life_status from app_private.game_players where id = %L $$, pg_temp.p(2)),
  $$ values (0, 'ghost'::text) $$,
  'Última Palavra não impede a morte');
select is(pg_temp.hand(2), 0, 'quem morre descarta a mão principal');
select is(pg_temp.hp(1), 8, 'Última Palavra causa 2 em quem eliminou');
select is((select knockouts::int from app_private.game_players where id = pg_temp.p(1)), 1,
  'a eliminação conta para quem atacou');

select pg_temp.reset();
update app_private.game_players set hp = 2 where id = pg_temp.p(3);
select pg_temp.set('atk', pg_temp.give(1, 'ATK-01')::text);
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[3]);
select pg_temp.respond(3);
select is((select life_status from app_private.game_players where id = pg_temp.p(3)), 'ghost',
  'aceitar golpe fatal vira fantasma');
select is(
  (select public_payload ->> 'byPlayerId' from app_private.game_events
   where game_id = pg_temp.g() and kind = 'player_died' order by seq desc limit 1),
  pg_temp.p(1)::text, 'histórico registra quem eliminou');

-- 8. Reverso do Reverso -------------------------------------------------------

select pg_temp.reset();
select pg_temp.set('atk', pg_temp.give(1, 'ATK-01')::text);
select pg_temp.set('def04', pg_temp.give(2, 'DEF-04')::text);
select pg_temp.set('a_def04', pg_temp.give(1, 'DEF-04')::text);
select pg_temp.set('a_def02', pg_temp.give(1, 'DEF-02')::text);
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2]);
select pg_temp.respond(2, pg_temp.v('def04')::uuid);
select is((select stage from app_private.pending_actions where id = pg_temp.pending()), 'counter',
  'o ataque volta para o autor, que pode se defender');
select is(pg_temp.view(1) -> 'myDecision' ->> 'role', 'counter', 'o autor vê a decisão de contradefesa');
select throws_ok(format('select pg_temp.respond(1, %L)', pg_temp.v('a_def04')),
  'P0001', 'REACTION_NOT_ALLOWED', 'não dá para redirecionar de novo');
select pg_temp.respond(1, pg_temp.v('a_def02')::uuid);
select ok(pg_temp.hp(1) = 16 and pg_temp.hp(2) = 16, 'contradefesa reduz 3 do ataque de 3: ninguém sofre');

-- 9. A Braba: dano próprio ----------------------------------------------------

select pg_temp.reset();
select pg_temp.set('atk', pg_temp.give(1, 'ATK-07')::text);
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2]);
select pg_temp.respond(2);
select ok(pg_temp.hp(2) = 12 and pg_temp.hp(1) = 15, 'A Braba causa 4 no alvo e 1 no autor');

select pg_temp.reset();
update app_private.game_players set hp = 1 where id = pg_temp.p(1);
select pg_temp.set('atk', pg_temp.give(1, 'ATK-07')::text);
select pg_temp.set('rev01', pg_temp.give(1, 'REV-01')::text);
select pg_temp.set('rev03', pg_temp.give(1, 'REV-03')::text);
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2]);
select pg_temp.respond(2);
select is(pg_temp.hp(2), 12, 'o ataque resolve antes do dano próprio (B6)');
select is((select stage from app_private.pending_actions where id = pg_temp.pending()), 'self_fatal',
  'dano próprio fatal abre a decisão do autor');
select is(pg_temp.view(1) -> 'myDecision' -> 'eligibleCardIds', jsonb_build_array(pg_temp.v('rev01')),
  'só Ressuscitou o Tio Paulo serve; Última Palavra não (B6)');
select pg_temp.respond(1, pg_temp.v('rev01')::uuid);
select is(pg_temp.hp(1), 1, 'autor sobrevive com 1 PV');

-- 10. Lor! compra depois ------------------------------------------------------

select pg_temp.reset();
select pg_temp.set('atk', pg_temp.give(1, 'ATK-06')::text);
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2]);
select pg_temp.respond(2);
select ok(pg_temp.hp(2) = 14 and pg_temp.hand(1) = 1, 'Lor! causa 2 e o autor compra 1');

-- 11. Morrer no próprio turno (B5) --------------------------------------------

select pg_temp.reset();
update app_private.game_players set hp = 3 where id = pg_temp.p(1);
select pg_temp.set('atk', pg_temp.give(1, 'ATK-01')::text);
select pg_temp.set('def04', pg_temp.give(2, 'DEF-04')::text);
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2]);
select pg_temp.respond(2, pg_temp.v('def04')::uuid);
select pg_temp.respond(1);
select is((select life_status from app_private.game_players where id = pg_temp.p(1)), 'ghost',
  'ataque devolvido mata o autor');
select is((select knockouts::int from app_private.game_players where id = pg_temp.p(2)), 1,
  'a eliminação é de quem devolveu');
select results_eq(
  format($$ select active_seat::int, phase from app_private.games where id = %L $$, pg_temp.g()),
  $$ values (2, 'turn_main'::text) $$,
  'quem morre no próprio turno perde a vez na hora');

select pg_temp.reset();
update app_private.game_players set hp = 1 where id = pg_temp.p(1);
select pg_temp.set('atk', pg_temp.give(1, 'ATK-07')::text);
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2]);
select pg_temp.respond(2);
select pg_temp.respond(1);
select ok(
  (select life_status = 'ghost' from app_private.game_players where id = pg_temp.p(1))
  and (select sum(knockouts) = 0 from app_private.game_players where game_id = pg_temp.g()),
  'morte por dano próprio não conta eliminação para ninguém');
select is((select active_seat::int from app_private.games where id = pg_temp.g()), 2,
  'e o turno passa adiante');

-- 12. Integridade -------------------------------------------------------------

select is((select count(*)::int from app_private.game_cards where game_id = pg_temp.g()), 197,
  'nenhuma carta criada ou perdida nos cenários');
select ok(
  not exists (
    select 1 from app_private.game_events e
    join app_private.game_cards c on c.game_id = e.game_id
    -- (select …): avaliado uma vez, usa o índice em vez de varrer todas as partidas.
    where e.game_id = (select pg_temp.g()) and position(c.id::text in e.public_payload::text) > 0
  ),
  'eventos públicos não trazem ids de cartas');
select ok(not has_function_privilege('authenticated', 'app_private.apply_damage_batch(app_private.pending_actions)', 'execute'),
  'navegador não aplica dano por conta própria');

select * from finish();
rollback;
