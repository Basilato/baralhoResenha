-- Fase 7: sabotagem, caos, recuperação e reviravolta.
begin;
create extension if not exists pgtap with schema extensions;

select plan(51);

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


-- Auxiliares desta fase --------------------------------------------------------

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

create function pg_temp.play_swap(p_seat int, p_card uuid, p_target int, p_own uuid)
returns jsonb
language sql
as $$
  select pg_temp.cmd(p_seat, jsonb_build_object(
    'type', 'PLAY_CARD',
    'cardInstanceId', p_card,
    'targetPlayerIds', jsonb_build_array(pg_temp.p(p_target)),
    'ownSwapCardId', p_own))
$$;

create function pg_temp.hand_ids(p_seat int) returns uuid[] language sql stable
as $$ select coalesce(array_agg(id order by pile_position), array[]::uuid[]) from app_private.game_cards
      where owner_player_id = pg_temp.p(p_seat) and zone = 'player_hand' $$;

create function pg_temp.owner(p_card text) returns int language sql stable
as $$ select gp.seat::int from app_private.game_cards c join app_private.game_players gp on gp.id = c.owner_player_id
      where c.id = p_card::uuid $$;

select pg_temp.set('g', pg_temp.started_game(array['1', '2', '3'])::text);

-- 1. Anota na Conta da Tuca (roubo) e Evento Raro ------------------------------

select pg_temp.reset();
select pg_temp.set('sab', pg_temp.give(1, 'SAB-01')::text);
select throws_ok(format('select pg_temp.play(1, %L, array[2])', pg_temp.v('sab')),
  'P0001', 'INVALID_TARGET', 'roubo não mira mão vazia');

select pg_temp.set('def01', pg_temp.give(2, 'DEF-01')::text);
select pg_temp.set('def05', pg_temp.give(2, 'DEF-05')::text);
select pg_temp.play(1, pg_temp.v('sab')::uuid, array[2]);
select is(pg_temp.view(2) -> 'myDecision' ->> 'role', 'sabotage_target', 'alvo da sabotagem decide');
select is(pg_temp.view(2) -> 'myDecision' -> 'eligibleCardIds', jsonb_build_array(pg_temp.v('def05')),
  'contra sabotagem só serve Evento Raro');
select pg_temp.respond(2);
select ok(pg_temp.hand(1) = 1 and pg_temp.hand(2) = 1, 'aceitou: o autor rouba 1 carta aleatória');
select is(pg_temp.phase(), 'turn_main', 'a vez volta para o autor');

select pg_temp.reset();
select pg_temp.set('sab', pg_temp.give(1, 'SAB-01')::text);
select pg_temp.set('def05', pg_temp.give(2, 'DEF-05')::text);
select pg_temp.give(2, 'REC-01');
select pg_temp.play(1, pg_temp.v('sab')::uuid, array[2]);
select pg_temp.respond(2, pg_temp.v('def05')::uuid);
select ok(pg_temp.hand(1) = 0 and pg_temp.hand(2) = 1, 'Evento Raro cancela a sabotagem');
select is(
  (select kind from app_private.game_events where game_id = pg_temp.g() order by seq desc offset 0 limit 1),
  'sabotage_blocked', 'histórico registra o cancelamento');

-- 2. Terapia de Boteco: só o autor vê a mão do alvo ----------------------------

select pg_temp.reset();
select pg_temp.set('sab', pg_temp.give(1, 'SAB-02')::text);
select pg_temp.set('b1', pg_temp.give(2, 'REC-01')::text);
select pg_temp.set('b2', pg_temp.give(2, 'ATK-01')::text);
select pg_temp.set('c1', pg_temp.give(3, 'ATK-02')::text);
select pg_temp.play(1, pg_temp.v('sab')::uuid, array[2]);
select pg_temp.respond(2);
select is(pg_temp.view(1) -> 'myDecision' ->> 'role', 'actor_pick', 'o autor escolhe o descarte');
select is(jsonb_array_length(pg_temp.view(1) -> 'myDecision' -> 'options'), 2,
  'o autor vê as 2 cartas do alvo');
select ok(position(pg_temp.v('b1') in pg_temp.view(3)::text) = 0,
  'a mão do alvo não aparece para os outros');
