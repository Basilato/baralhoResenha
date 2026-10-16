-- Fase 10: a checagem de integridade aceita partidas sãs e acusa cada tipo de
-- corrupção. (As simulações dependem dela para achar bugs do motor.)
begin;
create extension if not exists pgtap with schema extensions;

select plan(11);

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
grant select, insert, update on t to authenticated;

select pg_temp.login('1');
insert into t values ('game', public.create_room() ->> 'id');
insert into t values ('code', public.get_room_view((select v::uuid from t where k = 'game')) ->> 'code');
set local role postgres;
select pg_temp.login('2');
select public.join_room((select v from t where k = 'code'));
set local role postgres;
select pg_temp.login('3');
select public.join_room((select v from t where k = 'code'));
set local role postgres;

create function pg_temp.g() returns uuid language sql stable as $$ select v::uuid from t where k = 'game' $$;
grant execute on function pg_temp.g() to authenticated;
create function pg_temp.problems() returns text
language sql as $$ select array_to_string(app_private.check_game_integrity(pg_temp.g()), ' | ') $$;

select is(pg_temp.problems(), '', 'sala no lobby não tem o que conferir');

select pg_temp.login('1');
select public.start_game(pg_temp.g(), (public.get_room_view(pg_temp.g()) ->> 'version')::bigint);
set local role postgres;

select is(pg_temp.problems(), '', 'partida recém-iniciada está íntegra');

-- Cada corrupção num savepoint, desfeita depois.
savepoint s;
delete from app_private.game_cards
where id = (select id from app_private.game_cards where game_id = pg_temp.g() and zone = 'main_deck' limit 1);
select matches(pg_temp.problems(), 'cópias erradas', 'carta sumida');
rollback to savepoint s;

savepoint s;
update app_private.game_cards set card_code = 'ATK-01'
where id = (select id from app_private.game_cards where game_id = pg_temp.g() and card_code = 'DEF-01' limit 1);
select matches(pg_temp.problems(), 'ATK-01: 11 de 10', 'carta trocada por outra');
rollback to savepoint s;

savepoint s;
update app_private.game_players set life_status = 'ghost', hp = 0
where game_id = pg_temp.g() and seat = 2;
select matches(pg_temp.problems(), 'mão de quem não pode ter', 'fantasma com mão principal');
rollback to savepoint s;

savepoint s;
update app_private.game_players set hp = 0 where game_id = pg_temp.g() and seat = 3;
select matches(pg_temp.problems(), 'vivos com 0 PV', 'vivo com 0 PV');
rollback to savepoint s;

savepoint s;
update app_private.game_players set ghost_tokens = 4 where game_id = pg_temp.g() and seat = 3;
select matches(pg_temp.problems(), 'mais de 3 fichas', 'fichas demais');
rollback to savepoint s;

savepoint s;
update app_private.games set phase = 'awaiting_reactions' where id = pg_temp.g();
select matches(pg_temp.problems(), 'não combina com a jogada pendente', 'fase sem jogada pendente');
rollback to savepoint s;

savepoint s;
update app_private.games set phase = 'turn_ghost' where id = pg_temp.g();
select matches(pg_temp.problems(), 'não combina com quem está na vez', 'vez de fantasma para um vivo');
rollback to savepoint s;

savepoint s;
update app_private.games set status = 'finished', finished_at = now(), result_json = null
where id = pg_temp.g();
select matches(pg_temp.problems(), 'encerrada sem resultado', 'fim sem vencedor');
rollback to savepoint s;

select ok(
  not has_function_privilege('authenticated', 'public.admin_check_game_integrity(uuid)', 'execute')
  and has_function_privilege('service_role', 'public.admin_check_game_integrity(uuid)', 'execute'),
  'só o administrador roda a checagem');

select * from finish();
rollback;
