begin;
create extension if not exists pgtap with schema extensions;

select plan(50);

-- Contas do seed: teste1..teste9 = ...0001..0009
-- Troca de usuário: reset role (como postgres) e depois pg_temp.login().
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

-- Valores compartilhados entre os passos.
create temp table t (k text primary key, v text);
grant select, insert, update on t to authenticated;

-- Superfície exposta ---------------------------------------------------------

select ok(not has_table_privilege('authenticated', 'app_private.games', 'select'),
  'navegador não lê games');
select ok(not has_table_privilege('authenticated', 'app_private.game_players', 'select'),
  'navegador não lê game_players');
select ok(not has_table_privilege('authenticated', 'app_private.game_invites', 'select'),
  'navegador não lê game_invites');
select ok(not has_function_privilege('anon', 'public.create_room()', 'execute'),
  'anon não executa create_room');
select ok(not has_function_privilege('authenticated', 'app_private.touch_game(uuid)', 'execute'),
  'navegador não chama touch_game direto');
select ok(not has_function_privilege('authenticated', 'app_private.fail(text, text)', 'execute'),
  'navegador não chama auxiliares internos');

-- Criar sala -----------------------------------------------------------------

select pg_temp.login('1');
insert into t
select 'room', r ->> 'id' from (select public.create_room() as r) x;
insert into t
select 'code', r ->> 'code' from (select public.get_room_view((select v::uuid from t where k = 'room')) as r) x;

select matches((select v from t where k = 'code'), '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$',
  'código tem 6 caracteres sem ambíguos');

select is(
  (select jsonb_array_length(public.get_room_view((select v::uuid from t where k = 'room')) -> 'players')),
  1, 'criador entra na sala');

select is(
  (select public.get_room_view((select v::uuid from t where k = 'room')) -> 'players' -> 0 ->> 'isHost'),
  'true', 'criador é o host no assento 1');

-- Entrar ---------------------------------------------------------------------

reset role;
select pg_temp.login('2');

select is(
  (select public.join_room(lower(' ' || (select v from t where k = 'code') || ' ')) ->> 'gameId'),
  (select v from t where k = 'room'),
  'entra com código em minúsculas e espaços');

select is(
  (select public.join_room((select v from t where k = 'code')) ->> 'gameId'),
  (select v from t where k = 'room'),
  'entrar de novo é idempotente');

select is(
  (select jsonb_array_length(public.get_room_view((select v::uuid from t where k = 'room')) -> 'players')),
  2, 'entrada repetida não duplica jogador');

select is(public.join_room('ZZZZZZ') ->> 'error', 'INVALID_CODE', 'código inexistente é recusado');

select throws_ok(
  format('select public.start_game(%L, 1)', (select v from t where k = 'room')),
  'P0001', 'NOT_HOST', 'só o host inicia');

-- Não membro -----------------------------------------------------------------

reset role;
select pg_temp.login('9');

select throws_ok(
  format('select public.get_room_view(%L)', (select v from t where k = 'room')),
  'P0001', 'ROOM_NOT_FOUND', 'não membro não vê a sala');

select throws_ok(
  format('select public.close_room(%L)', (select v from t where k = 'room')),
  'P0001', 'ROOM_NOT_FOUND', 'não membro não encerra a sala');

select ok(
  not app_private.can_use_game_topic('game:' || (select v from t where k = 'room')),
  'não membro não assina o canal da sala');

-- Menos de 3 -----------------------------------------------------------------

reset role;
select pg_temp.login('1');

select throws_ok(
  format('select public.start_game(%L, %s)', (select v from t where k = 'room'),
    (select (public.get_room_view((select v::uuid from t where k = 'room')) ->> 'version'))),
  'P0001', 'NOT_ENOUGH_PLAYERS', 'não inicia com 2 jogadores');

select ok(
  app_private.can_use_game_topic('game:' || (select v from t where k = 'room')),
  'membro assina o canal da sala');
select ok(not app_private.can_use_game_topic('game:nao-e-uuid'), 'tópico malformado é negado');
select ok(not app_private.can_use_game_topic('outra:coisa'), 'tópico de outro tipo é negado');

-- Lotar a sala (3..8) --------------------------------------------------------