select throws_ok(format('select pg_temp.choose(1, array[%L, %L]::uuid[])', pg_temp.v('b1'), pg_temp.v('b2')),
  'P0001', 'WRONG_CHOICE', 'precisa escolher exatamente 1');
select throws_ok(format('select pg_temp.choose(1, array[%L]::uuid[])', pg_temp.v('c1')),
  'P0001', 'WRONG_CHOICE', 'só vale carta da mão do alvo');
select pg_temp.choose(1, array[pg_temp.v('b2')::uuid]);
select ok(
  (select zone from app_private.game_cards where id = pg_temp.v('b2')::uuid) = 'main_discard'
  and pg_temp.hand(2) = 1,
  'a carta escolhida vai para o descarte');

-- 3. Tem Alguém Seguindo: marca +2, consumo único e expiração -----------------

select pg_temp.reset();
select pg_temp.set('sab', pg_temp.give(1, 'SAB-03')::text);
select pg_temp.play(1, pg_temp.v('sab')::uuid, array[2]);
select pg_temp.respond(2);
select ok(pg_temp.view(3) -> 'markedPlayerIds' ? pg_temp.p(2)::text, 'todos veem quem está marcado');

select pg_temp.set('sab2', pg_temp.give(1, 'SAB-03')::text);
select pg_temp.play(1, pg_temp.v('sab2')::uuid, array[2]);
select pg_temp.respond(2);
select is((select count(*)::int from app_private.status_effects where game_id = pg_temp.g() and type = 'mark'), 1,
  'marcas não acumulam');

update app_private.games set actions_used = 0 where id = pg_temp.g();
select pg_temp.set('atk', pg_temp.give(1, 'ATK-01')::text);
select pg_temp.set('def01', pg_temp.give(2, 'DEF-01')::text);
select pg_temp.play(1, pg_temp.v('atk')::uuid, array[2]);
select is(pg_temp.view(2) -> 'myDecision' ->> 'baseDamage', '5', 'ataque no marcado causa +2');
select is((select count(*)::int from app_private.status_effects where game_id = pg_temp.g()), 0,
  'a marca é consumida no anúncio do ataque');
select pg_temp.respond(2, pg_temp.v('def01')::uuid);
select is(pg_temp.hp(2), 16, 'mesmo defendido, a marca já foi gasta');

select pg_temp.reset();
update app_private.games set round_number = 3 where id = pg_temp.g();
select pg_temp.set('sab', pg_temp.give(1, 'SAB-03')::text);
select pg_temp.play(1, pg_temp.v('sab')::uuid, array[2]);
select pg_temp.respond(2);
select app_private.end_round(pg_temp.g());
select is((select count(*)::int from app_private.status_effects where game_id = pg_temp.g()), 1,
  'a marca sobrevive ao fim da rodada em que foi aplicada');
select app_private.end_round(pg_temp.g());
select is((select count(*)::int from app_private.status_effects where game_id = pg_temp.g()), 0,
  'e expira ao fim da rodada seguinte');

-- 4. Eu Amo Mentir: troca simultânea ------------------------------------------

select pg_temp.reset();
select pg_temp.set('sab', pg_temp.give(1, 'SAB-04')::text);
select pg_temp.set('b1', pg_temp.give(2, 'REC-02')::text);
select throws_ok(format('select pg_temp.play_swap(1, %L, 2, null)', pg_temp.v('sab')),
  'P0001', 'SWAP_CARD_REQUIRED', 'precisa de outra carta sua para trocar');
select pg_temp.set('own', pg_temp.give(1, 'REC-01')::text);
select pg_temp.play_swap(1, pg_temp.v('sab')::uuid, 2, pg_temp.v('own')::uuid);
select pg_temp.respond(2);
select ok(pg_temp.owner(pg_temp.v('own')) = 2 and pg_temp.owner(pg_temp.v('b1')) = 1,
  'a carta escolhida vai para o alvo e a sorteada vem para o autor');

-- 5. Plano Dental Negado: o alvo escolhe o descarte ---------------------------

