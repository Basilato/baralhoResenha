-- Fase 9: artes das cartas no Storage.
--
-- Bucket privado `card-art` (plano, seção 9.3). Caminhos:
--   <set_version>/<CÓDIGO>.webp         arte inteira (cartas médias e grandes)
--   <set_version>/<CÓDIGO>_thumb.webp   miniatura 512×384 (cartas pequenas)
--
-- Só jogadores com conta ativa leem. Ninguém escreve pela API pública: o upload
-- é feito pelo administrador com a secret key (`pnpm art:upload`), que ignora RLS.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('card-art', 'card-art', false, 2 * 1024 * 1024, array['image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

create policy "card_art_select_active_players"
  on storage.objects
  for select
  to authenticated
  using (
    bucket_id = 'card-art'
    and exists (
      select 1 from public.profiles p
      where p.id = (select auth.uid()) and p.is_active
    )
  );

-- Marca quais cartas já têm arte no Storage (C2: a arte aparece sozinha quando
-- existe; sem ela, o app mostra o placeholder). Cartas fora da lista voltam a
-- não ter arte. Uso exclusivo do administrador (service_role).
create function public.admin_set_card_art(p_set_version text, p_codes text[])
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_unknown text[];
  v_count int;
begin
  select array_agg(u.code order by u.code) into v_unknown
  from unnest(coalesce(p_codes, '{}')) as u (code)
  where not exists (
    select 1 from app_private.card_definitions d
    where d.set_version = p_set_version and d.code = u.code
  );

  if v_unknown is not null then
    raise exception 'Cartas desconhecidas no catálogo %: %', p_set_version, v_unknown;
  end if;

  update app_private.card_definitions d
  set image_path = case
    when d.code = any (coalesce(p_codes, '{}')) then d.set_version || '/' || d.code || '.webp'
  end
  where d.set_version = p_set_version;

  select count(*)::int into v_count
  from app_private.card_definitions d
  where d.set_version = p_set_version and d.image_path is not null;

  return v_count;
end;
$$;

revoke all on function public.admin_set_card_art(text, text[]) from public, anon, authenticated;
grant execute on function public.admin_set_card_art(text, text[]) to service_role;
