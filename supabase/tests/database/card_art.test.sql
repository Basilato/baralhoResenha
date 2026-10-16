begin;
create extension if not exists pgtap with schema extensions;

select plan(12);

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

-- Bucket ---------------------------------------------------------------------

select is((select public from storage.buckets where id = 'card-art'), false, 'bucket card-art é privado');
select is((select allowed_mime_types from storage.buckets where id = 'card-art'),
  array['image/webp'], 'bucket aceita só WebP');

-- Objeto de teste (só metadados; o arquivo em si não importa para a RLS).
insert into storage.objects (bucket_id, name) values ('card-art', '7.1/TESTE.webp');

select pg_temp.login('1');
select is((select count(*)::int from storage.objects where bucket_id = 'card-art'
           and name = '7.1/TESTE.webp'), 1, 'jogador ativo lê a arte');

select throws_ok(
  $$ insert into storage.objects (bucket_id, name) values ('card-art', '7.1/INVASOR.webp') $$,
  '42501', null, 'jogador não envia arte');

update storage.objects set name = '7.1/RENOMEADA.webp' where bucket_id = 'card-art';
set local role postgres;
select is((select count(*)::int from storage.objects where bucket_id = 'card-art'
           and name = '7.1/TESTE.webp'), 1, 'jogador não renomeia arte');

update public.profiles set is_active = false where id = '00000000-0000-4000-8000-000000000002';
select pg_temp.login('2');
select is((select count(*)::int from storage.objects where bucket_id = 'card-art'), 0,
  'conta desativada não lê arte');

set local role anon;
select is((select count(*)::int from storage.objects where bucket_id = 'card-art'), 0,
  'visitante sem login não lê arte');

-- admin_set_card_art ---------------------------------------------------------

set local role postgres;
select pg_temp.login('1');
select throws_ok(
  $$ select public.admin_set_card_art('7.1', array['ATK-01']) $$,
  '42501', null, 'jogador não chama admin_set_card_art');

set local role service_role;
select is(public.admin_set_card_art('7.1', array['ATK-01', 'GHO-02']), 2,
  'service_role marca as cartas com arte');

set local role postgres;
select is((select image_path from app_private.card_definitions
           where set_version = '7.1' and code = 'GHO-02'), '7.1/GHO-02.webp',
  'image_path segue o padrão <versão>/<código>.webp');

set local role service_role;
select public.admin_set_card_art('7.1', array['GHO-02']);
set local role postgres;
select is((select image_path from app_private.card_definitions
           where set_version = '7.1' and code = 'ATK-01'), null,
  'carta fora da lista volta a não ter arte');

set local role service_role;
select throws_like(
  $$ select public.admin_set_card_art('7.1', array['ATK-01', 'XYZ-99']) $$,
  '%XYZ-99%', 'código desconhecido é recusado');

select * from finish();
rollback;