select pg_temp.reset();
select pg_temp.set('sab', pg_temp.give(1, 'SAB-05')::text);
select pg_temp.give(2, 'REC-01');
select pg_temp.give(2, 'REC-02');
select pg_temp.give(2, 'REC-03');
select pg_temp.play(1, pg_temp.v('sab')::uuid, array[2]);
select pg_temp.respond(2);
select ok((pg_temp.view(2) -> 'myDecision' ->> 'role') = 'target_discard'
          and (pg_temp.view(2) -> 'myDecision' ->> 'choiceCount')::int = 2,
  'o alvo escolhe 2 cartas para descartar');
select throws_ok(format('select pg_temp.choose(2, array[%L]::uuid[])', (pg_temp.hand_ids(2))[1]),
  'P0001', 'WRONG_CHOICE', 'tem carta suficiente: não pode descartar menos de 2');
select pg_temp.choose(2, (pg_temp.hand_ids(2))[1:2]);
select is(pg_temp.hand(2), 1, 'descarta 2 e fica com 1');

select pg_temp.reset();
select pg_temp.set('sab', pg_temp.give(1, 'SAB-05')::text);
select pg_temp.give(2, 'REC-01');
select pg_temp.play(1, pg_temp.v('sab')::uuid, array[2]);
select pg_temp.respond(2);
select is((pg_temp.view(2) -> 'myDecision' ->> 'choiceCount')::int, 1, 'com 1 carta, descarta 1');
select pg_temp.choose(2, pg_temp.hand_ids(2));
select is(pg_temp.hand(2), 0, 'fica sem cartas');

-- 6. Família Basilato (caos) ---------------------------------------------------

select pg_temp.reset();
update app_private.game_players set hp = 12 where id = pg_temp.p(3);
update app_private.games set leader_player_id = pg_temp.p(2) where id = pg_temp.g();
select pg_temp.set('cao', pg_temp.give(1, 'CAO-03')::text);
select throws_ok(format('select pg_temp.play(1, %L, array[3])', pg_temp.v('cao')),
  'P0001', 'INVALID_TARGET', 'mira só o adversário com mais PV');
select pg_temp.play(1, pg_temp.v('cao')::uuid, array[2]);
select ok(pg_temp.hp(2) = 13 and pg_temp.phase() = 'turn_main',
  'não fatal: 3 de dano direto, sem janela e sem bônus de Mais Odiado');

select pg_temp.reset();
update app_private.game_players set hp = 3 where game_id = pg_temp.g() and seat in (2, 3);
select pg_temp.set('cao', pg_temp.give(1, 'CAO-03')::text);
select pg_temp.give(2, 'DEF-01');
select pg_temp.set('rev01', pg_temp.give(2, 'REV-01')::text);
select pg_temp.play(1, pg_temp.v('cao')::uuid, array[2]);
select is(pg_temp.view(2) -> 'myDecision' -> 'eligibleCardIds', jsonb_build_array(pg_temp.v('rev01')),
  'golpe fatal de caos: só reação de golpe fatal, sem defesa comum (B4)');
select pg_temp.respond(2, pg_temp.v('rev01')::uuid);
select is(pg_temp.hp(2), 1, 'Ressuscitou o Tio Paulo segura em 1 PV');

select pg_temp.reset();
update app_private.game_players set hp = 3 where id = pg_temp.p(2);
update app_private.game_players set hp = 1 where id = pg_temp.p(3);
update app_private.game_players set hp = 10 where id = pg_temp.p(1);
select pg_temp.set('cao', pg_temp.give(1, 'CAO-03')::text);
select pg_temp.set('rev03', pg_temp.give(2, 'REV-03')::text);
select pg_temp.play(1, pg_temp.v('cao')::uuid, array[2]);
select pg_temp.respond(2, pg_temp.v('rev03')::uuid);
select ok(
  (select life_status = 'ghost' from app_private.game_players where id = pg_temp.p(2))
  and pg_temp.hp(1) = 8
  and (select knockouts = 1 from app_private.game_players where id = pg_temp.p(1)),
  'Última Palavra contra caos: morre, causa 2 e a eliminação conta para o autor');

-- 7. Bucetada e O Acre Existe! (escolhas simultâneas) --------------------------

