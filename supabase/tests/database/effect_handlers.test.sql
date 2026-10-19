-- Motor em handlers: toda carta jogável tem handler, cada handler tem a
-- assinatura do seu ponto de extensão, e o núcleo não volta a conhecer efeitos.
-- Carta nova sem handler registrado quebra este teste antes de ir para a mesa.
begin;
create extension if not exists pgtap with schema extensions;

select plan(8);

-- Assinatura esperada de cada ponto de extensão.
create temp table expected_signature (hook text primary key, args text, returns text);
insert into expected_signature values
  ('validate', 'app_private.games, app_private.game_players, app_private.game_cards, app_private.card_definitions, uuid[], jsonb', 'void'),
  ('play', 'app_private.games, app_private.game_players, app_private.game_cards, app_private.card_definitions, uuid[], jsonb, text', 'jsonb'),
  ('resolve', 'app_private.pending_actions', 'boolean'),
  ('after_damage', 'app_private.pending_actions', 'boolean'),
  ('finish', 'app_private.pending_actions', 'void'),
  ('choices', 'app_private.pending_actions', 'void');

select is_empty(
  $$ select d.set_version || ' ' || d.code from app_private.card_definitions d
     where d.enabled and not d.is_reaction
       and app_private.effect_handler(d.effect_code, 'play') is null $$,
  'toda carta jogável tem handler de jogada');

select is_empty(
  $$ select d.set_version || ' ' || d.code from app_private.card_definitions d
     where d.enabled and d.category = 'sabotage'
       and app_private.effect_handler(d.effect_code, 'resolve') is null $$,
  'toda sabotagem tem handler de resolução (sem ele, a carta não faria nada)');

select is_empty(
  $$ select h.effect_code || ' ' || h.hook from app_private.card_effect_handlers h
     where not exists (select 1 from app_private.card_definitions d where d.effect_code = h.effect_code) $$,
  'nenhum handler registrado para efeito que não existe (erro de digitação)');

select is_empty(
  $$ select h.effect_code || ' ' || h.hook || ': ' || h.handler::text
     from app_private.card_effect_handlers h
     join expected_signature s on s.hook = h.hook
     join pg_proc p on p.oid = h.handler::oid
     where oidvectortypes(p.proargtypes) <> s.args
        or pg_get_function_result(p.oid) <> s.returns $$,
  'cada handler tem a assinatura do seu ponto de extensão');

select is_empty(
  $$ select h.handler::text from app_private.card_effect_handlers h
     join pg_proc p on p.oid = h.handler::oid
     where not p.prosecdef
        or not coalesce('search_path=""' = any (p.proconfig), false) $$,
  'handlers rodam como security definer com search_path vazio');

-- O núcleo não decide nada pelo effect_code: só o usa para achar o handler.
-- (Pega "effect_code = 'x'", "effect_code in (...)" e "case ... effect_code".)
select is_empty(
  $$ select p.proname
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'app_private'
     where p.proname in ('cmd_play_card', 'cmd_play_ghost_card', 'resolve_sabotage',
                         'resolve_pending', 'finish_pending', 'apply_choices')
       and pg_get_functiondef(p.oid)
           ~* 'effect_code\s*(=|<>|!=|in\s*\()|case\s+[a-z_.]*effect_code' $$,
  'o núcleo do motor não tem nenhum efeito de carta escrito à mão');

select ok(
  not has_table_privilege('authenticated', 'app_private.card_effect_handlers', 'select')
  and not has_table_privilege('anon', 'app_private.card_effect_handlers', 'select'),
  'o registro de handlers não é legível pelo navegador');

select ok(
  not has_function_privilege('authenticated', 'app_private.play_attack(app_private.games, app_private.game_players, app_private.game_cards, app_private.card_definitions, uuid[], jsonb, text)', 'execute'),
  'handlers não podem ser chamados direto pelo navegador');

select * from finish();
rollback;
