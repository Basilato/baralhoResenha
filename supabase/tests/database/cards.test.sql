begin;
create extension if not exists pgtap with schema extensions;

select plan(40);

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
grant execute on function pg_temp.uid(text) to authenticated;

create temp table t (k text primary key, v text);
grant select, insert, update on t to authenticated;

-- Cria uma partida iniciada com os usuários informados (o primeiro é o host).
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

-- Catálogo -------------------------------------------------------------------

select is((select count(*)::int from app_private.card_definitions where set_version = '7.1'),
  40, '40 modelos de carta');
select is((select sum(copies)::int from app_private.card_definitions
           where set_version = '7.1' and deck_type = 'main'), 177, 'baralho principal soma 177');
select is((select sum(copies)::int from app_private.card_definitions
           where set_version = '7.1' and deck_type = 'ghost'), 20, 'Além soma 20');
select results_eq(
  $$ select category, sum(copies)::int from app_private.card_definitions
     where set_version = '7.1' and deck_type = 'main' group by category order by category $$,
  $$ values ('attack', 50), ('chaos', 19), ('defense', 40), ('recovery', 21),
            ('reversal', 12), ('sabotage', 35) $$,
  'proporções por categoria batem com o plano');
select is((select count(*)::int from app_private.card_definitions
           where set_version = '7.1' and is_reaction), 9, 'nove modelos de reação');
select ok((select not is_provisional and effect_code = 'ghost_peek_discard' from app_private.card_definitions where code = 'GHO-05'),
  'GHO-05 aprovada com o efeito privado (B1)');

-- Partida de 3 ---------------------------------------------------------------

insert into t values ('g3', pg_temp.started_game(array['1', '2', '3'])::text);

select is((select count(*)::int from app_private.game_cards where game_id = (select v::uuid from t where k = 'g3')),
  197, '197 instâncias por partida');

select results_eq(
  format($$ select d.code, d.copies::bigint
            from app_private.card_definitions d
            where d.set_version = '7.1' order by d.code $$),
  format($$ select card_code, count(*) from app_private.game_cards
            where game_id = %L group by card_code order by card_code $$,
         (select v from t where k = 'g3')),
  'cada modelo tem exatamente o número de cópias do catálogo');

select is((select count(*)::int from app_private.game_cards
           where game_id = (select v::uuid from t where k = 'g3') and zone = 'player_hand'),
  17, '5 cartas para cada um dos 3, mais as 2 da compra do lugar 1');
select ok(
  (select bool_and(n = case when seat = 1 then 7 else 5 end) from (
     select gp.seat, count(*) as n from app_private.game_cards c
     join app_private.game_players gp on gp.id = c.owner_player_id
     where gp.game_id = (select v::uuid from t where k = 'g3')
     group by gp.id, gp.seat) x),
  'cada um recebe 5; o lugar 1 já comprou as 2 do primeiro turno (A3)');
select is((select count(*)::int from app_private.game_cards
           where game_id = (select v::uuid from t where k = 'g3') and zone = 'main_deck'),
  160, 'sobram 160 no baralho principal');
select is((select count(*)::int from app_private.game_cards
           where game_id = (select v::uuid from t where k = 'g3') and zone = 'ghost_deck'),
  20, 'Além intacto com 20');
select ok(
  (select bool_and(card_code like 'GHO-%') from app_private.game_cards
   where game_id = (select v::uuid from t where k = 'g3') and deck_type = 'ghost'),
  'cartas do Além só no baralho do Além');
select ok(
  (select bool_and(hp = 16 and max_hp = 16 and life_status = 'alive') from app_private.game_players
   where game_id = (select v::uuid from t where k = 'g3')),
  'com 3 jogadores todos começam com 16 PV');
select is(
  (select array_agg(pile_position order by pile_position) from app_private.game_cards
   where game_id = (select v::uuid from t where k = 'g3') and zone = 'main_deck'),
  (select array_agg(n) from generate_series(1, 160) n),
  'posições do baralho são 1..160, sem buracos nem repetição');

