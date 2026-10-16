-- Partidas mais dinâmicas.
--
-- 1. Resposta automática quando a decisão não depende de informação secreta:
--    sem cartas na mão, regra que não admite reação, ou escolha forçada
--    (tantas opções quanto cartas a escolher). Quando a pessoa tem cartas mas
--    nenhuma serve, o servidor continua esperando: responder na hora revelaria
--    que ela não tem defesa (a tela dela aceita sozinha, com atraso aleatório).
-- 2. Turno encerra sozinho quando não há mais o que fazer: ações esgotadas (ou
--    mão vazia) e mão dentro do limite. Tudo isso é público, nada vaza.
-- 3. Prazos: turno, resposta e escolha têm tempo limite. Vencido o prazo,
--    qualquer participante envia TIMEOUT e o servidor aplica o padrão
--    (passar, escolher ao acaso, encerrar o turno, não ressuscitar). Sem cron:
--    o banco só confere se o prazo venceu.

-- -----------------------------------------------------------------------------
-- Prazos
-- -----------------------------------------------------------------------------

create function app_private.turn_time_limit()
returns interval language sql immutable set search_path = ''
as $$ select interval '60 seconds' $$;

create function app_private.response_time_limit()
returns interval language sql immutable set search_path = ''
as $$ select interval '20 seconds' $$;

create function app_private.choice_time_limit()
returns interval language sql immutable set search_path = ''
as $$ select interval '30 seconds' $$;

alter table app_private.games add column turn_deadline_at timestamptz;

-- Liga as respostas e o fim de turno automáticos (itens 1 e 2). Sempre ligado
-- nas partidas; os testes de regra desligam para montar mãos vazias à vontade.
alter table app_private.games add column auto_flow boolean not null default true;
alter table app_private.pending_actions add column deadline_at timestamptz;

-- O relógio do turno recomeça a cada turno novo e sempre que a vez volta para
-- quem está jogando (depois de uma jogada resolvida).
create function app_private.set_turn_deadline()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status <> 'playing' or new.phase is null then
    new.turn_deadline_at := null;
  elsif new.phase in ('turn_main', 'turn_ghost', 'ghost_decision')
    and (new.turn_deadline_at is null
         or old.phase is distinct from new.phase
         or old.active_seat is distinct from new.active_seat
         or old.round_number is distinct from new.round_number) then
    new.turn_deadline_at := now() + app_private.turn_time_limit();
  end if;
  return new;
end;
$$;

create trigger games_turn_deadline
  before update on app_private.games
  for each row execute function app_private.set_turn_deadline();

-- Cada estágio da jogada pendente (defesa, devolução, dano próprio, escolha)
-- ganha o seu prazo.
create function app_private.set_pending_deadline()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or old.stage is distinct from new.stage then
    new.deadline_at := now() + case when new.stage = 'choice'
                                    then app_private.choice_time_limit()
                                    else app_private.response_time_limit() end;
  end if;
  return new;
end;
$$;

create trigger pending_actions_deadline
  before insert or update on app_private.pending_actions
  for each row execute function app_private.set_pending_deadline();

revoke execute on function
  app_private.set_turn_deadline(),
  app_private.set_pending_deadline()
from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Respostas automáticas
-- -----------------------------------------------------------------------------

-- Cartas disponíveis para uma escolha (na Terapia de Boteco e no GHO-05, só
-- as cartas oferecidas).
create function app_private.choice_options(p_source uuid, p_option_ids uuid[])
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(c.id order by c.pile_position), array[]::uuid[])
  from app_private.game_cards c
  where c.owner_player_id = p_source and c.zone = 'player_hand'
    and (p_option_ids is null or c.id = any (p_option_ids));
$$;

