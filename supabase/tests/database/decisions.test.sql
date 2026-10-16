-- Testes das decisões aprovadas já aplicáveis: A1, E1, E3, E5, E6.
begin;
create extension if not exists pgtap with schema extensions;

select plan(22);

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

create function pg_temp.v(p_k text) returns text language sql stable
as $$ select v from t where k = p_k $$;
grant execute on function pg_temp.v(text) to authenticated;

-- Sala do teste1 com teste2 e teste3 ------------------------------------------

select pg_temp.login('1');
insert into t select 'room', public.create_room() ->> 'id';
insert into t select 'code', public.get_room_view(pg_temp.v('room')::uuid) ->> 'code';
reset role; select pg_temp.login('2'); select public.join_room(pg_temp.v('code'));
reset role; select pg_temp.login('3'); select public.join_room(pg_temp.v('code'));

-- E1: rotação do código -------------------------------------------------------

reset role; select pg_temp.login('2');
select throws_ok(
  format('select public.rotate_room_code(%L)', pg_temp.v('room')),
  'P0001', 'NOT_HOST', 'só o host troca o código');

reset role; select pg_temp.login('1');
select public.rotate_room_code(pg_temp.v('room')::uuid);
insert into t select 'code2', public.get_room_view(pg_temp.v('room')::uuid) ->> 'code';

select isnt(pg_temp.v('code2'), pg_temp.v('code'), 'host gera um código novo');
select matches(pg_temp.v('code2'), '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{10}$',
  'código novo também tem 10 caracteres');

reset role;
select ok(
  (select count(*) = 2 from app_private.room_codes_used where code in (pg_temp.v('code'), pg_temp.v('code2'))),
  'códigos antigos ficam registrados e nunca são reemitidos');

select pg_temp.login('4');
select is(public.join_room(pg_temp.v('code')) ->> 'error', 'INVALID_CODE',
  'código antigo para de funcionar na hora');
select is(public.join_room(pg_temp.v('code2')) ->> 'gameId', pg_temp.v('room'),
  'código novo funciona');

-- E5: removido não volta sem liberação ----------------------------------------

reset role;
insert into t select 'p4', id::text from app_private.game_players
where game_id = pg_temp.v('room')::uuid and user_id = pg_temp.uid('4');

select pg_temp.login('1');
select public.kick_player(pg_temp.v('room')::uuid, pg_temp.v('p4')::uuid);

select is(
  public.get_room_view(pg_temp.v('room')::uuid) -> 'removedPlayers' -> 0 ->> 'userId',
  pg_temp.uid('4')::text, 'host vê quem removeu');

reset role; select pg_temp.login('2');
select is(
  jsonb_array_length(public.get_room_view(pg_temp.v('room')::uuid) -> 'removedPlayers'),
  0, 'só o host vê a lista de removidos');
select throws_ok(
  format('select public.allow_rejoin(%L, %L)', pg_temp.v('room'), pg_temp.uid('4')),
  'P0001', 'NOT_HOST', 'só o host libera a volta');

reset role; select pg_temp.login('4');
select throws_ok(
  format('select public.join_room(%L)', pg_temp.v('code2')),
  'P0001', 'REMOVED_FROM_ROOM', 'removido não volta só com o código');

reset role;
select is(
  (select count(*)::int from app_private.join_failures where user_id = pg_temp.uid('4')),
  1, 'tentativa de removido não conta como código errado (só a do código antigo conta)');

select pg_temp.login('1');
select public.allow_rejoin(pg_temp.v('room')::uuid, pg_temp.uid('4'));

reset role; select pg_temp.login('4');
select is(public.join_room(pg_temp.v('code2')) ->> 'gameId', pg_temp.v('room'),
  'depois da liberação do host, volta normalmente');

-- E6: presença no servidor e transferência de host ----------------------------

reset role;
-- teste2 entrou antes, mas está "desconectado"; teste3 está conectado.
update app_private.game_players
set last_seen_at = now() - interval '5 minutes'
where game_id = pg_temp.v('room')::uuid and user_id = pg_temp.uid('2');

select pg_temp.login('3');
select public.heartbeat(pg_temp.v('room')::uuid);
select ok(
  (select p ->> 'connected' from jsonb_array_elements(
     public.get_room_view(pg_temp.v('room')::uuid) -> 'players') p
   where p ->> 'userId' = pg_temp.uid('3')::text)::boolean,
  'heartbeat marca o jogador como conectado');