select pg_temp.reset();
select pg_temp.set('cao', pg_temp.give(1, 'CAO-02')::text);
select pg_temp.set('a1', pg_temp.give(1, 'REC-01')::text);
select pg_temp.give(2, 'REC-02');
select pg_temp.give(2, 'REC-03');
select pg_temp.play(1, pg_temp.v('cao')::uuid, array[]::int[]);
select ok(pg_temp.view(1) -> 'myDecision' ->> 'role' = 'discard_pick'
          and pg_temp.view(2) -> 'myDecision' ->> 'role' = 'discard_pick'
          and pg_temp.view(3) -> 'myDecision' = 'null'::jsonb,
  'só os vivos com cartas escolhem (o lugar 3 está sem mão)');
select pg_temp.choose(2, array[(pg_temp.hand_ids(2))[1]]);
select is(pg_temp.hand(2), 2, 'nada sai da mão antes de todos escolherem');
select pg_temp.choose(1, array[pg_temp.v('a1')::uuid]);
select ok(pg_temp.hand(1) = 0 and pg_temp.hand(2) = 1 and pg_temp.phase() = 'turn_main',
  'cada um descarta a carta escolhida');

select pg_temp.reset();
select pg_temp.set('cao', pg_temp.give(1, 'CAO-04')::text);
select pg_temp.give(2, 'REC-02');
select pg_temp.play(1, pg_temp.v('cao')::uuid, array[]::int[]);
select ok(pg_temp.hand(1) = 1 and pg_temp.hand(2) = 2 and pg_temp.hand(3) = 1,
  'O Acre Existe!: todos os vivos compram 1');
select pg_temp.choose(1, array[(pg_temp.hand_ids(1))[1]]);
select pg_temp.choose(2, array[(pg_temp.hand_ids(2))[1]]);
select pg_temp.choose(3, array[(pg_temp.hand_ids(3))[1]]);
select ok(pg_temp.hand(1) = 0 and pg_temp.hand(2) = 1 and pg_temp.hand(3) = 0,
  'e depois cada um descarta 1');

-- 8. Tio Paulo: passa para a direita, ao mesmo tempo ---------------------------

select pg_temp.reset();
select pg_temp.set('cao', pg_temp.give(1, 'CAO-01')::text);
select pg_temp.set('a1', pg_temp.give(1, 'REC-01')::text);
select pg_temp.set('b1', pg_temp.give(2, 'REC-02')::text);
select pg_temp.set('c1', pg_temp.give(3, 'REC-03')::text);
select pg_temp.play(1, pg_temp.v('cao')::uuid, array[]::int[]);
select pg_temp.choose(3, array[pg_temp.v('c1')::uuid]);
select pg_temp.choose(1, array[pg_temp.v('a1')::uuid]);
select pg_temp.choose(2, array[pg_temp.v('b1')::uuid]);
select ok(pg_temp.owner(pg_temp.v('a1')) = 2 and pg_temp.owner(pg_temp.v('b1')) = 3
          and pg_temp.owner(pg_temp.v('c1')) = 1,
  'cada um entrega ao próximo vivo, dando a volta (ninguém repassa o que recebeu)');

select pg_temp.reset();
update app_private.game_players set life_status = 'ghost', hp = 0 where id = pg_temp.p(2);
select pg_temp.set('cao', pg_temp.give(1, 'CAO-01')::text);
select pg_temp.set('a1', pg_temp.give(1, 'REC-01')::text);
select pg_temp.set('c1', pg_temp.give(3, 'REC-03')::text);
select pg_temp.play(1, pg_temp.v('cao')::uuid, array[]::int[]);
select pg_temp.choose(1, array[pg_temp.v('a1')::uuid]);
select pg_temp.choose(3, array[pg_temp.v('c1')::uuid]);
select ok(pg_temp.owner(pg_temp.v('a1')) = 3 and pg_temp.owner(pg_temp.v('c1')) = 1,
  'fantasmas são pulados na passagem');

select pg_temp.reset();
select pg_temp.set('cao', pg_temp.give(1, 'CAO-01')::text);
select pg_temp.give(1, 'REC-01');
select pg_temp.play(1, pg_temp.v('cao')::uuid, array[]::int[]);
select ok(pg_temp.phase() = 'turn_main' and pg_temp.hand(1) = 1,
  'menos de 2 vivos com carta: não há troca');