-- Responde sozinho o que não exige decisão nem revela nada, e resolve a
-- jogada. Repete enquanto houver estágio novo (devolução, dano próprio).
create function app_private.auto_respond(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pending app_private.pending_actions;
  v_row record;
  v_options uuid[];
  v_changed boolean;
begin
  if not (select auto_flow from app_private.games where id = p_game_id) then
    return;
  end if;

  for i in 1..10 loop
    select * into v_pending from app_private.pending_actions
    where game_id = p_game_id and status = 'open';
    exit when not found;

    v_changed := false;

    for v_row in
      select r.*, gp.hp
      from app_private.pending_responses r
      join app_private.game_players gp on gp.id = r.responder_player_id
      where r.pending_action_id = v_pending.id and r.stage = v_pending.stage and r.response is null
      order by gp.seat
    loop
      if v_row.stage = 'choice' then
        -- Escolha forçada: o número de cartas na mão é público.
        v_options := app_private.choice_options(v_row.source_player_id, v_row.option_card_ids);
        continue when cardinality(v_options) <> v_row.choice_count;

        update app_private.pending_responses
        set response = 'choose', selected_card_ids = v_options, responded_at = now()
        where pending_action_id = v_row.pending_action_id
          and responder_player_id = v_row.responder_player_id and role = v_row.role;
        perform app_private.log_event(p_game_id, 'choice_made', v_row.responder_player_id,
          jsonb_build_object('role', v_row.role, 'auto', true));
      else
        -- Sem cartas na mão, ou a regra não admite nenhuma reação.
        continue when app_private.hand_size(v_row.responder_player_id) > 0
          and cardinality(app_private.allowed_reactions(
                v_row.role, v_pending.effect_code, v_row.base_damage, v_row.hp)) > 0;

        update app_private.pending_responses
        set response = 'pass', responded_at = now()
        where pending_action_id = v_row.pending_action_id
          and responder_player_id = v_row.responder_player_id and role = v_row.role;
        perform app_private.log_event(p_game_id, 'response_passed', v_row.responder_player_id,
          jsonb_build_object('role', v_row.role, 'auto', true));
      end if;
      v_changed := true;
    end loop;

    exit when not v_changed;
    perform app_private.resolve_pending(p_game_id);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Fim de turno automático
-- -----------------------------------------------------------------------------

-- Encerra o turno de quem não tem mais o que fazer. Repete porque o próximo
-- também pode não ter (ex.: baralho vazio e mão vazia).
create function app_private.auto_end_turn(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_game app_private.games;
  v_player app_private.game_players;
  v_main integer;
  v_ghost integer;
begin
  for i in 1..20 loop
    select * into v_game from app_private.games where id = p_game_id;
    exit when not v_game.auto_flow or v_game.status <> 'playing' or v_game.pending_action_id is not null;

    select * into v_player from app_private.game_players
    where game_id = p_game_id and seat = v_game.active_seat;

    select count(*) filter (where zone = 'player_hand'), count(*) filter (where zone = 'ghost_hand')
      into v_main, v_ghost
    from app_private.game_cards where owner_player_id = v_player.id;

    exit when not (
      (v_game.phase = 'turn_main'
        and (v_game.actions_used >= app_private.max_actions() or v_main = 0)
        and v_main <= app_private.hand_limit())
      or
      (v_game.phase = 'turn_ghost'
        and (v_game.actions_used >= 1 or v_ghost = 0)
        and v_ghost <= app_private.ghost_hand_limit())
    );

    perform app_private.log_event(p_game_id, 'turn_ended', v_player.id,
      jsonb_build_object('reason', 'auto', 'discarded', '[]'::jsonb,
                         'actionsUsed', v_game.actions_used));
    perform app_private.advance_turn(p_game_id);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Tempo esgotado
-- -----------------------------------------------------------------------------

create function app_private.cmd_timeout(p_game app_private.games)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pending app_private.pending_actions;
  v_row app_private.pending_responses;
  v_player app_private.game_players;
  v_picked uuid[];
  v_zone text;
  v_limit integer;
  v_codes jsonb;
begin
  select * into v_pending from app_private.pending_actions
  where game_id = p_game.id and status = 'open';

  if found then
    if v_pending.deadline_at > now() then
      perform app_private.fail('NOT_EXPIRED', 'Ainda há tempo para responder.');
    end if;

    -- Quem não respondeu passa; quem não escolheu tem a escolha sorteada.
    for v_row in
      select r.* from app_private.pending_responses r
      join app_private.game_players gp on gp.id = r.responder_player_id
      where r.pending_action_id = v_pending.id and r.stage = v_pending.stage and r.response is null
      order by gp.seat
    loop
      if v_row.stage = 'choice' then
        select coalesce(array_agg(x), array[]::uuid[]) into v_picked from (
          select x from unnest(app_private.choice_options(v_row.source_player_id, v_row.option_card_ids)) as x
          order by gen_random_uuid() limit v_row.choice_count
        ) s;
        update app_private.pending_responses
        set response = 'choose', selected_card_ids = v_picked, responded_at = now()
        where pending_action_id = v_row.pending_action_id
          and responder_player_id = v_row.responder_player_id and role = v_row.role;
        perform app_private.log_event(p_game.id, 'choice_made', v_row.responder_player_id,
          jsonb_build_object('role', v_row.role, 'timedOut', true));
      else
        update app_private.pending_responses
        set response = 'pass', responded_at = now()
        where pending_action_id = v_row.pending_action_id
          and responder_player_id = v_row.responder_player_id and role = v_row.role;
        perform app_private.log_event(p_game.id, 'response_passed', v_row.responder_player_id,
          jsonb_build_object('role', v_row.role, 'timedOut', true));
      end if;
    end loop;

    perform app_private.resolve_pending(p_game.id);
    return jsonb_build_object('ok', true);
  end if;

  if p_game.turn_deadline_at is null or p_game.turn_deadline_at > now() then
    perform app_private.fail('NOT_EXPIRED', 'Ainda há tempo para jogar.');
  end if;

  select * into v_player from app_private.game_players
  where game_id = p_game.id and seat = p_game.active_seat;

  -- Ressuscitar é uma escolha: sem resposta, o fantasma fica no Além.
  if p_game.phase = 'ghost_decision' then
    perform app_private.log_event(p_game.id, 'turn_timed_out', v_player.id,
      jsonb_build_object('phase', p_game.phase));
    return app_private.cmd_ghost_decision(p_game, v_player, false);
  end if;

  -- Encerra o turno descartando ao acaso o que passar do limite da mão.
  if v_player.life_status = 'alive' then
    v_zone := 'player_hand';
    v_limit := app_private.hand_limit();
  else
    v_zone := 'ghost_hand';
    v_limit := app_private.ghost_hand_limit();
  end if;

  select coalesce(array_agg(id), array[]::uuid[]) into v_picked from (
    select id from app_private.game_cards
    where owner_player_id = v_player.id and zone = v_zone
    order by gen_random_uuid()
    limit greatest((select count(*) from app_private.game_cards
                    where owner_player_id = v_player.id and zone = v_zone) - v_limit, 0)
  ) s;

  select coalesce(jsonb_agg(c.card_code order by x.ord), '[]'::jsonb) into v_codes
  from unnest(v_picked) with ordinality as x (id, ord)
  join app_private.game_cards c on c.id = x.id;

  perform app_private.discard_cards(p_game.id, v_player.id, v_picked);

  perform app_private.log_event(p_game.id, 'turn_ended', v_player.id,
    jsonb_build_object('reason', 'timeout', 'discarded', v_codes,
                       'actionsUsed', p_game.actions_used));
  perform app_private.advance_turn(p_game.id);
  return jsonb_build_object('ok', true);
end;
$$;

-- -----------------------------------------------------------------------------
-- Envio de comandos (mesmo corpo, com TIMEOUT e os passos automáticos)
-- -----------------------------------------------------------------------------

create or replace function app_private.submit_game_command(
  p_game_id uuid,
  p_expected_version bigint,
  p_request_id uuid,
  p_command jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_user();
  v_game app_private.games := app_private.lock_member_game(p_game_id, v_uid);
  v_player app_private.game_players;
  v_type text := p_command ->> 'type';
  v_receipt jsonb;
  v_result jsonb;
begin
  if p_request_id is null or v_type is null then
    perform app_private.fail('INVALID_COMMAND', 'Jogada inválida.');
  end if;

  select * into v_player from app_private.game_players
  where game_id = p_game_id and user_id = v_uid;

  select result_json into v_receipt
  from app_private.command_receipts
  where game_id = p_game_id and player_id = v_player.id and request_id = p_request_id;

  if found then
    return v_receipt || jsonb_build_object('replayed', true);
  end if;

  if v_game.status <> 'playing' then
    perform app_private.fail('GAME_NOT_ACTIVE', 'Esta partida não está em andamento.');
  end if;

  if v_game.version <> p_expected_version then
    perform app_private.fail('VERSION_CONFLICT', 'A mesa mudou enquanto você jogava. Confira e tente de novo.');
  end if;

  if v_player.life_status = 'quit' then
    perform app_private.fail('PLAYER_QUIT', 'Você foi removido desta partida por ausência.');
  end if;

  -- Responder, remover ausente, assumir host e cobrar o prazo não exigem
  -- estar na vez.
  if v_type not in ('RESPOND', 'REMOVE_ABSENT', 'CLAIM_HOST', 'TIMEOUT')
     and v_player.seat is distinct from v_game.active_seat then
    perform app_private.fail('NOT_YOUR_TURN', 'Agora não é a sua vez.');
  end if;

  case v_type
    when 'END_TURN' then
      if v_game.phase = 'ghost_decision' then
        perform app_private.fail('WRONG_PHASE', 'Decida primeiro se vai ressuscitar.');
      end if;
      v_result := app_private.cmd_end_turn(v_game, v_player, p_command);
    when 'PLAY_CARD' then
      if v_game.phase = 'turn_ghost' then
        v_result := app_private.cmd_play_ghost_card(v_game, v_player, p_command);
      else
        v_result := app_private.cmd_play_card(v_game, v_player, p_command);
      end if;
    when 'RESPOND' then
      v_result := app_private.cmd_respond(v_game, v_player, p_command);
    when 'GHOST_REVIVE' then
      v_result := app_private.cmd_ghost_decision(v_game, v_player, true);
    when 'GHOST_STAY' then
      v_result := app_private.cmd_ghost_decision(v_game, v_player, false);
    when 'REMOVE_ABSENT' then
      v_result := app_private.cmd_remove_absent(v_game, v_player, p_command);
    when 'CLAIM_HOST' then
      v_result := app_private.cmd_claim_host(v_game, v_player);
    when 'TIMEOUT' then
      v_result := app_private.cmd_timeout(v_game);
    else
      perform app_private.fail('INVALID_COMMAND', 'Jogada inválida.');
  end case;

  -- Respostas que não dependem de ninguém, depois o fim do turno de quem não
  -- tem mais o que fazer. Mortes, ressurreições e remoções podem decidir a
  -- partida em qualquer passo.
  perform app_private.auto_respond(p_game_id);
  if not app_private.check_game_end(p_game_id) then
    perform app_private.auto_end_turn(p_game_id);
    perform app_private.check_game_end(p_game_id);
  end if;

  v_result := v_result || jsonb_build_object('version', app_private.touch_game(p_game_id));

  insert into app_private.command_receipts (game_id, player_id, request_id, command_type, result_json)
  values (p_game_id, v_player.id, p_request_id, v_type, v_result);

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- Visão: prazos (com o relógio do servidor, para a tela corrigir a diferença)
-- -----------------------------------------------------------------------------

create function app_private.timers_view(p_game_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'serverNow', now(),
    'turnDeadlineAt', g.turn_deadline_at,
    'responseDeadlineAt', (
      select pa.deadline_at from app_private.pending_actions pa
      where pa.game_id = g.id and pa.status = 'open'
    ),
    'turnLimitSeconds', extract(epoch from app_private.turn_time_limit())::int,
    'responseLimitSeconds', extract(epoch from app_private.response_time_limit())::int,
    'choiceLimitSeconds', extract(epoch from app_private.choice_time_limit())::int
  )
  from app_private.games g
  where g.id = p_game_id;
$$;

create or replace function app_private.get_game_view(p_game_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_user();
  v_player uuid;
begin
  select id into v_player from app_private.game_players
  where game_id = p_game_id and user_id = v_uid;

  if v_player is null then
    perform app_private.fail('ROOM_NOT_FOUND', 'Sala não encontrada ou você não faz parte dela.');
  end if;

  return app_private.game_view(p_game_id, v_uid)
    || app_private.pending_view(p_game_id, v_player)
    || app_private.extras_view(p_game_id, v_player)
    || app_private.timers_view(p_game_id);
end;
$$;

revoke execute on function
  app_private.turn_time_limit(),
  app_private.response_time_limit(),
  app_private.choice_time_limit(),
  app_private.choice_options(uuid, uuid[]),
  app_private.auto_respond(uuid),
  app_private.auto_end_turn(uuid),
  app_private.cmd_timeout(app_private.games),
  app_private.timers_view(uuid)
from public, anon, authenticated;

-- Partidas já em andamento ganham os prazos a partir de agora.
update app_private.games set turn_deadline_at = now() + app_private.turn_time_limit()
where status = 'playing' and phase is not null;
update app_private.pending_actions set deadline_at = now() + app_private.response_time_limit()
where status = 'open';
