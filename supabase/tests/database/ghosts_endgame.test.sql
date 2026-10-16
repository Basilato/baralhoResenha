-- Fase 8: fantasmas, cartas do Além, Ressaca, fim de partida, ausência e revanche.
begin;
create extension if not exists pgtap with schema extensions;

select plan(48);

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
  set phase = 'turn_main', actions_used = 0, active_seat = 1, leader_player_id = null, pending_action_id = null
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

-- Partida nova para cada bloco de fim de jogo.
create function pg_temp.new_game() returns void language sql
as $$ select pg_temp.set('g', pg_temp.started_game(array['1', '2', '3'])::text) $$;

select pg_temp.new_game();

-- 1. Turno de fantasma e ressurreição ------------------------------------------

select pg_temp.reset();
select pg_temp.make_ghost(2, 2);
select pg_temp.give_ghost(2, 'GHO-01');
select pg_temp.cmd(1, '{"type": "END_TURN"}');
select results_eq(
  format($$ select g.phase, gp.ghost_tokens::int from app_private.games g
            join app_private.game_players gp on gp.game_id = g.id and gp.seat = g.active_seat
            where g.id = %L $$, pg_temp.g()),
  $$ values ('ghost_decision'::text, 3) $$,
  'com a 3ª ficha, o fantasma decide antes de comprar');
select is(pg_temp.ghost_hand(2), 1, 'ainda não comprou do Além');
select throws_ok('select pg_temp.cmd(2, ''{"type": "END_TURN"}'')',
  'P0001', 'WRONG_PHASE', 'não encerra sem decidir');

select pg_temp.cmd(2, '{"type": "GHOST_REVIVE"}');
select results_eq(
  format($$ select life_status, hp::int, revival_used, ghost_tokens::int from app_private.game_players where id = %L $$, pg_temp.p(2)),
  $$ values ('alive'::text, 6, true, 0) $$,
  'ressuscita com 6 PV, gasta a ressurreição e zera as fichas');
select ok(pg_temp.hand(2) = 3 and pg_temp.ghost_hand(2) = 0, 'volta com 3 cartas e sem cartas do Além');
select is((select active_seat::int from app_private.games where id = pg_temp.g()), 3,
  'ressuscitar encerra o turno');

-- Morre de novo: continua fantasma, sem fichas.
select pg_temp.make_ghost(2, 0, true);
update app_private.games set active_seat = 1, phase = 'turn_main', actions_used = 0 where id = pg_temp.g();
select pg_temp.cmd(1, '{"type": "END_TURN"}');
select results_eq(
  format($$ select g.phase, gp.ghost_tokens::int from app_private.games g
            join app_private.game_players gp on gp.game_id = g.id and gp.seat = g.active_seat
            where g.id = %L $$, pg_temp.g()),
  $$ values ('turn_ghost'::text, 0) $$,
  'depois da segunda morte não ganha mais fichas');

select pg_temp.reset();
select pg_temp.make_ghost(2, 2);
select pg_temp.cmd(1, '{"type": "END_TURN"}');
select pg_temp.cmd(2, '{"type": "GHOST_STAY"}');
select ok(pg_temp.phase() = 'turn_ghost' and pg_temp.ghost_hand(2) = 1
          and (select ghost_tokens = 3 from app_private.game_players where id = pg_temp.p(2)),
  'quem não ressuscita compra 1 do Além e guarda as fichas');

-- 2. Cartas do Além ------------------------------------------------------------

select pg_temp.reset();
select pg_temp.make_ghost(2);
update app_private.games set active_seat = 2, phase = 'turn_ghost', actions_used = 0 where id = pg_temp.g();
select pg_temp.set('g1', pg_temp.give_ghost(2, 'GHO-01')::text);
select pg_temp.set('g1b', pg_temp.give_ghost(2, 'GHO-01')::text);
select pg_temp.give(3, 'REC-01');
select pg_temp.give(3, 'REC-02');
select throws_ok(format('select pg_temp.play(2, %L, array[1])', pg_temp.v('g1')),
  'P0001', 'INVALID_TARGET', 'carta do Além não mira mão vazia');
select pg_temp.play(2, pg_temp.v('g1')::uuid, array[3]);
select ok(pg_temp.hand(3) = 1
          and (select zone from app_private.game_cards where id = pg_temp.v('g1')::uuid) = 'ghost_discard',
  'Victor Voltou Passando Mal: o vivo descarta 1 aleatória; a carta vai para o descarte do Além');