reset role; select pg_temp.login('3'); select public.join_room((select v from t where k = 'code'));
reset role; select pg_temp.login('4'); select public.join_room((select v from t where k = 'code'));
reset role; select pg_temp.login('5'); select public.join_room((select v from t where k = 'code'));
reset role; select pg_temp.login('6'); select public.join_room((select v from t where k = 'code'));
reset role; select pg_temp.login('7'); select public.join_room((select v from t where k = 'code'));
reset role; select pg_temp.login('8'); select public.join_room((select v from t where k = 'code'));

select is(
  (select jsonb_array_length(public.get_room_view((select v::uuid from t where k = 'room')) -> 'players')),
  8, 'oito pessoas na sala');

reset role;
select pg_temp.login('9');

select throws_ok(
  format('select public.join_room(%L)', (select v from t where k = 'code')),
  'P0001', 'ROOM_FULL', 'a 9ª pessoa é recusada');

reset role;
select is(
  (select count(*)::int from app_private.game_players where game_id = (select v::uuid from t where k = 'room')),
  8, 'recusa da 9ª não corrompe a mesa de 8');

-- Remover jogador ------------------------------------------------------------

insert into t select 'p8', id::text from app_private.game_players
where game_id = (select v::uuid from t where k = 'room') and user_id = pg_temp.uid('8');
insert into t select 'p1', id::text from app_private.game_players
where game_id = (select v::uuid from t where k = 'room') and user_id = pg_temp.uid('1');

select pg_temp.login('2');
select throws_ok(
  format('select public.kick_player(%L, %L)', (select v from t where k = 'room'), (select v from t where k = 'p8')),
  'P0001', 'NOT_HOST', 'só o host remove jogadores');

reset role;
select pg_temp.login('1');
select throws_ok(
  format('select public.kick_player(%L, %L)', (select v from t where k = 'room'), (select v from t where k = 'p1')),
  'P0001', 'CANNOT_KICK_SELF', 'host não remove a si mesmo');

select lives_ok(
  format('select public.kick_player(%L, %L)', (select v from t where k = 'room'), (select v from t where k = 'p8')),
  'host remove jogador no lobby');

reset role;
select pg_temp.login('9');
select is(
  (select public.join_room((select v from t where k = 'code')) ->> 'gameId'),
  (select v from t where k = 'room'),
  'vaga liberada pode ser ocupada');

-- Pronto ---------------------------------------------------------------------

reset role;
select pg_temp.login('2');
select public.set_ready((select v::uuid from t where k = 'room'), true);
select is(
  (select p ->> 'isReady' from jsonb_array_elements(
     public.get_room_view((select v::uuid from t where k = 'room')) -> 'players') p
   where p ->> 'userId' = pg_temp.uid('2')::text),
  'true', 'jogador marca pronto');

-- Iniciar --------------------------------------------------------------------

reset role;
select pg_temp.login('1');

select throws_ok(
  format('select public.start_game(%L, 1)', (select v from t where k = 'room')),
  'P0001', 'VERSION_CONFLICT', 'início com versão desatualizada é recusado');

select lives_ok(
  format('select public.start_game(%L, %s)', (select v from t where k = 'room'),
    (select (public.get_room_view((select v::uuid from t where k = 'room')) ->> 'version'))),
  'host inicia com 8');

select is(
  (select public.get_room_view((select v::uuid from t where k = 'room')) ->> 'status'),
  'playing', 'sala passa para playing');

select ok(
  (select public.get_room_view((select v::uuid from t where k = 'room')) -> 'code') = 'null'::jsonb,
  'código some depois do início');

select throws_ok(
  format('select public.start_game(%L, %s)', (select v from t where k = 'room'),
    (select (public.get_room_view((select v::uuid from t where k = 'room')) ->> 'version'))),
  'P0001', 'ROOM_ALREADY_STARTED', 'segundo início é recusado (não cria dois decks)');

select throws_ok(
  format('select public.kick_player(%L, %L)', (select v from t where k = 'room'), (select v from t where k = 'p1')),
  'P0001', 'ROOM_ALREADY_STARTED', 'ninguém é removido depois do início');

