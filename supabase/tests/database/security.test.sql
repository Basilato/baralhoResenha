-- Fase 10: auditoria de segurança da superfície exposta.
-- Se uma função nova for exposta, ou uma tabela perder a RLS, este teste quebra
-- de propósito: a mudança tem de ser revisada e a lista abaixo atualizada.
begin;
create extension if not exists pgtap with schema extensions;

select plan(27);

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

-- Partida iniciada com 1, 2 e 3. O 9 é o intruso.
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
select pg_temp.login('1');
select public.start_game((select v::uuid from t where k = 'game'),
  (public.get_room_view((select v::uuid from t where k = 'game')) ->> 'version')::bigint);
set local role postgres;

create function pg_temp.g() returns uuid language sql stable as $$ select v::uuid from t where k = 'game' $$;
grant execute on function pg_temp.g() to authenticated;

-- 1. Funções expostas -----------------------------------------------------------

select is(
  array(
    select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and has_function_privilege('authenticated', p.oid, 'execute')
    order by 1
  ),
  array[
    'allow_rejoin(p_game_id uuid, p_user_id uuid)',
    'close_room(p_game_id uuid)',
    'create_rematch(p_game_id uuid)',
    'create_room()',
    'get_card_catalog(p_set_version text)',
    'get_game_view(p_game_id uuid)',
    'get_room_view(p_game_id uuid)',
    'heartbeat(p_game_id uuid)',
    'join_rematch(p_game_id uuid)',
    'join_room(p_code text)',
    'kick_player(p_game_id uuid, p_player_id uuid)',
    'leave_room(p_game_id uuid)',
    'list_my_rooms()',
    'rotate_room_code(p_game_id uuid)',
    'set_ready(p_game_id uuid, p_ready boolean)',
    'start_game(p_game_id uuid, p_expected_version bigint)',
    'submit_game_command(p_game_id uuid, p_expected_version bigint, p_request_id uuid, p_command jsonb)'
  ],
  'jogadores executam exatamente estas RPCs públicas'
);

select is(
  array(
    select p.proname::text
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app_private' and has_function_privilege('authenticated', p.oid, 'execute')
      and p.proname not in (
        select p2.proname from pg_proc p2 join pg_namespace n2 on n2.oid = p2.pronamespace
        where n2.nspname = 'public'
      )
    order by 1
  ),
  array['can_use_game_topic'],
  'em app_private, além das RPCs, só a checagem de tópico do Realtime'
);

select is(
  (select count(*)::int
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'app_private')
     and has_function_privilege('anon', p.oid, 'execute')),
  0, 'visitante sem login não executa nenhuma função do app');

select is(
  (select count(*)::int
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('authenticated', p.oid, 'execute')
     and p.prosecdef),
  0, 'RPCs públicas são security invoker (o privilégio fica só em app_private)');