-- PV por número de jogadores
insert into t values ('g4', pg_temp.started_game(array['4', '5', '6', '7'])::text);
select ok(
  (select bool_and(hp = 18) from app_private.game_players where game_id = (select v::uuid from t where k = 'g4')),
  'com 4 jogadores todos começam com 18 PV');

select isnt(
  (select string_agg(card_code, ',' order by pile_position) from app_private.game_cards
   where game_id = (select v::uuid from t where k = 'g3') and zone = 'main_deck'),
  (select string_agg(card_code, ',' order by pile_position) from app_private.game_cards
   where game_id = (select v::uuid from t where k = 'g4') and zone = 'main_deck'),
  'cada partida tem um embaralhamento diferente');

insert into t
select 'p' || substr(gp.user_id::text, 36), gp.id::text
from app_private.game_players gp where gp.game_id = (select v::uuid from t where k = 'g3');

-- Privacidade ----------------------------------------------------------------

select ok(not has_table_privilege('authenticated', 'app_private.game_cards', 'select'),
  'navegador não lê game_cards');
select ok(not has_table_privilege('authenticated', 'app_private.card_definitions', 'select'),
  'navegador não lê card_definitions direto');
select ok(not has_function_privilege('authenticated', 'app_private.draw_cards(uuid, uuid, text, integer)', 'execute'),
  'navegador não compra cartas por conta própria');
select ok(not has_function_privilege('authenticated', 'app_private.discard_cards(uuid, uuid, uuid[])', 'execute'),
  'navegador não descarta por conta própria');
select ok(not has_function_privilege('authenticated', 'app_private.game_view(uuid, uuid)', 'execute'),
  'navegador não lê a visão de outro usuário');

select pg_temp.login('1');
insert into t select 'view1', public.get_game_view((select v::uuid from t where k = 'g3'))::text;
reset role;

select is(jsonb_array_length((select v::jsonb from t where k = 'view1') -> 'myHand'),
  (select count(*)::int from app_private.game_cards
   where owner_player_id = (select v::uuid from t where k = 'p1') and zone = 'player_hand'),
  'jogador vê todas as cartas da própria mão');
select ok(
  (select bool_and((p ->> 'cardsInHand')::int = case when (p ->> 'seat')::int = 1 then 7 else 5 end)
   from jsonb_array_elements((select v::jsonb from t where k = 'view1') -> 'participants') p),
  'vê quantas cartas cada um tem');
select ok(
  not exists (
    select 1 from app_private.game_cards c
    where c.game_id = (select v::uuid from t where k = 'g3')
      and c.owner_player_id is distinct from (select v::uuid from t where k = 'p1')
      and position(c.id::text in (select v from t where k = 'view1')) > 0
  ),
  'nenhuma carta fora da própria mão aparece na visão (nem por id)');
select ok(
  position('pile_position' in (select v from t where k = 'view1')) = 0
  and position('pilePosition' in (select v from t where k = 'view1')) = 0,
  'a ordem dos baralhos não sai do banco');
select is(((select v::jsonb from t where k = 'view1') ->> 'mainDeckCount')::int, 160,
  'visão mostra só a contagem do baralho');

select pg_temp.login('9');
select throws_ok(
  format('select public.get_game_view(%L)', (select v from t where k = 'g3')),
  'P0001', 'ROOM_NOT_FOUND', 'quem não está na partida não vê a mesa');
select is(jsonb_array_length(public.get_card_catalog()), 40, 'catálogo é legível por qualquer jogador');
reset role;

-- Compra e descarte ----------------------------------------------------------

insert into t select 'hand_before', count(*)::text from app_private.game_cards
where owner_player_id = (select v::uuid from t where k = 'p1') and zone = 'player_hand';

select is(app_private.draw_cards((select v::uuid from t where k = 'g3'), (select v::uuid from t where k = 'p1'), 'main', 3),
  3, 'compra 3 cartas');