select throws_ok(format('select pg_temp.play(2, %L, array[3])', pg_temp.v('g1b')),
  'P0001', 'NO_ACTIONS_LEFT', 'fantasma joga no máximo 1 carta do Além por turno');

select pg_temp.reset();
select pg_temp.make_ghost(2);
update app_private.games set active_seat = 2, phase = 'turn_ghost', actions_used = 0 where id = pg_temp.g();
select pg_temp.give(3, 'REC-01');
select pg_temp.give(3, 'REC-02');
select pg_temp.play(2, pg_temp.give_ghost(2, 'GHO-02'), array[3]);
select is(jsonb_array_length(pg_temp.view(2) -> 'myPrivateEvents' -> 0 -> 'payload' -> 'codes'), 2,
  'Fantasma Fofoqueiro: o fantasma vê 2 cartas');
select is(jsonb_array_length(pg_temp.view(1) -> 'myPrivateEvents'), 0, 'os outros não veem');
select ok(
  (select not (public_payload ? 'codes') from app_private.game_events
   where game_id = pg_temp.g() and kind = 'ghost_peeked' order by seq desc limit 1),
  'o histórico público não mostra as cartas');

select pg_temp.reset();
select pg_temp.make_ghost(2);
update app_private.games set active_seat = 2, phase = 'turn_ghost', actions_used = 0 where id = pg_temp.g();
select pg_temp.set('c1', pg_temp.give(3, 'REC-01')::text);
select pg_temp.play(2, pg_temp.give_ghost(2, 'GHO-03'), array[3]);
select ok(
  (select zone = 'main_deck' and pile_position = (select min(pile_position) from app_private.game_cards
                                                 where game_id = pg_temp.g() and zone = 'main_deck')
   from app_private.game_cards where id = pg_temp.v('c1')::uuid),
  'Mão de Defunto: a carta vai para o fundo do baralho principal');

-- Maldição da Ressaca
select pg_temp.reset();
select pg_temp.make_ghost(3);
update app_private.games set active_seat = 3, phase = 'turn_ghost', actions_used = 0 where id = pg_temp.g();
select pg_temp.play(3, pg_temp.give_ghost(3, 'GHO-04'), array[]::int[]);
select ok(pg_temp.view(1) ->> 'curseActive' = 'true', 'a maldição fica pendente e visível');
update app_private.games set active_seat = 1, phase = 'turn_main', actions_used = 0,
  leader_player_id = pg_temp.p(2) where id = pg_temp.g();
select pg_temp.play(1, pg_temp.give(1, 'ATK-01'), array[2]);
select is(pg_temp.view(2) -> 'myDecision' ->> 'baseDamage', '5',
  'próximo ataque ao Mais Odiado: 3 + 1 (Mais Odiado) + 1 (maldição)');
select pg_temp.respond(2);
select ok(pg_temp.view(1) ->> 'curseActive' = 'false', 'a maldição é consumida');

-- GHO-05 com escolha privada entre as reveladas
select pg_temp.reset();
select pg_temp.make_ghost(2);
update app_private.games set active_seat = 2, phase = 'turn_ghost', actions_used = 0 where id = pg_temp.g();
select pg_temp.give(3, 'REC-01');
select pg_temp.give(3, 'REC-02');
select pg_temp.give(3, 'REC-03');
select pg_temp.give(3, 'REC-05');
select pg_temp.set('g5', pg_temp.give_ghost(2, 'GHO-05')::text);
select pg_temp.play(2, pg_temp.v('g5')::uuid, array[3]);
select is(jsonb_array_length(pg_temp.view(2) -> 'myDecision' -> 'options'), 2,
  'Eu Sei o Que Você Fez: o fantasma vê só 2 cartas aleatórias');
select ok(pg_temp.view(3) -> 'myDecision' = 'null'::jsonb
          and position('options' in coalesce((pg_temp.view(1) -> 'myDecision')::text, '')) = 0,
  'só o fantasma vê as cartas reveladas');
select pg_temp.set('hidden', (
  select id::text from app_private.game_cards
  where owner_player_id = pg_temp.p(3) and zone = 'player_hand'
    and not (id::text = any (array(select jsonb_array_elements(pg_temp.view(2) -> 'myDecision' -> 'options') ->> 'instanceId')))
  limit 1));
select throws_ok(format('select pg_temp.choose(2, array[%L]::uuid[])', pg_temp.v('hidden')),
  'P0001', 'WRONG_CHOICE', 'não dá para escolher carta que não foi revelada');