select is(
  (select count(*)::int
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app_private' and p.prosecdef
     and not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')),
  0, 'toda função security definer fixa o search_path');

select ok(has_function_privilege('service_role', 'public.admin_set_card_art(text, text[])', 'execute')
  and not has_function_privilege('authenticated', 'public.admin_set_card_art(text, text[])', 'execute'),
  'funções de admin só para service_role');

-- 2. Tabelas --------------------------------------------------------------------

select is(
  array(
    select n.nspname || '.' || c.relname
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('public', 'app_private') and c.relkind in ('r', 'p')
      and not c.relrowsecurity
  ),
  array[]::text[], 'RLS ligada em todas as tabelas do app');

select is(
  array(
    select n.nspname || '.' || c.relname || ':' || r.role || ':' || pr.priv
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    cross join (values ('anon'), ('authenticated')) r (role)
    cross join (values ('select'), ('insert'), ('update'), ('delete'), ('truncate')) pr (priv)
    where n.nspname = 'app_private' and c.relkind in ('r', 'p', 'v', 'm')
      and has_table_privilege(r.role, c.oid, pr.priv)
  ),
  array[]::text[], 'nenhuma tabela de app_private é acessível direto pela API');

select ok(not has_schema_privilege('anon', 'app_private', 'usage'),
  'visitante nem enxerga o esquema app_private');

-- 3. Intruso numa partida em andamento ------------------------------------------

select pg_temp.login('9');
select throws_ok($$ select public.get_game_view(pg_temp.g()) $$,
  'P0001', 'ROOM_NOT_FOUND', 'intruso não vê a mesa');
select throws_ok($$ select public.get_room_view(pg_temp.g()) $$,
  'P0001', 'ROOM_NOT_FOUND', 'intruso não vê a sala');
select throws_ok(
  $$ select public.submit_game_command(pg_temp.g(), 1, gen_random_uuid(), '{"type": "END_TURN"}') $$,
  'P0001', 'ROOM_NOT_FOUND', 'intruso não joga');
select throws_ok($$ select public.heartbeat(pg_temp.g()) $$,
  'P0001', 'ROOM_NOT_FOUND', 'intruso não marca presença');
select throws_ok($$ select public.close_room(pg_temp.g()) $$,
  'P0001', 'ROOM_NOT_FOUND', 'intruso não encerra');
select throws_ok($$ select public.create_rematch(pg_temp.g()) $$,
  'P0001', 'ROOM_NOT_FOUND', 'intruso não cria revanche');
select throws_ok($$ select public.join_rematch(pg_temp.g()) $$,
  'P0001', 'ROOM_NOT_FOUND', 'intruso não entra na revanche');
select ok(not app_private.can_use_game_topic('game:' || pg_temp.g()), 'intruso não assina o canal');
select is((select count(*)::int from realtime.messages where topic = 'game:' || pg_temp.g()), 0,
  'intruso não lê mensagens do canal');
set local role postgres;

select pg_temp.login('2');
select ok(app_private.can_use_game_topic('game:' || pg_temp.g()), 'jogador da mesa assina o canal');
select ok(not app_private.can_use_game_topic('game:nao-e-uuid'), 'tópico malformado é recusado');
set local role postgres;

-- 4. Realtime nunca carrega estado ----------------------------------------------

select is(
  array(
    select n.nspname || '.' || p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'app_private') and p.prosrc ilike '%realtime.send%'
  ),
  array['app_private.touch_game'],
  'só touch_game publica no Realtime');

select ok((select count(*) from realtime.messages where topic = 'game:' || pg_temp.g()) > 0,
  'a partida publicou avisos');

select is(
  (select count(*)::int from realtime.messages
   where topic = 'game:' || pg_temp.g()
     -- "id" é o identificador da mensagem, que o próprio realtime.send acrescenta.
     and array(select jsonb_object_keys(payload) order by 1) <> array['game_id', 'id', 'version']),
  0, 'todo aviso carrega só game_id e version (nunca cartas)');

select is(
  (select count(*)::int from realtime.messages
   where topic = 'game:' || pg_temp.g() and not private),
  0, 'avisos da partida só em canal privado');

-- 5. Cada um vê só a própria mão ------------------------------------------------

create function pg_temp.leaks(p_uid text)
returns int
language plpgsql
as $$
declare
  v_view text;
  v_player uuid := (
    select id from app_private.game_players
    where game_id = pg_temp.g() and user_id = ('00000000-0000-4000-8000-00000000000' || p_uid)::uuid
  );
begin
  perform pg_temp.login(p_uid);
  v_view := public.get_game_view(pg_temp.g())::text;
  perform set_config('role', 'postgres', true);
  return (
    select count(*)::int from app_private.game_cards c
    where c.game_id = pg_temp.g()
      and not (c.owner_player_id = v_player and c.zone in ('player_hand', 'ghost_hand'))
      and strpos(v_view, c.id::text) > 0
  );
end;
$$;

select is(pg_temp.leaks('1'), 0, 'jogador 1 não recebe id de carta alheia ou do monte');
select is(pg_temp.leaks('2'), 0, 'jogador 2 não recebe id de carta alheia ou do monte');
select is(pg_temp.leaks('3'), 0, 'jogador 3 não recebe id de carta alheia ou do monte');

select * from finish();
rollback;