select is((select count(*)::int from app_private.game_cards
           where owner_player_id = (select v::uuid from t where k = 'p1') and zone = 'player_hand'),
  (select v::int + 3 from t where k = 'hand_before'), 'mão cresce 3');

select throws_ok(
  format('select app_private.discard_to_hand_limit(%L, %L, array[]::uuid[])',
         (select v from t where k = 'g3'), (select v from t where k = 'p1')),
  'P0001', 'WRONG_DISCARD_COUNT', 'acima de 7 cartas precisa descartar o excedente');

select throws_ok(
  format('select app_private.discard_cards(%L, %L, array[%L]::uuid[])',
         (select v from t where k = 'g3'), (select v from t where k = 'p1'),
         (select id from app_private.game_cards where owner_player_id = (select v::uuid from t where k = 'p2') limit 1)),
  'P0001', 'CARD_NOT_IN_HAND', 'não descarta carta da mão de outro');

-- Excedente = mão - 7; a última da lista vai para o topo do descarte.
insert into t select 'excess', string_agg(id::text, ',' order by pile_position)
from (
  select id, pile_position from app_private.game_cards
  where owner_player_id = (select v::uuid from t where k = 'p1') and zone = 'player_hand'
  order by pile_position
  limit (select v::int + 3 - 7 from t where k = 'hand_before')
) x;
insert into t select 'disc', (string_to_array(v, ','))[cardinality(string_to_array(v, ','))]
from t where k = 'excess';

select is(
  app_private.discard_to_hand_limit((select v::uuid from t where k = 'g3'), (select v::uuid from t where k = 'p1'),
    string_to_array((select v from t where k = 'excess'), ',')::uuid[]),
  (select v::int + 3 - 7 from t where k = 'hand_before'), 'descarta exatamente o excedente');
select is((select count(*)::int from app_private.game_cards
           where owner_player_id = (select v::uuid from t where k = 'p1') and zone = 'player_hand'),
  7, 'fica com 7');

insert into t select 'disc_code', card_code from app_private.game_cards
where id = (select v::uuid from t where k = 'disc');

select pg_temp.login('2');
select is(
  public.get_game_view((select v::uuid from t where k = 'g3')) ->> 'mainDiscardTop',
  (select v from t where k = 'disc_code'),
  'carta descartada fica visível no topo do descarte');
reset role;

-- Reciclagem -----------------------------------------------------------------

-- Joga o baralho inteiro no descarte e compra: o descarte volta embaralhado.
update app_private.game_cards c
set zone = 'main_discard', pile_position = s.n + 1000
from (select id, row_number() over () as n from app_private.game_cards
      where game_id = (select v::uuid from t where k = 'g3') and zone = 'main_deck') s
where c.id = s.id;

select is(app_private.draw_cards((select v::uuid from t where k = 'g3'), (select v::uuid from t where k = 'p2'), 'main', 2),
  2, 'baralho vazio recicla o descarte e a compra acontece');
select is(
  (select count(*)::int from app_private.game_cards
   where game_id = (select v::uuid from t where k = 'g3') and zone = 'main_discard'),
  0, 'descarte foi todo para o baralho');
select is((select count(*)::int from app_private.game_cards where game_id = (select v::uuid from t where k = 'g3')),
  197, 'reciclagem não cria nem perde cartas');

-- Sem cartas sobrando: compra o que existe, nada é criado.
update app_private.game_cards
set zone = 'player_hand', owner_player_id = (select v::uuid from t where k = 'p3'),
    pile_position = pile_position + 10000
where game_id = (select v::uuid from t where k = 'g3') and zone in ('main_deck', 'main_discard');

select is(app_private.draw_cards((select v::uuid from t where k = 'g3'), (select v::uuid from t where k = 'p2'), 'main', 2),
  0, 'sem cartas no baralho nem no descarte, não compra nada');

select * from finish();
rollback;