select pg_temp.choose(2, array[((pg_temp.view(2) -> 'myDecision' -> 'options' -> 0 ->> 'instanceId'))::uuid]);
select ok(pg_temp.hand(3) = 3 and pg_temp.phase() = 'turn_ghost'
          and (select zone from app_private.game_cards where id = pg_temp.v('g5')::uuid) = 'ghost_discard',
  'a escolhida é descartada e o fantasma volta ao turno dele');

-- 3. Ressaca Progressiva -------------------------------------------------------

select results_eq(
  $$ select r, app_private.hangover_damage(r)::int from generate_series(1, 10) r $$,
  $$ values (1,0),(2,0),(3,0),(4,0),(5,1),(6,1),(7,2),(8,2),(9,3),(10,3) $$,
  'Ressaca: 0 nas rodadas 1–4, 1 nas 5–6, 2 nas 7–8, 3 nas 9–10');

select pg_temp.reset();
update app_private.games set round_number = 5 where id = pg_temp.g();
select app_private.end_round(pg_temp.g());
select ok((select bool_and(hp = 15) from app_private.game_players where game_id = pg_temp.g()),
  'fim da rodada 5: todos os vivos sofrem 1');

select pg_temp.reset();
update app_private.games set round_number = 7 where id = pg_temp.g();
update app_private.game_players set hp = 2 where id = pg_temp.p(2);
select app_private.end_round(pg_temp.g());
select ok(
  (select life_status = 'ghost' from app_private.game_players where id = pg_temp.p(2))
  and (select sum(knockouts) = 0 from app_private.game_players where game_id = pg_temp.g()),
  'Ressaca elimina sem contar eliminação para ninguém');

-- 4. Fim antecipado ------------------------------------------------------------

select pg_temp.reset();
select pg_temp.make_ghost(3, 0, true);
-- A vítima já usou a ressurreição: depois de morrer, não volta mais.
update app_private.game_players set hp = 3, revival_used = true where id = pg_temp.p(2);
select pg_temp.play(1, pg_temp.give(1, 'ATK-01'), array[2]);
select pg_temp.respond(2);
select results_eq(
  format($$ select status, result_json ->> 'reason', result_json -> 'winnerPlayerIds' ->> 0
            from app_private.games where id = %L $$, pg_temp.g()),
  format($$ values ('finished'::text, 'last_alive'::text, %L::text) $$, pg_temp.p(1)),
  'último vivo vence quando nenhum fantasma pode mais voltar');

select pg_temp.new_game();
select pg_temp.reset();
select pg_temp.make_ghost(3, 0, false);
update app_private.game_players set hp = 3, revival_used = true where id = pg_temp.p(2);
select pg_temp.play(1, pg_temp.give(1, 'ATK-01'), array[2]);
select pg_temp.respond(2);
select is(pg_temp.status(), 'playing',
  'um vivo só, mas ainda há fantasma que pode ressuscitar: a partida continua');

select pg_temp.new_game();
select pg_temp.reset();
update app_private.games set round_number = 10 where id = pg_temp.g();
select pg_temp.make_ghost(3, 1, false);
update app_private.game_players set hp = 3 where id = pg_temp.p(2);
select pg_temp.play(1, pg_temp.give(1, 'ATK-01'), array[2]);
select pg_temp.respond(2);
select is(pg_temp.status(), 'finished',
  'na rodada 10, fantasma com 1 ficha e 1 turno restante não volta: acaba');

-- 5. Todos mortos --------------------------------------------------------------

select pg_temp.new_game();
select pg_temp.reset();
update app_private.games set round_number = 9 where id = pg_temp.g();
update app_private.game_players set hp = case seat when 1 then 2 when 2 then 3 else 1 end
where game_id = pg_temp.g();
select app_private.end_round(pg_temp.g());
select results_eq(
  format($$ select status, result_json ->> 'reason', result_json ->> 'criteria',
                   result_json -> 'winnerPlayerIds' ->> 0
            from app_private.games where id = %L $$, pg_temp.g()),
  format($$ values ('finished'::text, 'all_dead'::text, 'last_standing'::text, %L::text) $$, pg_temp.p(2)),
  'todos caem na mesma Ressaca: vence quem tinha mais PV antes do golpe');