reset role;
select pg_temp.login('8');
select throws_ok(
  format('select public.join_room(%L)', (select v from t where k = 'code')),
  'P0001', 'ROOM_ALREADY_STARTED', 'quem saiu não entra depois do início');

reset role;
select pg_temp.login('3');
select is(
  (select public.join_room((select v from t where k = 'code')) ->> 'status'),
  'playing', 'membro que reabre o link volta para a partida');

select throws_ok(
  format('select public.leave_room(%L)', (select v from t where k = 'room')),
  'P0001', 'ROOM_ALREADY_STARTED', 'ninguém sai no meio da partida');

-- Encerrar -------------------------------------------------------------------

select throws_ok(
  format('select public.close_room(%L)', (select v from t where k = 'room')),
  'P0001', 'NOT_HOST', 'só o host encerra');

reset role;
select pg_temp.login('1');
select public.close_room((select v::uuid from t where k = 'room'));
select is(
  (select public.get_room_view((select v::uuid from t where k = 'room')) ->> 'status'),
  'cancelled', 'host encerra a partida travada');

-- Troca de host e sala vazia -------------------------------------------------

reset role;
select pg_temp.login('2');
insert into t select 'room2', public.create_room() ->> 'id';
insert into t select 'code2', public.get_room_view((select v::uuid from t where k = 'room2')) ->> 'code';

reset role; select pg_temp.login('3'); select public.join_room((select v from t where k = 'code2'));
reset role; select pg_temp.login('2'); select public.leave_room((select v::uuid from t where k = 'room2'));

reset role; select pg_temp.login('3');
select is(
  (select public.get_room_view((select v::uuid from t where k = 'room2')) ->> 'hostUserId'),
  pg_temp.uid('3')::text, 'host que sai passa o posto para o próximo');

select public.leave_room((select v::uuid from t where k = 'room2'));
reset role;
select is(
  (select status from app_private.games where id = (select v::uuid from t where k = 'room2')),
  'cancelled', 'sala sem ninguém é cancelada');

-- Limites --------------------------------------------------------------------

insert into app_private.join_failures (user_id)
select pg_temp.uid('4') from generate_series(1, 10);

select pg_temp.login('4');
select throws_ok(
  $$ select public.join_room('ABCDEF') $$,
  'P0001', 'TOO_MANY_ATTEMPTS', 'muitos códigos errados bloqueiam por um tempo');

reset role;
select pg_temp.login('6');
select public.create_room() from generate_series(1, 5);
select throws_ok(
  $$ select public.create_room() $$,
  'P0001', 'TOO_MANY_ROOMS', 'limite de 5 salas abertas por pessoa');

select is(jsonb_array_length(public.list_my_rooms()), 5, 'list_my_rooms mostra as salas abertas');

-- Partidas em andamento não contam no limite (ninguém fica preso).
reset role;
update app_private.games
set status = 'playing', started_at = now()
where host_user_id = pg_temp.uid('6') and status = 'lobby';
select pg_temp.login('6');
select lives_ok(
  $$ select public.create_room() $$,
  'partidas em andamento não contam no limite de salas');

select ok(
  app_private.can_use_game_topic('game:' || upper(public.list_my_rooms() -> 0 ->> 'id')),
  'tópico com UUID em maiúsculas é aceito para membro');

-- teste9 não é host de nada: só a FK de game_players pode barrar.
reset role;
select throws_ok(
  format('delete from auth.users where id = %L', pg_temp.uid('9')),
  '23503',
  null,
  'apagar conta que está em partidas é bloqueado (desative em vez de apagar)');

reset role;
update public.profiles set is_active = false where id = pg_temp.uid('7');
select pg_temp.login('7');
select throws_ok(
  $$ select public.create_room() $$,
  'P0001', 'ACCOUNT_DISABLED', 'conta desativada não usa as RPCs');

-- Realtime -------------------------------------------------------------------

reset role;
select ok(
  exists (
    select 1 from realtime.messages
    where topic = 'game:' || (select v from t where k = 'room')
      and event = 'game_changed'
      and private
      and payload ? 'version'
      and not payload ? 'players'
  ),
  'mudanças geram aviso privado só com id e versão'
);

select * from finish();
rollback;
