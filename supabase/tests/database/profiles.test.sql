begin;
create extension if not exists pgtap with schema extensions;

select plan(21);

-- Estrutura -------------------------------------------------------------------

select has_table('public', 'profiles', 'tabela profiles existe');
select ok(
  (select relrowsecurity from pg_class where oid = 'public.profiles'::regclass),
  'RLS ativa em profiles'
);
select ok(
  not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'profiles'
      and column_name in ('password', 'email', 'encrypted_password')
  ),
  'profiles não guarda senha nem e-mail'
);

-- Trigger de provisionamento --------------------------------------------------

insert into auth.users (id, email, raw_app_meta_data)
values (
  '11111111-1111-4111-8111-111111111111',
  'pgtap_a@contas.baralhoresenha.test',
  '{"username": "PgTap_A", "display_name": "Pg Tap A"}'
);
insert into auth.users (id, email, raw_app_meta_data)
values (
  '22222222-2222-4222-8222-222222222222',
  'pgtap_b@contas.baralhoresenha.test',
  '{"username": "pgtap_b"}'
);

select is(
  (select username from public.profiles where id = '11111111-1111-4111-8111-111111111111'),
  'pgtap_a',
  'username é normalizado para minúsculas'
);

-- Fluxo real do Auth: cria o usuário e só depois grava o app_metadata.
insert into auth.users (id, email, raw_app_meta_data)
values ('33333333-3333-4333-8333-333333333333', 'pgtap_c@contas.baralhoresenha.test', '{}');

select ok(
  not exists (select 1 from public.profiles where id = '33333333-3333-4333-8333-333333333333'),
  'conta sem username fica sem perfil'
);

update auth.users
set raw_app_meta_data = '{"username": "pgtap_c", "display_name": "Pg Tap C"}'
where id = '33333333-3333-4333-8333-333333333333';

select is(
  (select username from public.profiles where id = '33333333-3333-4333-8333-333333333333'),
  'pgtap_c',
  'perfil nasce quando o admin define o username'
);

update auth.users
set raw_app_meta_data = '{"username": "trocado"}'
where id = '33333333-3333-4333-8333-333333333333';

select is(
  (select username from public.profiles where id = '33333333-3333-4333-8333-333333333333'),
  'pgtap_c',
  'mudar app_metadata depois não troca o username'
);

select throws_ok(
  $$ insert into auth.users (id, email, raw_app_meta_data)
     values ('55555555-5555-4555-8555-555555555555', 'y@contas.baralhoresenha.test',
             '{"username": "com espaço"}') $$,
  '23514',
  null,
  'username inválido é recusado'
);

insert into auth.users (id, email, raw_app_meta_data)
values ('66666666-6666-4666-8666-666666666666', 'pgtap_d@contas.baralhoresenha.test',
        '{"username": "pgtap_d", "display_name": "   "}');

select is(
  (select display_name from public.profiles where id = '66666666-6666-4666-8666-666666666666'),
  'pgtap_d',
  'apelido vazio cai para o username'
);

-- Privilégios padrão ----------------------------------------------------------

create function public.pgtap_nova_funcao() returns int language sql as 'select 1';

select ok(
  not has_function_privilege('anon', 'public.pgtap_nova_funcao()', 'execute'),
  'funções novas em public não ficam executáveis por anon'
);
select ok(
  not has_function_privilege('authenticated', 'public.pgtap_nova_funcao()', 'execute'),
  'funções novas em public exigem grant explícito para authenticated'
);
select ok(
  not has_schema_privilege('authenticated', 'app_private', 'usage'),
  'authenticated não acessa o schema app_private'
);

-- Anônimo não lê nada ---------------------------------------------------------

set local role anon;
select throws_ok(
  $$ select * from public.profiles $$,
  '42501',
  null,
  'anon não tem acesso a profiles'
);
reset role;

-- Autenticado como A ----------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "11111111-1111-4111-8111-111111111111", "role": "authenticated"}', true);

select ok(
  (select count(*) from public.profiles where id in (
    '11111111-1111-4111-8111-111111111111',
    '22222222-2222-4222-8222-222222222222'
  )) = 2,
  'autenticado lê perfis'
);

update public.profiles set display_name = 'Novo Nome'
where id = '11111111-1111-4111-8111-111111111111';
select is(
  (select display_name from public.profiles where id = '11111111-1111-4111-8111-111111111111'),
  'Novo Nome',
  'usuário altera o próprio apelido'
);

update public.profiles set display_name = 'Hackeado'
where id = '22222222-2222-4222-8222-222222222222';
select is(
  (select display_name from public.profiles where id = '22222222-2222-4222-8222-222222222222'),
  'pgtap_b',
  'usuário não altera perfil alheio'
);

select throws_ok(
  $$ select is_admin from public.profiles $$,
  '42501',
  null,
  'is_admin não é legível pelo navegador'
);

select ok(
  (select count(*) from public.profiles) >= 2,
  'count(*) funciona com grant por coluna'
);

select throws_ok(
  $$ update public.profiles set username = 'outro' where id = '11111111-1111-4111-8111-111111111111' $$,
  '42501',
  null,
  'username é imutável pelo cliente'
);

select throws_ok(
  $$ update public.profiles set is_admin = true where id = '11111111-1111-4111-8111-111111111111' $$,
  '42501',
  null,
  'usuário não se promove a admin'
);

select throws_ok(
  $$ insert into public.profiles (id, username, display_name)
     values ('44444444-4444-4444-8444-444444444444', 'intruso', 'Intruso') $$,
  '42501',
  null,
  'cliente não cria perfis'
);

reset role;

select * from finish();
rollback;