select pg_temp.new_game();
select pg_temp.reset();
update app_private.games set round_number = 9 where id = pg_temp.g();
update app_private.game_players set hp = 2 where game_id = pg_temp.g();
update app_private.game_players set knockouts = 1 where id = pg_temp.p(3);
select app_private.end_round(pg_temp.g());
select is(pg_temp.result() ->> 'criteria', 'knockouts', 'empate de PV no lote: decide por eliminações');

select pg_temp.new_game();
select pg_temp.reset();
update app_private.games set round_number = 9 where id = pg_temp.g();
update app_private.game_players set hp = 2 where game_id = pg_temp.g();
select app_private.end_round(pg_temp.g());
select ok(pg_temp.result() ->> 'criteria' = 'shared'
          and jsonb_array_length(pg_temp.result() -> 'winnerPlayerIds') = 3,
  'empate total: vitória compartilhada');

select pg_temp.new_game();
select pg_temp.reset();
update app_private.games set round_number = 10 where id = pg_temp.g();
update app_private.game_players set hp = case seat when 1 then 5 when 2 then 4 else 4 end
where game_id = pg_temp.g();
select app_private.end_round(pg_temp.g());
select ok(pg_temp.result() ->> 'reason' = 'round_limit'
          and pg_temp.result() -> 'winnerPlayerIds' ->> 0 = pg_temp.p(1)::text,
  'fim da rodada 10 depois da Ressaca: vence quem ficou com mais PV');

-- 5b. A Braba derruba o último rival, mas o dano próprio ainda vem (B6) ------
-- Achado pelas simulações: a partida terminava antes do dano próprio, o autor
-- vencia sem pagar o custo e a carta ficava presa "em resolução".

select pg_temp.new_game();
select pg_temp.reset();
-- Rodada 10: quem cair agora não tem tempo de juntar fichas e voltar.
update app_private.games set round_number = 10 where id = pg_temp.g();
select pg_temp.make_ghost(3, 0, true); -- já voltou uma vez: não volta mais
update app_private.game_players set hp = 1 where id = pg_temp.p(1);
update app_private.game_players set hp = 2 where id = pg_temp.p(2);
select pg_temp.set('rev', pg_temp.give(1, 'REV-01')::text); -- autor pode se salvar
select pg_temp.play(1, pg_temp.give(1, 'ATK-07'), array[2]);
select pg_temp.respond(2);
select is(pg_temp.status(), 'playing',
  'alvo caiu, mas a partida espera o dano próprio da A Braba');
select pg_temp.respond(1);
select results_eq(
  format($$ select status, result_json ->> 'reason' from app_private.games where id = %L $$, pg_temp.g()),
  $$ values ('finished'::text, 'all_dead'::text) $$,
  'autor aceita o dano próprio fatal: todos caíram');
select is(array_to_string(app_private.check_game_integrity(pg_temp.g()), ' | '), '',
  'nenhuma carta presa em resolução no fim');

select pg_temp.new_game();
select pg_temp.reset();
update app_private.games set round_number = 10 where id = pg_temp.g();
select pg_temp.make_ghost(3, 0, true);
update app_private.game_players set hp = 1 where id = pg_temp.p(1);
update app_private.game_players set hp = 2 where id = pg_temp.p(2);
select pg_temp.set('rev', pg_temp.give(1, 'REV-01')::text);
select pg_temp.play(1, pg_temp.give(1, 'ATK-07'), array[2]);
select pg_temp.respond(2);
select pg_temp.respond(1, pg_temp.v('rev')::uuid);
select results_eq(
  format($$ select status, result_json ->> 'reason', result_json -> 'winnerPlayerIds' ->> 0
            from app_private.games where id = %L $$, pg_temp.g()),
  format($$ values ('finished'::text, 'last_alive'::text, %L::text) $$, pg_temp.p(1)),
  'autor se salva com Ressuscitou o Tio Paulo: vence como último vivo');
select is(array_to_string(app_private.check_game_integrity(pg_temp.g()), ' | '), '',
  'A Braba e a reação vão para o descarte');

-- 6. Ausência (E2) e sucessão de host ------------------------------------------

select pg_temp.new_game();
select pg_temp.reset();
select pg_temp.set('hs', pg_temp.host_seat()::text);
select pg_temp.set('vic', (case pg_temp.v('hs')::int when 2 then 3 else 2 end)::text);
select pg_temp.set('oth', (6 - pg_temp.v('hs')::int - pg_temp.v('vic')::int)::text);
update app_private.game_players set last_seen_at = now() - interval '5 minutes'
where id = pg_temp.p(pg_temp.v('vic')::int);