-- 9. Recuperação ---------------------------------------------------------------

select pg_temp.reset();
update app_private.game_players set hp = 10 where id = pg_temp.p(1);
select pg_temp.play(1, pg_temp.give(1, 'REC-01'), array[]::int[]);
select ok(pg_temp.hp(1) = 14 and pg_temp.phase() = 'turn_main', 'After do After cura 4 na hora');
select pg_temp.play(1, pg_temp.give(1, 'REC-02'), array[]::int[]);
select is(pg_temp.hp(1), 16, 'cura não passa do PV máximo');

select pg_temp.reset();
update app_private.game_players set hp = 8 where id = pg_temp.p(1);
select pg_temp.play(1, pg_temp.give(1, 'REC-03'), array[]::int[]);
select ok(pg_temp.hp(1) = 11 and pg_temp.hand(1) = 1, 'Consultório Lucboy cura 3 e compra 1');
select pg_temp.play(1, pg_temp.give(1, 'REC-05'), array[]::int[]);
select ok(pg_temp.hp(1) = 13 and pg_temp.hand(1) = 3, 'English Mode cura 2 e compra 2');

select pg_temp.reset();
update app_private.game_players set hp = 8 where id = pg_temp.p(1);
select pg_temp.set('rec', pg_temp.give(1, 'REC-04')::text);
select throws_ok(format('select pg_temp.play(1, %L, array[]::int[])', pg_temp.v('rec')),
  'P0001', 'COST_REQUIRED', 'Anestesia Alcoólica exige descartar outra carta');
select pg_temp.play(1, pg_temp.v('rec')::uuid, array[]::int[], pg_temp.give(1, 'ATK-01'));
select ok(pg_temp.hp(1) = 13 and pg_temp.hand(1) = 0, 'paga o custo e cura 5');

-- 10. Lucboy & Laragirl: troca de mãos -----------------------------------------

select pg_temp.reset();
select pg_temp.set('rev', pg_temp.give(1, 'REV-02')::text);
select pg_temp.set('a1', pg_temp.give(1, 'REC-01')::text);
select pg_temp.set('b1', pg_temp.give(2, 'REC-02')::text);
select pg_temp.set('b2', pg_temp.give(2, 'REC-03')::text);
select pg_temp.set('def05', pg_temp.give(2, 'DEF-05')::text);
select pg_temp.play(1, pg_temp.v('rev')::uuid, array[2]);
select ok(
  pg_temp.phase() = 'turn_main'
  and pg_temp.owner(pg_temp.v('a1')) = 2
  and pg_temp.owner(pg_temp.v('b1')) = 1 and pg_temp.owner(pg_temp.v('def05')) = 1,
  'troca as mãos restantes na hora; Evento Raro não cancela (B2)');

select pg_temp.reset();
select pg_temp.set('rev', pg_temp.give(1, 'REV-02')::text);
select pg_temp.give(1, 'REC-01');
select pg_temp.play(1, pg_temp.v('rev')::uuid, array[3]);
select ok(pg_temp.hand(1) = 0 and pg_temp.hand(3) = 1, 'troca vale mesmo com uma mão vazia');

-- 11. Integridade --------------------------------------------------------------

select ok(
  (select bool_and(n = 1) from (
     select count(*) as n from app_private.game_cards
     where game_id = pg_temp.g() and owner_player_id is not null and zone = 'player_hand'
     group by owner_player_id, pile_position) x),
  'nenhuma posição repetida dentro de uma mão depois das trocas');
select is((select count(*)::int from app_private.game_cards where game_id = pg_temp.g()), 200,
  'nenhuma carta criada ou perdida');
select ok(
  not exists (
    select 1 from app_private.game_events e
    join app_private.game_cards c on c.game_id = e.game_id
    -- (select …): avaliado uma vez, usa o índice em vez de varrer todas as partidas.
    where e.game_id = (select pg_temp.g()) and position(c.id::text in e.public_payload::text) > 0
  ),
  'eventos públicos não trazem ids de cartas');

select * from finish();
rollback;