select ok(
  not (select p ->> 'connected' from jsonb_array_elements(
     public.get_room_view(pg_temp.v('room')::uuid) -> 'players') p
   where p ->> 'userId' = pg_temp.uid('2')::text)::boolean,
  'sem sinal há mais de 60 s aparece como desconectado');

reset role; select pg_temp.login('9');
select throws_ok(
  format('select public.heartbeat(%L)', pg_temp.v('room')),
  'P0001', 'ROOM_NOT_FOUND', 'quem não é membro não manda sinal de presença');

reset role; select pg_temp.login('1');
select public.leave_room(pg_temp.v('room')::uuid);

reset role;
select is(
  (select host_user_id from app_private.games where id = pg_temp.v('room')::uuid),
  pg_temp.uid('3'),
  'host que sai passa o posto ao conectado mais antigo, não a quem entrou antes e sumiu');

-- A1: lugares sorteados ao iniciar ---------------------------------------------

select pg_temp.login('5');
insert into t select 'big', public.create_room() ->> 'id';
insert into t select 'bigcode', public.get_room_view(pg_temp.v('big')::uuid) ->> 'code';
reset role; select pg_temp.login('6'); select public.join_room(pg_temp.v('bigcode'));
reset role; select pg_temp.login('7'); select public.join_room(pg_temp.v('bigcode'));
reset role; select pg_temp.login('8'); select public.join_room(pg_temp.v('bigcode'));
reset role; select pg_temp.login('9'); select public.join_room(pg_temp.v('bigcode'));
reset role; select pg_temp.login('2'); select public.join_room(pg_temp.v('bigcode'));
reset role; select pg_temp.login('3'); select public.join_room(pg_temp.v('bigcode'));
reset role; select pg_temp.login('4'); select public.join_room(pg_temp.v('bigcode'));

reset role;
insert into t
select 'join_order', string_agg(user_id::text, ',' order by seat)
from app_private.game_players where game_id = pg_temp.v('big')::uuid;

select pg_temp.login('5');
select public.start_game(pg_temp.v('big')::uuid,
  (public.get_room_view(pg_temp.v('big')::uuid) ->> 'version')::bigint);
reset role;

select is(
  (select array_agg(seat order by seat) from app_private.game_players where game_id = pg_temp.v('big')::uuid),
  array[1, 2, 3, 4, 5, 6, 7, 8]::smallint[],
  'lugares continuam sendo 1..8, sem repetição');

-- Probabilidade de sair igual à ordem de entrada: 1 em 40.320.
select isnt(
  (select string_agg(user_id::text, ',' order by seat) from app_private.game_players
   where game_id = pg_temp.v('big')::uuid),
  pg_temp.v('join_order'),
  'ordem dos lugares é sorteada, não a de entrada');

insert into t
select 'seats_after', string_agg(user_id::text, ',' order by seat)
from app_private.game_players where game_id = pg_temp.v('big')::uuid;

select pg_temp.login('5');
select public.get_game_view(pg_temp.v('big')::uuid);
reset role;
select is(
  (select string_agg(user_id::text, ',' order by seat) from app_private.game_players
   where game_id = pg_temp.v('big')::uuid),
  pg_temp.v('seats_after'),
  'ler a mesa (reload) não muda os lugares');

select ok(
  (select bool_and(n = case when seat = 1 then 7 else 5 end) from (
     select gp.seat, count(*) as n from app_private.game_cards c
     join app_private.game_players gp on gp.id = c.owner_player_id
     where gp.game_id = pg_temp.v('big')::uuid group by gp.id, gp.seat) x),
  'cartas distribuídas depois do sorteio: 5 para cada, e o lugar 1 já comprou 2');

select ok(
  (select is_deferrable from information_schema.table_constraints
   where constraint_schema = 'app_private' and constraint_name = 'game_players_game_id_seat_key') = 'YES',
  'unicidade de lugar é conferida no fim da troca');

-- B1 --------------------------------------------------------------------------

select ok(
  (select rules_text like '%só você vê%' and effect_params = '{"peek": 2, "discard": 1}'::jsonb
   from app_private.card_definitions where code = 'GHO-05'),
  'GHO-05 com o texto e os parâmetros aprovados');

select * from finish();
rollback;