select throws_ok(
  format($$ select pg_temp.cmd(%s, jsonb_build_object('type', 'REMOVE_ABSENT', 'playerId', %L)) $$,
         pg_temp.v('oth'), pg_temp.p(pg_temp.v('vic')::int)),
  'P0001', 'NOT_HOST', 'só o host remove ausentes');
select throws_ok(
  format($$ select pg_temp.cmd(%s, jsonb_build_object('type', 'REMOVE_ABSENT', 'playerId', %L)) $$,
         pg_temp.v('hs'), pg_temp.p(pg_temp.v('oth')::int)),
  'P0001', 'PLAYER_NOT_ABSENT', 'quem está conectado não é removido');

-- O ausente é alvo de um ataque pendente: a remoção resolve como "passar".
update app_private.games set active_seat = pg_temp.v('oth')::int where id = pg_temp.g();
select pg_temp.play(pg_temp.v('oth')::int, pg_temp.give(pg_temp.v('oth')::int, 'ATK-01'),
  array[pg_temp.v('vic')::int]);
select pg_temp.give(pg_temp.v('vic')::int, 'REC-01');
select pg_temp.cmd(pg_temp.v('hs')::int,
  jsonb_build_object('type', 'REMOVE_ABSENT', 'playerId', pg_temp.p(pg_temp.v('vic')::int)));
select ok(
  (select life_status = 'quit' from app_private.game_players where id = pg_temp.p(pg_temp.v('vic')::int))
  and pg_temp.hand(pg_temp.v('vic')::int) = 0 and pg_temp.phase() = 'turn_main',
  'removido vira desistente, perde as cartas e a jogada pendente não trava');
select throws_ok(format('select pg_temp.cmd(%s, ''{"type": "END_TURN"}'')', pg_temp.v('vic')),
  'P0001', 'PLAYER_QUIT', 'desistente não joga mais');

select pg_temp.cmd(pg_temp.v('oth')::int, '{"type": "END_TURN"}');
select isnt((select active_seat::int from app_private.games where id = pg_temp.g()), pg_temp.v('vic')::int,
  'desistente é pulado na ordem dos turnos');

select throws_ok(format('select pg_temp.cmd(%s, ''{"type": "CLAIM_HOST"}'')', pg_temp.v('oth')),
  'P0001', 'HOST_PRESENT', 'não assume o posto com o host conectado');
update app_private.game_players set last_seen_at = now() - interval '5 minutes'
where id = pg_temp.p(pg_temp.v('hs')::int);
select pg_temp.cmd(pg_temp.v('oth')::int, '{"type": "CLAIM_HOST"}');
select is(pg_temp.host_seat(), pg_temp.v('oth')::int, 'host sumido há mais de 2 minutos: outro assume');

-- 7. Revanche ------------------------------------------------------------------

create function pg_temp.rematch(p_user text, p_join boolean)
returns text
language plpgsql
as $$
declare
  v_game uuid := pg_temp.g();
  v jsonb;
begin
  perform pg_temp.login(p_user);
  v := case when p_join then public.join_rematch(v_game) else public.create_rematch(v_game) end;
  perform set_config('role', 'postgres', true);
  return v ->> 'gameId';
end;
$$;

select pg_temp.new_game();
select app_private.finish_game(pg_temp.g(), 'round_limit', 'hp', array[pg_temp.p(1)]);
select pg_temp.set('rm', pg_temp.rematch(pg_temp.u(2), false));
select is(pg_temp.rematch(pg_temp.u(3), true), pg_temp.v('rm'), 'os outros entram na revanche sem código');
select is(pg_temp.rematch(pg_temp.u(1), false), pg_temp.v('rm'), 'pedir revanche de novo cai na mesma sala');
select is(
  (select count(*)::int from app_private.game_players where game_id = pg_temp.v('rm')::uuid),
  3, 'revanche com os 3 jogadores, em outra partida');
create function pg_temp.try_join_rematch(p_user text)
returns text
language plpgsql
as $$
declare
  v_game uuid := pg_temp.g();
begin
  perform pg_temp.login(p_user);
  perform public.join_rematch(v_game);
  perform set_config('role', 'postgres', true);
  return 'ok';
exception when others then
  perform set_config('role', 'postgres', true);
  return sqlerrm;
end;
$$;

select is(pg_temp.try_join_rematch('9'), 'ROOM_NOT_FOUND', 'quem não jogou não entra pela revanche');

select * from finish();
rollback;
